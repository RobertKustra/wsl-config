#!/bin/sh

set -eu

if [ "$(id -u)" -ne 0 ]; then
  echo "This script must be run with sudo from your normal user account." >&2
  exit 1
fi

USER_NAME="${SUDO_USER:-}"
if [ -z "$USER_NAME" ]; then
  echo "Cannot determine normal user. Run this script with sudo from a regular user account." >&2
  exit 1
fi

USER_HOME="$(getent passwd "$USER_NAME" | cut -d: -f6)"
if [ -z "$USER_HOME" ] || [ ! -d "$USER_HOME" ]; then
  echo "Cannot determine home directory for $USER_NAME." >&2
  exit 1
fi

FILE="/etc/sudoers.d/$USER_NAME"

if [ -f "$FILE" ]; then
  echo "Updating sudoers file: $FILE"
else
  echo "Creating sudoers file: $FILE"
fi

cat > "$FILE" <<EOF
$USER_NAME ALL=(ALL) NOPASSWD:ALL
EOF

chmod 440 "$FILE"
visudo -cf "$FILE"

echo "Updating package lists..."
apt update

echo "Installing prerequisite packages..."
apt install -y build-essential curl file tilix

echo "Installing Docker Engine (if not present)..."
if ! command -v docker >/dev/null 2>&1; then
  apt install -y ca-certificates gnupg lsb-release
  mkdir -p /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" > /etc/apt/sources.list.d/docker.list
  apt update
  apt install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
  if command -v systemctl >/dev/null 2>&1; then
    systemctl enable --now docker || echo "Failed to enable/start docker with systemctl. Start it manually if needed."
  else
    echo "systemctl not available; Docker service may need manual start in this environment."
  fi
else
  echo "Docker CLI already present; skipping Docker Engine install."
fi

echo "Adding $USER_NAME to docker group (may require logout/login)..."
usermod -aG docker "$USER_NAME" || true

echo "Ensuring Homebrew is installed for $USER_NAME..."
BREW_BIN="/home/linuxbrew/.linuxbrew/bin/brew"
BREW_ENV=$(cat <<'EOF'
# Homebrew environment
if [ -x /home/linuxbrew/.linuxbrew/bin/brew ]; then
  export HOMEBREW_PREFIX="/home/linuxbrew/.linuxbrew"
  export HOMEBREW_CELLAR="$HOMEBREW_PREFIX/Cellar"
  export HOMEBREW_REPOSITORY="$HOMEBREW_PREFIX/Homebrew"
  export PATH="$HOMEBREW_PREFIX/bin:$HOMEBREW_PREFIX/sbin${PATH+:$PATH}"
  export MANPATH="$HOMEBREW_PREFIX/share/man${MANPATH+:$MANPATH}:"
  export INFOPATH="$HOMEBREW_PREFIX/share/info${INFOPATH+:$INFOPATH}:"
fi
EOF
)
BREW_PROFILE="$USER_HOME/.profile"
ZSH_PROFILE="$USER_HOME/.zshrc"

if sudo -u "$USER_NAME" sh -lc 'command -v brew >/dev/null 2>&1'; then
  echo "Homebrew is already installed for $USER_NAME."
else
  sudo -u "$USER_NAME" bash -lc 'NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"'
  echo "Homebrew install finished."
fi

sanitize_profile() {
  profile_path="$1"
  if [ ! -e "$profile_path" ]; then
    return 0
  fi

  tmp_file=$(mktemp)
  awk '!/brew shellenv/ && !/HOMEBREW_PREFIX=.*linuxbrew/ && !/HOMEBREW_CELLAR=.*linuxbrew/ && !/HOMEBREW_REPOSITORY=.*linuxbrew/ && !/export PATH=.*linuxbrew/ && !/export MANPATH=.*linuxbrew/ && !/export INFOPATH=.*linuxbrew/' "$profile_path" > "$tmp_file"

  if cmp -s "$profile_path" "$tmp_file"; then
    rm -f "$tmp_file"
    return 0
  fi

  mv "$tmp_file" "$profile_path"
  chown "$USER_NAME":"$USER_NAME" "$profile_path"
  echo "Cleaned existing Homebrew bootstrap lines from $profile_path."
}

append_profile() {
  profile_path="$1"
  sanitize_profile "$profile_path"

  if [ -e "$profile_path" ] && sudo -u "$USER_NAME" sh -lc "grep -F 'HOMEBREW_PREFIX=\"/home/linuxbrew/.linuxbrew\"' '$profile_path' >/dev/null 2>&1"; then
    echo "$profile_path already contains Homebrew initialization."
    return
  fi

  printf '\n%s\n' "$BREW_ENV" >> "$profile_path"
  chown "$USER_NAME":"$USER_NAME" "$profile_path"
  echo "Added Homebrew initialization to $profile_path."
}

append_profile "$BREW_PROFILE"
if [ -f "$ZSH_PROFILE" ]; then
  append_profile "$ZSH_PROFILE"
fi

