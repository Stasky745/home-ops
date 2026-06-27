# homelab

Personal Kubernetes homelab cluster managed with [Talos Linux](https://www.talos.dev/) and [FluxCD](https://fluxcd.io/).

## Architecture

Three-node Kubernetes cluster where all nodes run as control planes with scheduling enabled. Cluster state is managed via GitOps using FluxCD, which watches the `kubernetes/` directory and reconciles the cluster to match what is committed here.

| Layer | Tool |
|---|---|
| OS | Talos Linux |
| Kubernetes | Managed by talhelper + talosctl |
| GitOps | FluxCD |
| Secrets | SOPS + age |
| Tasks | go-task |
| Dev environment | Nix + direnv |

## Repository Structure

```
.
├── .tasks/
│   └── talos.yaml          # Talos task definitions
├── kubernetes/
│   ├── apps/               # Applications, organised by namespace
│   │   ├── kustomization.yaml              # Lists active namespaces
│   │   └── <namespace>/
│   │       ├── namespace.yaml
│   │       ├── kustomization.yaml          # Lists apps in this namespace
│   │       └── <app>/
│   │           ├── ks.yaml                 # Flux Kustomization CR (per-app reconciliation)
│   │           └── app/
│   │               ├── kustomization.yaml
│   │               ├── ocirepository.yaml  # Pins chart version
│   │               └── helmrelease.yaml
│   ├── components/         # Reusable Kustomize components (volsync, alerts, etc.)
│   └── flux/
│       └── apps.yaml       # cluster-apps Kustomization CR watching kubernetes/apps
├── talos/
│   ├── clusterconfig/      # Generated node configs + kubeconfig (gitignored)
│   ├── nodes.env           # Node IPs and names (gitignored)
│   ├── nodes.env.example   # Template for nodes.env
│   ├── schematic.yaml      # Talos image extensions
│   ├── talos_schematics.json
│   ├── talconfig.yaml      # Cluster config (gitignored)
│   ├── talconfig.yaml.example  # Template for talconfig.yaml
│   └── talsecret.sops.yaml # Encrypted cluster secrets
├── .envrc                  # Sets KUBECONFIG and SOPS_AGE_KEY_FILE
├── .sops.yaml              # SOPS encryption rules
├── Taskfile.yaml           # Root task runner
└── flake.nix               # Nix dev environment
```

## Prerequisites

The Nix flake provides all required tools. After cloning, run:

```sh
task init
```

This installs all tools from `flake.nix` into your Nix profile and allows direnv. If you are not using Nix, install the following manually:

- [talhelper](https://github.com/budimanjojo/talhelper)
- [talosctl](https://www.talos.dev/latest/reference/cli/)
- [kubectl](https://kubernetes.io/docs/tasks/tools/)
- [go-task](https://taskfile.dev/)
- [sops](https://getsops.io/)
- [age](https://github.com/FiloSottile/age)
- [direnv](https://direnv.net/)

## Initial Setup

### 1. Configure secrets and node values

```sh
cp talos/talconfig.yaml.example talos/talconfig.yaml
cp talos/nodes.env.example talos/nodes.env
```

Fill in both files with your cluster values. Neither file is committed.

You also need an age key for SOPS:

```sh
age-keygen -o age.key
```

Update the public key in `.sops.yaml`, then re-encrypt `talsecret.sops.yaml` or generate a new one with talhelper.

### 2. Generate node configs

```sh
task talos:generate
```

This produces per-node config files in `talos/clusterconfig/`.

### 3. Boot nodes

Download the Talos ISO matching your schematic from [factory.talos.dev](https://factory.talos.dev) and boot each node from it. Nodes will start in maintenance mode.

### 4. Apply config to each node

```sh
task talos:apply:maintenance NODE=<hostname>
```

Repeat for each node. If a node does not reboot automatically after apply:

```sh
talosctl reboot --nodes <node-ip> --talosconfig talos/clusterconfig/talosconfig
```

### 5. Bootstrap the cluster

Run once, on any single node, after all nodes have config applied:

```sh
task talos:bootstrap
```

### 6. Fetch kubeconfig

```sh
task talos:kubeconfig
```

This writes the kubeconfig to `talos/clusterconfig/kubeconfig`. The `.envrc` sets `KUBECONFIG` to this path automatically when inside the repo directory.

### 7. Bootstrap FluxCD

Flux is managed via the **Flux Operator**. The initial bootstrap is a two-step one-time process:

```sh
# Step 1 — install the Flux Operator
helm install flux-operator oci://ghcr.io/controlplaneio-fluxcd/charts/flux-operator \
  --namespace flux-system --create-namespace

# Step 2 — push the repo (including kubernetes/apps/flux-system/) then let Flux
# pick up the flux-instance HelmRelease, which creates the FluxInstance CR and
# has the operator take over managing the Flux controllers.
```

After the FluxInstance is healthy, Flux is fully GitOps-managed. To upgrade Flux, bump `instance.distribution.version` in `kubernetes/apps/flux-system/flux-instance/app/helmrelease.yaml` and commit.

### Cleanup after initial bootstrap

Once the FluxInstance is healthy and the operator is managing Flux, remove the legacy bootstrap files:

```sh
git rm -r kubernetes/flux-system kubernetes/kustomization.yaml
git commit -m "chore: remove flux bootstrap artifacts after migration to flux-operator"
git push
```

## Day-2 Operations

### Apply a config change to a node

```sh
task talos:apply NODE=<hostname>
```

### Apply to all nodes

```sh
task talos:apply:all
```

### Upgrade Talos on a node

```sh
task talos:upgrade NODE=<hostname>
```

### Check cluster health

```sh
task talos:health
```

### Open the Talos dashboard for a node

```sh
task talos:dashboard NODE=<hostname>
```

## Adding Applications

See [CLAUDE.md](CLAUDE.md) for conventions on structuring new applications under `kubernetes/apps/`.

## Task Reference

| Task | Description |
|---|---|
| `task init` | Install tools and allow direnv (run once) |
| `task talos:generate` | Generate node configs from talconfig.yaml |
| `task talos:apply NODE=<n>` | Apply config to a running node |
| `task talos:apply:maintenance NODE=<n>` | Apply config to a node in maintenance mode |
| `task talos:apply:all` | Apply config to all nodes |
| `task talos:bootstrap` | Bootstrap the cluster (once) |
| `task talos:kubeconfig` | Fetch kubeconfig |
| `task talos:health` | Check cluster health |
| `task talos:dashboard NODE=<n>` | Open Talos dashboard for a node |
| `task talos:upgrade NODE=<n>` | Upgrade Talos on a node |
