#!/usr/bin/env bash
# Managed installation of four CLIs (agy, grok, claude, codex), plus optional
# native Cursor Agent. One installation per provider under ~/.install, and
# separate named account homes at ~/.install/profiles/PROVIDER/ACCOUNT.
# The `agent` dispatcher follows native Cursor/Grok ownership, NOT Grok always.
# Ubuntu/Linux, macOS (Bash >= 3.2), WSL. No sudo required.
set -euo pipefail
umask 077
SCRIPT_VERSION="2026-11-22.5"

if [ "${SUDO_USER:-}" ] && [ "$(id -u)" -eq 0 ]; then
  printf 'ERROR: Do not use sudo; install as the intended normal user.\n' >&2
  exit 1
fi
REAL_HOME="${HOME:?HOME is not set}"
REAL_HOME="${REAL_HOME%/}"
case "$REAL_HOME" in /*) ;; *) echo 'ERROR: HOME must be an absolute path' >&2; exit 1 ;; esac
ROOT="$REAL_HOME/.install"
SOURCES="$ROOT/installers"
ALL_NAMES=(agy grok claude codex)
ALL_SUPPORTED=(agy grok claude codex cursor)
SELECTED=()

fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
info() { printf '\n==> %s\n' "$*" >&2; }

usage() {
  cat <<'HELP'
One installation per tool under ~/.install; independent account profiles.
By default, install all FOUR original tools. Cursor Agent is optional.

  ./install_all_4_to_dotinstall.sh                 Interactive selector
  ./install_all_4_to_dotinstall.sh --install all   Install original four
  ./install_all_4_to_dotinstall.sh --install grok claude
  ./install_all_4_to_dotinstall.sh --install cursor   Install Cursor Agent
  ./install_all_4_to_dotinstall.sh --install all cursor  Install all five
  ./install_all_4_to_dotinstall.sh --fetch all     Save installer source snapshots
  ./install_all_4_to_dotinstall.sh --update all    Refresh original four
  ./install_all_4_to_dotinstall.sh --repair        Fix launchers and PATH offline
  ./install_all_4_to_dotinstall.sh --doctor        Repair and verify installed
  ./install_all_4_to_dotinstall.sh --verify all    Verify binaries and fresh PATH
  ./install_all_4_to_dotinstall.sh --status        Installed tools and profiles

Native command behavior:
  grok                  Always launches Grok
  cursor-agent          Launches native Cursor Agent when installed
  agent                 Uses Cursor's native agent when available,
                        otherwise uses Grok's native agent
  agy / claude / codex  Their respective provider CLIs

Accounts (no duplicate downloads):
  grok --account personal
  grok --account work
  cursor-agent --account work
  agent --account work      # follows currently selected native provider
  claude --account personal
  codex --account work
  ai-clis --set-default grok work
  ai-clis --set-default cursor personal
  ai-clis --run grok work [ARGS...]
  ai-clis --profiles [TOOL]
  ai-clis --update cursor
  ai-clis --doctor

This manager NEVER writes a Grok-owned `agent` symlink over Cursor's native
installation. The Grok binary remains in ~/.install/.grok/downloads, and
Cursor's native `agent` and `cursor-agent` are in ~/.install/.local/bin.
Both can coexist. Cursor's own switching/updater may place per-account
native launchers in the profile home; `agent` follows such native launchers.

Profiles use distinct HOME, XDG_* directories, CURSOR_CONFIG_DIR,
CLAUDE_CONFIG_DIR and CODEX_HOME. OS keyrings and inherited API keys are
NOT guaranteed isolated; for strict account separation use separate Linux
users/keyrings or independent API credentials. Running as sudo is rejected.

Bash/Zsh PATH configuration is automatic for future shells. To activate the
new PATH in the CURRENT terminal, use:
    . "$HOME/.install/env.sh"
A child installer cannot change its parent terminal's environment.

Installer snapshots and checksums are saved under ~/.install/installers.
The SHA-256 manifest prevents accidental changes after --fetch, but is
NOT a cryptographic signature of the upstream vendor.
HELP
}


check_platform() {
  case "$(uname -s)" in Darwin|Linux) ;; *) fail 'Only macOS/Linux/WSL supported' ;; esac
  command -v bash >/dev/null 2>&1 || fail 'Bash required'
}

# Reject symlinked directories, including account profile ancestors.
ensure_real_dir() {
  local dir
  for dir in "$@"; do
    [ ! -L "$dir" ] || fail "Refusing symlinked directory: $dir"
    if [ -e "$dir" ] && [ ! -d "$dir" ]; then fail "Not a directory: $dir"; fi
  done
}
prepare_dirs() {
  ensure_real_dir "$ROOT" "$ROOT/bin" "$SOURCES" "$ROOT/libexec" \
    "$ROOT/.local" "$ROOT/.local/bin" "$ROOT/.local/share" \
    "$ROOT/.local/state" "$ROOT/.grok" "$ROOT/.grok/downloads" \
    "$ROOT/.claude" "$ROOT/.codex" "$ROOT/.cache" "$ROOT/.config" \
    "$ROOT/grok" "$ROOT/grok/bin" "$ROOT/codex" "$ROOT/codex/bin" \
    "$ROOT/tmp" "$ROOT/profiles" "$ROOT/profiles/defaults"
  mkdir -p "$ROOT/bin" "$SOURCES" "$ROOT/libexec" "$ROOT/.local/bin" \
    "$ROOT/.local/share" "$ROOT/.local/state" "$ROOT/.grok/downloads" \
    "$ROOT/.claude" "$ROOT/.codex" "$ROOT/.cache" "$ROOT/.config" \
    "$ROOT/grok/bin" "$ROOT/codex/bin" "$ROOT/tmp" \
    "$ROOT/profiles/defaults"
}

sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | awk '{print $1}'
  elif command -v openssl >/dev/null 2>&1; then openssl dgst -sha256 "$1" | sed 's/^.*= //'
  else fail 'Need sha256sum, shasum, or openssl'; fi
}

normalize_tool() {
  case "$1" in
    1|agy|antigravity) printf 'agy\n' ;;
    2|grok) printf 'grok\n' ;;
    3|claude|claude-code) printf 'claude\n' ;;
    4|codex|openai-codex) printf 'codex\n' ;;
    6|cursor|cursor-agent) printf 'cursor\n' ;;
    agent)
      if [ -x "$ROOT/.local/bin/cursor-agent" ]; then printf 'cursor\n'
      else printf 'grok\n'; fi ;;
    *) fail "Unknown CLI '$1' (agy, grok, claude, codex, cursor)" ;;
  esac
}


valid_account() {
  case "$1" in
    ''|.|..|*[!a-zA-Z0-9._-]*) return 1 ;;
    [a-zA-Z0-9]*) return 0 ;;
    *) return 1 ;;
  esac
}
add_selected() {
  local name="$1" current
  case "$name" in
    all|a|5) for name in "${ALL_NAMES[@]}"; do add_selected "$name"; done; return ;;
    all-five|all5|7) for name in "${ALL_SUPPORTED[@]}"; do add_selected "$name"; done; return ;;
  esac
  name="$(normalize_tool "$name")"
  for current in "${SELECTED[@]}"; do [ "$name" != "$current" ] || return 0; done
  SELECTED+=("$name")
}
select_tools() {
  local argument part
  SELECTED=()
  if [ "$#" -eq 0 ]; then add_selected all; return; fi
  for argument in "$@"; do
    local parts=()
    IFS=',' read -r -a parts <<< "$argument"
    for part in "${parts[@]}"; do
      [ -n "$part" ] || fail "Empty tool name in '$argument'"
      add_selected "$part"
    done
  done
  [ "${#SELECTED[@]}" -gt 0 ] || fail 'No CLIs specified'
}
menu_select() {
  local answer part pieces=()
  printf '\nChoose CLIs to install into %s\n\n' "$ROOT"
  printf '  1) Antigravity (agy)\n  2) Grok (grok)\n  3) Claude Code (claude)\n  4) Codex (codex)\n  5) All four\n  6) Cursor Agent (optional)\n  7) All five\n\n'
  printf 'Selection (e.g. 3 or 2,4 or 5): '
  IFS= read -r answer || fail 'No input received'
  answer="${answer//,/ }"
  read -r -a pieces <<< "$answer"
  [ "${#pieces[@]}" -gt 0 ] || fail 'No selection given'
  SELECTED=()
  for part in "${pieces[@]}"; do add_selected "$part"; done
}
url_for() {
  case "$1" in
    agy) printf '%s\n' 'https://antigravity.google/cli/install.sh' ;;
    grok) printf '%s\n' 'https://x.ai/cli/install.sh' ;;
    claude) printf '%s\n' 'https://claude.ai/install.sh' ;;
    codex) printf '%s\n' 'https://chatgpt.com/codex/install.sh' ;;
    cursor) printf '%s\n' 'https://cursor.com/install' ;;
  esac
}
shell_for() { case "$1" in codex) printf 'sh\n';; *) printf 'bash\n';; esac; }

fetch_one() {
  local name="$1" url shell_kind saved tmp numbered hashfile
  command -v curl >/dev/null 2>&1 || fail 'curl needed for --fetch / --install'
  url="$(url_for "$name")"; shell_kind="$(shell_for "$name")"
  saved="$SOURCES/$name.sh"
  tmp="$(mktemp "$SOURCES/.$name.fetch.XXXXXX")"
  info "Fetching $name from $url"
  if ! curl --fail --silent --show-error --location --retry 3 \
      --connect-timeout 15 --proto '=https' --proto-redir '=https' -o "$tmp" "$url"; then
    rm -f "$tmp"; fail "Fetch failed for $name"
  fi
  if [ ! -s "$tmp" ] || ! "$shell_kind" -n "$tmp"; then
    rm -f "$tmp"; fail "Invalid installer source for $name"
  fi
  chmod 600 "$tmp"
  mv -f "$tmp" "$saved"
  numbered="$(mktemp "$SOURCES/.$name.numbered.XXXXXX")"
  hashfile="$(mktemp "$SOURCES/.$name.hash.XXXXXX")"
  nl -ba "$saved" > "$numbered"
  sha256_file "$saved" > "$hashfile"
  mv -f "$numbered" "$SOURCES/$name.numbered.txt"
  mv -f "$hashfile" "$SOURCES/$name.sha256"
  printf '%s: %s lines; sha256 %s\n' "$name" \
    "$(wc -l < "$saved" | tr -d ' ')" "$(cat "$SOURCES/$name.sha256")"
}
fetch_selected() {
  prepare_dirs
  local name failed=()
  for name in "${SELECTED[@]}"; do
    if ( fetch_one "$name" ); then
      printf 'FETCHED %s\n' "$name"
    else
      failed+=("$name")
      printf 'FAILED downloading %s; trying remaining selections\n' "$name" >&2
    fi
  done
  printf '\nSources with numbered lines: %s/NAME.numbered.txt\n' "$SOURCES"
  [ "${#failed[@]}" -eq 0 ] || fail "Failed fetching: ${failed[*]}"
}
ensure_snapshot() {
  local name="$1"
  if [ ! -e "$SOURCES/$name.sh" ] && [ ! -e "$SOURCES/$name.sha256" ]; then
    fetch_one "$name"
  elif [ ! -s "$SOURCES/$name.sh" ] || [ ! -f "$SOURCES/$name.sha256" ]; then
    fail "Incomplete installer snapshot for $name. Run --fetch $name"
  fi
}
check_snapshot() {
  local name="$1" expected actual
  expected="$(cat "$SOURCES/$name.sha256")"
  actual="$(sha256_file "$SOURCES/$name.sh")"
  [ "$expected" = "$actual" ] || fail "Installer for $name changed since fetch: review and --fetch again"
  "$(shell_for "$name")" -n "$SOURCES/$name.sh" || fail "Shell syntax error: $name.sh"
}

isolated_install() (
  local name="$1"
  cd "$ROOT"
  # Installations and installers use ONE shared prefix, not a per-account HOME.
  export HOME="$ROOT"
  export XDG_CONFIG_HOME="$ROOT/.config"
  export XDG_DATA_HOME="$ROOT/.local/share"
  export XDG_STATE_HOME="$ROOT/.local/state"
  export XDG_CACHE_HOME="$ROOT/.cache"
  export TMPDIR="$ROOT/tmp"
  export CLAUDE_CONFIG_DIR="$ROOT/.claude"
  export CODEX_HOME="$ROOT/.codex"
  export CODEX_SQLITE_HOME="$ROOT/.codex"
  export CODEX_INSTALL_DIR="$ROOT/codex/bin"
  export CODEX_NON_INTERACTIVE=1
  export GROK_BIN_DIR="$ROOT/grok/bin"
  export CURSOR_CONFIG_DIR="$ROOT/.config/cursor"
  export PATH="$ROOT/.local/bin:$ROOT/grok/bin:$ROOT/codex/bin:$PATH"
  unset BASH_ENV ENV
  info "Installing $name with isolated installer HOME=$ROOT"
  case "$name" in
    codex) sh "$SOURCES/$name.sh" ;;
    agy) bash "$SOURCES/$name.sh" --skip-aliases --skip-path ;;
    *) bash "$SOURCES/$name.sh" ;;
  esac
)

grok_download_path() {
  local os arch
  case "$(uname -s)" in Linux) os=linux ;; Darwin) os=macos ;; *) fail 'Unsupported OS' ;; esac
  case "$(uname -m)" in
    x86_64|amd64|AMD64) arch=x86_64 ;;
    arm64|aarch64|ARM64) arch=aarch64 ;;
    *) fail 'Unsupported architecture for Grok' ;;
  esac
  printf '%s\n' "$ROOT/.grok/downloads/grok-$os-$arch"
}
expected_command() {
  case "$1" in
    agy) printf '%s\n' "$ROOT/.local/bin/agy" ;;
    grok)
      if [ -x "$ROOT/grok/bin/grok" ]; then printf '%s\n' "$ROOT/grok/bin/grok"
      else grok_download_path; fi ;;
    claude) printf '%s\n' "$ROOT/.local/bin/claude" ;;
    codex) printf '%s\n' "$ROOT/codex/bin/codex" ;;
    cursor) printf '%s\n' "$ROOT/.local/bin/cursor-agent" ;;
  esac
}
agent_native_command() {
  if [ -x "$ROOT/.local/bin/cursor-agent" ]; then
    if [ -x "$ROOT/.local/bin/agent" ]; then
      printf '%s\n' "$ROOT/.local/bin/agent"
    else printf '%s\n' "$ROOT/.local/bin/cursor-agent"; fi
  elif [ -x "$ROOT/grok/bin/agent" ]; then
    printf '%s\n' "$ROOT/grok/bin/agent"
  else
    expected_command grok
  fi
}


# Dispatcher deliberately keeps upstream Cursor and Grok link ownership intact.
# `agent` dispatches to a provider selected from actual native installations.
# Cursor's per-profile native agent links take priority over the shared ones.
write_dispatcher() {
  local tmp
  tmp="$(mktemp "$ROOT/libexec/.launch-cli.XXXXXX")"
  cat > "$tmp" <<'DISPATCH'
#!/bin/sh
set -eu
requested=${1:?missing CLI name}; shift
ROOT=$(CDPATH= cd "$(dirname "$0")/.." && pwd -P)
case "$requested" in
  agent)
    if [ -x "$ROOT/.local/bin/cursor-agent" ]; then name=cursor
    else name=grok; fi ;;
  cursor-agent) name=cursor ;;
  agy|grok|claude|codex) name=$requested ;;
  *) echo "Invalid CLI: $requested" >&2; exit 2 ;;
esac
if [ "${1:-}" = '--account' ]; then
  [ "$#" -ge 2 ] || { echo 'Usage: CLI --account ACCOUNT [ARGS...]' >&2; exit 2; }
  account=$2; shift 2
elif [ -n "${AI_CLI_ACCOUNT:-}" ]; then
  account=$AI_CLI_ACCOUNT
elif [ -f "$ROOT/profiles/defaults/$name" ]; then
  account=$(cat "$ROOT/profiles/defaults/$name")
else
  account=default
fi
case "$account" in
  ''|.|..|*[!a-zA-Z0-9._-]*) echo "Invalid account name: $account" >&2; exit 2 ;;
  [a-zA-Z0-9]*) ;;
  *) echo "Invalid account name: $account" >&2; exit 2 ;;
esac
# Unqualified updates of non-switching CLIs refresh the SHARED installation.
# `agent update` stays native only when Cursor owns agent; Grok-owned
# `agent update` refreshes the shared Grok installation. Native channel
# switching (`agent update --channel ...`) is never intercepted.
if [ "${1:-}" = update ] && [ "$#" -eq 1 ]; then
  case "$requested" in
    grok|claude|codex|cursor-agent)
      [ -x "$ROOT/bin/ai-clis" ] || { echo 'Missing manager; run --repair' >&2; exit 127; }
      exec "$ROOT/bin/ai-clis" --update "$name" ;;
    agent)
      if [ "$name" = grok ]; then
        [ -x "$ROOT/bin/ai-clis" ] || { echo 'Missing manager; run --repair' >&2; exit 127; }
        exec "$ROOT/bin/ai-clis" --update grok
      fi ;;
  esac
fi
folder="$ROOT/profiles/$name/$account"
home="$folder/home"
for d in "$ROOT/profiles" "$ROOT/profiles/$name" "$folder" "$home" \
  "$home/.config" "$home/.local" "$home/.local/bin" "$home/.local/share" \
  "$home/.local/state" "$home/.cache" "$home/.tmp" \
  "$home/.claude" "$home/.codex" "$home/.grok"; do
  [ ! -L "$d" ] || { echo "Refusing symlinked profile directory: $d" >&2; exit 2; }
done
mkdir -p "$home/.config" "$home/.local/bin" "$home/.local/share" \
  "$home/.local/state" "$home/.cache" "$home/.tmp" \
  "$home/.claude" "$home/.codex" "$home/.grok"
chmod 700 "$folder" "$home" "$home/.claude" "$home/.codex" "$home/.grok" 2>/dev/null || :
export HOME="$home"
export XDG_CONFIG_HOME="$home/.config"
export XDG_DATA_HOME="$home/.local/share"
export XDG_STATE_HOME="$home/.local/state"
export XDG_CACHE_HOME="$home/.cache"
export TMPDIR="$home/.tmp"
export CLAUDE_CONFIG_DIR="$home/.claude"
export CODEX_HOME="$home/.codex"
export CODEX_SQLITE_HOME="$home/.codex"
export CODEX_INSTALL_DIR="$ROOT/codex/bin"
export GROK_BIN_DIR="$ROOT/grok/bin"
export CURSOR_CONFIG_DIR="$home/.config/cursor"
export AGY_CLI_DISABLE_AUTO_UPDATE="${AGY_CLI_DISABLE_AUTO_UPDATE:-true}"
export PATH="$ROOT/bin:$home/.local/bin:$ROOT/.local/bin:$ROOT/grok/bin:$ROOT/codex/bin:$PATH"
# Credentials from the outside process can override the profile login.
case "$requested" in
  agy) binary="$ROOT/.local/bin/agy" ;;
  grok|agent)
    if [ "$requested" = agent ] && [ "$name" = cursor ]; then
      if [ -x "$home/.local/bin/agent" ]; then
        binary="$home/.local/bin/agent"
      elif [ -x "$ROOT/.local/bin/agent" ]; then
        binary="$ROOT/.local/bin/agent"
      else
        binary="$ROOT/.local/bin/cursor-agent"
      fi
    else
      if [ "$requested" = agent ] && [ -x "$ROOT/grok/bin/agent" ]; then
        binary="$ROOT/grok/bin/agent"
      elif [ -x "$ROOT/grok/bin/grok" ]; then
        binary="$ROOT/grok/bin/grok"
      else
        case "$(uname -s)" in Linux) os=linux ;; Darwin) os=macos ;; *) echo 'Unsupported OS' >&2; exit 2 ;; esac
        case "$(uname -m)" in
          x86_64|amd64|AMD64) arch=x86_64 ;;
          arm64|aarch64|ARM64) arch=aarch64 ;;
          *) echo 'Unsupported Grok architecture' >&2; exit 2 ;;
        esac
        binary="$ROOT/.grok/downloads/grok-$os-$arch"
      fi
    fi ;;
  cursor-agent)
    if [ -x "$home/.local/bin/cursor-agent" ]; then binary="$home/.local/bin/cursor-agent"
    else binary="$ROOT/.local/bin/cursor-agent"; fi ;;
  claude) binary="$ROOT/.local/bin/claude" ;;
  codex) binary="$ROOT/codex/bin/codex" ;;
esac
[ -x "$binary" ] || { echo "Missing $requested executable: $binary" >&2; exit 127; }
# Resolve symlinks to avoid launching arbitrary executables outside ~/.install.
path=$binary
hops=0
while [ -L "$path" ]; do
  hops=$((hops+1))
  [ "$hops" -le 40 ] || { echo "Symlink loop: $binary" >&2; exit 2; }
  link=$(readlink "$path") || exit 2
  case "$link" in /*) path=$link ;; *) path="$(dirname "$path")/$link" ;; esac
done
parent=$(CDPATH= cd -P "$(dirname "$path")" && pwd -P) || exit 2
case "$parent/$(basename "$path")" in
  "$ROOT"/*) ;;
  *) echo "Refusing executable outside ~/.install: $binary" >&2; exit 2 ;;
esac
exec "$binary" "$@"
DISPATCH
  chmod 755 "$tmp"
  mv -f "$tmp" "$ROOT/libexec/launch-cli"
}


# Persist an executable copy of this management script under the installation
# prefix. This lets users repair/update the install without keeping downloads in ~.
write_manager() {
  local self tmp
  self="${BASH_SOURCE[0]}"
  [ -f "$self" ] || fail 'Cannot locate running manager script on disk'
  tmp="$(mktemp "$ROOT/libexec/.ai-clis.XXXXXX")"
  cat "$self" > "$tmp"
  chmod 700 "$tmp"
  mv -f "$tmp" "$ROOT/libexec/ai-clis"
  tmp="$(mktemp "$ROOT/bin/.ai-clis.XXXXXX")"
  cat > "$tmp" <<'MANAGER'
#!/bin/sh
set -eu
SELF=$0
case "$SELF" in
  */*) ;;
  *) SELF=$(command -v "$SELF") || exit 127 ;;
