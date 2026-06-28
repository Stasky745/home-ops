# CLAUDE.md

This file tells Claude how to work in this repository.

## Critical Rules

- **Never apply changes directly.** Always provide commands for the user to run and wait for confirmation. Do not run `talosctl apply-config`, `kubectl apply`, `flux reconcile`, or any command that mutates cluster state.
- **Never commit sensitive information.** Node IPs, hostnames, network topology, kubeconfigs, and age keys must never appear in committed files. When in doubt, check `.gitignore`.
- **No hardcoded values.** IPs, node names, and cluster-specific values live in gitignored files (`talos/nodes.env`, `talos/talconfig.yaml`). Taskfile tasks and Kubernetes manifests must remain reusable across different environments.
- **Keep documentation up to date.** When adding tasks, changing repo structure, or introducing new conventions, update `README.md` and this file as part of the same change.

---

## Cluster Overview

**Talos Linux** `v1.13.4` · **Kubernetes** `v1.36.1` · **Flux** `v2.8.8` (via Flux Operator `v0.52.0`)

### Nodes

| Hostname | IP | Role | Disk |
|---|---|---|---|
| sanji | 192.168.42.13 | control-plane | /dev/nvme0n1 |
| zoro | 192.168.42.14 | control-plane | /dev/nvme0n1 |
| luffy | 192.168.42.15 | control-plane | /dev/nvme0n1 |

All three nodes are control-plane only (`allowSchedulingOnControlPlanes: true`). There are no dedicated workers. All nodes use the same Talos factory image:
`factory.talos.dev/installer/613e1592b2da41ae5e265e8789429f22e121aab91cb4deb6bc3c0b6262961245`
(includes `iscsi_tcp` and `dm_crypt` kernel extensions for Longhorn storage).

Primary network interface on all nodes: `eno1`

| Node | eno1 MAC |
|---|---|
| sanji | c4:65:16:b0:09:07 |
| zoro | c4:65:16:b7:0e:a7 |
| luffy | c4:65:16:ab:ec:cb |

### Key IPs

| Address | Purpose |
|---|---|
| 192.168.42.10 | Talos L2 VIP — kube-apiserver endpoint (floats between nodes) |
| 192.168.42.100 | Internal Envoy Gateway (Cilium LB IPAM, pinned) |
| 192.168.42.101 | External Envoy Gateway (Cilium LB IPAM, pinned) |
| 192.168.42.100–150 | Cilium LoadBalancer IP pool |
| 10.244.0.0/22 | Pod CIDR (three /24s across nodes) |
| 127.0.0.1:7445 | Talos local kube-apiserver proxy (used by Cilium — see gotchas) |

### Network Context

This cluster lives on the **servers VLAN (42)** of a segmented home network managed by an OpenWrt router (`nami`, 192.168.42.1). Key facts for cluster work:

- `*.stasky.win` resolves to `192.168.42.100` internally via split-horizon DNS (dnsmasq on nami)
- `*.stasky.win` → `192.168.42.100` externally via Cloudflare wildcard (for VPN clients)
- External Envoy Gateway (`192.168.42.101`) handles public-facing services via Cloudflare + DNAT on nami
- WireGuard VPN clients get split-tunnel `AllowedIPs = 192.168.42.0/24` — they use the internal gateway

---

## What Is Gitignored (and Why)

| Path | Reason |
|---|---|
| `age.key` | Private age key — never commit |
| `*.iso` | Large binary files |
| `talos/clusterconfig/` | Generated node configs contain secrets; kubeconfig contains cluster credentials |
| `talos/talconfig.yaml` | Contains node IPs and hostnames |
| `talos/nodes.env` | Contains node IPs, hostnames, and cluster name |
| `kubernetes/cluster.env` | Contains `ACME_EMAIL` and other per-cluster env vars |

Every gitignored config file has a committed `.example` counterpart as a template.

---

## Repo Structure

