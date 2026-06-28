# CLAUDE.md

This file tells Claude how to work in this repository.

## Critical Rules

- **Never apply changes directly.** Always provide commands for the user to run and wait for confirmation. Do not run `talosctl apply-config`, `kubectl apply`, `flux reconcile`, or any command that mutates cluster state.
- **Never commit sensitive information.** Node IPs, hostnames, network topology, kubeconfigs, and age keys must never appear in committed files. When in doubt, check `.gitignore`.
- **No hardcoded values.** IPs, node names, and cluster-specific values live in gitignored files (`talos/nodes.env`, `talos/talconfig.yaml`). Taskfile tasks and Kubernetes manifests must remain reusable across different environments.
- **Keep documentation up to date.** When adding tasks, changing repo structure, or introducing new conventions, update `README.md` and this file as part of the same change.

## What Is Gitignored (and Why)

| Path | Reason |
|---|---|
| `age.key` | Private age key — never commit |
| `*.iso` | Large binary files |
| `talos/clusterconfig/` | Generated node configs contain secrets; kubeconfig contains cluster credentials |
| `talos/talconfig.yaml` | Contains node IPs and hostnames |
| `talos/nodes.env` | Contains node IPs, hostnames, and cluster name |

Every gitignored config file has a committed `.example` counterpart as a template.

## Repo Structure

```
.tasks/talos.yaml                              # All Talos task definitions (included by root Taskfile)
kubernetes/apps/                               # Applications organised by namespace → app
kubernetes/apps/flux-system/flux-operator/     # Flux Operator (manages Flux upgrades)
kubernetes/apps/flux-system/flux-instance/     # FluxInstance CR (configures Flux itself)
kubernetes/components/                         # Reusable Kustomize components (opt-in per app)
kubernetes/flux/apps.yaml                      # cluster-apps Kustomization CR watching kubernetes/apps
talos/                                         # All Talos configuration
Taskfile.yaml                                  # Root: loads dotenv, includes .tasks/*
.envrc                                         # Sets KUBECONFIG and SOPS_AGE_KEY_FILE via direnv
.sops.yaml                                     # SOPS encryption rules (safe to commit — public key only)
```

Flux is managed via the **Flux Operator** pattern:
- `flux-operator` HelmRelease installs/upgrades the operator itself
- `flux-instance` HelmRelease creates the `FluxInstance` CR that configures which Flux controllers run and where they sync from
- The FluxInstance watches `kubernetes/flux/` as its root sync path; `kubernetes/flux/apps.yaml` is the entry point that points Flux at `kubernetes/apps/`
- To upgrade Flux: bump `instance.distribution.version` (or the tag in `flux-operator/app/ocirepository.yaml`) and commit

Cilium is deployed via a `HelmRelease` in `kubernetes/apps/kube-system/cilium/`. Its `ks.yaml` uses `postBuild.substituteFrom` referencing a `cluster-settings` ConfigMap in `flux-system`. This ConfigMap is **not committed** — it is created once during bootstrap via `task kubernetes:bootstrap-cilium` and holds the `CLUSTER_VIP` value. Without it, Flux will hold the Cilium Kustomization in a pending state (this is intentional — it prevents Cilium from deploying before the Talos CNI migration is done).

## Talos Operations

Node values come from `talos/nodes.env` (gitignored). Tasks are defined in `.tasks/talos.yaml` and namespaced under `talos:`.

Always check health before and after making changes:
```sh
task talos:health
```

After editing `talos/talconfig.yaml`, regenerate configs before applying:
```sh
task talos:generate
task talos:apply NODE=<hostname>
```

Never edit files inside `talos/clusterconfig/` directly — they are generated.

## Kubernetes / FluxCD Conventions

### App structure

Applications live under `kubernetes/apps/<namespace>/<app-name>/`. A typical app looks like:

```
kubernetes/apps/
└── <namespace>/
    ├── namespace.yaml          # Namespace manifest (if not managed elsewhere)
    └── <app-name>/
        ├── kustomization.yaml  # Kustomize entry point
        └── helmrelease.yaml    # HelmRelease + HelmRepository
```

### HelmRelease pattern