esac
ROOT=$(CDPATH= cd "$(dirname "$SELF")/.." && pwd -P)
exec "$ROOT/libexec/ai-clis" "$@"
MANAGER
  chmod 755 "$tmp"
  mv -f "$tmp" "$ROOT/bin/ai-clis"
}

# Do not create or overwrite vendor-owned native Grok/Cursor links.
# The managed `agent` entry point routes to the actual native agent source.
verify_agent() {
  local source actual base
  source="$(agent_native_command)"
  [ -x "$source" ] || { printf 'FAIL agent  missing native source: %s\n' "$source" >&2; return 1; }
  [ -x "$ROOT/bin/agent" ] || { echo 'FAIL agent  missing managed dispatcher' >&2; return 1; }
  actual="$(physical_target "$source")" || return 1
  base="$(CDPATH= cd -P "$ROOT" && pwd -P)"
  case "$actual" in "$base"/*) ;; *) echo "FAIL agent  native target outside ~/.install: $actual" >&2; return 1 ;; esac
  "$ROOT/bin/agent" --version || { echo 'FAIL agent  --version' >&2; return 1; }
  printf 'CHECK %-7s native=%s (owner=%s)\n' agent "$source" "$(normalize_tool agent)"
}


write_launcher() {
  local name="$1" tmp
  tmp="$(mktemp "$ROOT/bin/.$name.XXXXXX")"
  cat > "$tmp" <<'LAUNCHER'
#!/bin/sh
set -eu
SELF=$0
case "$SELF" in
  */*) ;;
  *) SELF=$(command -v "$SELF") || exit 127 ;;
