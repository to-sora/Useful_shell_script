#!/usr/bin/env bash

NVM_VERSION="${NVM_VERSION:-v0.40.4}"
NODE_VERSION="${NODE_VERSION:-24}"
INSTALL_CODEX="${INSTALL_CODEX:-1}"

NVM_DIR="$HOME/.nvm"
BASHRC="$HOME/.bashrc"

USER_INSTALL_DIR="$HOME/install_nvm"
USER_CACHE_DIR="$HOME/.cache/node-npm-install"
USER_TMP_DIR="$HOME/.cache/tmp"

NVM_INSTALLER="$USER_INSTALL_DIR/nvm-install-$NVM_VERSION.sh"

mkdir -p "$USER_INSTALL_DIR" "$USER_CACHE_DIR" "$USER_TMP_DIR"

# Force tools that respect TMPDIR to avoid /tmp.
export TMPDIR="$USER_TMP_DIR"
export TEMP="$USER_TMP_DIR"
export TMP="$USER_TMP_DIR"

echo "Installing per-user Node.js/npm setup"
echo "User: $(whoami)"
echo "Home: $HOME"
echo "nvm version: $NVM_VERSION"
echo "Node version: $NODE_VERSION"
echo "TMPDIR: $TMPDIR"
echo

cd "$HOME"

# Basic dependency check
for cmd in curl bash grep sed awk tar; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "Missing required command: $cmd"
    echo "Ask your administrator to install it, or use a system where it exists."
    exit 1
  fi
done

# Ensure .bashrc exists
touch "$BASHRC"

# Install nvm if needed
if [ ! -s "$NVM_DIR/nvm.sh" ]; then
  echo "nvm not found. Downloading pinned installer to:"
  echo "$NVM_INSTALLER"
  echo

  curl -fsSL "https://raw.githubusercontent.com/nvm-sh/nvm/$NVM_VERSION/install.sh" \
    -o "$NVM_INSTALLER"

  chmod 700 "$NVM_INSTALLER"

  echo "Installer downloaded."
  echo "To inspect it before running, use:"
  echo "  less \"$NVM_INSTALLER\""
  echo
  echo "Running installer..."
  bash "$NVM_INSTALLER"
else
  echo "nvm already exists at $NVM_DIR"
fi

# Ensure .bashrc loads nvm every time
if ! grep -Fq '# >>> nvm per-user Node.js >>>' "$BASHRC"; then
  echo "Adding nvm loader to $BASHRC"

  cat >> "$BASHRC" <<'EOF'

# >>> nvm per-user Node.js >>>
export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"
# <<< nvm per-user Node.js <<<
EOF
else
  echo "nvm loader already exists in $BASHRC"
fi

# Load nvm into this current shell
export NVM_DIR="$HOME/.nvm"
# shellcheck source=/dev/null
. "$NVM_DIR/nvm.sh"

# Install Node.js and bundled npm
echo
echo "Installing/using Node.js $NODE_VERSION"
nvm install "$NODE_VERSION"
nvm alias default "$NODE_VERSION"
nvm use default

# Refresh shell command cache
hash -r

echo
echo "Verifying Node/npm/npx paths:"
echo "node: $(command -v node || true)"
echo "npm:  $(command -v npm || true)"
echo "npx:  $(command -v npx || true)"
echo

node -v
npm -v
npx -v

echo
echo "Node executable:"
nvm which current

# Sanity check: ensure npm is from ~/.nvm, not system apt
NPM_PATH="$(command -v npm)"
case "$NPM_PATH" in
  "$HOME/.nvm/"*)
    echo "npm is correctly installed under your user account."
    ;;
  *)
    echo "Warning: npm is not under ~/.nvm:"
    echo "$NPM_PATH"
    echo "Check your PATH."
    exit 1
    ;;
esac


echo
echo "Done."
echo
echo "Open a new terminal, or run:"
echo "  source ~/.bashrc"
echo
echo "Then verify with:"
echo "  command -v node"
echo "  command -v npm"
echo "  command -v npx"
echo
echo "No installer file was written to /tmp."
echo "Installer location:"
echo "  $NVM_INSTALLER"
