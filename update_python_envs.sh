#!/usr/bin/env bash
# Native Bash CPython patch updater. No embedded or generated Python source.
# See update_python_envs.md for trusted roots, backups, and examples.
set -Eeuo pipefail
umask 077
export LC_ALL=C
SELF="$(realpath -e -- "${BASH_SOURCE[0]}")"
MARKER='.pyenv-update-'
WORK=''
declare -a ROOTS=() EXCLUDES=() SCAN_ROOTS=() SCAN_EXCLUDES=() TARGET_SPECS=() LOCK_FDS=()
declare -a PRUNE_PATHS=() TRUSTED_TARGETS=()
declare -a INVOCATION=("$@")
OUTPUT='' CHECKS='' COMMAND='' JOURNAL=''
ASSUME_YES=0
RUNTIME_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/python-env-updater"
BUILD_JOBS=4
SKIP_APT=0 NO_SUDO=0
declare -A POLICY=()
LOG_ROOT="${SELF%/*}/log"
LOG_DIR='' LOG_FILE='' LOGGING=0
LOG_STDOUT_FD='' LOG_STDERR_FD='' LOG_STDOUT_PID='' LOG_STDERR_PID=''
declare -A EOL=([3.8]=2024-10-07 [3.9]=2025-10-31 [3.10]=2026-10-01)
die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 2
}
now() { date -u +%FT%TZ; }
cleanup() {
  local status=$? pid
  trap - EXIT
  if ((LOGGING)); then
    printf '[%s] Finished %s (exit %s)\n' "$(now)" "$COMMAND" "$status" >&2
    # Close both writers before waiting, so the log is complete on return.
    exec 1>&"$LOG_STDOUT_FD" 2>&"$LOG_STDERR_FD"
    exec {LOG_STDOUT_FD}>&- {LOG_STDERR_FD}>&-
    for pid in "$LOG_STDOUT_PID" "$LOG_STDERR_PID"; do
      if ! wait "$pid"; then
        printf 'ERROR: Could not finish writing %s\n' "$LOG_FILE" >&2
        [[ $status != 0 ]] || status=1
      fi
    done
    if ! sync -d "$LOG_FILE"; then [[ $status != 0 ]] || status=1; fi
  fi
  [[ -z "$WORK" ]] || rm -rf -- "$WORK"
  exit "$status"
}
trap cleanup EXIT
start_logging() {
  LOG_ROOT="$(realpath -m -- "$LOG_ROOT")"
  mkdir -p -- "$LOG_ROOT"
  LOG_DIR="$(mktemp -d "$LOG_ROOT/$(date -u +%Y%m%dT%H%M%SZ).XXXXXX")"
  LOG_FILE="$LOG_DIR/process.log"
  : >"$LOG_FILE"
  exec {LOG_STDOUT_FD}>&1 {LOG_STDERR_FD}>&2
  exec > >(tee -a -- "$LOG_FILE")
  LOG_STDOUT_PID=$!
  exec 2> >(tee -a -- "$LOG_FILE" >&2)
  LOG_STDERR_PID=$!
  LOGGING=1
  printf 'Log: %s\n[%s] Command:' "$LOG_FILE" "$(now)" >&2
  printf ' %q' "$SELF" "${INVOCATION[@]}" >&2
  printf '\n' >&2
}
usage() {
  cat <<'HELP'
Usage:
  update_python_envs.sh scan [ROOT...]
  update_python_envs.sh plan [ROOT...]
  update_python_envs.sh [-Y] apply [ROOT...]
  update_python_envs.sh verify JOURNAL
  update_python_envs.sh rollback JOURNAL

Roots default to HOME. Plan/apply use the adjacent installer's release pins.
Apply reuses healthy targets or builds missing branches, then updates environments.
Plan reports required builds without installing. Installer --print-pins lists versions.
Options: --target MINOR=/existing/bin/python (repeatable override),
         --output FILE (default: JSON inside the run's log directory),
         --exclude PATH (repeatable), --checks checks.json (apply/verify),
         --log-dir DIR (default: script directory/log),
         --runtime-dir DIR (default: ${XDG_DATA_HOME:-$HOME/.local/share}/python-env-updater),
         --jobs N (default: 4), --skip-apt, --no-sudo (implies --skip-apt).
Automatic builds use install_python.sh with --skip-conda and --no-bashrc.
Ubuntu dependency installation and builds may request a sudo password.
Apply asks for y/Y for each venv before changing any environment; other answers
skip it. EOF aborts before updating. -Y before or after apply bypasses prompts.
Each public command writes DIR/<UTC timestamp>.<unique suffix>/process.log.
Journal, journal.entries and logs must be outside the updated prefixes.
Discovery probes interpreter binaries within the supplied roots. Supply the
linked directory or interpreter base as another root to include an external target.
All control flow, discovery, JSON, copying, validation, and recovery use Bash and
Unix utilities. Python is invoked through existing version/module commands.
Stop applications before apply or rollback. Use trusted private installation roots.
HELP
}
require_tools() {
  local tool
  [[ ${BASH_VERSINFO[0]} -ge 4 ]] || die 'Bash 4 or newer is required'
  for tool in jq find realpath stat readlink sha256sum rsync cp mv mktemp flock timeout awk sort sync od tee; do
    command -v "$tool" >/dev/null || die "Required utility missing: $tool"
  done
}
prepare_tools() {
  local tool os
  local -a missing=()
  for tool in jq rsync; do command -v "$tool" >/dev/null || missing+=("$tool"); done
  if ((${#missing[@]})) && [[ $COMMAND == apply ]] && ((SKIP_APT == 0)); then
    os="$(. /etc/os-release && printf '%s' "$ID")"
    [[ $os == ubuntu ]] || die "Install required utilities: ${missing[*]}"
    command -v sudo >/dev/null || die "Install required utilities: ${missing[*]} (sudo unavailable)"
    printf 'Installing updater dependencies: %s\n' "${missing[*]}" >&2
    sudo apt-get update </dev/null
    sudo apt-get install -y "${missing[@]}" </dev/null
  fi
  require_tools
}
root_guard() {
  if [[ $EUID -eq 0 ]]; then
    local mapping=''
    [[ ! -r /proc/self/uid_map ]] || mapping="$(awk '{$1=$1;print}' /proc/self/uid_map)"
    [[ $mapping == '0 0 1' ]] || die 'Run as the installation owner, without sudo'
  fi
}
safe_path() { [[ $1 != *$'\n'* && $1 != *$'\r'* && $1 != *$'\t'* ]] || die 'Paths containing tabs or line breaks are unsupported'; }
absolute() {
  safe_path "$1"
  realpath -ms -- "$1"
}
canonical() {
  safe_path "$1"
  realpath -e -- "$1"
}
within() { [[ $1 == "$2" || $1 == "${2%/}/"* ]]; }
assert_control_paths() {
  local prefixes=$1 path resolved prefix
  shift
  for path in "$@"; do
    [[ -n $path ]] || continue
    resolved="$(realpath -m -- "$path")"
    while IFS= read -r prefix; do
      if within "$resolved" "$prefix"; then
        die "Control path must be outside updated prefixes: $path overlaps $prefix"
      fi
    done < <(jq -r '.[].prefix' "$prefixes")
  done
}
stable_version() { [[ $1 =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; }
minor() { printf '%s\n' "${1%.*}"; }
is_python_name() { [[ $1 =~ ^python([0-9]+(\.[0-9]+)*)?$ ]]; }
is_standard() { [[ $1 == python || $1 == python3 || $1 == "python$2" ]]; }
is_elf() {
  [[ -f $1 && -x $1 ]] || return 1
  [[ $(od -An -N4 -tx1 -- "$1" 2>/dev/null | tr -d ' \n') == 7f454c46 ]]
}
runpy() {
  local name
  local -a environment=(env -u VIRTUAL_ENV -u CONDA_PREFIX)
  for name in ${!PYTHON@}; do environment+=(-u "$name"); done
  timeout --kill-after=5 "${PY_TIMEOUT:-120}" "${environment[@]}" PIP_DISABLE_PIP_VERSION_CHECK=1 PIP_NO_INPUT=1 "$@"
}
config_value() {
  awk -v key="$2" '$1==key && $2=="=" {sub(/^[^=]*= \"/, "");sub(/\"$/, "");print;exit}' "$1"
}
# The sysconfig module CLI supplies identity and ABI without inline code.
probe() {
  local binary version report prefix base abi shared bits pure plat machine configured managed='private'
  binary="$(absolute "$1")"
  is_elf "$binary" || return 1
  version="$(PY_TIMEOUT=45 runpy "$binary" -I --version 2>/dev/null)" || return 1
  version=${version#Python }
  stable_version "$version" || return 1
  report="$(mktemp "$WORK/sysconfig.XXXXXX")"
  if ! PY_TIMEOUT=45 runpy "$binary" -I -m sysconfig >"$report" 2>/dev/null; then
    rm -f -- "$report"
    return 1
  fi
  prefix="$(config_value "$report" base)"
  base="$(config_value "$report" installed_base)"
  configured="$(config_value "$report" prefix)"
  abi="$(config_value "$report" SOABI)"
  shared="$(config_value "$report" Py_ENABLE_SHARED)"
  bits="$(config_value "$report" SIZEOF_VOID_P)"
  pure="$(config_value "$report" purelib)"
  plat="$(config_value "$report" platlib)"
  machine="$(awk '/^Platform:/ {sub(/^Platform: \"/, "");sub(/\"$/, "");print;exit}' "$report")"
  rm -f -- "$report"
  [[ $prefix == /* && $base == /* && $abi == cpython-* && $bits =~ ^[0-9]+$ && $shared =~ ^[01]$ ]] || return 1
  prefix="$(canonical "$prefix")"
  base="$(canonical "$base")"
  if [[ -d $prefix/conda-meta ]]; then
    managed=conda
  elif [[ -f $prefix/info/index.json ]] && jq -e '.name=="python"' "$prefix/info/index.json" >/dev/null 2>&1; then managed=conda-package-cache; fi
  jq -cn --arg binary "$binary" --arg resolved "$(canonical "$binary")" --arg version "$version" \
    --arg prefix "$prefix" --arg base "$base" --arg soabi "$abi" --argjson shared "$shared" \
    --argjson bytes "$bits" --arg machine "$machine" --arg managed "$managed" --arg purelib "$pure" --arg platlib "$plat" --arg configured_prefix "$configured" \
    '{binary:$binary,resolved:$resolved,version:$version,prefix:$prefix,base_prefix:$base,soabi:$soabi,
      shared:$shared,pointer_bits:($bytes*8),machine:$machine,managed:$managed,purelib:$purelib,platlib:$platlib,configured_prefix:$configured_prefix,
      kind:(if $prefix==$base then "raw" else "venv" end)}'
}
atomic_write() {
  local destination=$1 temp
  mkdir -p -- "$(dirname -- "$destination")"
  temp="$(mktemp "${destination}.tmp.XXXXXX")"
  cat >"$temp"
  sync -d "$temp"
  mv -f -- "$temp" "$destination"
  sync -f "$(dirname -- "$destination")"
}
json_edit() {
  local destination=$1 temp
  shift
  temp="$(mktemp "$WORK/json.XXXXXX")"
  jq "$@" "$destination" >"$temp"
  atomic_write "$destination" <"$temp"
  rm -f -- "$temp"
}
event() { jq -cn --arg time "$(now)" --arg event "$1" --arg prefix "${2:-}" --arg detail "${3:-}" '{time:$time,event:$event,prefix:$prefix,detail:$detail}'; }
warning() { jq -cn --arg path "$1" --arg reason "$2" '{path:$path,reason:$reason}' >>"$WORK/warnings.ndjson"; }
scan_path_allowed() {
  local path=$1 root
  case "/${path#/}/" in */.git/* | */node_modules/* | *"$MARKER"*) return 1 ;; esac
  for root in "${SCAN_EXCLUDES[@]}"; do within "$path" "$root" && return 1; done
  for root in "${SCAN_ROOTS[@]}"; do within "$path" "$root" && return 0; done
  # Validated, explicitly supplied or updater-managed targets can back a venv.
  for root in "${TRUSTED_TARGETS[@]}"; do within "$path" "$root" && return 0; done
  return 1
}
scan() {
  local destination=$1 root path name resolved prefix base info marker line status=0
  local -a expression=('(' -name "*$MARKER*" -o -name .git -o -path '*/.git/*' -o -name node_modules -o -path '*/node_modules/*')
  local -A seen=()
  SCAN_ROOTS=()
  SCAN_EXCLUDES=()
  : >"$WORK/probes.ndjson"
  : >"$WORK/warnings.ndjson"
  : >"$WORK/links.ndjson"
  : >"$WORK/found"
  for path in "${EXCLUDES[@]}"; do
    resolved="$(realpath -m -- "$path")"
    SCAN_EXCLUDES+=("$resolved")
    expression+=(-o -path "$resolved")
  done
  for path in "${PRUNE_PATHS[@]}"; do expression+=(-o -path "$(realpath -m -- "$path")"); done
  expression+=(')' -prune -o '(' -type l -o -name pyvenv.cfg -o -path '*/bin/python*' ')' -print0)
  for root in "${ROOTS[@]}"; do
    if [[ ! -e $root ]]; then
      warning "$root" 'Missing search root'
      continue
    fi
    resolved="$(canonical "$root")"
    SCAN_ROOTS+=("$resolved")
    if [[ -L $root ]]; then
      jq -cn --arg path "$root" --arg target "$resolved" '{path:$path,target:$target}' >>"$WORK/links.ndjson"
    fi
  done
  # A physical walk reaches in-root directories without descending via aliases.
  # Only a link supplied as a root grants access to an external directory.
  if ((${#SCAN_ROOTS[@]})); then
    find -P "${SCAN_ROOTS[@]}" "${expression[@]}" >"$WORK/found" 2>"$WORK/find-errors" || status=$?
    while IFS= read -r line; do warning '' "$line"; done <"$WORK/find-errors"
  fi
  while IFS= read -r -d '' path; do
    safe_path "$path"
    scan_path_allowed "$path" || continue
    [[ ! ${seen[$path]+yes} ]] || continue
    seen[$path]=1
    if [[ -L $path ]]; then
      resolved="$(realpath -m -- "$path")"
      jq -cn --arg path "$path" --arg target "$resolved" '{path:$path,target:$target}' >>"$WORK/links.ndjson"
      if ! scan_path_allowed "$resolved"; then
        warning "$path" 'Link target outside discovery scope'
        continue
      fi
      if [[ ! -e $path ]]; then
        warning "$path" 'Broken link'
        continue
      fi
    fi
    if [[ ${path##*/} == pyvenv.cfg && ! -d ${path%/*}/bin ]]; then
      warning "${path%/*}" 'pyvenv.cfg has no bin directory'
    fi
    name=${path##*/}
    is_python_name "$name" && [[ $path == */bin/"$name" ]] || continue
    prefix=${path%/bin/*}
    scan_path_allowed "$prefix" || continue
    # An arbitrary executable named python in a project bin directory is not
    # enough. Require a venv config or a CPython standard library in the prefix.
    marker=''
    for root in "$prefix/pyvenv.cfg" "$prefix"/lib/python*/os.py "$prefix"/lib64/python*/os.py; do
      if [[ -f $root ]] && scan_path_allowed "$(canonical "$root")"; then
        marker=$root
        break
      fi
    done
    [[ -n $marker ]] || continue
    if ! info="$(probe "$path")"; then
      warning "$path" 'Missing, non-ELF, or unusable CPython interpreter'
      continue
    fi
    if [[ $(jq -r .prefix <<<"$info") != "$prefix" ]]; then
      warning "$path" 'Interpreter reports a different prefix'
      continue
    fi
    base="$(jq -r .base_prefix <<<"$info")"
    if scan_path_allowed "$(realpath -m -- "$base/bin/python$(minor "$(jq -r .version <<<"$info")")")"; then
      jq -c '.+{base_in_scope:true}' <<<"$info" >>"$WORK/probes.ndjson"
    else
      printf '%s\n' "$info" >>"$WORK/probes.ndjson"
      warning "$base" 'Referenced base outside discovery scope; add its directory as a root'
    fi
  done <"$WORK/found"
  jq -s 'group_by(.prefix)|map(.[0] as $first|$first+{aliases:(map(.binary)|unique),
    binaries:map({path:.binary,version:.version,resolved:.resolved}),versions:(map(.version)|unique)})|sort_by(.prefix)' "$WORK/probes.ndjson" >"$WORK/environments.json"
  jq -n --arg created "$(now)" --argjson walk_status "$status" --slurpfile environments "$WORK/environments.json" \
    --slurpfile warnings "$WORK/warnings.ndjson" --slurpfile links "$WORK/links.ndjson" \
    '{created:$created,engine:"bash",walk_status:$walk_status,environments:$environments[0],warnings:($warnings|unique),symlinks:($links|unique)}' | atomic_write "$destination"
}
load_release_policy() {
  local pins version
  pins="$(bash "${SELF%/*}/install_python.sh" --print-pins)" || die 'Cannot read release pins from the adjacent install_python.sh'
  while IFS= read -r version; do
    stable_version "$version" || die 'Installer returned an invalid release pin'
    POLICY[${version%.*}]=$version
  done <<<"$pins"
}
target_info() {
  local mm=$1 path=$2 info version floor
  info="$(probe "$path")" || return 1
  version="$(jq -r .version <<<"$info")"
  floor=${POLICY[$mm]}
  [[ $(minor "$version") == "$mm" && $(jq -r .kind <<<"$info") == raw &&
    $(jq -r .managed <<<"$info") == private ]] || return 1
  ((10#${version##*.} >= 10#${floor##*.})) || return 1
  printf '%s\n' "$info"
}
remember_target() {
  local mm=$1 info=$2 source=$3 prefix
  prefix="$(jq -r .prefix <<<"$info")"
  json_edit "$WORK/targets.json" --arg mm "$mm" --arg source "$source" --argjson info "$info" '.[$mm]=$info+{minor:$mm,source:$source}'
  PRUNE_PATHS+=("$prefix")
  TRUSTED_TARGETS+=("$prefix")
  event target_selected "$prefix" "$mm ($source)"
}
load_targets() {
  local spec mm path info version floor
  printf '{}\n' >"$WORK/targets.json"
  for spec in "${TARGET_SPECS[@]}"; do
    [[ $spec == *=* ]] || die 'Target syntax: MINOR=/absolute/path/bin/python'
    mm=${spec%%=*}
    path=${spec#*=}
    [[ $mm =~ ^[0-9]+\.[0-9]+$ && ${POLICY[$mm]+yes} ]] || die "No tested release policy for Python $mm"
    jq -e --arg mm "$mm" 'has($mm)|not' "$WORK/targets.json" >/dev/null || die 'Duplicate target branch'
    info="$(probe "$path")" || die "Target is not a working CPython ELF interpreter: $path"
    version="$(jq -r .version <<<"$info")"
    floor=${POLICY[$mm]}
    [[ $(minor "$version") == "$mm" ]] || die 'Cross-minor target refused'
    [[ $(jq -r .kind <<<"$info") == raw ]] || die 'Target must be a raw installation'
    ((10#${version##*.} >= 10#${floor##*.})) || die "Target is below policy floor $floor"
    [[ $(jq -r .managed <<<"$info") == private ]] || die 'Conda cannot serve as a raw CPython patch target'
    remember_target "$mm" "$info" explicit
  done
}
healthy_target() {
  local binary=$1 check_dir name failed=0
  check_dir="$(mktemp -d "$WORK/target-imports.XXXXXX")"
  (cd "$check_dir" && runpy "$binary" -I -m pydoc -w ssl sqlite3 bz2 lzma ctypes venv >imports.log 2>&1) || failed=1
  for name in ssl sqlite3 bz2 lzma ctypes venv; do [[ -s $check_dir/$name.html ]] || failed=1; done
  rm -rf -- "$check_dir"
  ((failed == 0))
}
load_cached_targets() {
  local mm path info
  [[ -f $RUNTIME_DIR/targets.json ]] || return 0
  jq -e 'type=="object" and all(.[];type=="string")' "$RUNTIME_DIR/targets.json" >/dev/null || die 'Invalid runtime cache targets.json'
  for mm in "${!POLICY[@]}"; do
    jq -e --arg mm "$mm" 'has($mm)' "$WORK/targets.json" >/dev/null && continue
    path="$(jq -r --arg mm "$mm" '.[$mm]//empty' "$RUNTIME_DIR/targets.json")"
    [[ -n $path ]] || continue
    # Cache pointers cannot grant discovery access outside the chosen cache.
    within "$(realpath -m -- "$path")" "$RUNTIME_DIR" || die "Cached target escapes runtime directory: $path"
    if info="$(target_info "$mm" "$path")" && within "$(jq -r .prefix <<<"$info")" "$RUNTIME_DIR" && healthy_target "$path"; then
      remember_target "$mm" "$info" cache
    else
      event target_unusable "$path" 'A fresh target will be prepared if needed'
    fi
  done
}
discover_targets() {
  local inventory=$1 mm path info prefix
  # Prefer the newest healthy private raw installation in the trusted scan.
  while IFS= read -r path; do
    info="$(jq -c --arg path "$path" '.environments[]|select(.binary==$path)' "$inventory")"
    mm="$(minor "$(jq -r .version <<<"$info")")"
    [[ ${POLICY[$mm]+yes} ]] || continue
    jq -e --arg mm "$mm" 'has($mm)' "$WORK/targets.json" >/dev/null && continue
    prefix="$(jq -r .prefix <<<"$info")"
    protected "$prefix" && continue
    if info="$(target_info "$mm" "$path")" && healthy_target "$path"; then remember_target "$mm" "$info" discovered; fi
  done < <(jq -r '.environments|map(select(.kind=="raw" and .managed=="private" and (.versions|length)==1))|
    sort_by(.version|split(".")|map(tonumber))|reverse|.[].binary' "$inventory")
}
prepare_targets() {
  local plan=$1 mm build_dir path info fd
  local -a needed=() options=(--reuse --skip-conda --no-bashrc --jobs "$BUILD_JOBS")
  mapfile -t needed < <(jq -r '[.plan[]|select(.action=="prepare_target")|.version|split(".")[0:2]|join(".")]|unique[]' "$plan")
  ((${#needed[@]})) || return 0
  jq '[.plan[]|select(.action!="skip")]' "$plan" >"$WORK/control-prefixes.json"
  assert_control_paths "$WORK/control-prefixes.json" "$OUTPUT" "$OUTPUT.entries" "$OUTPUT.post-verify.json" "$LOG_DIR" "$WORK" "$RUNTIME_DIR"
  [[ ! -e $OUTPUT && ! -L $OUTPUT && ! -e $OUTPUT.entries && ! -L $OUTPUT.entries ]] || die 'Journal exists; choose a new output path'
  mkdir -p -- "$RUNTIME_DIR"
  exec {fd}>"$RUNTIME_DIR/.build.lock"
  flock -n "$fd" || die "Another updater is preparing targets in $RUNTIME_DIR"
  # Each build has a permanent, unique prefix. An interrupted or unhealthy
  # cached build is never rebuilt in place underneath an existing venv.
  build_dir="$(mktemp -d "$RUNTIME_DIR/build-$(date -u +%Y%m%dT%H%M%SZ).XXXXXX")"
  ((SKIP_APT == 0)) || options+=(--skip-apt)
  ((NO_SUDO == 0)) || options+=(--no-sudo)
  event target_build_started "$build_dir" "${needed[*]}"
  bash "${SELF%/*}/install_python.sh" "$build_dir" "${options[@]}" --py "${needed[*]}" </dev/null || die 'Target preparation failed; existing environments were not updated'
  for mm in "${needed[@]}"; do
    path="$build_dir/opt/python-${POLICY[$mm]}/bin/python$mm"
    info="$(target_info "$mm" "$path")" && healthy_target "$path" || die "Prepared target failed validation: $path"
    remember_target "$mm" "$info" installed
  done
  [[ -f $RUNTIME_DIR/targets.json ]] || printf '{}\n' | atomic_write "$RUNTIME_DIR/targets.json"
  for mm in "${needed[@]}"; do
    path="$(jq -r --arg mm "$mm" '.[$mm].binary' "$WORK/targets.json")"
    json_edit "$RUNTIME_DIR/targets.json" --arg mm "$mm" --arg path "$path" '.[$mm]=$path'
  done
  event target_build_finished "$build_dir" "${needed[*]}"
  exec {fd}>&-
}
protected() {
  local root
  for root in /usr /bin /sbin /lib /lib64 /System "${CODEX_PRIMARY_RUNTIME_ROOT:-}"; do
    [[ -n $root ]] && within "$1" "$(realpath -m -- "$root")" && return 0
  done
  return 1
}
make_plan() {
  local inventory=$1 destination=$2 item prefix kind version mm target reason candidate newer flag unresolved name patch outside action older requested
  : >"$WORK/plan.ndjson"
  while IFS= read -r item; do
    prefix="$(jq -r .prefix <<<"$item")"
    kind="$(jq -r .kind <<<"$item")"
    version="$(jq -r .version <<<"$item")"
    mm=$(minor "$version")
    target="$(jq -c --arg mm "$mm" '.[$mm]//null' "$WORK/targets.json")"
    reason=''
    action=update
    requested=${POLICY[$mm]:-}
    unresolved='[]'
    flag=0
    outside=0
    while IFS= read -r -d '' candidate; do
      name=${candidate##*/}
      is_python_name "$name" || continue
      if [[ -e $candidate ]] && ! scan_path_allowed "$(canonical "$candidate")"; then
        outside=1
        continue
      fi
      if ! is_elf "$candidate"; then
        if is_standard "$name" "$mm"; then flag=1; else unresolved="$(jq -c --arg name "$name" '.+[$name]' <<<"$unresolved")"; fi
      fi
    done < <(find "$prefix/bin" -mindepth 1 -maxdepth 1 -name 'python*' -print0)
    if [[ $(jq -r .managed <<<"$item") != private ]]; then
      reason='Conda-managed prefix/cache: use the Conda solver'
    elif protected "$prefix"; then
      reason='Distribution/runtime-managed prefix'
    elif [[ -L $prefix/bin || -L $prefix/lib ]]; then
      reason='Linked bin/lib subdirectories require a separate rebuild'
    elif [[ -L $prefix/pyvenv.cfg ]]; then
      reason='Linked pyvenv.cfg requires a separate rebuild'
    elif ((outside)); then
      reason='Interpreter points outside discovery scope; add its target directory as a root'
    elif [[ $(jq '[.versions[]|split(".")[0:2]|join(".")]|unique|length' <<<"$item") != 1 ]]; then
      reason='Multiple minor branches share a prefix'
    elif [[ $(stat -Lc %u -- "$prefix") != "$EUID" || ! -w $(dirname -- "$prefix") ]]; then
      reason='Prefix ownership or parent write access does not permit updating'
    elif [[ $target == null ]]; then
      if [[ -z $requested ]]; then
        reason="No tested release policy for Python $mm"
      elif [[ $kind == raw && $(jq -r .shared <<<"$item") != 0 ]]; then
        reason='Shared raw build requires a prefix-specific rebuild'
      else
        older=0 newer=0
        patch=${requested##*.}
        while IFS= read -r candidate; do
          ((10#${candidate##*.} >= 10#$patch)) || older=1
          ((10#${candidate##*.} <= 10#$patch)) || newer=1
        done < <(jq -r '.versions[]' <<<"$item")
        if ((older == 0 && flag == 0)); then
          reason=up_to_date
        elif ((newer)); then
          reason='Downgrade refused'
        else
          action=prepare_target
          reason="Prepare pinned Python $requested"
        fi
      fi
    elif [[ $(jq -c '[.soabi,.shared,.pointer_bits,.machine]' <<<"$item") != "$(jq -c '[.soabi,.shared,.pointer_bits,.machine]' <<<"$target")" ]]; then
      reason='Interpreter ABI/build mismatch'
    else
      newer=0
      patch="$(jq -r '.version|split(".")[-1]' <<<"$target")"
      while IFS= read -r candidate; do ((10#${candidate##*.} <= 10#$patch)) || newer=1; done < <(jq -r '.versions[]' <<<"$item")
      if ((newer)); then
        reason='Downgrade refused'
      elif [[ $(jq -c .versions <<<"$item") == "$(jq -c '[.version]' <<<"$target")" && $flag == 0 ]]; then
        reason=up_to_date
      elif [[ $kind == raw && $(jq -r .shared <<<"$item") != 0 ]]; then
        reason='Shared raw build requires a prefix-specific rebuild'
      elif [[ $kind == raw ]] && within "$(jq -r .prefix <<<"$target")" "$prefix"; then
        reason='Target is inside the source prefix'
      fi
    fi
    [[ -z $reason || $action == prepare_target ]] || action=skip
    jq -c --arg action "$action" --arg requested "$requested" --arg reason "$reason" --arg eol "${EOL[$mm]:-}" --argjson target "$target" --argjson unresolved "$unresolved" \
      '.+{target:$target,requested_version:$requested,eol:$eol,unresolved_aliases:$unresolved,action:$action,reason:$reason}' <<<"$item" >>"$WORK/plan.ndjson"
  done < <(jq -c '.environments[]' "$inventory")
  jq -n --slurpfile inventory "$inventory" --slurpfile plan "$WORK/plan.ndjson" \
    '{engine:"bash",inventory:$inventory[0],plan:($plan|sort_by(.kind!="raw",.prefix))}' | atomic_write "$destination"
}

confirm_plan() {
  local plan=$1 destination=$2 item prefix answer input_fd base
  local -A blocked=()
  : >"$WORK/confirmed.ndjson"
  # Keep responses separate from the JSON stream used by the loop.
  exec {input_fd}<&0
  while IFS= read -r item; do
    if [[ $(jq -r .kind <<<"$item") == venv ]]; then
      prefix="$(jq -r .prefix <<<"$item")"
      if [[ $(jq -r .action <<<"$item") == update ]]; then
        if ((ASSUME_YES)); then
          item="$(jq -c '.approval="bypassed"' <<<"$item")"
          event confirmation "$prefix" 'bypassed (-Y)'
        else
          printf 'Update venv %s (%s -> %s)? [y/N] ' "$prefix" \
            "$(jq -r .version <<<"$item")" "$(jq -r .target.version <<<"$item")" >&2
          if ! IFS= read -r -u "$input_fd" answer; then
            printf '\n' >&2
            die 'Confirmation input ended; no environments updated. Use -Y for unattended apply.'
          fi
          printf '\n' >&2
          case "$answer" in
            y | Y)
              item="$(jq -c '.approval="confirmed"' <<<"$item")"
              event confirmation "$prefix" 'approved'
              ;;
            *)
              item="$(jq -c '.action="skip"|.reason="Venv update declined"|.approval="declined"' <<<"$item")"
              event confirmation "$prefix" 'declined'
              ;;
          esac
        fi
      fi
      if [[ $(jq -r .action <<<"$item") == skip ]]; then
        base="$(jq -r .base_prefix <<<"$item")"
        blocked[$base]=1
      fi
    fi
    printf '%s\n' "$item" >>"$WORK/confirmed.ndjson"
  done < <(jq -c '.plan[]' "$plan")
  exec {input_fd}<&-
  : >"$WORK/approved.ndjson"
  while IFS= read -r item; do
    prefix="$(jq -r .prefix <<<"$item")"
    if [[ $(jq -r .kind <<<"$item") == raw && $(jq -r .action <<<"$item") == update && ${blocked[$prefix]+yes} ]]; then
      item="$(jq -c '.action="skip"|.reason="Dependent venv is skipped; raw base left unchanged"' <<<"$item")"
    fi
    printf '%s\n' "$item" >>"$WORK/approved.ndjson"
  done <"$WORK/confirmed.ndjson"
  jq --slurpfile approved "$WORK/approved.ndjson" '.plan=$approved' "$plan" | atomic_write "$destination"
}

# Read installed distribution records with awk/jq, including inherited packages.
packages() {
  local prefix=$1 destination=$2 info site scope metadata name version path metadata_file base mm index
  local -a sites=() scopes=()
  local -A seen_sites=()
  info="$(probe "$(choose_binary "$prefix")")" || return 1
  base="$(jq -r .base_prefix <<<"$info")"
  mm="$(minor "$(jq -r .version <<<"$info")")"
  sites+=("$prefix/lib/python$mm/site-packages" "$prefix/lib64/python$mm/site-packages" "$prefix/lib/python$mm/dist-packages")
  scopes+=(local local local)
  if [[ $base != "$prefix" && -f $prefix/pyvenv.cfg ]] && awk -F= '$1~/^include-system-site-packages *$/ && $2~/true/ {found=1} END{exit !found}' "$prefix/pyvenv.cfg"; then
    sites+=("$base/lib/python$mm/site-packages" "$base/lib64/python$mm/site-packages" "$base/lib/python$mm/dist-packages")
    scopes+=(base base base)
  fi
  : >"$WORK/packages.ndjson"
  : >"$WORK/empty-metadata.ndjson"
  for index in "${!sites[@]}"; do
    site=${sites[$index]}
    scope=${scopes[$index]}
    [[ -d $site ]] || continue
    site="$(canonical "$site")"
    [[ ! ${seen_sites[$site]+yes} ]] || continue
    seen_sites[$site]=1
    while IFS= read -r -d '' metadata; do
      if [[ -d $metadata ]]; then
        metadata_file=$metadata/METADATA
        [[ -f $metadata_file ]] || metadata_file=$metadata/PKG-INFO
      else metadata_file=$metadata; fi
      if [[ ! -f $metadata_file ]]; then
        path="$(find -P "$metadata" \( -type f -o -type l \) -print -quit)"
        if [[ -z $path ]]; then
          jq -cn --arg path "$metadata" '{path:$path}' >>"$WORK/empty-metadata.ndjson"
          continue
        fi
        printf 'Incomplete distribution metadata: %s\n' "$metadata" >&2
        return 1
      fi
      name="$(awk '/^Name: / {sub(/^Name: /, "");sub(/\r$/, "");print;exit}' "$metadata_file")"
      version="$(awk '/^Version: / {sub(/^Version: /, "");sub(/\r$/, "");print;exit}' "$metadata_file")"
      [[ -n $name && -n $version ]] || {
        printf 'Incomplete distribution metadata: %s\n' "$metadata" >&2
        return 1
      }
      jq -cn --arg name "$name" --arg version "$version" --arg scope "$scope" \
        '{name:($name|ascii_downcase|gsub("[-_.]+";"-")),version:$version,scope:$scope}' >>"$WORK/packages.ndjson"
    done < <(find "$site" -mindepth 1 -maxdepth 1 \( -name '*.dist-info' -o -name '*.egg-info' \) -print0)
  done
  jq -n --slurpfile packages "$WORK/packages.ndjson" --slurpfile ignored "$WORK/empty-metadata.ndjson" \
    '{packages:($packages|sort_by(.scope,.name,.version)),ignored_empty_metadata:$ignored}' >"$destination"
}
choose_binary() {
  local prefix=$1 path name
  for name in python python3; do is_elf "$prefix/bin/$name" && {
    printf '%s\n' "$prefix/bin/$name"
    return
  }; done
  while IFS= read -r -d '' path; do
    name=${path##*/}
    is_python_name "$name" || continue
    is_elf "$path" && {
      printf '%s\n' "$path"
      return
    }
  done < <(find "$prefix/bin" -mindepth 1 -maxdepth 1 -name 'python*' -print0)
  return 1
}
# pip uses exit 1 for unsatisfied requirements and writes one issue per line.
# A timeout, traceback or failed invocation cannot serve as a dependency baseline.
pip_conflicts() {
  local binary=$1 output error status=0
  output="$(mktemp "$WORK/pip.XXXXXX")"
  error="$output.err"
  runpy "$binary" -I -m pip check >"$output" 2>"$error" || status=$?
  if ((status == 0)); then
    printf '[]\n'
    return
  fi
  if ((status != 1)) || [[ ! -s $output ]] || grep -q '^Traceback' "$error"; then
    printf 'pip check failed for %s (exit %s)\n' "$binary" "$status" >&2
    cat "$output" "$error" >&2
    return 1
  fi
  jq -Rn '[inputs | select(length>0)] | unique' <"$output"
}
snapshot_packages() {
  local prefix=$1 destination=$2 binary issues
  packages "$prefix" "$destination" || return 1
  if jq -e 'any(.packages[]; .name=="pip")' "$destination" >/dev/null; then
    binary="$(choose_binary "$prefix")" || return 1
    issues="$(pip_conflicts "$binary")" || return 1
    json_edit "$destination" --argjson issues "$issues" '.pip_conflicts=$issues' || return 1
  fi
}
hashes() {
  local prefix=$1 kind=$2 destination=$3 path relative hash name
  : >"$WORK/hashes.ndjson"
  while IFS= read -r -d '' path; do
    name=${path##*/}
    if [[ $path == "$prefix/bin/"* ]]; then is_python_name "$name" || continue; fi
    [[ -f $path ]] || continue
    hash="$(sha256sum -- "$path")"
    hash=${hash%% *}
    relative=${path#"$prefix/"}
    jq -cn --arg path "$relative" --arg sha256 "$hash" '{path:$path,sha256:$sha256}' >>"$WORK/hashes.ndjson"
  done < <(
    find "$prefix/bin" -mindepth 1 -maxdepth 1 -name 'python*' -print0
    if [[ $kind == raw ]]; then find "$prefix/lib" -type f \( -path '*/lib-dynload/*.so' -o -path '*/python*/tarfile.py' -o -path '*/python*/ssl.py' -o -path '*/python*/urllib/request.py' \) -print0; fi
  )
  jq -s 'sort_by(.path)' "$WORK/hashes.ndjson" >"$destination"
}
check_hashes() {
  local prefix=$1 manifest=$2 record path expected actual
  jq -e 'type=="array" and length>0 and all(.[];
    (.path|type=="string") and (.sha256|type=="string"))' "$manifest" >/dev/null || {
    printf 'Missing or invalid runtime hash manifest: %s\n' "$prefix" >&2
    return 1
  }
  while IFS= read -r record; do
    path="$(jq -r .path <<<"$record")"
    expected="$(jq -r .sha256 <<<"$record")"
    [[ -f $prefix/$path ]] || {
      printf 'Missing runtime file: %s\n' "$prefix/$path" >&2
      return 1
    }
    actual="$(sha256sum -- "$prefix/$path")"
    actual=${actual%% *}
    [[ $actual == "$expected" ]] || {
      printf 'Runtime integrity mismatch: %s\n' "$prefix/$path" >&2
      return 1
    }
  done < <(jq -c '.[]' "$manifest")
}
application_checks() {
  local prefix=$1 logical=$2 binary=$3 phase=$4 config=$5 pattern check argument output seconds
  local -a argv=()
  [[ -n $config ]] || return 0
  while IFS= read -r pattern; do
    [[ $logical == $pattern ]] || continue
    while IFS= read -r check; do
      [[ $phase == final || $(jq -r '.final_only//false' <<<"$check") != true ]] || continue
      argv=()
      while IFS= read -r -d '' argument; do
        argument=${argument//\{python\}/$binary}
        argument=${argument//\{prefix\}/$prefix}
        argv+=("$argument")
      done < <(jq -j '.argv[]|.,"\u0000"' <<<"$check")
      ((${#argv[@]})) || return 1
      seconds="$(jq -r '.timeout//120' <<<"$check")"
      [[ $seconds =~ ^[1-9][0-9]*$ ]] || return 1
      event application_check "$logical" "$phase: ${argv[0]}"
      output="$(cd "$prefix" && timeout --kill-after=5 "$seconds" "${argv[@]}" </dev/null 2>&1)" || {
        printf '%s\n' "$output" >&2
        return 1
      }
      [[ -z $output ]] || printf '%s\n' "$output" >&2
      if [[ $(jq -r '.contains//""' <<<"$check") != '' ]]; then [[ $output == *"$(jq -r .contains <<<"$check")"* ]] || return 1; fi
    done < <(jq -c --arg pattern "$pattern" '.[$pattern][]' "$config")
  done < <(jq -r 'keys[]' "$config")
}
validate() {
  local prefix=$1 expected=$2 package_file=$3 manifest=$4 logical=$5 phase=$6 checks=$7 destination=$8
  local path name info binary mm actual core issues='[]' added count=0 unresolved='[]' pip_status='pip absent'
  mm=$(minor "$expected")
  : >"$WORK/validated.ndjson"
  [[ -z $manifest ]] || check_hashes "$prefix" "$manifest" || return 1
  while IFS= read -r -d '' path; do
    name=${path##*/}
    is_python_name "$name" || continue
    if ! is_elf "$path" && ! is_standard "$name" "$mm"; then
      unresolved="$(jq -c --arg path "$path" '.+[$path]' <<<"$unresolved")"
      continue
    fi
    info="$(probe "$path")" || {
      printf 'Interpreter failed: %s\n' "$path" >&2
      return 1
    }
    [[ $(jq -r .version <<<"$info") == "$expected" && $(jq -r .prefix <<<"$info") == "$(canonical "$prefix")" ]] || {
      printf 'Wrong version/prefix: %s\n' "$path" >&2
      return 1
    }
    printf '%s\n' "$info" >>"$WORK/validated.ndjson"
    count=$((count + 1))
  done < <(find "$prefix/bin" -mindepth 1 -maxdepth 1 -name 'python*' -print0)
  ((count > 0)) || return 1
  binary="$(choose_binary "$prefix")" || return 1
  actual="$(mktemp "$WORK/actual-packages.XXXXXX")"
  packages "$prefix" "$actual" || return 1
  [[ $(jq -c .packages "$package_file") == "$(jq -c .packages "$actual")" ]] || {
    printf 'Installed package inventory changed: %s\n' "$prefix" >&2
    return 1
  }
  if jq -e 'any(.packages[]; .name=="pip")' "$actual" >/dev/null; then
    issues="$(pip_conflicts "$binary")" || return 1
    added="$(jq -r --argjson current "$issues" '($current - (.pip_conflicts // []))[]' "$package_file")" || return 1
    if [[ -n $added ]]; then
      printf 'New pip conflicts in %s:\n%s\n' "$prefix" "$added" >&2
      return 1
    fi
    if [[ $issues == '[]' ]]; then pip_status='No broken requirements found.'; else pip_status='Pre-existing dependency conflicts'; fi
  fi
  core="$(mktemp -d "$WORK/core.XXXXXX")"
  (cd "$core" && runpy "$binary" -I -m pydoc -w ssl sqlite3 bz2 lzma ctypes venv >"$core/imports.log" 2>&1) || {
    printf 'Core module check failed for %s:\n' "$binary" >&2
    cat "$core/imports.log" >&2
    return 1
  }
  for name in ssl sqlite3 bz2 lzma ctypes venv; do [[ -s $core/$name.html ]] || {
    printf 'Core module failed to load: %s\n' "$name" >&2
    return 1
  }; done
  application_checks "$prefix" "$logical" "$binary" "$phase" "$checks" || return 1
  jq -n --slurpfile interpreters "$WORK/validated.ndjson" --slurpfile packages "$actual" --arg pip_check "$pip_status" --argjson issues "$issues" --argjson unresolved "$unresolved" \
    '{interpreters:$interpreters,packages:$packages[0],pip_check:$pip_check,pip_conflicts:$issues,unresolved_aliases:$unresolved,core_modules:["ssl","sqlite3","bz2","lzma","ctypes","venv"]}' >"$destination"
}
replace_literal() {
  local file=$1 old=$2 new=$3 temp
  [[ -f $file && ! -L $file ]] || return 0
  temp="$(mktemp "$WORK/rewrite.XXXXXX")"
  OLD_PREFIX=$old NEW_PREFIX=$new awk 'BEGIN{old=ENVIRON["OLD_PREFIX"];new=ENVIRON["NEW_PREFIX"]}
    {s=$0;out="";while((n=index(s,old))>0){out=out substr(s,1,n-1) new;s=substr(s,n+length(old))}print out s}' "$file" >"$temp"
  if ! cmp -s -- "$file" "$temp"; then cat "$temp" >"$file"; fi
  rm -f -- "$temp"
}
patch_stage() {
  local entry=$1 stage prefix kind target target_prefix version mm path name base candidate info
  local -a names=() options=()
  stage="$(jq -r .stage "$entry")"
  prefix="$(jq -r .prefix "$entry")"
  kind="$(jq -r .kind "$entry")"
  target="$(jq -r .target.binary "$entry")"
  target_prefix="$(jq -r .target.prefix "$entry")"
  version="$(jq -r .target.version "$entry")"
  mm=$(minor "$version")
  if [[ $kind == venv ]]; then
    [[ -f $stage/pyvenv.cfg && ! -L $stage/pyvenv.cfg ]] || die 'Venv requires a regular pyvenv.cfg; rebuild required'
    while IFS= read -r -d '' path; do
      name=${path##*/}
      is_python_name "$name" || continue
      if is_elf "$path" || is_standard "$name" "$mm"; then
        names+=("$name")
        rm -f -- "$path"
      fi
    done < <(find "$stage/bin" -mindepth 1 -maxdepth 1 -name 'python*' -print0)
    base="$(jq -r .base_prefix "$entry")"
    candidate=$base/bin/python$mm
    if [[ $(jq -r '.base_in_scope//false' "$entry") == true ]] && info="$(probe "$candidate")" && [[ $(jq -r .version <<<"$info") == "$version" ]]; then target=$candidate; fi
    if awk -F= '$1~/^include-system-site-packages *$/ && $2~/true/ {found=1} END{exit !found}' "$stage/pyvenv.cfg"; then options+=(--system-site-packages); fi
    # venv rewrites pyvenv.cfg on upgrade. Preserve CPython's verbatim prompt
    # record (including quotes and escapes) without sourcing or decoding it.
    awk '/^prompt[[:space:]]*=/{print; exit}' "$stage/pyvenv.cfg" >"$WORK/venv-prompt"
    runpy "$target" -I -m venv --upgrade --without-pip --copies "${options[@]}" "$stage"
    for name in "${names[@]}"; do [[ -f $stage/bin/$name ]] || cp -p --remove-destination -- "$stage/bin/python" "$stage/bin/$name"; done
    replace_literal "$stage/pyvenv.cfg" "$stage" "$prefix"
    cat "$WORK/venv-prompt" >>"$stage/pyvenv.cfg"
  else
    rsync -aHAX --modify-window=-1 --exclude='/bin/***' --exclude='/lib/python*/site-packages/***' --exclude='/lib/python*/dist-packages/***' \
      --exclude='/lib64/python*/site-packages/***' "$target_prefix/" "$stage/"
    while IFS= read -r -d '' path; do
      name=${path##*/}
      if is_python_name "$name" || [[ $name =~ ^python[0-9.]+-config$ ]]; then cp -a --remove-destination -- "$path" "$stage/bin/$name"; fi
    done < <(find "$target_prefix/bin" -mindepth 1 -maxdepth 1 -print0)
    while IFS= read -r -d '' path; do
      name=${path##*/}
      is_python_name "$name" || continue
      if is_elf "$path" || is_standard "$name" "$mm"; then cp -p --remove-destination -- "$target" "$path"; fi
    done < <(find "$stage/bin" -mindepth 1 -maxdepth 1 -name 'python*' -print0)
    while IFS= read -r -d '' path; do
      replace_literal "$path" "$target_prefix" "$prefix"
      candidate="$(jq -r .target.configured_prefix "$entry")"
      [[ -z $candidate || $candidate == "$target_prefix" ]] || replace_literal "$path" "$candidate" "$prefix"
    done < <(
      find "$stage/lib" -type f \( -name '_sysconfigdata_*.py' -o -path '*/config-*/Makefile' -o -path '*/pkgconfig/python*.pc' \) -print0
      find "$stage/bin" -maxdepth 1 -name 'python*-config' -type f -print0
    )
  fi
}
checkpoint() {
  local entry=$1 journal=$2
  shift 2
  json_edit "$entry" "$@"
  json_edit "$journal" --slurpfile entry "$entry" '.entries |= map(if .prefix==$entry[0].prefix then $entry[0] else . end)'
}
publish_tree() {
  local source=$1 destination=$2
  shift 2
  rsync -aHAX --modify-window=-1 --delete "$@" -- "$source/" "$destination/"
  sync -f "$destination"
}
restore_one() {
  local entry=$1 journal=$2 prefix backup identity
  jq -e '.publication_started == true' "$entry" >/dev/null || die 'No publication started; backup is not restorable'
  prefix="$(jq -r .prefix "$entry")"
  backup="$(jq -r .backup "$entry")"
  [[ -d $backup && ! -L $backup && ! -L $prefix && -d $prefix ]] || die 'Rollback requires the original prefix and its backup'
  identity="$(stat -Lc '%d:%i' -- "$prefix")"
  [[ $identity == "$(jq -r .identity "$entry")" ]] || die "Rollback prefix identity changed: $prefix"
  # A failed publish may leave equal-sized files with the same timestamps.
  publish_tree "$backup" "$prefix" --ignore-times
  checkpoint "$entry" "$journal" --arg at "$(now)" '.status="rolled_back"|.rolled_back_at=$at'
  event rolled_back "$prefix"
}
worker_failure() {
  local status=$1 entry=$2 journal=$3 prefix backup publication
  trap - ERR INT TERM
  set +e
  prefix="$(jq -r .prefix "$entry")"
  backup="$(jq -r .backup "$entry")"
  publication="$(jq -r '.publication_started//false' "$entry")"
  checkpoint "$entry" "$journal" --argjson exit "$status" '.error=("Update worker exited with status "+($exit|tostring))|.status="failed"'
  if [[ $publication == true && -d $backup ]]; then bash "$SELF" _restore "$entry" "$journal" || checkpoint "$entry" "$journal" '.status="rollback_failed"'; fi
  event failed "$prefix" "Worker exit $status"
  exit "$status"
}
apply_one() {
  local entry=$1 journal=$2 checks=$3 prefix stage backup kind version available size needed identity manifest packages_file result
  trap 'worker_failure "$?" "$entry" "$journal"' ERR
  trap 'worker_failure 130 "$entry" "$journal"' INT TERM
  prefix="$(jq -r .prefix "$entry")"
  stage="$(jq -r .stage "$entry")"
  backup="$(jq -r .backup "$entry")"
  kind="$(jq -r .kind "$entry")"
  version="$(jq -r .target.version "$entry")"
  [[ ! -L $prefix && -d $prefix && ! -e $stage && ! -e $backup ]]
  [[ ! -L $prefix/pyvenv.cfg ]] || die 'Linked pyvenv.cfg requires a separate rebuild'
  [[ $(stat -Lc %u -- "$prefix") == "$EUID" ]]
  identity="$(stat -Lc '%d:%i' -- "$prefix")"
  available="$(df -PB1 -- "$prefix" | awk 'NR==2 {print $4}')"
  size="$(du -sB1 -- "$prefix" | awk '{print $1}')"
  needed=$((size * 3 + 104857600))
  ((available > needed)) || die "Insufficient free space for stage and backup: $prefix"
  checkpoint "$entry" "$journal" --arg identity "$identity" '.identity=$identity|.status="preparing"'
  event prepare "$prefix" "$version"
  cp -a --reflink=never -- "$prefix" "$stage"
  event patch_stage "$prefix" "$stage"
  patch_stage "$entry"
  packages_file="$WORK/expected-packages.json"
  jq .package_snapshot "$entry" >"$packages_file"
  result="$WORK/staged-validation.json"
  event validate_stage "$prefix"
  validate "$stage" "$version" "$packages_file" '' "$prefix" stage "$checks" "$result"
  manifest="$WORK/runtime-hashes.json"
  hashes "$stage" "$kind" "$manifest"
  checkpoint "$entry" "$journal" --slurpfile hashes "$manifest" --slurpfile result "$result" '.runtime_hashes=$hashes[0]|.staged_validation=$result[0]|.status="prepared"'
  [[ $(stat -Lc '%d:%i' -- "$prefix") == "$identity" ]]
  event backup "$prefix" "$backup"
  cp -a --reflink=never -- "$prefix" "$backup"
  sync -f "$backup"
  checkpoint "$entry" "$journal" '.status="backed_up"|.publication_started=true'
  event publish "$prefix"
  publish_tree "$stage" "$prefix"
  checkpoint "$entry" "$journal" '.status="installed"'
  result="$WORK/final-validation.json"
  event validate_final "$prefix"
  validate "$prefix" "$version" "$packages_file" "$manifest" "$prefix" final "$checks" "$result"
  checkpoint "$entry" "$journal" --slurpfile result "$result" --arg at "$(now)" '.validation=$result[0]|.status="verified"|.finished=$at'
  trap - ERR INT TERM
  rm -rf -- "$stage" || printf 'Stage cleanup failed: %s\n' "$stage" >&2
  event verified "$prefix" "$version"
}
acquire_locks() {
  local list=$1 parent fd
  while IFS= read -r parent; do
    exec {fd}>"$parent/${MARKER}lock"
    flock -n "$fd" || die "Another updater holds $parent"
    LOCK_FDS+=("$fd")
  done < <(jq -r '.[]|.prefix|sub("/[^/]+$";"")' "$list" | sort -u)
}
rollback_entries() {
  local journal=$1 entry path status failed=0
  while IFS= read -r entry; do
    status="$(jq -r .status <<<"$entry")"
    path="$(jq -r .entry_file <<<"$entry")"
    case "$status" in verified | installed | backed_up | failed | rollback_failed)
      if jq -e '.publication_started == true' <<<"$entry" >/dev/null; then bash "$SELF" _restore "$path" "$journal" || failed=1; fi
      ;;
    esac
  done < <(jq -c '.entries|reverse[]' "$journal")
  return "$failed"
}
apply_plan() {
  local plan=$1 journal=$2 item prefix snapshot path token stage backup count=0 failed=0 fatal=0 base
  local -A blocked=()
  [[ ! -e $journal && ! -L $journal && ! -e $journal.entries && ! -L $journal.entries ]] || die 'Journal exists; choose a new output path'
  jq '[.plan[]|select(.action=="update")]' "$plan" >"$WORK/lock-list.json"
  assert_control_paths "$WORK/lock-list.json" "$journal" "$journal.entries" "$journal.post-verify.json" "$LOG_DIR" "$WORK"
  acquire_locks "$WORK/lock-list.json"
  confirm_plan "$plan" "$WORK/confirmed-plan.json"
  plan="$WORK/confirmed-plan.json"
  cp -- "$plan" "$LOG_DIR/approved-plan.json"
  mkdir -p -- "$journal.entries"
  jq -n --arg created "$(now)" --arg path "$journal" --arg log_file "$LOG_FILE" --slurpfile plan "$plan" \
    '{schema:2,engine:"bash",created:$created,path:$path,log_file:$log_file,complete:false,failures:0,entries:[],failed_snapshots:[],
      skipped:[$plan[0].plan[]|select(.action=="skip")|{prefix,version,reason}],
      end_of_support:[$plan[0].plan[]|select(.eol!="")|{prefix,version,eol}],discovery_warnings:$plan[0].inventory.warnings}' | atomic_write "$journal"
  : >"$WORK/prepared-plan.ndjson"
  while IFS= read -r item; do
    [[ $(jq -r .action <<<"$item") == update ]] || {
      printf '%s\n' "$item" >>"$WORK/prepared-plan.ndjson"
      continue
    }
    prefix="$(jq -r .prefix <<<"$item")"
    event snapshot "$prefix"
    snapshot="$(mktemp "$WORK/snapshot.XXXXXX")"
    if snapshot_packages "$prefix" "$snapshot" 2>"$WORK/snapshot-error"; then
      jq -c --slurpfile snapshot "$snapshot" '.+{package_snapshot:$snapshot[0]}' <<<"$item" >>"$WORK/prepared-plan.ndjson"
    else
      failed=$((failed + 1))
      cat "$WORK/snapshot-error" >&2
      base="$(jq -r .base_prefix <<<"$item")"
      [[ $(jq -r .kind <<<"$item") != venv ]] || blocked[$base]=1
      json_edit "$journal" --arg prefix "$prefix" --arg error "$(cat "$WORK/snapshot-error")" '.failed_snapshots += [{prefix:$prefix,error:$error}]'
      jq -c '.action="skip"|.reason="Package snapshot failed"' <<<"$item" >>"$WORK/prepared-plan.ndjson"
    fi
  done < <(jq -c '.plan[]' "$plan")
  while IFS= read -r item; do
    prefix="$(jq -r .prefix <<<"$item")"
    if [[ $(jq -r .kind <<<"$item") == raw && ${blocked[$prefix]+yes} ]]; then
      item="$(jq -c '.action="skip"|.reason="Dependent venv snapshot failed; raw base left unchanged"' <<<"$item")"
      json_edit "$journal" --arg prefix "$prefix" '.skipped += [{prefix:$prefix,reason:"Dependent venv snapshot failed; raw base left unchanged"}]'
    fi
    if [[ $(jq -r .action <<<"$item") != update ]]; then
      event skip "$prefix" "$(jq -r .reason <<<"$item")"
      continue
    fi
    count=$((count + 1))
    token="${BASHPID}-${RANDOM}-${count}"
    stage=$prefix$MARKER$token.stage
    backup=$prefix$MARKER$token.backup
    path="$journal.entries/$count.json"
    jq --arg stage "$stage" --arg backup "$backup" --arg entry_file "$path" '.+{stage:$stage,backup:$backup,entry_file:$entry_file,status:"pending",old_version:.version}' <<<"$item" | atomic_write "$path"
    json_edit "$journal" --slurpfile entry "$path" '.entries += [$entry[0]]'
    if ! bash "$SELF" _apply-one "$path" "$journal" "$CHECKS" </dev/null; then
      failed=$((failed + 1))
      fatal=1
      rollback_entries "$journal" || failed=$((failed + 1))
      break
    fi
  done <"$WORK/prepared-plan.ndjson"
  json_edit "$journal" --argjson failures "$failed" --arg finished "$(now)" '.complete=true|.finished=$finished|.failures=$failures'
  if ((fatal == 0)); then
    if ! bash "$SELF" _verify "$journal" "$journal.post-verify.json" "$CHECKS"; then
      if [[ ! -s $journal.post-verify.json ]] || jq -e '.results[]|select(.passed==false and .snapshot_failed!=true)' "$journal.post-verify.json" >/dev/null; then rollback_entries "$journal" || true; fi
      failed=$((failed + 1))
      json_edit "$journal" --argjson failures "$failed" '.failures=$failures'
    fi
  fi
  ((failed == 0))
}
verify_journal() {
  local journal=$1 destination=$2 entry prefix packages_file manifest result failed=0
  : >"$WORK/verification.ndjson"
  while IFS= read -r entry; do
    jq -c '.+{passed:false,snapshot_failed:true}' <<<"$entry" >>"$WORK/verification.ndjson"
    failed=$((failed + 1))
  done < <(jq -c '.failed_snapshots[]?' "$journal")
  while IFS= read -r entry; do
    prefix="$(jq -r .prefix <<<"$entry")"
    if [[ $(jq -r .status <<<"$entry") != verified ]]; then
      jq -cn --arg prefix "$prefix" --arg status "$(jq -r .status <<<"$entry")" '{prefix:$prefix,passed:false,error:$status}' >>"$WORK/verification.ndjson"
      failed=$((failed + 1))
      continue
    fi
    packages_file="$(mktemp "$WORK/expected.XXXXXX")"
    manifest="$(mktemp "$WORK/manifest.XXXXXX")"
    result="$(mktemp "$WORK/result.XXXXXX")"
    jq .package_snapshot <<<"$entry" >"$packages_file"
    jq .runtime_hashes <<<"$entry" >"$manifest"
    if validate "$prefix" "$(jq -r .target.version <<<"$entry")" "$packages_file" "$manifest" "$prefix" final "$CHECKS" "$result" 2>"$WORK/verify-error"; then
      jq -cn --arg prefix "$prefix" --slurpfile validation "$result" '{prefix:$prefix,passed:true,validation:$validation[0]}' >>"$WORK/verification.ndjson"
    else
      failed=$((failed + 1))
      cat "$WORK/verify-error" >&2
      jq -cn --arg prefix "$prefix" --arg error "$(cat "$WORK/verify-error")" '{prefix:$prefix,passed:false,error:$error}' >>"$WORK/verification.ndjson"
    fi
  done < <(jq -c '.entries[]' "$journal")
  jq -n --arg created "$(now)" --slurpfile results "$WORK/verification.ndjson" '{created:$created,engine:"bash",results:$results}' | atomic_write "$destination"
  jq -c '{event:"verification",passed:([.results[]|select(.passed)]|length),failed:([.results[]|select(.passed==false)]|length),unresolved_aliases:([.results[].validation.unresolved_aliases[]?]|length)}' "$destination"
  ((failed == 0))
}
main() {
  local root
  while [[ ${1:-} == -Y ]]; do ASSUME_YES=1; shift; done
  COMMAND=${1:---help}
  shift || true
  case "$COMMAND" in
    -h | --help | help)
      usage
      return
      ;;
    _apply-one)
      root_guard
      require_tools
      WORK="$(mktemp -d)"
      apply_one "$@"
      return
      ;;
    _restore)
      root_guard
      require_tools
      WORK="$(mktemp -d)"
      restore_one "$@"
      return
      ;;
    _verify)
      root_guard
      require_tools
      WORK="$(mktemp -d)"
      CHECKS=$3
      verify_journal "$1" "$2"
      return
      ;;
    scan | plan | apply) ;;
    verify | rollback)
      (($#)) || die 'Journal path required'
      JOURNAL="$(absolute "$1")"
      shift
      ;;
    *)
      usage >&2
      exit 2
      ;;
  esac
  root_guard
  while (($#)); do
    case "$1" in
      --output | --checks | --exclude | --target | --log-dir | --runtime-dir | --jobs)
        (($# >= 2)) || die "Missing value for $1"
        case "$1" in
          --output) OUTPUT="$(absolute "$2")" ;;
          --checks) CHECKS="$(canonical "$2")" ;;
          --exclude) EXCLUDES+=("$(absolute "$2")") ;;
          --target) TARGET_SPECS+=("$2") ;;
          --log-dir) LOG_ROOT="$(absolute "$2")" ;;
          --runtime-dir) RUNTIME_DIR="$(absolute "$2")" ;;
          --jobs)
            [[ $2 =~ ^[1-9][0-9]*$ ]] || die '--jobs requires a positive integer'
            BUILD_JOBS=$2
            ;;
        esac
        shift 2
        ;;
      -Y)
        ASSUME_YES=1
        shift
        ;;
      --skip-apt)
        SKIP_APT=1
        shift
        ;;
      --no-sudo)
        NO_SUDO=1 SKIP_APT=1
        shift
        ;;
      --)
        shift
        ROOTS+=("$@")
        break
        ;;
      -*) die "Unknown option: $1" ;;
      *)
        ROOTS+=("$(absolute "$1")")
        shift
        ;;
    esac
  done
  start_logging
  ((ASSUME_YES == 0)) || [[ $COMMAND == apply ]] || die '-Y is only supported by apply'
  prepare_tools
  WORK="$(mktemp -d)"
  if [[ -z $OUTPUT ]]; then
    case "$COMMAND" in
      scan) OUTPUT="$LOG_DIR/inventory.json" ;;
      plan) OUTPUT="$LOG_DIR/plan.json" ;;
      apply) OUTPUT="$LOG_DIR/journal.json" ;;
      verify) OUTPUT="$LOG_DIR/verification.json" ;;
    esac
  fi
  [[ -z $OUTPUT ]] || printf 'Output: %s\n' "$OUTPUT" >&2
  if [[ -n $CHECKS ]]; then jq -e 'type=="object" and all(.[];type=="array" and all(.[];.argv|type=="array" and length>0 and all(.[];type=="string")))' "$CHECKS" >/dev/null || die 'Invalid application checks JSON'; fi
  if [[ -n $JOURNAL ]]; then
    jq -e '.schema==2 and .engine=="bash" and (.entries|type=="array")' "$JOURNAL" >/dev/null || die 'Expected a native Bash schema-2 journal'
  fi
  case "$COMMAND" in
    scan | plan | apply)
      ((${#ROOTS[@]})) || ROOTS=("$(canonical "$HOME")")
      RUNTIME_DIR="$(realpath -m -- "$RUNTIME_DIR")"
      for root in "${ROOTS[@]}"; do
        if within "$(realpath -m -- "$root")" "$RUNTIME_DIR"; then die 'Runtime directory must not contain a search root'; fi
      done
      [[ ! -f $RUNTIME_DIR/pyvenv.cfg ]] || die 'Runtime directory must be separate from existing environments'
      PRUNE_PATHS+=("$RUNTIME_DIR" "$LOG_ROOT")
      if [[ $COMMAND != scan ]]; then
        load_release_policy
        load_targets
        load_cached_targets
      fi
      event scan_started
      scan "$WORK/inventory.json"
      cp -- "$WORK/inventory.json" "$LOG_DIR/inventory.json"
      if [[ $COMMAND == scan ]]; then
        atomic_write "$OUTPUT" <"$WORK/inventory.json"
        event scanned '' "$(jq '.environments|length' "$OUTPUT") environments"
        return
      fi
      discover_targets "$WORK/inventory.json"
      make_plan "$WORK/inventory.json" "$WORK/plan.json"
      if [[ $COMMAND == apply ]]; then
        cp -- "$WORK/plan.json" "$LOG_DIR/plan.json"
        prepare_targets "$WORK/plan.json"
        make_plan "$WORK/inventory.json" "$WORK/plan.json"
      fi
      cp -- "$WORK/plan.json" "$LOG_DIR/plan.json"
      event planned '' "$(jq '[.plan[]|select(.action=="update")]|length' "$WORK/plan.json") updates, $(jq '[.plan[]|select(.action=="prepare_target")]|length' "$WORK/plan.json") environments need a target build"
      if [[ $COMMAND == plan ]]; then
        atomic_write "$OUTPUT" <"$WORK/plan.json"
        return
      fi
      apply_plan "$WORK/plan.json" "$OUTPUT"
      ;;
    verify)
      verify_journal "$JOURNAL" "$OUTPUT"
      ;;
    rollback)
      jq .entries "$JOURNAL" >"$WORK/lock-list.json"
      assert_control_paths "$WORK/lock-list.json" "$JOURNAL" "$JOURNAL.entries" "$LOG_DIR" "$WORK"
      acquire_locks "$WORK/lock-list.json"
      rollback_entries "$JOURNAL"
      ;;
  esac
}
main "$@"