esac
ROOT=$(CDPATH= cd "$(dirname "$SELF")/.." && pwd -P)
exec "$ROOT/libexec/launch-cli" "${SELF##*/}" "$@"
LAUNCHER
  chmod 755 "$tmp"
  mv -f "$tmp" "$ROOT/bin/$name"
}
write_env_helper() {
  local tmp
  tmp="$(mktemp "$ROOT/.env.sh.XXXXXX")"
  cat > "$tmp" <<'ENVFILE'
# Bash, Zsh, POSIX sh: add ~/.install/bin to PATH, idempotently.
case ":${PATH:-}:" in
  *":$HOME/.install/bin:"*) ;;
  *) PATH="$HOME/.install/bin${PATH:+:$PATH}" ;;
esac
export PATH
# In Bash, clear any previously cached command path.
if command -v hash >/dev/null 2>&1; then hash -r 2>/dev/null || :; fi
ENVFILE
  chmod 644 "$tmp"
  mv -f "$tmp" "$ROOT/env.sh"
}
add_profile_hook() {
  local profile="$1"
  local hook='[ -f "$HOME/.install/env.sh" ] && . "$HOME/.install/env.sh"'
  if [ -L "$profile" ] || { [ -e "$profile" ] && [ ! -f "$profile" ]; }; then
    printf 'WARNING: Cannot safely edit profile %s (symlink or not regular)\n' "$profile" >&2
    return 1
  fi
  if [ -f "$profile" ] && grep -Fqx -- "$hook" "$profile"; then return 0; fi
  printf '\n# Managed AI CLIs (~/.install/bin)\n%s\n' "$hook" >> "$profile" || return 1
  printf 'PATH hook added: %s\n' "$profile"
}
setup_path() {
  prepare_dirs
  write_env_helper
  local shell_name="${SHELL##*/}" profile had_error=0
  # Update Bash *and* Zsh interactive RCs, including mixed shell workflows.
  # Bash login may use .bash_profile or .bash_login instead of .profile.
  for profile in "$REAL_HOME/.bashrc" "$REAL_HOME/.profile"; do
    add_profile_hook "$profile" || had_error=1
  done
  for profile in "$REAL_HOME/.bash_profile" "$REAL_HOME/.bash_login"; do
    if [ -e "$profile" ] || [ -L "$profile" ]; then
      add_profile_hook "$profile" || had_error=1
    fi
  done
  if command -v zsh >/dev/null 2>&1 || [ "$shell_name" = zsh ] || [ -e "$REAL_HOME/.zshrc" ]; then
    for profile in "$REAL_HOME/.zshrc" "$REAL_HOME/.zprofile"; do
      add_profile_hook "$profile" || had_error=1
    done
  fi
  [ "$had_error" -eq 0 ] || printf 'WARNING: Some shell profiles could not be modified\n' >&2
  printf '\nACTIVE TERMINAL: . "%s/env.sh"\n' "$ROOT"
}