```
.tasks/talos.yaml                              # Talos task definitions
.tasks/kubernetes.yaml                         # Kubernetes bootstrap task definitions
bootstrap/                                     # Bootstrap secrets (SOPS-encrypted, applied manually)
bootstrap/github-token.sops.yaml              # GitHub PAT for Flux to pull from this repo
kubernetes/apps/                               # Applications organised by namespace → app
kubernetes/apps/flux-system/flux-operator/    # Flux Operator (manages Flux upgrades)
kubernetes/apps/flux-system/flux-instance/    # FluxInstance CR (configures Flux itself)
kubernetes/components/                         # Reusable Kustomize components (opt-in per app)
kubernetes/flux/apps.yaml                      # cluster-apps Kustomization CR watching kubernetes/apps
kubernetes/flux/cluster-settings.yaml         # (does not exist — see Variable Substitution section)
talos/                                         # All Talos configuration
Taskfile.yaml                                  # Root: loads dotenv, includes .tasks/*
.envrc                                         # Sets KUBECONFIG and SOPS_AGE_KEY_FILE via direnv
.sops.yaml                                     # SOPS encryption rules (safe to commit — public key only)
```

---

## Secrets Architecture

Secrets flow through two layers:

**1. Bootstrap secrets (SOPS + age)**
- Age private key lives at `age.key` (gitignored). The `.envrc` sets `SOPS_AGE_KEY_FILE=./age.key`.
- Age public key is in `.sops.yaml` — safe to commit.
- SOPS-encrypted files are committed as `*.sops.yaml`. They are decrypted by Flux's kustomize-controller at reconcile time using the `sops-age` Secret in `flux-system`.
- `bootstrap/github-token.sops.yaml` — GitHub PAT (username `git`) so Flux can pull from this private repo. Applied during bootstrap via `task kubernetes:bootstrap-flux-operator`.
- `kubernetes/apps/external-secrets/onepassword-connect/app/op-credentials.sops.yaml` — 1Password Connect credentials.

**2. Runtime secrets (External Secrets + 1Password)**
- **ClusterSecretStore** `onepassword` (in `external-secrets` namespace) — backed by 1Password Connect.
- Apps create **ExternalSecret** resources that reference 1Password items by name and field.
- Pattern: `remoteRef.key` = 1Password item name, `remoteRef.property` = field label.
- Example: cert-manager's ACME email → item `CertManager`, field `ACME_EMAIL`.

**There is no `cluster-settings` ConfigMap.** The previous pattern of substituting variables from a ConfigMap was removed. The only variable substitution in the cluster is `cert-manager-config`, which reads `ACME_EMAIL` from the `cluster-settings` **Secret** (created by an ExternalSecret in `cert-manager/cert-manager/secrets/`).

---

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

### Critical talconfig.yaml patches

These two patches **must** exist in `talos/talconfig.yaml` under the global `patches:` section. Without them, etcd registers on Cilium's internal `cilium_host` IPs (`10.0.x.x`) which are only reachable via VXLAN. Switching to native routing (or any re-bootstrap) without these causes an unrecoverable etcd deadlock:

```yaml
patches:
  - |-
    cluster:
      etcd:
        advertisedSubnets:
          - 192.168.42.0/24
    machine:
      kubelet:
        nodeIP:
          validSubnets:
            - 192.168.42.0/24
```

### Re-bootstrap sequence

If the cluster needs a full wipe and re-bootstrap (e.g. after a CNI misconfiguration):

```sh
# 1. Verify talconfig.yaml has the patches above, then regenerate
task talos:generate

# 2. Reset all nodes simultaneously
talosctl -n 192.168.42.13,192.168.42.14,192.168.42.15 reset --graceful=false --reboot

# 3. Apply configs in maintenance mode (nodes show no OS, just installer)
task talos:apply:maintenance NODE=sanji
task talos:apply:maintenance NODE=zoro
task talos:apply:maintenance NODE=luffy

# 4. Bootstrap etcd (run once, on any node, after all are up)
task talos:bootstrap
task talos:kubeconfig

# 5. Install Cilium before Flux (nodes stay NotReady without CNI)
task kubernetes:bootstrap-cilium

# 6. Bootstrap Flux (seeds SOPS key + GitHub token + Flux Operator + Instance)
task kubernetes:bootstrap-sops
task kubernetes:bootstrap-flux-operator
```

---

## Cilium

Cilium `v1.19.5` is the CNI, kube-proxy replacement, and LoadBalancer IP manager. It is deployed as a HelmRelease via `kubernetes/apps/kube-system/cilium/` using an OCIRepository (`oci://quay.io/cilium/charts/cilium`). Values are **inline** in the HelmRelease (no ConfigMap, no `valuesFrom`).

A second Kustomization `cilium-config` (same `ks.yaml`) applies the `CiliumLoadBalancerIPPool` and `CiliumL2AnnouncementPolicy` from `kubernetes/apps/kube-system/cilium/config/`.

### Key config decisions

