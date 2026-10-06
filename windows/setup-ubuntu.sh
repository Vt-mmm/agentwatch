#!/usr/bin/env bash
# Piagent inside WSL (Ubuntu): the part of windows/setup.ps1 that runs in the
# distribution. Safe to run again; a second run updates.
#   bash setup-ubuntu.sh system <user>          as root: packages, the sandbox
#   bash setup-ubuntu.sh piagent [name] [email]  as the member: Node, Piagent
set -euo pipefail

NVM_VERSION=v0.40.3
NODE_MAJOR=24
PACKAGES=(bubblewrap git ripgrep fd-find build-essential curl ca-certificates)

step() { printf '\n==> %s\n' "$*"; }

system_phase() {
  local user=${1:?member user}
  [ "$(id -u)" = 0 ] || { echo "system phase runs as root" >&2; exit 64; }
  id "$user" >/dev/null 2>&1 || { echo "no user $user" >&2; exit 67; }
  step "Ubuntu packages: ${PACKAGES[*]}"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y -qq --no-install-recommends "${PACKAGES[@]}" >/dev/null
  # Company conversations run every command in a bubblewrap sandbox, which
  # needs unprivileged user namespaces. Ubuntu 24.04 restricts them through
  # AppArmor wherever the kernel has it.
  local key=kernel.apparmor_restrict_unprivileged_userns
  if [ "$(sysctl -n "$key" 2>/dev/null || echo 0)" = 1 ]; then
    step "Allowing unprivileged user namespaces for the sandbox"
    printf '%s=0\n' "$key" > /etc/sysctl.d/60-piagent-userns.conf
    sysctl -q -p /etc/sysctl.d/60-piagent-userns.conf
  fi
}

piagent_phase() {
  local name=${1:-} email=${2:-}
  # setup.ps1 sends "-" for an empty value.
  [ "$name" != - ] || name=""; [ "$email" != - ] || email=""
  [ "$(id -u)" != 0 ] || { echo "piagent phase runs as the member, not root" >&2; exit 64; }
  cd "$HOME"
  export NVM_DIR="$HOME/.nvm"
  # nvm from its tagged source (no install script piped to a shell); the
  # member's shells load it from ~/.bashrc.
  if [ ! -s "$NVM_DIR/nvm.sh" ]; then
    step "nvm $NVM_VERSION"
    git -c advice.detachedHead=false clone -q --depth 1 --branch "$NVM_VERSION" https://github.com/nvm-sh/nvm.git "$NVM_DIR"
  fi
  if ! grep -q 'NVM_DIR/nvm.sh' "$HOME/.bashrc" 2>/dev/null; then
    printf '\nexport NVM_DIR="$HOME/.nvm"\n[ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"\n' >> "$HOME/.bashrc"
  fi
  set +u; . "$NVM_DIR/nvm.sh"; set -u
  step "Node $NODE_MAJOR"
  set +u; nvm install "$NODE_MAJOR" >/dev/null; nvm alias default "$NODE_MAJOR" >/dev/null; nvm use "$NODE_MAJOR" >/dev/null; set -u
  step "Piagent"
  npm install -g --ignore-scripts --no-fund --no-audit --loglevel=error @piagent/platform@latest
  piagent-update
  # Records where Piagent and its Node are, for Agent Watch's binding.
  piagent --help >/dev/null
  if [ -n "$name" ] && [ -z "$(git config --global user.name || true)" ]; then git config --global user.name "$name"; fi
  if [ -n "$email" ] && [ -z "$(git config --global user.email || true)" ]; then git config --global user.email "$email"; fi
  # The sandbox check of the doctor, without a model request.
  if bwrap --unshare-user --unshare-net --ro-bind / / true 2>/dev/null; then
    echo "SANDBOX-OK"
  else
    echo "SANDBOX-UNAVAILABLE"
  fi
  printf 'PIAGENT-VERSION %s\n' "$(node -p "require('$(npm root -g)/@piagent/platform/package.json').version")"
}

case "${1:-}" in
  system) shift; system_phase "$@" ;;
  piagent) shift; piagent_phase "$@" ;;
  *) echo "usage: setup-ubuntu.sh system <user> | piagent [name] [email]" >&2; exit 64 ;;
esac