physical_target() {
  local path="$1" link hop=0 parent
  while [ -L "$path" ]; do
    hop=$((hop+1)); [ "$hop" -le 40 ] || return 1
    link="$(readlink "$path")" || return 1
    case "$link" in /*) path="$link" ;; *) path="$(dirname "$path")/$link" ;; esac
  done
  parent="$(CDPATH= cd -P "$(dirname "$path")" && pwd -P)" || return 1
  printf '%s/%s\n' "$parent" "$(basename "$path")"
}
verify_one() {
  local name="$1" source actual root_physical wrapper
  source="$(expected_command "$name")"
  wrapper="$ROOT/bin/$(if [ "$name" = cursor ]; then printf cursor-agent; else printf '%s' "$name"; fi)"
  if [ ! -x "$source" ]; then
    printf 'FAIL %-7s missing executable: %s\n' "$name" "$source" >&2; return 1
  fi
  if [ ! -x "$wrapper" ] || [ ! -x "$ROOT/libexec/launch-cli" ]; then
    printf 'FAIL %-7s missing launcher or account dispatcher\n' "$name" >&2; return 1
  fi
  actual="$(physical_target "$source")" || return 1
  root_physical="$(CDPATH= cd -P "$ROOT" && pwd -P)"
  case "$actual" in
    "$root_physical"/*) ;;
    *) printf 'FAIL %-7s binary points OUTSIDE ~/.install: %s\n' "$name" "$actual" >&2; return 1 ;;
  esac
  printf 'CHECK %-7s %s\n' "$name" "$actual"
  "$wrapper" --version || { printf 'FAIL %-7s --version\n' "$name" >&2; return 1; }
  printf 'OK    %-7s shared binary and profile launcher\n' "$name"
}


# Test a NEW interactive shell loading its own RC rather than relying on PATH
# inherited from the caller or on an executable invoked by absolute path.
verify_new_shell() {
  local name="$1" shell_name="${SHELL##*/}" shell_bin resolved mode flags
  case "$shell_name" in
    bash|zsh) shell_bin="$(command -v "$shell_name" 2>/dev/null || true)" ;;
    *) printf 'INFO  %-7s shell=%s; PATH test skipped (Bash/Zsh supported)\n' "$name" "$shell_name"; return 0 ;;
  esac
  [ -n "$shell_bin" ] || { printf 'FAIL %-7s shell %s missing\n' "$name" "$shell_name" >&2; return 1; }
  for mode in interactive login; do
    # Offline fixtures use HOME pointing at a temporary directory. A login
    # Bash resets HOME to the real passwd entry, which would test the wrong
    # user's dotfiles. Real installations do not set this test-only option.
    if [ "$mode" = login ] && [ "${AI_CLI_TEST_SKIP_LOGIN:-0}" = 1 ]; then
      continue
    fi
    case "$mode" in interactive) flags=-ic ;; login) flags=-lic ;; esac
    resolved="$(HOME="$REAL_HOME" PATH='/usr/local/bin:/usr/bin:/bin' "$shell_bin" "$flags" \
      'command -v "$1"' _ "$name" 2>/dev/null | tail -n 1)" || resolved=''
    if [ "$resolved" != "$ROOT/bin/$name" ]; then
      printf 'FAIL %-7s fresh %s %s shell resolves to %s (expected %s)\n' \
        "$name" "$shell_name" "$mode" "${resolved:-<missing>}" "$ROOT/bin/$name" >&2
      return 1
    fi
    printf 'SHELL %-7s %s (%s %s shell)\n' "$name" "$resolved" "$shell_name" "$mode"
  done
}