| Setting | Value | Why |
|---|---|---|
| `k8sServiceHost` | `127.0.0.1` | Talos local apiserver proxy — avoids circular dependency with cluster VIP |
| `k8sServicePort` | `"7445"` | Talos local apiserver proxy port |
| `routingMode` | `native` | No tunnelling; pods route directly over eno1 |
| `autoDirectNodeRoutes` | `true` | Nodes install routes to each other's pod CIDRs |
| `ipv4NativeRoutingCIDR` | `10.244.0.0/22` | Pod CIDR — traffic within this range is not masqueraded |
| `devices` | `["eno1"]` | **Must be set explicitly** — tells Cilium to attach TC BPF programs to eno1 |
| `extraConfig.direct-routing-device` | `"eno1"` | **Must use extraConfig** — the top-level `directRoutingDevice` Helm value does not write to the cilium-config ConfigMap in v1.19.x |
| `bpf.masquerade` | `true` | Required for BPF-based host routing |
| `l2announcements.enabled` | `true` | ARP announcements for LoadBalancer IPs |
| `kubeProxyReplacement` | `true` | Full kube-proxy replacement via eBPF |

### Non-obvious gotchas

**`devices: ["eno1"]` is critical for external traffic.** Without it, Cilium does not attach TC BPF programs to `eno1` ingress. LoadBalancer VIP traffic from external subnets arrives at eno1, is not intercepted by Cilium, the kernel has no route for the VIP IP, and the connection is silently dropped (no conntrack entry, no RST from Cilium). Symptom: `curl` to a VIP gets `connection refused` in ~30ms from outside the cluster; works fine from inside. Verify with: `kubectl exec -n kube-system <cilium-pod> -- tc filter show dev eno1 ingress` — should return output.

**`direct-routing-device` must go in `extraConfig`, not as a top-level value.** The Helm chart's `directRoutingDevice` key does not propagate to the `cilium-config` ConfigMap in this version. Use `extraConfig: { direct-routing-device: "eno1" }`.

**etcd deadlock on CNI mode change.** Switching from VXLAN to native routing on a live cluster (without the `advertisedSubnets` patch) causes etcd to lose peer connectivity permanently. etcd stores peer URLs as `cilium_host` IPs which only exist via VXLAN. Without VXLAN, there is no recovery path — full re-bootstrap is required.

**Future investigation:** `loadBalancer.mode: dsr` (Direct Server Return) — pods reply directly to clients, reducing load at scale. Low-risk one-line change but not yet validated.

### LoadBalancer IP pool

```yaml
# kubernetes/apps/kube-system/cilium/config/ippool.yaml
kind: CiliumLoadBalancerIPPool
spec:
  blocks:
    - start: 192.168.42.100
      stop: 192.168.42.150
```

```yaml
# kubernetes/apps/kube-system/cilium/config/l2policy.yaml
kind: CiliumL2AnnouncementPolicy
spec:
  loadBalancerIPs: true
  interfaces: ["eno1"]
  nodeSelector:
    matchLabels:
      kubernetes.io/os: linux
```

---

## Networking (Envoy Gateway)

Envoy Gateway is deployed in the `network` namespace. Two Gateways exist:

| Gateway | IP | Purpose |
|---|---|---|
| `internal` | 192.168.42.100 | Internal services — all `*.stasky.win` |
| `external` | 192.168.42.101 | Public-facing services via Cloudflare |

**IPs are pinned via `EnvoyProxy` CRD**, not via `Gateway.spec.addresses`. The `addresses` field causes Envoy Gateway to request an additional IP on top of any dynamically assigned one, resulting in duplicate IPs per service. The correct pattern:

```yaml
apiVersion: gateway.envoyproxy.io/v1alpha1
kind: EnvoyProxy
metadata:
  name: internal
  namespace: network
spec:
  provider:
    type: Kubernetes
    kubernetes:
      envoyService:
        externalTrafficPolicy: Cluster
        annotations:
          io.cilium/lb-ipam-ips: "192.168.42.100"
```

`externalTrafficPolicy: Cluster` is set on both gateways. Source IP is not preserved (replaced by the forwarding node IP) but this is acceptable for a homelab.

### TLS

A single wildcard certificate `stasky-win-wildcard-tls` (Secret in `network` namespace) covers `*.stasky.win` and `stasky.win`. Issued by cert-manager via Let's Encrypt DNS-01 challenge against Cloudflare. Both gateways reference it.

The `envoy-gateway-config` Kustomization depends on `cert-manager-config` to ensure the `letsencrypt-prod` ClusterIssuer exists before the Certificate resource is applied.

