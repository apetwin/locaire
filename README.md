# aibox

Local Kubernetes AI infrastructure sandbox for macOS M3 (arm64).

`make run` → one command → full local AI stack running in KinD.

## Stack

- **KinD** cluster (arm64, Kubernetes v1.35, 1 control-plane + 2 workers)
- **Flux CD** via Flux Operator + FluxInstance (GitOps over OCI, no Git polling)
- **agentgateway** v2.2.1 — AI-aware API gateway, LLM routing + failover
- **kagent** 0.7.23 — AI agent runtime with UI
- **Arize Phoenix** — agent trace UI on port 6006
- **OpenTelemetry Collector** — collects metrics/traces/logs, exports to Phoenix

## Quick start

```bash
# 1. Replace YOUR_GITHUB_USERNAME in bootstrap/variables.tf with your GitHub username

# 2. Run everything
make run

# 3. Access services via the gateway LoadBalancer IP
kubectl -n agentgateway-system get svc
```

## Makefile targets

```
make help     — list all targets
make run      — bootstrap the full stack
make down     — destroy the cluster
make push     — bump patch tag and push
make tools    — install opentofu, k9s, flux CLI
make tofu     — initialize OpenTofu
make apply    — apply OpenTofu config
```

## Architecture

See [CODEBASE.md](CODEBASE.md) for the full architecture ground truth.

## Prerequisites

- Docker Desktop (arm64)
- macOS with Homebrew (optional, tools install via scripts)
- GitHub account with GHCR access (for OCI artifacts)
