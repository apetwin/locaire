You are building a local Kubernetes AI infrastructure sandbox called **aibox** for macOS M3 (arm64). Study this entire prompt before writing a single file.

---

## Reference repository

Before writing any code, read and internalize the architecture of https://github.com/den-vasyliev/abox. That repository is the direct inspiration for aibox. Follow its patterns exactly for:
- OpenTofu bootstrap structure (cluster.tf, flux.tf, providers.tf, variables.tf)
- Flux GitOps-over-OCI pattern (RSIP + ResourceSet, no Git polling)
- The two-kustomization ordering pattern (releases-crds runs first with wait:true, releases depends on it)
- The `gavinbunney/kubectl` provider choice and the reasoning behind it
- The `make push` patch-bump logic and RSIP lexicographic sort constraint
- The CI workflow structure in `.github/workflows/flux-push.yaml`
- The CODEBASE.md ground-truth document format

The key difference is that aibox lives in **your own GitHub repository** (not den-vasyliev/abox). All OCI artifact URLs must reference `ghcr.io/${{ github.repository }}` (the user's own repo). The `oci_registry` variable in variables.tf must default to `oci://ghcr.io/YOUR_GITHUB_USERNAME/aibox` with a comment instructing the user to replace `YOUR_GITHUB_USERNAME` with their actual GitHub username before running.

---

## Goal

`make run` → one command → full local AI stack running in KinD.

Stack:
- KinD cluster (arm64-compatible, Kubernetes v1.35)
- Flux CD via Flux Operator + FluxInstance (GitOps over OCI, no Git polling)
- agentgateway v2.2.1 — AI-aware API gateway, LLM routing + failover
- kagent 0.7.23 (pinned — do NOT bump; newer versions break Kubernetes label validation with `+` metadata)
- Arize Phoenix — agent trace UI on port 6006
- OpenTelemetry Collector — collects metrics/traces/logs, exports to Phoenix
- GitHub Actions CI — on every push to main that changes `releases/**`, bump patch version, push a semver tag, publish `releases/` as OCI artifact to GHCR, create a GitHub Release with auto-generated notes

---

## Architecture (non-negotiable)

### Bootstrap flow (single `tofu apply`)

```
KinD cluster (k8s v1.35)
  → helm: flux-operator             (bootstrap/)
  → helm: flux-instance             (wait=true)
  → kubectl_manifest: RSIP          (polls ghcr.io/<owner>/aibox/releases for semver tags)
  → kubectl_manifest: ResourceSet   (creates OCIRepository + 2 Kustomizations)
```

ResourceSet creates exactly two Flux Kustomizations:
1. `releases-crds` — `path: ./crds` — installs all CRDs, `wait: true`
2. `releases` — `path: ./` — installs all apps, `dependsOn: releases-crds`

### GitOps release flow

```
git push → CI detects releases/** change → bumps patch tag → flux push artifact → RSIP detects tag → cluster reconciles
```

### Directory layout to create

```
bootstrap/
  cluster.tf          KinD cluster (arm64, k8s v1.35, 1 control-plane + 2 workers)
  flux.tf             flux-operator helm, flux-instance helm, RSIP kubectl_manifest, ResourceSet kubectl_manifest
  providers.tf        tehcyx/kind, hashicorp/helm, gavinbunney/kubectl (REQUIRED — not hashicorp/kubernetes)
  variables.tf        cluster_name, kubernetes_version, oci_registry, releases_version

releases/
  crds/
    gateway-api-crds.yaml       HelmRelease, install.crds: CreateReplace
    agentgateway-crds.yaml      HelmRelease, install.crds: CreateReplace
    kagent-crds.yaml            HelmRelease, install.crds: CreateReplace, ref.semver: ">=0.0.1"
    kustomization.yaml
  agentgateway.yaml             Namespace + OCIRepository + HelmRelease + Gateway
  kagent.yaml                   Namespace + OCIRepository + HelmRelease + HTTPRoute + ReferenceGrant
  phoenix.yaml                  Namespace + Deployment + Service + HTTPRoute + ReferenceGrant
  otel-collector.yaml           Namespace + HelmRelease + ConfigMap + HTTPRoute + ReferenceGrant
  kustomization.yaml

scripts/
  setup.sh            install tofu, k9s, flux CLI; tofu init; tofu apply; install cloud-provider-kind (darwin_arm64)

.github/
  workflows/
    release.yml       trigger: push to main with changes in releases/**
                      steps: detect version bump needed, tag, flux push artifact, create GitHub Release

Makefile              run, down, push, tools, tofu, apply targets
README.md
CODEBASE.md           architecture ground truth (mirror den-vasyliev/abox CODEBASE.md structure exactly)
```

---

## Mandatory implementation rules

### Kubernetes version

The KinD cluster MUST run Kubernetes v1.35. Add a `kubernetes_version` variable (default `"v1.35.0"`) and use it in the node image field:

```hcl
variable "kubernetes_version" {
  description = "Kubernetes version for KinD node image"
  type        = string
  default     = "v1.35.0"
  # Verify the exact patch tag at https://github.com/kubernetes-sigs/kind/releases
}

resource "kind_cluster" "this" {
  name           = var.cluster_name
  wait_for_ready = true
  kind_config {
    kind        = "Cluster"
    api_version = "kind.x-k8s.io/v1alpha4"
    node {
      role  = "control-plane"
      image = "kindest/node:${var.kubernetes_version}"
    }
    node {
      role  = "worker"
      image = "kindest/node:${var.kubernetes_version}"
    }
    node {
      role  = "worker"
      image = "kindest/node:${var.kubernetes_version}"
    }
    networking {
      kube_proxy_mode = "ipvs"
    }
  }
}
```

### Terraform / OpenTofu

1. Use `gavinbunney/kubectl` provider (`source = "gavinbunney/kubectl"`) for ALL `kubectl_manifest` resources. NEVER use `hashicorp/kubernetes` for RSIP or ResourceSet — it validates CRD schema at plan time and breaks single-pass apply. This is the same decision made in the reference repo and the reasoning is identical.

2. RSIP filter MUST be `"^\\d+\\.\\d+\\.\\d+$"` — clean semver only, no pre-release tags.

3. ResourceSet `releases` Kustomization MUST have:
   ```yaml
   dependsOn:
     - name: releases-crds
   ```

4. kagent version MUST be pinned to `0.7.23` in ALL locations: OCIRepository ref.tag, HelmRelease values.controller.image.tag, values.tag, values.ui.image.tag. Add a postRenderer kustomize patch to force `app.kubernetes.io/version: "0.7.23"` on all kagent-labeled resources (prevents `+` metadata injection).

5. Bootstrap Flux exactly as in the reference repo: flux-operator via Helm, then flux-instance via Helm with `wait = true`. Do not use `flux bootstrap git` or any approach requiring a deploy key or PAT in OpenTofu state.

### Helm chart versions (pin all of these exactly)

- agentgateway: `oci://ghcr.io/kgateway-dev/charts/agentgateway`, tag `v2.2.1`
- agentgateway-crds: `oci://ghcr.io/kgateway-dev/charts/agentgateway-crds`, tag `v2.2.1`
- gateway-api-crds: `oci://ghcr.io/den-vasyliev/gateway-api-crds`, tag `1.4.0`
- kagent: `oci://ghcr.io/kagent-dev/kagent/helm/kagent`, tag `0.7.23`
- kagent-crds: `oci://ghcr.io/kagent-dev/kagent/helm/kagent-crds`, semver `>=0.0.1`
- Arize Phoenix: deploy as plain Deployment + Service using image `ariziai/phoenix:latest` in namespace `phoenix` (multi-arch, no Helm chart needed)
- OTel Collector: use chart `opentelemetry-collector` from repo `https://open-telemetry.github.io/opentelemetry-helm-charts`, mode `deployment`

### Namespaces

Every namespace MUST be defined in the SAME kustomization as the HelmRelease that uses it. The two Flux Kustomizations (`releases-crds` and `releases`) reconcile independently — a namespace created only in `releases/crds/` does not exist when `releases/` reconciles. This pattern is identical to the reference repo.

- `releases/crds/agentgateway-crds.yaml` defines: `agentgateway-system`
- `releases/crds/kagent-crds.yaml` defines: `kagent`
- `releases/agentgateway.yaml` ALSO defines `agentgateway-system`
- `releases/kagent.yaml` ALSO defines `kagent`
- `releases/phoenix.yaml` defines `phoenix`
- `releases/otel-collector.yaml` defines `otel-collector`

### Gateway routing

Single Gateway `agentgateway-external` in `agentgateway-system`, `allowedRoutes.namespaces.from: All` (intentional for sandbox — do not restrict this).

Every HTTPRoute that references this gateway from another namespace MUST have a ReferenceGrant in its own namespace. Required routes:
- `kagent`: `/api` → kagent-controller:8083, `/` → kagent-ui:8080
- `phoenix`: `/phoenix` → phoenix:6006
- `otel`: `/otel` → otel-collector:4318 (OTLP HTTP receiver)

### agentgateway LLM routing config

Configure agentgateway with multiple LLM backends and failover policy using its native Backend/BackendPolicy CRDs (or equivalent Gateway API extension). Create:
- Backend `openai` — OpenAI API endpoint
- Backend `anthropic` — Anthropic API endpoint
- Backend `ollama-local` — `http://host.docker.internal:11434` (Ollama running on the host Mac)
- Failover order: openai → anthropic → ollama-local
- Mount API keys as Kubernetes Secrets referenced via secretKeyRef

If the exact CRD name for LLM backends in agentgateway v2.2.1 is uncertain, generate the best-effort manifest and add `# TODO: verify CRD name against agentgateway v2.2.1 docs at https://agentgateway.dev`.

### OpenTelemetry Collector config

Configure with these pipelines in the Helm values or a ConfigMap mounted into the collector pod:

```yaml
receivers:
  otlp:
    protocols:
      grpc:
        endpoint: 0.0.0.0:4317
      http:
        endpoint: 0.0.0.0:4318

processors:
  batch: {}
  memory_limiter:
    limit_mib: 400

exporters:
  otlp/phoenix:
    endpoint: phoenix.phoenix.svc.cluster.local:6006
    tls:
      insecure: true
  logging:
    verbosity: detailed

service:
  pipelines:
    traces:
      receivers: [otlp]
      processors: [memory_limiter, batch]
      exporters: [otlp/phoenix, logging]
    metrics:
      receivers: [otlp]
      processors: [memory_limiter, batch]
      exporters: [logging]
```

### CI workflow (`.github/workflows/release.yml`)

Model this on the reference repo's `.github/workflows/flux-push.yaml` with these additions:

Trigger: push to `main` with path filter `releases/**`

Steps:
1. Checkout with `fetch-depth: 0`
2. Setup Flux CLI via `fluxcd/flux2/action@main`
3. Login to GHCR with `docker/login-action@v3`, username `${{ github.actor }}`, password `${{ secrets.GITHUB_TOKEN }}`
4. Compute next semver tag: fetch all tags, find latest `v*`, bump patch. CRITICAL: if patch would reach 10 or above, bump minor and reset patch to 0 — RSIP uses lexicographic tag sort, so `0.3.10 < 0.3.9` and the higher tag would never be detected.
5. `flux push artifact oci://ghcr.io/${{ github.repository }}/releases:${TAG} --path=./releases --source="${{ github.repositoryUrl }}" --revision="${{ github.ref_name }}@sha1:${{ github.sha }}" --output json | jq -r '.digest'` → capture digest
6. `flux tag artifact oci://ghcr.io/${{ github.repository }}/releases:${TAG}@${digest} --tag latest`
7. `gh release create ${TAG} --generate-notes --title "Release ${TAG}"`

Required permissions: `contents: write`, `packages: write`

### Makefile

Match the style of the reference repo's Makefile exactly, including a `help` target that lists all targets:

```
help:   list all targets with one-line descriptions
run:    call scripts/setup.sh
down:   cd bootstrap && tofu destroy -auto-approve
push:   fetch tags; find latest v* tag; if patch >= 9 bump minor and reset patch to 0, else bump patch; git tag; git push
tools:  install opentofu (standalone), k9s (webi), flux CLI
tofu:   cd bootstrap && tofu init
apply:  cd bootstrap && tofu apply -auto-approve
```

### macOS M3 specifics

- `scripts/setup.sh`: detect arch with `$(uname -m)`; map `arm64` for all binary downloads
- cloud-provider-kind: download `darwin_arm64` from `https://github.com/kubernetes-sigs/cloud-provider-kind/releases/download/v0.6.0/cloud-provider-kind_0.6.0_darwin_arm64.tar.gz`; start with `nohup` in background as in the reference repo
- Shell aliases: write to `~/.zshrc` (macOS default), not `~/.bashrc`
- KinD node image `kindest/node:v1.35.0` is multi-arch — arm64 is supported natively
- Do not hardcode `amd64` anywhere

### CODEBASE.md

Generate a complete CODEBASE.md that mirrors the structure and depth of the reference repo's CODEBASE.md. Required sections:

1. "What this repo is" — one paragraph
2. Tech Stack table — Layer / Tech / Version (KinD row must show Kubernetes 1.35)
3. Architecture section:
   - Bootstrap flow (ASCII diagram, same style as reference)
   - GitOps release flow (ASCII diagram)
   - Directory layout (annotated tree)
   - Component roles table — Component / Namespace / What it does (include Phoenix and OTel Collector)
4. Conventions:
   - "Adding a new component" (numbered steps: CRDs, apps, namespaces, routing, ReferenceGrants)
   - "Versioning"
   - "Releasing"
5. Forbidden Patterns table — Pattern / Why (include all patterns from this prompt)
6. Key Design Decisions — one paragraph per decision covering: gavinbunney/kubectl, no github_token in Terraform, kagent pin, gateway allowedRoutes, OCI-only GitOps, k8s 1.35 explicit pin

---

## Forbidden patterns — never generate these

| Pattern | Why |
|---|---|
| `ref.tag: latest` in any HelmRelease | Non-reproducible; Flux treats it as a static tag with no update detection |
| App HelmRelease without `dependsOn` pointing to its CRD release | Reconciliation fails with "no matches for kind" |
| HTTPRoute referencing cross-namespace gateway without ReferenceGrant | Route silently rejected by gateway controller |
| `hashicorp/kubernetes` provider for kubectl_manifest | Validates CRD schema at plan time, breaks single-pass apply |
| Namespace defined only in crds/ kustomization but used by app in releases/ | Namespace won't exist when apps kustomization reconciles |
| Patch >= 10 without bumping minor in make push or CI | RSIP lexicographic sort regression — new tag never detected |
| kagent version other than 0.7.23 without explicit label value verification | Kubernetes rejects `+` build metadata in label values |
| KinD node image without explicit version tag | Non-reproducible; cluster Kubernetes version drifts |
| OCI registry URL pointing to den-vasyliev/abox | That is the reference repo; aibox must use the user's own repo |
| Aliases written to ~/.bashrc on macOS | macOS default shell is zsh; bashrc changes are silently ignored |

---

## Validation checklist — verify every item before finishing

For each HelmRelease in `releases/`:
- [ ] Has explicit `ref.tag` (never `latest`, never a semver range — except kagent-crds which uses `ref.semver`)
- [ ] Has `dependsOn` pointing to its CRD HelmRelease by name and namespace
- [ ] Namespace is defined in the same YAML file (not only in the crds/ kustomization)

For each HTTPRoute:
- [ ] ReferenceGrant exists in the same namespace if the referenced gateway is in a different namespace

For `bootstrap/`:
- [ ] `gavinbunney/kubectl` is the provider for all `kubectl_manifest` resources
- [ ] RSIP `filter.includeTag` is `"^\\d+\\.\\d+\\.\\d+$"`
- [ ] ResourceSet `releases` Kustomization has `dependsOn: [{name: releases-crds}]`
- [ ] KinD node image uses `var.kubernetes_version` with default `v1.35.0`
- [ ] `oci_registry` variable default says `oci://ghcr.io/YOUR_GITHUB_USERNAME/aibox` with replacement instruction

For `.github/workflows/release.yml`:
- [ ] Patch >= 10 triggers minor bump and patch reset to 0
- [ ] GitHub Release is created with `--generate-notes`
- [ ] OCI artifact is tagged with both the semver tag AND `latest`
- [ ] OCI URL uses `${{ github.repository }}`, not a hardcoded value

For `scripts/setup.sh` and `Makefile`:
- [ ] cloud-provider-kind downloads `darwin_arm64` binary
- [ ] Aliases written to `~/.zshrc`
- [ ] No hardcoded `amd64` anywhere

---

Generate all files now. Output each file with its full relative path as a comment header (e.g. `# bootstrap/providers.tf`). Write complete file contents — do not truncate, do not summarize, do not skip sections. Every file in the directory layout above must be present in the output.