### HTTPRoute conventions

- **Internal gateway routes**: no `external-dns` annotation needed. Covered by split-horizon DNS on nami.
- **External gateway routes**: must include:
  ```yaml
  annotations:
    external-dns.alpha.kubernetes.io/cloudflare-proxied: "true"   # proxied HTTP/HTTPS
    # or
    external-dns.alpha.kubernetes.io/cloudflare-proxied: "false"  # DNS-only (e.g. WireGuard UDP)
  ```

external-dns only manages routes attached to the `external` gateway (`--gateway-name=external --gateway-namespace=network`).

---

## Flux

Flux is managed via the **Flux Operator** pattern:
- `flux-operator` HelmRelease installs/upgrades the operator itself
- `flux-instance` HelmRelease creates the `FluxInstance` CR that configures which Flux controllers run and where they sync from
- The FluxInstance watches `kubernetes/flux/` as its root sync path; `kubernetes/flux/apps.yaml` is the entry point that points Flux at `kubernetes/apps/`
- Sync source: `https://github.com/Stasky745/home-ops.git`, branch `main`, pull secret `flux-system` (the GitHub token secret)
- To upgrade Flux: bump the tag in `flux-operator/app/ocirepository.yaml` and the version in `flux-instance/app/ocirepository.yaml`, commit

Flux reconciliation state overview:
```sh
flux get kustomizations
flux get helmreleases -A
flux get sources git
```

Force-reconcile a specific kustomization:
```sh
flux reconcile kustomization <name>
```

---

## Cert-Manager

Cert-manager `v1.20.3` is deployed from OCI (`oci://quay.io/jetstack/charts/cert-manager`).

Two ClusterIssuers: `letsencrypt-staging` and `letsencrypt-prod`. Both use DNS-01 via Cloudflare. The Cloudflare API token is fetched from 1Password (item `CF - stasky.win Edit Zone DNS`, field `credential`) into a Secret `cloudflare-api-token` in `cert-manager` namespace.

The ACME email (`ACME_EMAIL`) comes from 1Password (item `CertManager`, field `ACME_EMAIL`) via an ExternalSecret in `kubernetes/apps/cert-manager/cert-manager/secrets/`. This creates a Secret named `cluster-settings` in `flux-system`, which `cert-manager-config` references via `postBuild.substituteFrom`.

**Dependency chain:**
```
external-secrets-clustersecretstore
  → cert-manager-secrets (ExternalSecret for ACME_EMAIL → Secret/cluster-settings in flux-system)
  → cert-manager-config (ClusterIssuers + Cloudflare ExternalSecret)
  → envoy-gateway-config (Certificate resource + Gateways)
```

---

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

### Full app directory layout

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

### Variable substitution

Only `cert-manager-config` uses `postBuild.substituteFrom`. It reads from the `cluster-settings` Secret in `flux-system` (not a ConfigMap). Do not introduce ConfigMap-based substitution for new apps — if a value is sensitive, use an ExternalSecret; if it is not sensitive, hardcode it in the manifest.

---

## Adding New Tasks

New task modules go in `.tasks/<module>.yaml` and must be included in the root `Taskfile.yaml`:

```yaml
includes:
  talos: .tasks/talos.yaml
  kubernetes: .tasks/kubernetes.yaml
  <module>: .tasks/<module>.yaml
```

Tasks must not hardcode IPs, hostnames, or cluster-specific values. Use dotenv-loaded variables or task inputs instead.

### Key tasks reference

| Task | Description |
|---|---|
| `task talos:health` | Check etcd, node, and API health |
| `task talos:generate` | Regenerate node configs from talconfig.yaml |
| `task talos:apply NODE=<host>` | Apply config to a running node |
| `task talos:apply:maintenance NODE=<host>` | Apply to a node in maintenance mode |
| `task talos:bootstrap` | Bootstrap etcd (once only, on first node) |
| `task talos:kubeconfig` | Pull kubeconfig to talos/clusterconfig/kubeconfig |
| `task kubernetes:bootstrap-cilium` | Install Cilium via helm (before Flux exists) |
| `task kubernetes:bootstrap-sops` | Seed age private key into flux-system Secret |
| `task kubernetes:bootstrap-flux-operator` | Install Flux Operator + Instance (applies github-token from bootstrap/) |
| `task kubernetes:bootstrap-flux` | Full Flux bootstrap: sops + flux-operator |
