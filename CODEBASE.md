# CODEBASE.md

Ground truth for the aibox repository. Covers architecture, component roles, conventions, and forbidden patterns.

---

## What this repo is

aibox is a **local AI infrastructure sandbox** for macOS M3 (arm64). A single `make run` provisions a KinD cluster running Kubernetes v1.35 and reconciles a full AI stack via Flux GitOps over OCI. The stack includes an AI-aware gateway with LLM routing and failover, an agent runtime, distributed tracing via OpenTelemetry, and a trace visualization UI. There is no application code — the repo is entirely Kubernetes manifests, OpenTofu, and shell scripts.

---

## Tech Stack

| Layer | Tech | Version |
|---|---|---|
| Cluster | KinD | Kubernetes 1.35 |
| GitOps operator | Flux CD (Flux Operator + FluxInstance) | 2.x |
| Infrastructure as code | OpenTofu | latest |
| AI gateway | agentgateway | v2.2.1 |
| Agent runtime | kagent | 0.7.23 (pinned) |
| Gateway API | gateway-api-crds | 1.4.0 |
| Trace UI | Arize Phoenix | latest |
| Telemetry collector | OpenTelemetry Collector | 0.108.0 |
| OCI artifact store | GHCR | — |
| CI | GitHub Actions | — |

---

## Architecture

### Bootstrap flow

A single `tofu apply` produces a running cluster:

```
KinD cluster (k8s v1.35)
  → helm: flux-operator             (bootstrap/)
  → helm: flux-instance             (wait=true)
  → kubectl_manifest: RSIP          (polls ghcr.io/<owner>/aibox/releases for semver tags)
  → kubectl_manifest: ResourceSet   (creates OCIRepository + 2 Kustomizations)
```

The ResourceSet creates two Flux Kustomizations:

1. **`releases-crds`** — `path: ./crds` — installs CRDs, runs with `wait: true`
2. **`releases`** — `path: ./` — installs apps, `dependsOn: releases-crds`

This ordering is non-negotiable. Apps reference CRD types (GatewayClass, HelmRelease) that must exist before reconciliation.

### Gitless GitOps via OCI

There is no Git polling. The cluster reconciles from OCI artifacts:

```
git push → CI detects releases/** change → bumps patch tag → flux push artifact → RSIP detects new tag → cluster reconciles
```

The RSIP filter `^\d+\.\d+\.\d+$` matches only clean semver tags. Pre-release and build metadata tags are ignored.

### Directory layout

```
bootstrap/                 OpenTofu: cluster.tf, flux.tf, providers.tf, variables.tf
  cluster.tf               KinD cluster (arm64, k8s v1.35, 1 CP + 2 workers)
  flux.tf                  flux-operator, flux-instance, RSIP, ResourceSet
  providers.tf             tehcyx/kind, hashicorp/helm, gavinbunney/kubectl
  variables.tf             cluster_name, kubernetes_version, oci_registry, releases_version
releases/
  crds/                    CRD HelmReleases (must reconcile before releases/)
    gateway-api-crds.yaml  Gateway API CRDs v1.4.0
    agentgateway-crds.yaml agentgateway CRDs v2.2.1 + agentgateway-system namespace
    kagent-crds.yaml       kagent CRDs (semver >=0.0.1) + kagent namespace
    kustomization.yaml
  agentgateway.yaml        agentgateway HelmRelease + Gateway + LLM Backend routing
  kagent.yaml              kagent HelmRelease + HTTPRoute + ReferenceGrant
  phoenix.yaml             Arize Phoenix Deployment + Service + HTTPRoute + ReferenceGrant
  otel-collector.yaml      OTel Collector HelmRelease + HTTPRoute + ReferenceGrant
  kustomization.yaml
scripts/
  setup.sh                 Called by make run — installs tools, tofu init + apply, cloud-provider-kind
.github/
  workflows/
    release.yml            Publishes releases/ as OCI artifact on push to main
```

### Component roles

| Component | Namespace | What it does |
|---|---|---|
| agentgateway | `agentgateway-system` | Gateway API controller; handles AI/MCP-aware routing with LLM failover |
| Gateway `agentgateway-external` | `agentgateway-system` | Single ingress point, port 80, allows routes from all namespaces |
| LLM Backends | `agentgateway-system` | OpenAI, Anthropic, Ollama backends with failover policy |
| kagent | `kagent` | AI agent runtime; exposes MCP server on `:8083`, UI on `:8080` |
| Arize Phoenix | `phoenix` | Agent trace visualization UI on `:6006`, OTLP receiver on `:4317` |
| OTel Collector | `otel-collector` | Collects traces/metrics via OTLP, exports traces to Phoenix |
| HTTPRoute `kagent` | `kagent` | Routes `/api` → kagent MCP, `/` → kagent UI |
| HTTPRoute `phoenix` | `phoenix` | Routes `/phoenix` → Phoenix UI |
| HTTPRoute `otel-collector` | `otel-collector` | Routes `/otel` → OTel Collector OTLP HTTP endpoint |
| ReferenceGrant `kagent` | `kagent` | Allows HTTPRoute to reference gateway in agentgateway-system |
| ReferenceGrant `phoenix` | `phoenix` | Allows HTTPRoute to reference gateway in agentgateway-system |
| ReferenceGrant `otel-collector` | `otel-collector` | Allows HTTPRoute to reference gateway in agentgateway-system |

---

## Conventions

### Adding a new component

