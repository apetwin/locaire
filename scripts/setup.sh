#!/bin/bash
set -euo pipefail

LOG_FILE="/tmp/setup.log"
exec > >(tee -a "$LOG_FILE") 2>&1

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

ARCH=$(uname -m)

# ==========================================
# Install OpenTofu
# ==========================================
log "Installing OpenTofu..."
if ! command -v tofu &>/dev/null; then
  curl --proto '=https' --tlsv1.2 -fsSL https://get.opentofu.org/install-opentofu.sh -o /tmp/install-opentofu.sh
  chmod +x /tmp/install-opentofu.sh
  /tmp/install-opentofu.sh --install-method standalone
  rm -f /tmp/install-opentofu.sh
else
  log "OpenTofu already installed"
fi

# ==========================================
# Install k9s
# ==========================================
log "Installing k9s..."
if ! command -v k9s &>/dev/null; then
  curl -sS https://webi.sh/k9s | sh
else
  log "k9s already installed"
fi

# ==========================================
# Install Flux CLI
# ==========================================
log "Installing Flux CLI..."
if ! command -v flux &>/dev/null; then
  curl -s https://fluxcd.io/install.sh | bash
else
  log "Flux CLI already installed"
fi

# ==========================================
# Shell aliases
# ==========================================
log "Configuring shell aliases..."
ZSHRC="$HOME/.zshrc"
if ! grep -q 'alias kk=' "$ZSHRC" 2>/dev/null; then
  cat >> "$ZSHRC" <<'ALIASES'

# aibox aliases
alias kk='EDITOR=code k9s'
alias tf='tofu'
alias k='kubectl'
ALIASES
  log "Aliases added to $ZSHRC"
else
  log "Aliases already present"
fi

# ==========================================
# OpenTofu init + apply
# ==========================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BOOTSTRAP_DIR="${SCRIPT_DIR}/../bootstrap"

log "Initializing OpenTofu..."
cd "$BOOTSTRAP_DIR"
tofu init

log "Applying infrastructure..."
tofu apply -auto-approve

# ==========================================
# Set KUBECONFIG
# ==========================================
export KUBECONFIG=$(kind get kubeconfig-path --name=aibox 2>/dev/null || echo "$HOME/.kube/config")
log "KUBECONFIG set to $KUBECONFIG"

# ==========================================
# Install cloud-provider-kind (LoadBalancer support)
# ==========================================
log "Installing cloud-provider-kind..."
CPK_VERSION="0.6.0"
CPK_ARCH="darwin_${ARCH}"
CPK_URL="https://github.com/kubernetes-sigs/cloud-provider-kind/releases/download/v${CPK_VERSION}/cloud-provider-kind_${CPK_VERSION}_${CPK_ARCH}.tar.gz"

CPK_BIN="${HOME}/.local/bin"
mkdir -p "$CPK_BIN"
if ! command -v cloud-provider-kind &>/dev/null; then
  curl -L "$CPK_URL" | tar xz -C "$CPK_BIN" cloud-provider-kind
  chmod +x "$CPK_BIN/cloud-provider-kind"
fi
export PATH="$CPK_BIN:$PATH"

log "Starting cloud-provider-kind..."
nohup cloud-provider-kind > /tmp/cloud-provider-kind.log 2>&1 &

log "Setup complete!"