**Always use HelmReleases for workloads.** Never write plain Deployment, DaemonSet, or StatefulSet manifests for applications — every app must be a HelmRelease. If no dedicated Helm chart exists for an app, use the [bjw-s app-template](https://github.com/bjw-s-labs/helm-charts) chart (`https://bjw-s.github.io/helm-charts/`, chart name `app-template`).

**All versions must be pinned.** Never use `latest`, a major-only tag (`:1`), or any floating tag for container images or chart versions. Always specify an exact version (e.g. `image.tag: "1.15.0"`, `version: "3.5.0"`).

**Every HTTPRoute attached to the `external` gateway must include the Cloudflare proxy annotation** to explicitly declare whether Cloudflare should proxy the traffic:

```yaml
metadata:
  annotations:
    external-dns.alpha.kubernetes.io/cloudflare-proxied: "true"   # orange cloud — proxied
    # or
    external-dns.alpha.kubernetes.io/cloudflare-proxied: "false"  # grey cloud — DNS only
```

Use `"true"` for HTTP/HTTPS services. Use `"false"` for UDP services like WireGuard (which can't be proxied). HTTPRoutes on the `internal` gateway do not need this annotation — they are covered by the `*.stasky.win` wildcard and are never managed by external-dns.

**Always split HelmRepository and HelmRelease into separate files** (`helmrepository.yaml` and `helmrelease.yaml`). Never combine them in a single file with `---`.

**Prefer OCI over HTTPS for Helm chart sources.** Use `OCIRepository` (with `chartRef` in the HelmRelease) instead of `HelmRepository` when the chart is available as an OCI artifact. Check the chart's GitHub/docs for an OCI URL before falling back to an HTTPS repo.

**Every `ks.yaml` must include a `healthChecks` entry for every significant resource it manages** — not just HelmReleases. Include OCIRepositories, ExternalSecrets, ClusterSecretStores, and any other resource whose readiness is meaningful. This ensures the Kustomization only reports ready once all managed resources are actually healthy:

```yaml
healthChecks:
  - apiVersion: helm.toolkit.fluxcd.io/v2
    kind: HelmRelease
    name: <app-name>
    namespace: <namespace>
  - apiVersion: source.toolkit.fluxcd.io/v1
    kind: OCIRepository
    name: <app-name>
    namespace: <namespace>
  - apiVersion: external-secrets.io/v1
    kind: ExternalSecret
    name: <secret-name>
    namespace: <namespace>
  - apiVersion: external-secrets.io/v1
    kind: ClusterSecretStore
    name: <store-name>
    namespace: <namespace>
```

A minimal example:

```yaml
---
apiVersion: source.toolkit.fluxcd.io/v1
kind: HelmRepository
metadata:
  name: <chart-repo-name>
  namespace: <namespace>
spec:
  interval: 1h
  url: https://<helm-repo-url>
---
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: <app-name>
  namespace: <namespace>
spec:
  interval: 1h
  chart:
    spec:
      chart: <chart-name>
      version: "<version>"
      sourceRef:
        kind: HelmRepository
        name: <chart-repo-name>
        namespace: <namespace>
  values:
    {}
```

Plain manifests are acceptable for simple resources (Namespaces, ConfigMaps, RBAC) where a Helm chart would be overkill.

### Kustomize components

Reusable patterns (e.g. volsync backups, alert rules) live in `kubernetes/components/`. An app opts in by referencing a component in its `kustomization.yaml`:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - helmrelease.yaml
components:
  - ../../../components/<component-name>
```

Only create a component when the same pattern is needed in more than one app.

### App structure

Each app follows the `ks.yaml` pattern for independent reconciliation:

```
kubernetes/apps/
└── <namespace>/
    ├── namespace.yaml          # Namespace with kustomize.toolkit.fluxcd.io/prune: disabled label
    ├── kustomization.yaml      # Lists namespace.yaml and each app's ks.yaml
    └── <app-name>/
        ├── ks.yaml             # Flux Kustomization CR pointing at ./app
        └── app/
            ├── kustomization.yaml
            ├── ocirepository.yaml  # OCIRepository pinning the chart version
            └── helmrelease.yaml    # HelmRelease referencing the OCIRepository
```

### Adding a new app — checklist

1. If the namespace is new: create `kubernetes/apps/<namespace>/namespace.yaml` and `kubernetes/apps/<namespace>/kustomization.yaml`, then add the namespace directory to `kubernetes/apps/kustomization.yaml`
2. Create `kubernetes/apps/<namespace>/<app-name>/ks.yaml` (Flux Kustomization CR) and `kubernetes/apps/<namespace>/<app-name>/app/` with `kustomization.yaml`, `ocirepository.yaml`, and `helmrelease.yaml`
3. Add the app's `ks.yaml` to the namespace's `kustomization.yaml` resources list
4. Provide the commands for the user to apply; do not run them directly

The `cluster-apps` Kustomization in `kubernetes/flux/apps.yaml` already watches `./kubernetes/apps` — no additional Flux Kustomization wiring is needed at the top level. Use `dependsOn` in `ks.yaml` when an app must wait for another (e.g. CRDs before the app that uses them). All kustomizations must set `retryInterval: 1m` so any transient failure (missing dependency, CRD not yet registered, ConfigMap not found) recovers within a minute instead of waiting for the full `interval`.

## Adding New Tasks

New task modules go in `.tasks/<module>.yaml` and must be included in the root `Taskfile.yaml`:

```yaml
includes:
  talos: .tasks/talos.yaml
  <module>: .tasks/<module>.yaml
```

Tasks must not hardcode IPs, hostnames, or cluster-specific values. Use dotenv-loaded variables or task inputs instead.