1. **CRDs go in `releases/crds/`** as a HelmRelease. Use `install.crds: CreateReplace`.
2. **Apps go in `releases/`** as a HelmRelease. Add `dependsOn: [name: <crd-release>, namespace: <ns>]`.
3. **Namespaces** — define the Namespace resource in the same file as the HelmRelease. Define it in BOTH `releases/crds/` and `releases/` if the namespace is needed in both kustomizations.
4. **Cross-namespace routing** — always add a ReferenceGrant in the app's namespace when an HTTPRoute references the gateway in `agentgateway-system`.
5. All HelmReleases live in the component's own namespace, not `flux-system` (exception: OCIRepository sources stay in `flux-system`).
6. **Add the new file to the appropriate `kustomization.yaml`** — `releases/crds/kustomization.yaml` for CRDs, `releases/kustomization.yaml` for apps.

### Versioning

- Versions in HelmReleases must be explicit tags (`ref.tag`), never `latest`.
- When bumping a component version, update all tag references that appear in a HelmRelease (chart tag, controller image tag, UI image tag if present).
- kagent is pinned to `0.7.23` — do NOT upgrade without verifying label values are clean semver.

### Releasing

`make push` bumps the patch version and pushes a git tag. CI detects the push to main with `releases/**` changes, computes the next semver tag, pushes the OCI artifact, and creates a GitHub Release. The RSIP picks up the new tag within 5 minutes (poll interval).

**CRITICAL**: patch version must never reach 10. When patch >= 9, bump minor and reset patch to 0. RSIP uses lexicographic sort — `0.3.10` sorts before `0.3.9`, so the higher tag would never be detected.

---

## Forbidden Patterns

| Pattern | Why |
|---|---|
| `ref.tag: latest` in any HelmRelease | Non-reproducible; Flux won't detect updates |
| App HelmRelease without `dependsOn` pointing to its CRD release | CRD may not exist when app reconciles |
| HTTPRoute referencing a gateway in another namespace without ReferenceGrant | Route will be rejected by the gateway controller |
| Namespace resource only in `releases/crds/` when the app is in `releases/` | CRD kustomization runs in a separate reconcile; namespace may not exist when app installs |
| Patch version >= 10 without bumping minor | RSIP uses lexicographic sort: `0.3.10` < `0.3.9` |
| `kubectl_manifest` with `hashicorp/kubernetes` provider for RSIP/ResourceSet | `hashicorp/kubernetes` validates against CRD schema at plan time, breaking single-pass apply |
| Pushing without verifying `flux get all` shows Ready | Broken releases are published to GHCR and reconciled automatically |
| `ref.tag: latest` in any HelmRelease | Non-reproducible; Flux treats it as a static tag with no update detection |
| kagent version other than 0.7.23 without explicit label verification | Kubernetes rejects `+` build metadata in label values |
| KinD node image without explicit version tag | Non-reproducible; cluster Kubernetes version drifts |
| OCI registry URL pointing to den-vasyliev/abox | That is the reference repo; aibox must use the user's own repo |
| Aliases written to ~/.bashrc on macOS | macOS default shell is zsh; bashrc changes are silently ignored |
| Hardcoded `amd64` anywhere | aibox targets macOS M3 (arm64) |

---

## Key Design Decisions

**`gavinbunney/kubectl` provider** — Used for RSIP and ResourceSet manifests because it skips CRD schema validation at plan time. The `hashicorp/kubernetes` provider attempts to validate custom resource fields against the CRD schema during `terraform plan`, which fails because the CRDs don't exist yet (they're installed in the same `tofu apply`). `gavinbunney/kubectl` sends raw YAML to the API server, enabling a single-pass bootstrap.

**No github_token in Terraform** — Flux is bootstrapped via Helm charts (flux-operator + flux-instance), not `flux bootstrap git`. This avoids storing a deploy key or PAT in OpenTofu state and eliminates Git polling entirely. The cluster reconciles from OCI artifacts pushed by CI.

**kagent pinned to `0.7.23`** — Newer versions of kagent embed `+` build metadata in `app.kubernetes.io/version` label values (e.g., `0.8.0+abc123`). Kubernetes label values must match `[a-zA-Z0-9._-]` — the `+` character is rejected. A postRenderer kustomize patch forces the label to `"0.7.23"` on all kagent resources as an additional safety net.

**Gateway `allowedRoutes.namespaces.from: All`** — The `agentgateway-external` gateway accepts HTTPRoutes from all namespaces. This is intentional for a local sandbox — every new component can add an HTTPRoute without modifying the Gateway resource. Each cross-namespace route still requires a ReferenceGrant for security.

**OCI-only GitOps** — No Git polling. Flux reconciles from OCI artifacts stored in GHCR. CI pushes a new artifact on every push to main that changes `releases/**`. The RSIP polls GHCR for new semver tags every 5 minutes. This eliminates the need for deploy keys, PATs, or webhook infrastructure.

**Kubernetes v1.35 explicit pin** — The `kubernetes_version` variable defaults to `v1.35.0` and is used in the KinD node image tag (`kindest/node:v1.35.0`). This prevents version drift when KinD updates its default node image and ensures all developers run the same Kubernetes version.

**`gateway-api-crds` as a Helm chart** — Managed via HelmRelease (`ghcr.io/den-vasyliev/gateway-api-crds:1.4.0`), not a raw Kustomization. This gives Flux lifecycle management (install, upgrade, uninstall) over the CRDs and keeps the CRD installation pattern consistent across all components.