verify_selected() {
  local name command_name resolved failed=0 has_agent=0
  for name in "${SELECTED[@]}"; do
    if ! verify_one "$name"; then failed=1; continue; fi
    command_name="$name"
    [ "$name" != cursor ] || command_name=cursor-agent
    if ! verify_new_shell "$command_name"; then failed=1; fi
    resolved="$(command -v "$command_name" 2>/dev/null || true)"
    if [ "$resolved" != "$ROOT/bin/$command_name" ]; then
      printf 'NOTE  %-12s activate current terminal: . "%s/env.sh"\n' "$command_name" "$ROOT" >&2
    else printf 'PATH  %-12s %s\n' "$command_name" "$resolved"; fi
    case "$name" in grok|cursor) has_agent=1 ;; esac
  done
  if [ "$has_agent" -eq 1 ]; then
    verify_agent || failed=1
    verify_new_shell agent || failed=1
    resolved="$(command -v agent 2>/dev/null || true)"
    [ "$resolved" = "$ROOT/bin/agent" ] || printf 'NOTE  agent        activate terminal: . "%s/env.sh"\n' "$ROOT" >&2
  fi
  [ "$failed" -eq 0 ] || fail 'Verification failed (see diagnostics above)'
  printf '\nSUCCESS: verified %s and PATH\n' "${SELECTED[*]}"
}


