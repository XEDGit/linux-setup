#!/usr/bin/env bash
# Bootstrap a fresh Ubuntu system
set -euo pipefail

usage() {
  cat <<EOF
Usage: $(basename "$0") [options]

Install zsh, oh-my-zsh, starship, tmux, ghostty and docker, and deploy the dotfiles in ./files.

Options:
  --container   Set up inside a container: allows running as root, skips ghostty and docker
  --trust-repo  Let git use this repo even if it's owned by another user (e.g. mounted in a container)
  -h, --help    Show this help
EOF
}

# flags
CONTAINER=0
TRUST_REPO=0
for arg in "$@"; do
  case "$arg" in
    --container) CONTAINER=1 ;;
    --trust-repo) TRUST_REPO=1 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $arg (see --help)" >&2; exit 1 ;;
  esac
done

# container check
in_container() {
  [[ -f /.dockerenv || -f /run/.containerenv ]] || systemd-detect-virt --container --quiet 2>/dev/null
}
if [[ $CONTAINER -eq 0 ]] && in_container; then
  echo "This looks like a container, rerun with --container." >&2
  exit 1
fi

# Re-launch as root if needed
if [[ $EUID -ne 0 ]]; then
  exec sudo --preserve-env=HOME bash "$(realpath "$0")" "$@"
fi

TARGET_USER="${SUDO_USER:-root}"
if [[ "$TARGET_USER" == "root" && $CONTAINER -eq 0 ]]; then
  echo "Run this script as your normal user (it will elevate itself), root is only allowed with --container." >&2
  exit 1
fi
TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
TARGET_GROUP="$(id -gn "$TARGET_USER")"
SCRIPT_DIR="$(cd "$(dirname "$(realpath "$0")")" && pwd)"
FILES_DIR="$SCRIPT_DIR/files"
BACKUP_DIR="$TARGET_HOME/.setup-backup/$(date +%Y%m%d-%H%M%S)"

log() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
as_user() {
  if [[ "$TARGET_USER" == "root" ]]; then
    HOME="$TARGET_HOME" "$@"
  else
    sudo -u "$TARGET_USER" HOME="$TARGET_HOME" "$@"
  fi
}

# trust repo if owned by another user
GIT_ARGS=()
if [[ $TRUST_REPO -eq 1 ]]; then
  GIT_ARGS=(-c safe.directory='*')
fi

# backup existing files to $BACKUP_DIR
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
PACKAGES=(zsh tmux git curl ca-certificates nala build-essential cmake)
[[ $CONTAINER -eq 1 ]] || PACKAGES+=(ghostty)
apt-get install -y "${PACKAGES[@]}"

# docker
if [[ $CONTAINER -eq 0 ]]; then
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
fi

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

# git error hint
if [[ -e "$SCRIPT_DIR/.git" ]]; then
  git_check="$(as_user git "${GIT_ARGS[@]}" -C "$SCRIPT_DIR" rev-parse 2>&1 || true)"
  if [[ "$git_check" == *"dubious ownership"* ]]; then
    echo "git doesn't trust $SCRIPT_DIR because it's owned by another user, rerun with --trust-repo." >&2
    exit 1
  fi
fi

ensure_submodule() {
  local url="$1" path="$2"
  if [[ ! -e "$SCRIPT_DIR/.git" ]]; then
    [[ -n "$(ls -A "$SCRIPT_DIR/$path" 2>/dev/null)" ]] || as_user git clone "$url" "$SCRIPT_DIR/$path"
  elif as_user git "${GIT_ARGS[@]}" -C "$SCRIPT_DIR" config -f .gitmodules --get "submodule.$path.url" >/dev/null 2>&1; then
    as_user git "${GIT_ARGS[@]}" -C "$SCRIPT_DIR" submodule update --init -- "$path"
  else
    as_user git "${GIT_ARGS[@]}" -C "$SCRIPT_DIR" submodule add "$url" "$path"
  fi
}

SUBMODULES=(
  "https://github.com/wfxr/tmux-power.git  files/tmux/tmux-power"
  "https://github.com/tmux-plugins/tpm.git files/tmux/plugins/tpm"
)
for sub in "${SUBMODULES[@]}"; do
  ensure_submodule $sub
done

# tmux
log "Deploying tmux config to ~/.config/tmux"
backup "$TARGET_HOME/.config/tmux"
cp -a "$FILES_DIR/tmux" "$TARGET_HOME/.config/tmux"
chown -R "$TARGET_USER:$TARGET_GROUP" "$TARGET_HOME/.config/tmux"

for sub in "${SUBMODULES[@]}"; do
  read -r url path <<<"$sub"
  dest="$TARGET_HOME/.config/${path#files/}"
  rm -rf "$dest"
  as_user git "${GIT_ARGS[@]}" clone -q "$SCRIPT_DIR/$path" "$dest"
  as_user git -C "$dest" checkout -q "$(as_user git "${GIT_ARGS[@]}" -C "$SCRIPT_DIR/$path" rev-parse HEAD)"
  as_user git -C "$dest" remote set-url origin "$url"
done

chmod +x "$TARGET_HOME/.config/tmux/utilities/"*.sh \
         "$TARGET_HOME/.config/tmux/utilities/show-tmux-ks" \
         "$TARGET_HOME/.config/tmux/tmux-power/tmux-power.tmux"

# shortcut cheat sheet
ln -sf "$TARGET_HOME/.config/tmux/utilities/show-tmux-ks" /usr/local/bin/show-tmux-ks

log "Installing tmux plugins via TPM"
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
