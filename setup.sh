#!/usr/bin/env bash
# Bootstrap a fresh Ubuntu system
set -euo pipefail

# Re-launch as root if needed
if [[ $EUID -ne 0 ]]; then
  exec sudo --preserve-env=HOME bash "$(realpath "$0")" "$@"
fi

TARGET_USER="${SUDO_USER:-}"
if [[ -z "$TARGET_USER" || "$TARGET_USER" == "root" ]]; then
  echo "Run this script as your normal user (it will elevate itself), not directly as root." >&2
  exit 1
fi
TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
TARGET_GROUP="$(id -gn "$TARGET_USER")"
SCRIPT_DIR="$(cd "$(dirname "$(realpath "$0")")" && pwd)"
FILES_DIR="$SCRIPT_DIR/files"
BACKUP_DIR="$TARGET_HOME/.setup-backup/$(date +%Y%m%d-%H%M%S)"

log() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
as_user() { sudo -u "$TARGET_USER" HOME="$TARGET_HOME" "$@"; }

# Move an existing file/dir into $BACKUP_DIR
backup() {
  if [[ -e "$1" || -L "$1" ]]; then
    local dest="$BACKUP_DIR/${1#"$TARGET_HOME"/}"
    echo "Backing up $1 -> $dest"
    as_user mkdir -p "$(dirname "$dest")"
    mv "$1" "$dest"
  fi
}

# apt packages
log "Installing packages"
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y \
  zsh tmux git curl ca-certificates nala \
  build-essential cmake \
  ghostty

# docker
log "Installing Docker"
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc
cat > /etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: $(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}")
Components: stable
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/docker.asc
EOF
apt-get update
apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
systemctl enable --now docker
usermod -aG docker "$TARGET_USER"

# starship
log "Installing starship"
if ! command -v starship >/dev/null 2>&1; then
  curl -fsSL https://starship.rs/install.sh | sh -s -- -y
fi

log "Applying starship preset: gruvbox-rainbow"
as_user mkdir -p "$TARGET_HOME/.config"
backup "$TARGET_HOME/.config/starship.toml"
as_user starship preset gruvbox-rainbow -o "$TARGET_HOME/.config/starship.toml"

# omz
log "Installing oh-my-zsh"
if [[ ! -d "$TARGET_HOME/.oh-my-zsh" ]]; then
  as_user env RUNZSH=no CHSH=no KEEP_ZSHRC=yes sh -c \
    "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended
fi

log "Deploying .zshrc"
backup "$TARGET_HOME/.zshrc"
install -m 644 -o "$TARGET_USER" -g "$TARGET_GROUP" "$FILES_DIR/.zshrc" "$TARGET_HOME/.zshrc"

# submodules
log "Fetching tmux submodules"

# Init a submodule if registered, otherwise add it
ensure_submodule() {
  local url="$1" path="$2"
  if [[ ! -e "$SCRIPT_DIR/.git" ]]; then
    # Not a git checkout, clone if missing
    [[ -n "$(ls -A "$SCRIPT_DIR/$path" 2>/dev/null)" ]] || as_user git clone "$url" "$SCRIPT_DIR/$path"
  elif as_user git -C "$SCRIPT_DIR" config -f .gitmodules --get "submodule.$path.url" >/dev/null 2>&1; then
    as_user git -C "$SCRIPT_DIR" submodule update --init -- "$path"
  else
    as_user git -C "$SCRIPT_DIR" submodule add "$url" "$path"
  fi
}

ensure_submodule https://github.com/wfxr/tmux-power.git  files/tmux/tmux-power
ensure_submodule https://github.com/tmux-plugins/tpm.git files/tmux/plugins/tpm

# tmux
log "Deploying tmux config to ~/.config/tmux"
backup "$TARGET_HOME/.config/tmux"
cp -a "$FILES_DIR/tmux" "$TARGET_HOME/.config/tmux"
chown -R "$TARGET_USER:$TARGET_GROUP" "$TARGET_HOME/.config/tmux"
chmod +x "$TARGET_HOME/.config/tmux/utilities/"*.sh \
         "$TARGET_HOME/.config/tmux/tmux-power/tmux-power.tmux"

log "Installing tmux plugins via TPM"
# TPM needs a running server to know where plugins go, use a throwaway one
TPM_TMPDIR="$(as_user mktemp -d)"
as_user env TMUX_TMPDIR="$TPM_TMPDIR" tmux new-session -d -s tpm-setup
as_user env TMUX_TMPDIR="$TPM_TMPDIR" "$TARGET_HOME/.config/tmux/plugins/tpm/bin/install_plugins"
as_user env TMUX_TMPDIR="$TPM_TMPDIR" tmux kill-server || true
rm -rf "$TPM_TMPDIR"

log "Building tmux-mem-cpu-load"
BUILD_DIR="$(mktemp -d)"
cmake -S "$TARGET_HOME/.config/tmux/plugins/tmux-mem-cpu-load" -B "$BUILD_DIR" -DCMAKE_BUILD_TYPE=Release
cmake --build "$BUILD_DIR" -j"$(nproc)"
cmake --install "$BUILD_DIR"
rm -rf "$BUILD_DIR"

# chsh
log "Setting zsh as default shell for $TARGET_USER"
chsh -s "$(command -v zsh)" "$TARGET_USER"

log "Done."