# Repair historical installs (including your existing installed agy) without
# downloading hundreds of MB again. Only trust binaries resolving inside root.
repair_launchers() {
  local name source actual base found=0 has_agent=0
  prepare_dirs
  write_dispatcher
  write_manager
  base="$(CDPATH= cd -P "$ROOT" && pwd -P)"
  for name in "${ALL_SUPPORTED[@]}"; do
    source="$(expected_command "$name")"
    if [ -x "$source" ]; then
      actual="$(physical_target "$source" 2>/dev/null || true)"
      case "$actual" in
        "$base"/*)
          if [ "$name" = cursor ]; then
            write_launcher cursor-agent
            printf 'REPAIRED %-12s %s\n' cursor-agent "$ROOT/bin/cursor-agent"
          else
            write_launcher "$name"
            printf 'REPAIRED %-12s %s\n' "$name" "$ROOT/bin/$name"
          fi
          found=$((found+1))
          case "$name" in grok|cursor) has_agent=1 ;; esac ;;
        *) printf 'WARNING: Not repairing %s, binary points outside prefix\n' "$name" >&2 ;;
      esac
    fi
  done
  if [ "$has_agent" -eq 1 ]; then
    write_launcher agent
    printf 'REPAIRED %-12s native-dispatch (no vendor links modified)\n' agent
  fi
  if [ "$found" -eq 0 ]; then printf 'No installed binaries found under %s\n' "$ROOT"; fi
}


install_one() {
  local name="$1" source command_name
  ensure_snapshot "$name"
  check_snapshot "$name"
  isolated_install "$name" || fail "Upstream installer failed: $name"
  source="$(expected_command "$name")"
  [ -x "$source" ] || fail "Installer completed but CLI is missing: $source"
  command_name="$name"
  if [ "$name" = cursor ]; then command_name=cursor-agent; fi
  write_launcher "$command_name"
  case "$name" in grok|cursor) write_launcher agent ;; esac
  verify_one "$name" || return 1
  verify_new_shell "$command_name" || return 1
  case "$name" in
    grok|cursor) verify_agent && verify_new_shell agent || return 1 ;;
  esac
}


install_selected() {
  prepare_dirs
  local name ok=() failed=()
  setup_path
  write_dispatcher
  write_manager
  for name in "${SELECTED[@]}"; do
    if ( install_one "$name" ); then
      ok+=("$name")
      printf '\nINSTALLED: %s\n' "$name"
    else
      failed+=("$name")
      printf '\nFAILED: %s (other selected installers will continue)\n' "$name" >&2
    fi
  done
  printf '\n=== SUMMARY (%s) ===\n' "$ROOT"
  printf 'OK: %s\n' "${ok[*]:-none}"
  printf 'FAILED: %s\n' "${failed[*]:-none}"
  printf 'Available now in a fresh shell. Current terminal activation:\n  . "%s/env.sh"\n' "$ROOT"
  printf 'Future management: %s/bin/ai-clis --doctor\n' "$ROOT"
  [ "${#failed[@]}" -eq 0 ] || fail 'One or more installations failed; see per-tool diagnostics above'
}
update_selected() {
  prepare_dirs
  local name ok=() failed=()
  setup_path
  write_dispatcher
  write_manager
  for name in "${SELECTED[@]}"; do
    if ( fetch_one "$name" && install_one "$name" ); then
      ok+=("$name")
    else
      failed+=("$name")
      printf 'FAILED updating %s; continuing with others\n' "$name" >&2
    fi
  done
  printf '\nUPDATED: %s\nFAILED: %s\n' "${ok[*]:-none}" "${failed[*]:-none}"
  [ "${#failed[@]}" -eq 0 ] || fail 'One or more CLI updates failed'
}

make_profile() {
  local name="$1" account="$2" folder home
  valid_account "$account" || fail "Invalid account '$account'"
  prepare_dirs
  folder="$ROOT/profiles/$name/$account"; home="$folder/home"
  ensure_real_dir "$ROOT/profiles/$name" "$folder" "$home" \
    "$home/.config" "$home/.local" "$home/.local/bin" "$home/.local/share" \
    "$home/.local/state" "$home/.cache" "$home/.tmp" \
    "$home/.claude" "$home/.codex" "$home/.grok"
  mkdir -p "$home/.config" "$home/.local/bin" "$home/.local/share" \
    "$home/.local/state" "$home/.cache" "$home/.tmp" "$home/.claude" "$home/.codex" "$home/.grok"
  chmod 700 "$ROOT/profiles/$name" "$folder" "$home" "$home/.claude" "$home/.codex" "$home/.grok"
  printf 'PROFILE %-7s %-18s %s\n' "$name" "$account" "$folder"
}


set_default() {
  local name="$1" account="$2" tmp
  make_profile "$name" "$account"
  tmp="$(mktemp "$ROOT/profiles/defaults/.$name.XXXXXX")"
  printf '%s\n' "$account" > "$tmp"
  chmod 600 "$tmp"
  mv -f "$tmp" "$ROOT/profiles/defaults/$name"
  printf 'DEFAULT %s = %s\n' "$name" "$account"
}
show_profiles() {
  local name="${1:-}" name_loop folder account default
  if [ -z "$name" ]; then
    for name_loop in "${ALL_SUPPORTED[@]}"; do show_profiles "$name_loop"; done
    return
  fi
  default=default
  if [ -f "$ROOT/profiles/defaults/$name" ]; then
    default="$(cat "$ROOT/profiles/defaults/$name")"
  fi
  printf '\n%s (default=%s):\n' "$name" "$default"
  if [ -d "$ROOT/profiles/$name" ]; then
    for folder in "$ROOT/profiles/$name"/*; do
      [ -d "$folder" ] || continue
      account="${folder##*/}"
      if [ "$account" = "$default" ]; then printf '  * %s\n' "$account"
      else printf '    %s\n' "$account"; fi
    done
  fi
}
show_status() {
  local name target actual base primary
  printf 'Installation root: %s\n' "$ROOT"
  if [ -d "$ROOT" ]; then base="$(CDPATH= cd -P "$ROOT" && pwd -P)"
  else base="$ROOT"; fi
  for name in "${ALL_SUPPORTED[@]}"; do
    target="$(expected_command "$name")"
    primary="$name"
    [ "$name" != cursor ] || primary=cursor-agent
    if [ -x "$target" ] && [ -x "$ROOT/bin/$primary" ]; then
      actual="$(physical_target "$target" 2>/dev/null || true)"
      case "$actual" in
        "$base"/*) printf '  %-12s INSTALLED   %s\n' "$primary" "$ROOT/bin/$primary" ;;
        *) printf '  %-12s INVALID     binary outside root\n' "$primary" ;;
      esac
    elif [ -x "$target" ]; then
      printf '  %-12s NEEDS REPAIR (run --repair)\n' "$primary"
    else
      printf '  %-12s NOT INSTALLED\n' "$primary"
    fi
  done
  if [ -x "$ROOT/bin/agent" ]; then
    printf '  %-12s DISPATCHED  native %s\n' agent "$(agent_native_command)"
  else
    printf '  %-12s NOT CONFIGURED\n' agent
  fi
  show_profiles
}


doctor() {
  repair_launchers
  setup_path
  local name command_name failures=0 found=0 has_agent=0
  for name in "${ALL_SUPPORTED[@]}"; do
    if [ -x "$(expected_command "$name")" ]; then
      found=$((found+1))
      verify_one "$name" || failures=$((failures+1))
      command_name="$name"
      [ "$name" != cursor ] || command_name=cursor-agent
      verify_new_shell "$command_name" || failures=$((failures+1))
      case "$name" in grok|cursor) has_agent=1 ;; esac
    fi
  done
  if [ "$has_agent" -eq 1 ]; then
    verify_agent || failures=$((failures+1))
    verify_new_shell agent || failures=$((failures+1))
  fi
  printf '\nDOCTOR: %s installed, %s failed checks\n' "$found" "$failures"
  [ "$failures" -eq 0 ] || fail 'Doctor found a problem; see diagnostics above'
}


run_account() {
  local name="$1" account="$2"; shift 2
  valid_account "$account" || fail "Invalid account: $account"
  [ -x "$ROOT/bin/$name" ] || fail "$name not installed (run --install $name)"
  exec "$ROOT/bin/$name" --account "$account" "$@"
}
main() {
  local action="${1:---help}" name account
  check_platform
  if [ "$#" -eq 0 ] && [ -t 0 ]; then
    menu_select
    install_selected
    return
  fi
  case "$action" in
    --menu)
      [ "$#" -eq 1 ] || fail '--menu takes no extra args'
      menu_select; install_selected ;;
    --install|--fetch|--verify|--update)
      shift; select_tools "$@"
      case "$action" in
        --install) install_selected ;;
        --fetch) fetch_selected ;;
        --verify) verify_selected ;;
        --update) update_selected ;;
      esac ;;
    --setup-path|--repair)
      [ "$#" -eq 1 ] || fail "$action takes no extra args"
      repair_launchers; setup_path ;;
    --doctor)
      [ "$#" -eq 1 ] || fail '--doctor takes no extra args'
      doctor ;;
    --version)
      printf 'AI CLI manager %s\n' "$SCRIPT_VERSION" ;;
    --status|--list)
      [ "$#" -eq 1 ] || fail "$action takes no extra args"
      show_status ;;
    --set-default|--profile-create)
      [ "$#" -eq 3 ] || fail "Usage: $action CLI ACCOUNT"
      name="$(normalize_tool "$2")"; account="$3"
      case "$action" in
        --set-default) set_default "$name" "$account" ;;
        --profile-create) make_profile "$name" "$account" ;;
      esac ;;
    --profiles)
      [ "$#" -le 2 ] || fail 'Usage: --profiles [CLI]'
      if [ "$#" -eq 2 ]; then name="$(normalize_tool "$2")"; show_profiles "$name"
      else show_profiles; fi ;;
    --run)
      [ "$#" -ge 3 ] || fail 'Usage: --run CLI ACCOUNT [CLI_ARGUMENTS...]'
      name="$(normalize_tool "$2")"
      case "$2" in agent) name=agent ;; cursor|cursor-agent) name=cursor-agent ;; esac
      account="$3"; shift 3
      run_account "$name" "$account" "$@" ;;
    --help|-h|help) usage ;;
    *) usage; fail "Unknown option: $action" ;;
  esac
}
main "$@"