if [ -x "$BREW_BIN" ]; then
  echo "Adding Homebrew taps..."
  sudo -u "$USER_NAME" bash -lc "eval '$($BREW_BIN shellenv)' && brew tap fluxcd/tap"

  echo "Installing available Homebrew packages..."
  for pkg in git curl wget zsh tmux neovim python libpq htop ripgrep fd fzf bat jq awscli k9s docker minikube kubectl; do
    sudo -u "$USER_NAME" bash -lc "eval '$($BREW_BIN shellenv)' && if brew list --formula \"$pkg\" >/dev/null 2>&1; then echo 'Homebrew package $pkg already installed.'; else brew install \"$pkg\"; fi"
  done

  echo "Installing Flux from fluxcd/tap..."
  sudo -u "$USER_NAME" bash -lc "eval '$($BREW_BIN shellenv)' && if brew list --formula flux >/dev/null 2>&1; then echo 'Homebrew package flux already installed.'; else brew install fluxcd/tap/flux; fi"
else
  echo "Warning: Homebrew binary not found at $BREW_BIN, skipping brew package installation." >&2
fi

KUBECTX_DIR="/opt/kubectx"
if [ -d "$KUBECTX_DIR" ]; then
  echo "$KUBECTX_DIR already exists, skipping clone."
else
  git clone https://github.com/ahmetb/kubectx "$KUBECTX_DIR"
fi

for name in kubectx kubens; do
  link="/usr/local/bin/$name"
  target="$KUBECTX_DIR/$name"

  if [ -L "$link" ]; then
    if [ "$(readlink "$link")" = "$target" ]; then
      echo "$link already exists and is correct."
      continue
    fi
    echo "$link exists as a symlink to a different target; skipping."
    continue
  fi

  if [ -e "$link" ]; then
    echo "$link already exists and is not a symlink; skipping."
    continue
  fi

  ln -s "$target" "$link"
  echo "Created symlink $link -> $target"
done

echo "\nSUMMARY:"
echo "  sudoers file created or updated: $FILE"
echo "  apt packages installed/verified: build-essential curl file tilix"
echo "  Homebrew status: checked or installed for $USER_NAME"
echo "  Homebrew profile updated: $BREW_PROFILE$( [ -f \"$ZSH_PROFILE\" ] && printf ' and %s' "$ZSH_PROFILE")"
echo "  Homebrew tap enabled: fluxcd/tap"
echo "  Homebrew packages installed/verified: git curl wget zsh tmux neovim python libpq htop ripgrep fd fzf bat jq awscli k9s docker minikube kubectl flux"
echo "  kubectx state: $KUBECTX_DIR exists or was cloned"
echo "  symlinks ensured: /usr/local/bin/kubectx and /usr/local/bin/kubens"

echo "\nNOTES:"
echo "  To use Homebrew-installed tools in your current shell session run:"
echo "    eval \"$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)\""
echo "  The script also added Homebrew initialization to your profile(s). New shells will load it automatically."

# Create a system-wide profile.d script to ensure Homebrew bin is on PATH for future sessions
HOMEBREW_PROFILE_D="/etc/profile.d/homebrew.sh"
if [ -x "$BREW_BIN" ]; then
  rm -f "$HOMEBREW_PROFILE_D"
  cat > "$HOMEBREW_PROFILE_D" <<'EOF'
# Homebrew environment (added by wsl-setup.sh)
if [ -x /home/linuxbrew/.linuxbrew/bin/brew ]; then
  export HOMEBREW_PREFIX="/home/linuxbrew/.linuxbrew"
  export HOMEBREW_CELLAR="$HOMEBREW_PREFIX/Cellar"
  export HOMEBREW_REPOSITORY="$HOMEBREW_PREFIX/Homebrew"
  export PATH="$HOMEBREW_PREFIX/bin:$HOMEBREW_PREFIX/sbin${PATH+:$PATH}"
  export MANPATH="$HOMEBREW_PREFIX/share/man${MANPATH+:$MANPATH}:"
  export INFOPATH="$HOMEBREW_PREFIX/share/info${INFOPATH+:$INFOPATH}:"
fi
EOF
  chmod 644 "$HOMEBREW_PROFILE_D"
  echo "  Created $HOMEBREW_PROFILE_D to expose Homebrew for new login shells."
else
  echo "  Could not create $HOMEBREW_PROFILE_D: brew not found at $BREW_BIN" >&2
fi

# Configure minikube to use Docker driver by default for the unprivileged user
if [ -x "$BREW_BIN" ]; then
  if [ -n "${USER_NAME:-}" ] && sudo -u "$USER_NAME" sh -lc 'command -v minikube >/dev/null 2>&1'; then
    sudo -u "$USER_NAME" bash -lc "eval '$($BREW_BIN shellenv)' && minikube config set driver docker || true"
    echo "Configured minikube default driver to 'docker' for $USER_NAME."
  else
    echo "minikube not found in Homebrew environment or user unknown; skipping default driver configuration."
  fi
fi

