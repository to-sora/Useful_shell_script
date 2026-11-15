#!/usr/bin/env bash
# Native Bash CPython patch updater. No embedded or generated Python source.
# See update_python_envs.md for trusted roots, backups, and examples.
set -Eeuo pipefail
umask 077
export LC_ALL=C
SELF="$(realpath -e -- "${BASH_SOURCE[0]}")"
MARKER='.pyenv-update-'
WORK=''
PENDING_BUILD=''
declare -a ROOTS=() EXCLUDES=() SCAN_ROOTS=() SCAN_EXCLUDES=() TARGET_SPECS=() LOCK_FDS=()
declare -a PRUNE_PATHS=() TRUSTED_TARGETS=()
declare -a INVOCATION=("$@")
OUTPUT='' CHECKS='' COMMAND='' JOURNAL=''
ASSUME_YES=0
INTERACTIVE=0 STORAGE_READY=0
HOME_ONLY_MOUNT=''
declare -a MOUNT_PATHS=() MOUNT_CLASSES=() MOUNT_QUESTIONS=() MOUNT_APPROVED=()
declare -A STORAGE_WARNED=()
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
  if [[ -n $PENDING_BUILD ]]; then
    rm -rf --one-file-system -- "$PENDING_BUILD" || printf 'Could not remove unfinished target build: %s\n' "$PENDING_BUILD" >&2
  fi
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
  update_python_envs.sh                 # discover and choose each environment
  update_python_envs.sh scan [ROOT...]
  update_python_envs.sh plan [ROOT...]
  update_python_envs.sh [-Y] apply [ROOT...]
  update_python_envs.sh verify JOURNAL
  update_python_envs.sh rollback JOURNAL

With no arguments, scan SSD/memory mounts and ask [y/N] for each uncertain local
mount before discovery. Scan permission covers that mount for this run.
If no mounts qualify and HOME is on a reported HDD, offer to scan HOME only.
Review each Python installation, venv and Conda transaction. Answer y/yes to
update that path or n/no/Enter to skip. All choices precede builds and writes.
If a venv requires a different base, its prompt names that change.
Explicit commands retain their HOME default.
HDDs are excluded from automatic scans. Loops and unsupported filesystems
are excluded. Explicit commands skip HDDs and uncertain media.
Plan/apply use the adjacent installer's release pins.
Conda installations use python_updater_conda.sh and their own Conda solver.
Apply reuses healthy targets or builds missing branches, then updates environments.
Plan reports required builds without installing. Installer --print-pins lists versions.
Options: --target MINOR=/existing/bin/python (repeatable override),
         --output FILE (default: JSON inside the run's log directory),
         --exclude PATH (repeatable), --checks checks.json (apply/verify),
         --log-dir DIR (default: script directory/log),
         --runtime-dir DIR (default: ${XDG_DATA_HOME:-$HOME/.local/share}/python-env-updater),
         --jobs N (default: 4), --skip-apt, --no-sudo (implies --skip-apt).
Automatic builds use install_python.sh with --skip-conda and --no-bashrc.
Explicit commands may request a sudo password for Ubuntu dependencies/builds.
No-argument mode requires preinstalled dependencies and uses --skip-apt --no-sudo.
Explicit apply asks for each venv and Conda environment before changing any
environment. EOF aborts before updating. -Y on explicit apply bypasses prompts.
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
  for tool in jq find realpath stat readlink sha256sum rsync cp mv mktemp flock timeout awk sort sync od tee findmnt lsblk; do
    command -v "$tool" >/dev/null || die "Required utility missing: $tool"
  done
}
prepare_tools() {
  local tool os
  local -a missing=()
  for tool in jq rsync; do command -v "$tool" >/dev/null || missing+=("$tool"); done
  if ((${#missing[@]})) && [[ $COMMAND == apply ]] && ((SKIP_APT == 0)); then
    ((INTERACTIVE == 0)) || die "Install required utilities before interactive updates: ${missing[*]}"
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

# Read the mount table once. Walking each mount with -xdev and pruning every
# nested mount prevents even a directory traversal into an HDD/bind mount.
# Inverse lsblk trees include the backing devices of partitions, LVM and RAID.
# A known HDD or loop excludes the complete stack. An emulated disk's rotation
# flag describes the guest interface; the operator can decide whether to scan it.
load_storage() {
  local path class question vm=false
  if command -v systemd-detect-virt >/dev/null && systemd-detect-virt --vm --quiet </dev/null 2>/dev/null; then vm=true; fi
  findmnt --json --list --uniq --output TARGET,SOURCE,FSTYPE,MAJ:MIN >"$WORK/mounts.json" || die 'Cannot read mounted filesystems'
  if ! lsblk --json --inverse --tree --output NAME,MAJ:MIN,ROTA,TYPE,VENDOR,MODEL >"$WORK/block-devices.json"; then
    printf 'Cannot read the block device tree; block-backed mounts will be classified as unknown.\n' >&2
    printf '{"blockdevices":[]}\n' >"$WORK/block-devices.json"
  fi
  jq -e '(.filesystems|type)=="array" and all(.filesystems[];
    (.target|type)=="string" and (.target|startswith("/")) and (.target|test("[\\t\\r\\n]")|not))' \
    "$WORK/mounts.json" >/dev/null || die 'Unsupported paths in mount inventory'
  jq -n --argjson vm "$vm" --slurpfile mounts "$WORK/mounts.json" --slurpfile devices "$WORK/block-devices.json" '
    def backing: recurse(.children[]?);
    def rotational: .rota==true or .rota==1 or .rota=="1";
    def virtual_disk:
      .type=="disk" and (
        ((.name // "")|test("^(xvd|vd)[a-z]+$")) or
        ([.vendor,.model]|join(" ")|test("QEMU|VMware|VBOX|VirtIO|Xen|Parallels|Virtual[ _-]*(Disk|HD)|Elastic Block Store|Persistent[ _-]*Disk";"i")) or
        ($vm and ((.model // "")|test("^\\s*(unknown|generic|scsi disk|disk)?\\s*$";"i"))));
    def disk_class:
      if any(backing; .type=="loop" or ((.["maj:min"] // "")|startswith("7:"))) then "loop"
      elif any(backing; .type=="disk" and rotational and (virtual_disk|not)) then "hdd"
      elif any(backing; rotational) then
        if any(backing; virtual_disk) or ($vm and all(backing; .type!="disk"))
        then "virtual-hdd" else "hdd" end
      elif any(backing; (.rota!=false and .rota!=0 and .rota!="0")
               or ((.children|length)==0 and .type!="disk")) then "unknown"
      else "ssd" end;
    def mount_class($disk):
      if (.fstype=="tmpfs" or .fstype=="ramfs") then {class:"memory",reason:"memory filesystem"}
      elif (.fstype|test("^(ext[234]|xfs|btrfs|f2fs|vfat|exfat|ntfs3?)$")|not)
        then {class:"unknown",reason:"filesystem type excluded from discovery"}
      elif $disk=="loop" or ((.["maj:min"] // "")|startswith("7:")) or
           ((.source // "")|test("^/dev/loop[0-9]+(p[0-9]+)?($|\\[)"))
        then {class:"unknown",reason:"loop-backed mount"}
      elif $disk=="hdd" then {class:"hdd",reason:"device stack reports rotational media"}
      elif $disk=="virtual-hdd" then {class:"hdd",ask:true,reason:"virtual disk reports rotation; host media unknown"}
      elif $disk=="ssd" then {class:"ssd",reason:"device stack reports non-rotational disks"}
      elif $disk=="unknown" then {class:"unknown",ask:true,reason:"incomplete backing disk or rotation information"}
      else {class:"unknown",ask:true,reason:"mount device ID absent from the block device tree"} end;
    [$devices[0].blockdevices[]? | backing | {device:.["maj:min"],class:disk_class}]
    | group_by(.device) | map({key:.[0].device,value:
        (if any(.[];.class=="loop") then "loop"
         elif any(.[];.class=="hdd") then "hdd"
         elif any(.[];.class=="virtual-hdd") then "virtual-hdd"
         elif any(.[];.class=="unknown") then "unknown" else "ssd" end)}) | from_entries as $disks
    | [$mounts[0].filesystems[] | (.["maj:min"] // "") as $id |
        {path:.target, filesystem:.fstype, device:$id} + mount_class($disks[$id])]
    | sort_by(.path|length) | reverse' >"$WORK/storage.json" || die 'Invalid storage inventory'
  MOUNT_PATHS=() MOUNT_CLASSES=() MOUNT_QUESTIONS=() MOUNT_APPROVED=()
  while IFS= read -r -d '' path && IFS= read -r -d '' class && IFS= read -r -d '' question; do
    MOUNT_PATHS+=("$path")
    MOUNT_CLASSES+=("$class")
    MOUNT_QUESTIONS+=("$question")
  done < <(jq -j '.[]|.path,"\u0000",.class,"\u0000",(.ask // false|tostring),"\u0000"' "$WORK/storage.json")
  STORAGE_READY=1
  cp -- "$WORK/storage.json" "$LOG_DIR/storage.json"
}
storage_class() {
  local path=$1 i
  STORAGE_CLASS=unknown STORAGE_APPROVED=0 STORAGE_MOUNT_INDEX=''
  for i in "${!MOUNT_PATHS[@]}"; do
    if within "$path" "${MOUNT_PATHS[$i]}"; then
      STORAGE_CLASS=${MOUNT_CLASSES[$i]}
      STORAGE_MOUNT_INDEX=$i
      if [[ -n ${MOUNT_APPROVED[$i]:-} ]] && within "$path" "${MOUNT_APPROVED[$i]}"; then STORAGE_APPROVED=1; fi
      break
    fi
  done
}
storage_allowed() {
  local path=$1
  ((STORAGE_READY)) || return 0
  storage_class "$path"
  if [[ -n $HOME_ONLY_MOUNT ]]; then
    [[ $STORAGE_MOUNT_INDEX == "$HOME_ONLY_MOUNT" && $STORAGE_APPROVED == 1 ]]
    return
  fi
  [[ $STORAGE_CLASS == ssd || $STORAGE_CLASS == memory || $STORAGE_APPROVED == 1 ]]
}
storage_warning() {
  local path=$1
  [[ ! ${STORAGE_WARNED[$path]+yes} ]] || return 0
  STORAGE_WARNED[$path]=1
  storage_class "$path"
  warning "$path" "Storage excluded: $STORAGE_CLASS"
  event storage_skipped "$path" "$STORAGE_CLASS"
}
ask_scan_mount() {
  local i=$1 mount=${MOUNT_PATHS[$1]} scope=$2 answer choice
  jq -r --arg mount "$mount" 'first(.[]|select(.path==$mount)) |
    "\(.path) (\(.filesystem), device \(.device), class \(.class): \(.reason))"' "$LOG_DIR/storage.json" >&2
  while true; do
    printf 'Scan %s for Python environments? [y/N] ' "$scope" >&2
    if ! IFS= read -r answer; then
      printf '\n' >&2
      choice=input_ended
      break
    fi
    case "${answer,,}" in
      y | yes) choice=approved; break ;;
      '' | n | no) choice=skipped; break ;;
      *) printf 'Enter y to scan or n to skip.\n' >&2 ;;
    esac
  done
  json_edit "$LOG_DIR/storage.json" --arg mount "$mount" --arg scope "$scope" --arg choice "$choice" \
    'map(if .path==$mount then .+{scan_scope:$scope,scan_choice:$choice} else . end)'
  event storage_choice "$scope" "$choice"
  case "$choice" in
    approved) MOUNT_APPROVED[$i]=$scope ;;
    input_ended) die "Storage selection ended before discovery. Storage inventory: $LOG_DIR/storage.json" ;;
  esac
}
automatic_roots() {
  local path i home asked=0
  ROOTS=()
  for i in "${!MOUNT_PATHS[@]}"; do
    path=${MOUNT_PATHS[$i]}
    case "$path/" in /proc/* | /sys/* | /dev/* | /run/*) continue ;; esac
    protected "$path" && continue
    if within "$path" "$RUNTIME_DIR" || within "$path" "$LOG_ROOT"; then continue; fi
    if [[ ${MOUNT_QUESTIONS[$i]} == true ]]; then
      [[ -d $path ]] || continue
      if ((asked == 0)); then
        printf '\nSelect trusted mounts for discovery. Scanning runs candidate Python interpreters. Updates require a separate confirmation.\n' >&2
      fi
      asked=1
      ask_scan_mount "$i" "$path"
      if [[ -n ${MOUNT_APPROVED[$i]:-} ]]; then ROOTS+=("$path"); fi
    elif [[ ${MOUNT_CLASSES[$i]} == ssd || ${MOUNT_CLASSES[$i]} == memory ]]; then
      if [[ -d $path ]]; then ROOTS+=("$path"); fi
    fi
  done
  if ((${#ROOTS[@]} == 0)); then
    if ((asked)); then
      event no_scan '' 'All offered mounts were skipped'
      return 0
    fi
    home="$(realpath -m -- "$HOME")"
    storage_class "$home"
    if [[ $STORAGE_CLASS == hdd && $home != / && -d $home ]] && walk_root_allowed "$home" &&
      ! within "$home" "$RUNTIME_DIR" && ! within "$home" "$LOG_ROOT"; then
      i=$STORAGE_MOUNT_INDEX
      printf '\nNo automatic scan roots. The home mount reports rotational media.\n' >&2
      printf 'Only %s on this mount is offered. Scanning runs candidate Python interpreters. Updates require a separate confirmation.\n' "$home" >&2
      printf 'Storage inventory: %s/storage.json\n' "$LOG_DIR" >&2
      ask_scan_mount "$i" "$home"
      if [[ -n ${MOUNT_APPROVED[$i]:-} ]]; then
        HOME_ONLY_MOUNT=$i
        ROOTS+=("$home")
      else
        event no_scan "$home" 'Home scan skipped'
      fi
      return 0
    fi
    # storage.json is ordered by descending mount path length. Use the same
    # path boundary as storage_class, including when HOME is on the root mount.
    jq -r --arg home "$home" '
      first(.[] | .path as $mount | select($home==$mount or
        ($home|startswith(($mount|rtrimstr("/"))+"/")))) |
      "Home \($home): mount \(.path), filesystem \(.filesystem), device \(.device), class \(.class) (\(.reason))."
    ' "$LOG_DIR/storage.json" >&2
    die "No eligible SSD or memory directory mounts for discovery. Storage inventory: $LOG_DIR/storage.json"
  fi
}
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
  timeout --kill-after=5 "${PY_TIMEOUT:-120}" "${environment[@]}" PIP_DISABLE_PIP_VERSION_CHECK=1 PIP_NO_INPUT=1 "$@" </dev/null
}
config_value() {
  awk -v key="$2" '$1==key && $2=="=" {sub(/^[^=]*= "/, "");sub(/"$/, "");print;exit}' "$1"
}
venv_home() {
  awk '/^home[[:space:]]*=/ {sub(/^[^=]*=[[:space:]]*/, ""); print; exit}' "$1"
}
# The sysconfig module CLI supplies identity and ABI without inline code.
probe() {
  local binary version report prefix base abi shared bits pure plat machine configured managed='private'
  binary="$(absolute "$1")"
  storage_allowed "$(realpath -m -- "$binary")" || return 1
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
  machine="$(awk '/^Platform:/ {sub(/^Platform: "/, "");sub(/"$/, "");print;exit}' "$report")"
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
  storage_allowed "$path" || return 1
  case "/${path#/}/" in */.git/* | */node_modules/* | *"$MARKER"*) return 1 ;; esac
  for root in "${SCAN_EXCLUDES[@]}"; do within "$path" "$root" && return 1; done
  for root in "${SCAN_ROOTS[@]}"; do within "$path" "$root" && return 0; done
  # Validated, explicitly supplied or updater-managed targets can back a venv.
  for root in "${TRUSTED_TARGETS[@]}"; do within "$path" "$root" && return 0; done
  return 1
}
find_literal() {
  local value=$1
  value=${value//\\/\\\\}
  value=${value//\*/\\*}
  value=${value//\?/\\?}
  value=${value//\[/\\[}
  value=${value//\]/\\]}
  printf '%s\n' "$value"
}
walk_root_allowed() {
  local path=$1 excluded
  if ((INTERACTIVE)); then
    case "$path/" in /proc/* | /sys/* | /dev/* | /run/*) return 1 ;; esac
    protected "$path" && return 1
  fi
  for excluded in "${SCAN_EXCLUDES[@]}" "${PRUNE_PATHS[@]}"; do
    within "$path" "$(realpath -m -- "$excluded")" && return 1
  done
  return 0
}
scan() {
  local destination=$1 root path name resolved prefix base info marker line status=0 mount identity owner flag
  local -a expression=('(' -name "*$MARKER*" -o -name .git -o -path '*/.git/*' -o -name node_modules -o -path '*/node_modules/*')
  local -a walk_expression=()
  local -A seen=() identities=() walk_seen=()
  SCAN_ROOTS=()
  SCAN_EXCLUDES=()
  : >"$WORK/probes.ndjson"
  : >"$WORK/warnings.ndjson"
  : >"$WORK/links.ndjson"
  : >"$WORK/found"
  STORAGE_WARNED=()
  if ((INTERACTIVE)); then
    for path in /proc /sys /dev /run /usr /bin /sbin /lib /lib64 /System "${CODEX_PRIMARY_RUNTIME_ROOT:-}"; do
      [[ -z $path ]] || expression+=(-o -path "$(find_literal "$(realpath -m -- "$path")")")
    done
  fi
  for path in "${EXCLUDES[@]}"; do
    resolved="$(realpath -m -- "$path")"
    SCAN_EXCLUDES+=("$resolved")
    expression+=(-o -path "$(find_literal "$resolved")")
  done
  for path in "${PRUNE_PATHS[@]}"; do expression+=(-o -path "$(find_literal "$(realpath -m -- "$path")")"); done
  expression+=(')' -prune -o '(' -type l -o -name pyvenv.cfg -o -path '*/bin/python*' ')' -print0)
  for root in "${ROOTS[@]}"; do
    resolved="$(realpath -m -- "$root")"
    if ! storage_allowed "$resolved"; then
      storage_warning "$resolved"
      continue
    fi
    if [[ ! -e $root ]]; then
      warning "$root" 'Missing search root'
      continue
    fi
    resolved="$(canonical "$root")"
    walk_root_allowed "$resolved" || continue
    SCAN_ROOTS+=("$resolved")
    if [[ -L $root ]]; then
      jq -cn --arg path "$root" --arg target "$resolved" '{path:$path,target:$target}' >>"$WORK/links.ndjson"
    fi
  done
  # A selected root can contain other eligible mountpoints. Add those roots
  # explicitly; each individual walk still stops at every mount boundary.
  for root in "${SCAN_ROOTS[@]}"; do
    for mount in "$root" "${MOUNT_PATHS[@]}"; do
      within "$mount" "$root" && storage_allowed "$mount" || continue
      walk_root_allowed "$mount" || continue
      [[ $mount == "$root" || -d $mount ]] || continue
      [[ ! ${walk_seen[$mount]+yes} ]] || continue
      walk_seen[$mount]=1
    done
  done
  SCAN_ROOTS=()
  for root in "${!walk_seen[@]}"; do SCAN_ROOTS+=("$root"); done
  # Explicit roots retain their discovery boundary. Automatic mode enumerates
  # allowed mounts; neither mode follows directory links during the walk.
  : >"$WORK/find-errors"
  for root in "${SCAN_ROOTS[@]}"; do
    walk_expression=('(')
    for mount in "${MOUNT_PATHS[@]}"; do
      [[ $mount != "$root" ]] && within "$mount" "$root" || continue
      walk_expression+=(-path "$(find_literal "$mount")" -o)
      storage_allowed "$mount" || storage_warning "$mount"
    done
    walk_expression+=(-false ')' -prune -o)
    find -P "$root" -xdev "${walk_expression[@]}" "${expression[@]}" >>"$WORK/found" 2>>"$WORK/find-errors" || status=$?
  done
  while IFS= read -r line; do warning '' "$line"; done <"$WORK/find-errors"
  while IFS= read -r -d '' path; do
    safe_path "$path"
    scan_path_allowed "$path" || continue
    [[ ! ${seen[$path]+yes} ]] || continue
    seen[$path]=1
    if [[ -L $path ]]; then
      resolved="$(realpath -m -- "$path")"
      jq -cn --arg path "$path" --arg target "$resolved" '{path:$path,target:$target}' >>"$WORK/links.ndjson"
      if ! storage_allowed "$resolved"; then
        storage_warning "$resolved"
        continue
      fi
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
    if ((INTERACTIVE)); then
      protected "$prefix" && continue
    fi
    # Check config/base and library locations before invoking a copied venv or
    # a linked interpreter. Its startup may otherwise read an HDD-backed base.
    base=''
    if [[ -f $prefix/pyvenv.cfg ]]; then
      resolved="$(realpath -m -- "$prefix/pyvenv.cfg")"
      if ! storage_allowed "$resolved"; then
        storage_warning "$resolved"
        continue
      fi
      base="$(venv_home "$prefix/pyvenv.cfg")"
    fi
    flag=0
    for root in "$prefix/lib" "$prefix/lib64" "$base"; do
      [[ -n $root ]] || continue
      resolved="$(realpath -m -- "$root")"
      if ! storage_allowed "$resolved"; then
        storage_warning "$resolved"
        flag=1
      fi
    done
    ((flag == 0)) || continue
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
    if ((INTERACTIVE)); then
      owner="$(stat -Lc %u -- "$prefix")"
      if [[ $owner != "$EUID" ]]; then
        warning "$prefix" 'Prefix owned by another account; original-path updates require owner access'
        continue
      fi
    fi
    if ! info="$(probe "$path")"; then
      warning "$path" 'Missing, non-ELF, or unusable CPython interpreter'
      continue
    fi
    if [[ $(jq -r .prefix <<<"$info") != "$prefix" ]]; then
      warning "$path" 'Interpreter reports a different prefix'
      continue
    fi
    identity="$(stat -Lc '%d:%i' -- "$prefix")"
    if [[ ${identities[$identity]:-$prefix} != "$prefix" ]]; then
      warning "$prefix" "Directory alias of ${identities[$identity]}"
      continue
    fi
    identities[$identity]=$prefix
    info="$(jq -c --arg id "$identity" '.prefix_identity=$id' <<<"$info")"
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
  json_edit "$WORK/targets.json" --arg mm "$mm" --arg source "$source" --argjson info "$info" \
    '.[$mm][($info.shared|tostring)]=$info+{minor:$mm,source:$source}'
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
  if ((INTERACTIVE)) && ! storage_allowed "$(realpath -m -- "$RUNTIME_DIR/targets.json")"; then return 0; fi
  [[ -f $RUNTIME_DIR/targets.json ]] || return 0
  jq -e 'type=="object" and all(.[];type=="string")' "$RUNTIME_DIR/targets.json" >/dev/null || die 'Invalid runtime cache targets.json'
  for mm in "${!POLICY[@]}"; do
    jq -e --arg mm "$mm" 'has($mm)' "$WORK/targets.json" >/dev/null && continue
    while IFS= read -r path; do
      within "$(realpath -m -- "$path")" "$RUNTIME_DIR" || die "Cached target escapes runtime directory: $path"
      if info="$(target_info "$mm" "$path")" && within "$(jq -r .prefix <<<"$info")" "$RUNTIME_DIR" && healthy_target "$path"; then
        remember_target "$mm" "$info" cache
      else
        event target_unusable "$path" 'A fresh target will be prepared if needed'
      fi
    done < <(jq -r --arg mm "$mm" '[.[$mm],.[$mm+":shared=0"],.[$mm+":shared=1"]]|map(select(.!=null))|unique[]' "$RUNTIME_DIR/targets.json")
  done
}
discover_targets() {
  local inventory=$1 mm path info prefix
  # Prefer the newest healthy private raw installation in the trusted scan.
  while IFS= read -r path; do
    info="$(jq -c --arg path "$path" '.environments[]|select(.binary==$path)' "$inventory")"
    mm="$(minor "$(jq -r .version <<<"$info")")"
    [[ ${POLICY[$mm]+yes} ]] || continue
    jq -e --arg mm "$mm" --argjson i "$info" '.[$mm] as $v |
      $v[($i.shared|tostring)]!=null or any($v[]?;.source=="explicit")' "$WORK/targets.json" >/dev/null && continue
    prefix="$(jq -r .prefix <<<"$info")"
    protected "$prefix" && continue
    if info="$(target_info "$mm" "$path")" && healthy_target "$path"; then remember_target "$mm" "$info" discovered; fi
  done < <(jq -r '.environments|map(select(.kind=="raw" and .managed=="private" and (.versions|length)==1))|
    sort_by(.version|split(".")|map(tonumber))|reverse|.[].binary' "$inventory")
}
check_build_space() {
  local version=$1 report available total_inodes free_inodes
  # One source tree, its objects and its installed runtime coexist until validation.
  local min_bytes=$((1024 * 1024 * 1024)) min_inodes=16000 inode_short=0
  report=$(df -B1 --output=avail,itotal,iavail -- "$RUNTIME_DIR") || die "Cannot measure build space at $RUNTIME_DIR"
  read -r available total_inodes free_inodes <<< "${report##*$'\n'}"
  [[ $available =~ ^-?[0-9]+$ ]] || die "Cannot read available bytes at $RUNTIME_DIR"
  # Some filesystems allocate inodes dynamically and report zero or '-' for their total.
  if [[ $total_inodes =~ ^[1-9][0-9]*$ && $free_inodes =~ ^-?[0-9]+$ ]]; then
    ((free_inodes >= min_inodes)) || inode_short=1
  else
    free_inodes=unreported
  fi
  printf 'Python %s build at %s: %s bytes available, free inodes: %s. Build estimate: %s bytes (1 GiB) and %s inodes.\n' \
    "$version" "$RUNTIME_DIR" "$available" "$free_inodes" "$min_bytes" "$min_inodes" >&2
  if ((available >= min_bytes && inode_short == 0)); then return 0; fi
  if [[ ${PYTHON_UPDATER_ALLOW_LOW_BUILD_SPACE:-} == 1 ]] && ((available > 0)) && { ((inode_short == 0)) || ((free_inodes > 0)); }; then
    printf 'Proceeding below the estimate at operator request (PYTHON_UPDATER_ALLOW_LOW_BUILD_SPACE=1).\n' >&2
    return 0
  fi
  die "Insufficient build space for Python $version at $RUNTIME_DIR. Free space there or set XDG_DATA_HOME to a directory on an approved mount (--runtime-dir for explicit apply). Existing environments were not updated."
}
prepare_targets() {
  local plan=$1 mm build_dir path info fd shared skip_apt=$SKIP_APT
  local -a needed options=(--reuse --skip-conda --no-bashrc --jobs "$BUILD_JOBS") build_options
  jq -e 'any(.plan[];.action=="prepare_target")' "$plan" >/dev/null || return 0
  jq '[.plan[]|select(.action!="skip")]' "$plan" >"$WORK/control-prefixes.json"
  assert_control_paths "$WORK/control-prefixes.json" "$OUTPUT" "$OUTPUT.entries" "$OUTPUT.post-verify.json" "$LOG_DIR" "$WORK" "$RUNTIME_DIR"
  [[ ! -e $OUTPUT && ! -L $OUTPUT && ! -e $OUTPUT.entries && ! -L $OUTPUT.entries ]] || die 'Journal exists; choose a new output path'
  mkdir -p -- "$RUNTIME_DIR"
  exec {fd}>"$RUNTIME_DIR/.build.lock"
  flock -n "$fd" || die "Another updater is preparing targets in $RUNTIME_DIR"
  # Each build has a permanent, unique prefix. An interrupted or unhealthy
  # cached build is never rebuilt in place underneath an existing venv.
  ((NO_SUDO == 0)) || options+=(--no-sudo)
  for shared in 0 1; do
    mapfile -t needed < <(jq -r --argjson shared "$shared" '[.plan[]|select(.action=="prepare_target" and .shared==$shared)|
      .version|split(".")[0:2]|join(".")]|unique[]' "$plan")
    ((${#needed[@]})) || continue
    for mm in "${needed[@]}"; do
      check_build_space "${POLICY[$mm]}"
      build_dir="$(mktemp -d "$RUNTIME_DIR/build-$(date -u +%Y%m%dT%H%M%SZ).XXXXXX")"
      PENDING_BUILD=$build_dir
      mkdir -- "$build_dir/src"
      build_options=("${options[@]}")
      ((shared == 0)) || build_options+=(--enable-shared)
      ((skip_apt == 0)) || build_options+=(--skip-apt)
      event target_build_started "$build_dir" "$mm (shared=$shared)"
      if ! TMPDIR="$build_dir/src" bash "${SELF%/*}/install_python.sh" "$build_dir" "${build_options[@]}" --py "$mm" </dev/null; then
        df -B1 --output=target,avail,iavail -- "$build_dir" >&2 || true
        die "Target preparation failed; existing environments were not updated (Python ${POLICY[$mm]}, build directory $build_dir)"
      fi
      skip_apt=1
      path="$build_dir/opt/python-${POLICY[$mm]}/bin/python$mm"
      info="$(target_info "$mm" "$path")" && [[ $(jq -r .shared <<<"$info") == "$shared" ]] && healthy_target "$path" || die "Prepared target failed validation: $path"
      remember_target "$mm" "$info" installed
      rm -rf --one-file-system -- "$build_dir/src" || printf 'Could not remove build intermediates: %s/src\n' "$build_dir" >&2
      # Once a cache write can refer to this runtime, cleanup must preserve it,
      # including on interruption between atomic rename and filesystem sync.
      PENDING_BUILD=''
      if [[ ! -f $RUNTIME_DIR/targets.json ]]; then printf '{}\n' | atomic_write "$RUNTIME_DIR/targets.json"; fi
      json_edit "$RUNTIME_DIR/targets.json" --arg mm "$mm" --arg path "$path" --arg shared "$shared" \
        --slurpfile selected "$WORK/targets.json" '
        reduce ($selected[0][$mm][]|select(.source=="cache")) as $t (.;
          .[$mm+":shared="+($t.shared|tostring)]=$t.binary)
        | .[$mm]=$path | .[$mm+":shared="+$shared]=$path'
      event target_build_finished "$build_dir" "$mm (shared=$shared)"
    done
  done
  exec {fd}>&-
}
protected() {
  local root
  for root in /usr /bin /sbin /lib /lib64 /System "${CODEX_PRIMARY_RUNTIME_ROOT:-}"; do
    [[ -n $root ]] && within "$1" "$(realpath -m -- "$root")" && return 0
  done
  return 1
}
load_conda_support() {
  declare -F conda_plan_item >/dev/null && return 0
  [[ -r ${SELF%/*}/python_updater_conda.sh ]] || return 1
  source "${SELF%/*}/python_updater_conda.sh"
}
make_plan() {
  local inventory=$1 destination=$2 item prefix kind managed version mm target reason candidate newer flag unresolved name patch outside action older requested conda_item
  : >"$WORK/plan.ndjson"
  touch "$WORK/conda-plans.ndjson"
  while IFS= read -r item; do
    prefix="$(jq -r .prefix <<<"$item")"
    kind="$(jq -r .kind <<<"$item")"
    managed="$(jq -r .managed <<<"$item")"
    version="$(jq -r .version <<<"$item")"
    mm=$(minor "$version")
    target="$(jq -c --arg mm "$mm" --argjson i "$item" '.[$mm] as $v |
      $v[($i.shared|tostring)] // first($v[]? | select(.source=="explicit")) // null' "$WORK/targets.json")"
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
    if [[ $managed == conda-package-cache ]]; then
      reason='Conda package cache'
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
    elif [[ $managed == conda ]]; then
      if load_conda_support; then
        conda_item="$(jq -sc --arg p "$prefix" 'first(.[] | select(.prefix==$p)) // empty' "$WORK/conda-plans.ndjson")"
        if [[ -z $conda_item ]]; then
          conda_item="$(conda_plan_item "$item" "$inventory")"
          printf '%s\n' "$conda_item" >>"$WORK/conda-plans.ndjson"
        fi
        printf '%s\n' "$conda_item" >>"$WORK/plan.ndjson"
        continue
      fi
      reason='Conda updates require the adjacent python_updater_conda.sh'
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
    '{engine:"bash",inventory:$inventory[0],plan:($plan|sort_by(.kind=="venv",.prefix))}' | atomic_write "$destination"
}

# Reapply the same individual choices to both the initial and post-build plans.
# A declined venv protects its base even when a different venv was approved.
selected_plan() {
  local candidates=$1 destination=$2
  jq --slurpfile choices "$WORK/choices.ndjson" '
    def pending: .action=="update" or .action=="prepare_target";
    def goal: if .reason=="up_to_date" then .version else .target.version // .requested_version end;
    def abi: [.soabi,.shared,.pointer_bits,.machine];
    def conda_provider($v): .kind=="conda" and $v.base_in_scope and (pending or .reason=="up_to_date") and
      goal==($v|goal) and abi==($v|abi);
    ($choices|INDEX(.prefix)) as $choices | .inventory.warnings as $warnings |
    .plan |= map($choices[.prefix] as $choice |
      if $choice==null then .
      else .approval=$choice.approval |
        (if $choice.base_choice!=null then .base_choice=$choice.base_choice else . end) |
        if .approval=="declined" then .action="skip" | .reason=$choice.reason else . end
      end) |
    .plan as $all | .plan |= map(. as $base |
      if .kind!="venv" and pending and any($all[]; . as $v |
          .kind=="venv" and .base_prefix==$base.prefix and (goal!=($base|goal) or
          (.action=="skip" and (.reason!="Interpreter ABI/build mismatch" or ($base|conda_provider($v)|not)))))
      then .action="skip" | .reason="Dependent venv requires the original base to remain unchanged"
      else . end) |
    (.plan | map(select(.kind!="venv")) | INDEX(.prefix)) as $bases |
    .plan |= map(. as $v | $bases[.base_prefix] as $base |
      if .kind=="venv" and (pending or (.reason=="Interpreter ABI/build mismatch" and ($base|conda_provider($v)))) then
      if .base_choice=="replacement" then .required_base=.target.prefix
      elif ($base|conda_provider($v))
      then .target=($base|{prefix,binary,version:goal,source:"original-conda"}) |
        .action="update" | .reason="Use the Conda interpreter at the original base" | .required_base=.base_prefix
      elif .target.prefix==.base_prefix or
        ($base!=null and (($base|pending) or $base.reason=="up_to_date") and ($base|goal)==goal)
      then .required_base=.base_prefix
      else .base_issue=(if $base!=null then ($base.reason|select(length>0)) // "Original base has a different target version"
        else ([$warnings[]? | select(.path==$v.base_prefix or (.path|startswith($v.base_prefix+"/bin/"))) | .reason] | unique | join(". ")) as $why |
          if $why=="" then "Original base has no raw installation in the scan" else $why end end)
      end else . end)' "$candidates" | atomic_write "$destination"
}
ask_environment() {
  local item=$1 input_fd=$2 answer reason
  local kind prefix current target
  kind="$(jq -r .kind <<<"$item")"
  prefix="$(jq -r .prefix <<<"$item")"
  current="$(jq -r .version <<<"$item")"
  target="$(jq -r '.target.version//.requested_version' <<<"$item")"
  printf '\nUpdate %s %s (%s -> %s)\n' "$kind" "$prefix" "$current" "$target" >&2
  if [[ $kind == conda ]]; then
    jq -r '"Conda package changes: "+.conda.summary' <<<"$item" >&2
  elif [[ $kind == venv ]]; then
    reason="$(jq -r '.base_issue//empty' <<<"$item")"
    jq -r --arg reason "$reason" '"Original base: "+.base_prefix+
      (if $reason=="" then "" else " ("+$reason+")" end)' <<<"$item" >&2
    if [[ -n $reason ]]; then
      jq -r --arg cache "$RUNTIME_DIR" '"Replacement base: Python "+(.target.version//.requested_version)+", "+
        (.target.prefix//("a new private runtime under "+$cache))' <<<"$item" >&2
    elif ((INTERACTIVE==0)); then
      jq -r '"Target if the original base cannot provide this version: "+.target.prefix' <<<"$item" >&2
    fi
  fi
  while true; do
    if [[ -n ${reason:-} ]]; then
      printf 'Update this venv at its existing path using the replacement base? [y/N] ' >&2
    else
      printf 'Update this %s at its existing path? [y/N] ' "$kind" >&2
    fi
    if ! IFS= read -r -u "$input_fd" answer; then
      printf '\n' >&2
      die 'Confirmation input ended; no environments updated'
    fi
    case "${answer,,}" in
      y|yes) ENV_APPROVAL=confirmed; break ;;
      ''|n|no) ENV_APPROVAL=declined; break ;;
      *) printf 'Enter y/yes to update or n/no to skip.\n' >&2 ;;
    esac
  done
  if [[ $ENV_APPROVAL == confirmed ]]; then event confirmation "$prefix" approved; else event confirmation "$prefix" declined; fi
}
collect_choices() {
  local plan=$1 phase=$2 item prefix base_choice reason input_fd ENV_APPROVAL
  exec {input_fd}<&0
  while IFS= read -r item; do
    ask_environment "$item" "$input_fd"
    prefix="$(jq -r .prefix <<<"$item")"
    base_choice=null
    reason='Environment update declined'
    if jq -e '.base_issue!=null' <<<"$item" >/dev/null; then
      if [[ $ENV_APPROVAL == confirmed ]]; then base_choice='"replacement"'; else base_choice='"skipped"'; fi
      reason='Replacement base declined'
    fi
    jq -cn --arg p "$prefix" --arg a "$ENV_APPROVAL" --argjson b "$base_choice" --arg r "$reason" \
      '{prefix:$p,approval:$a,base_choice:$b,reason:$r}' >>"$WORK/choices.ndjson"
  done < <(jq -c --arg phase "$phase" '.plan[]|select(.action=="update" or .action=="prepare_target")|
    select(if $phase=="installations" then .kind!="venv"
      elif $phase=="venvs" then .kind=="venv"
      else .kind=="venv" and .approval=="confirmed" and .base_issue!=null and .base_choice==null end)' "$plan")
  exec {input_fd}<&-
}
confirm_interactive() {
  local plan=$1 selected="$WORK/selection.json" phase
  : >"$WORK/choices.ndjson"
  selected_plan "$plan" "$selected"
  cp -- "$selected" "$LOG_DIR/plan.json"
  printf '\nDiscovered environments (installation paths are retained):\n' >&2
  jq -r '.plan[]|[.kind,.prefix,(.version+" -> "+(.target.version//.requested_version//"")),.action,.reason]|@tsv' "$selected" >&2
  printf '\nStorage inventory: %s/storage.json\n' "$LOG_DIR" >&2
  if ! jq -e 'any(.plan[];.action=="update" or .action=="prepare_target")' "$selected" >/dev/null; then
    event no_updates '' 'See plan.json for exclusions and skip reasons'
    return 0
  fi
  printf 'Stop applications using the environments selected for update. Enter skips an environment.\n' >&2
  for phase in installations venvs replacement; do
    collect_choices "$selected" "$phase"
    selected_plan "$plan" "$selected"
  done
  cp -- "$selected" "$plan"
  cp -- "$plan" "$LOG_DIR/plan.json"
  jq -r '.plan[]|select(.approval=="confirmed" and .action=="skip")|"\(.prefix): \(.reason)"' "$plan" >&2
  jq '[.plan[]|select(.action=="update" or .action=="prepare_target")|
    {prefix,kind,approval,version,base_prefix,target_version:(.target.version//.requested_version),base_choice,required_base,conda}]' "$plan" >"$WORK/approved-intent.json"
  if ! jq -e 'length>0' "$WORK/approved-intent.json" >/dev/null; then
    event cancelled '' 'No targets prepared or environments updated'
    return 0
  fi
  if jq -e 'any(.plan[];.action=="prepare_target")' "$plan" >/dev/null && ! storage_allowed "$RUNTIME_DIR"; then
    die "A target build needs an eligible cache mount for $RUNTIME_DIR. Run again with XDG_DATA_HOME on a mount included for discovery."
  fi
}
check_interactive_plan() {
  local plan=$1
  selected_plan "$plan" "$plan"
  cp -- "$plan" "$LOG_DIR/plan.json"
  if ! jq -e --arg cache "$RUNTIME_DIR" --slurpfile intent "$WORK/approved-intent.json" '
    [.plan[]|select(.action=="update" or .action=="prepare_target")] as $updates |
    ($updates|length)==($intent[0]|length) and all($intent[0][]; . as $expected |
      any($updates[]; .action=="update" and .approval=="confirmed" and .prefix==$expected.prefix and .kind==$expected.kind and
        .version==$expected.version and .base_prefix==$expected.base_prefix and .conda==$expected.conda and
        .target.version==$expected.target_version and .base_choice==$expected.base_choice and
        (if $expected.base_choice=="replacement" and $expected.required_base==null then
          .target.source=="installed" and .required_base==.target.prefix and (.required_base|startswith($cache+"/"))
         else .required_base==$expected.required_base end)))' "$plan" >/dev/null; then
    jq -r --slurpfile intent "$WORK/approved-intent.json" '
      ($intent[0]|INDEX(.prefix)) as $approved | .plan[] |
      select($approved[.prefix]!=null and .action=="skip") | "\(.prefix): \(.reason)"' "$plan" >&2
    die "Prepared targets changed the approved plan; no environments updated. See $LOG_DIR/plan.json"
  fi
}
confirm_plan() {
  local plan=$1 destination=$2 item prefix kind input_fd base ENV_APPROVAL
  local -A blocked=()
  : >"$WORK/confirmed.ndjson"
  # Keep responses separate from the JSON stream used by the loop.
  exec {input_fd}<&0
  while IFS= read -r item; do
    kind="$(jq -r .kind <<<"$item")"
    prefix="$(jq -r .prefix <<<"$item")"
    if [[ $kind == venv || $kind == conda ]] && [[ $(jq -r .action <<<"$item") == update ]]; then
      if ((ASSUME_YES)); then
        item="$(jq -c '.approval="bypassed"' <<<"$item")"
        event confirmation "$prefix" 'bypassed (-Y)'
      else
        ask_environment "$item" "$input_fd"
        item="$(jq -c --arg choice "$ENV_APPROVAL" '.approval=$choice |
          if $choice=="declined" then .action="skip" |
            .reason=(if .kind=="venv" then "Venv update declined" else "Conda update declined" end) else . end' <<<"$item")"
      fi
    fi
    if [[ $kind == venv && $(jq -r .action <<<"$item") == skip ]]; then
      base="$(jq -r .base_prefix <<<"$item")"
      blocked[$base]=1
    fi
    printf '%s\n' "$item" >>"$WORK/confirmed.ndjson"
  done < <(jq -c '.plan[]' "$plan")
  exec {input_fd}<&-
  : >"$WORK/approved.ndjson"
  while IFS= read -r item; do
    prefix="$(jq -r .prefix <<<"$item")"
    if [[ $(jq -r .kind <<<"$item") != venv && $(jq -r .action <<<"$item") == update && ${blocked[$prefix]+yes} ]]; then
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
  local required_base=${9:-}
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
    if [[ -n $required_base && $(jq -r .base_prefix <<<"$info") != "$required_base" ]]; then
      printf 'Original base changed: %s (expected %s)\n' "$path" "$required_base" >&2
      return 1
    fi
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
  local venv_mode=--copies
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
    if jq -e '.base_in_scope==true and .base_choice!="replacement"' "$entry" >/dev/null &&
      info="$(probe "$candidate")" && [[ $(jq -r .version <<<"$info") == "$version" ]]; then target=$candidate; fi
    if awk -F= '$1~/^include-system-site-packages *$/ && $2~/true/ {found=1} END{exit !found}' "$stage/pyvenv.cfg"; then options+=(--system-site-packages); fi
    # venv rewrites pyvenv.cfg on upgrade. Preserve CPython's verbatim prompt
    # record (including quotes and escapes) without sourcing or decoding it.
    awk '/^prompt[[:space:]]*=/{print; exit}' "$stage/pyvenv.cfg" >"$WORK/venv-prompt"
    # Conda binaries can locate libpython relative to their own bin/ directory.
    if [[ -d ${target%/bin/*}/conda-meta ]]; then venv_mode=--symlinks; fi
    runpy "$target" -I -m venv --upgrade --without-pip "$venv_mode" "${options[@]}" "$stage"
    for name in "${names[@]}"; do
      [[ ! -f $stage/bin/$name ]] || continue
      if [[ $venv_mode == --symlinks ]]; then ln -sfn -- python "$stage/bin/$name"
      else cp -p --remove-destination -- "$stage/bin/python" "$stage/bin/$name"; fi
    done
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
  if [[ $(jq -r .kind "$entry") == conda ]]; then
    load_conda_support || die 'Conda rollback requires python_updater_conda.sh'
    conda_restore_one "$entry" "$journal"
    return
  fi
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
  if [[ $publication == true && ( -d $backup || $(jq -r .kind "$entry") == conda ) ]]; then
    bash "$SELF" _restore "$entry" "$journal" || checkpoint "$entry" "$journal" '.status="rollback_failed"'
  fi
  event failed "$prefix" "Worker exit $status"
  exit "$status"
}
apply_one() {
  local entry=$1 journal=$2 checks=$3 prefix stage backup kind version available size needed identity manifest packages_file result
  if [[ $(jq -r .kind "$entry") == conda ]]; then
    load_conda_support || die 'Conda update requires python_updater_conda.sh'
    conda_apply_one "$entry" "$journal" "$checks"
    return
  fi
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
  validate "$stage" "$version" "$packages_file" '' "$prefix" stage "$checks" "$result" "$(jq -r '.required_base//empty' "$entry")"
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
  validate "$prefix" "$version" "$packages_file" "$manifest" "$prefix" final "$checks" "$result" "$(jq -r '.required_base//empty' "$entry")"
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
# Builds can take time. Check the scanned installation under its lock before
# making a journal for the approved source paths.
approved_source_matches() {
  local item=$1 prefix binary config_home='' path live
  prefix="$(jq -r .prefix <<<"$item")"
  binary="$(jq -r .binary <<<"$item")"
  [[ -d $prefix && ! -L $prefix && ! -L $prefix/bin && ! -L $prefix/lib ]] || return 1
  [[ $(stat -Lc '%d:%i' -- "$prefix") == "$(jq -r .prefix_identity <<<"$item")" &&
    $(stat -Lc %u -- "$prefix") == "$EUID" ]] || return 1
  scan_path_allowed "$(realpath -m -- "$binary")" || return 1
  if [[ $(jq -r .kind <<<"$item") == venv ]]; then
    [[ -f $prefix/pyvenv.cfg && ! -L $prefix/pyvenv.cfg ]] && storage_allowed "$prefix/pyvenv.cfg" || return 1
    config_home="$(venv_home "$prefix/pyvenv.cfg")" || return 1
  fi
  for path in "$prefix/lib" "$prefix/lib64" "$config_home"; do
    [[ -z $path ]] || storage_allowed "$(realpath -m -- "$path")" || return 1
  done
  live="$(probe "$binary")" || return 1
  jq -e --argjson expected "$item" '
    def identity: [.kind,.prefix,.base_prefix,.version,.soabi,.shared,.pointer_bits,.machine,.managed];
    identity==($expected|identity)' <<<"$live" >/dev/null
}
apply_plan() {
  local plan=$1 journal=$2 item prefix snapshot path token stage backup count=0 failed=0 fatal=0 base
  local -A blocked=()
  [[ ! -e $journal && ! -L $journal && ! -e $journal.entries && ! -L $journal.entries ]] || die 'Journal exists; choose a new output path'
  jq '[.plan[]|select(.action=="update")]' "$plan" >"$WORK/lock-list.json"
  assert_control_paths "$WORK/lock-list.json" "$journal" "$journal.entries" "$journal.post-verify.json" "$LOG_DIR" "$WORK"
  acquire_locks "$WORK/lock-list.json"
  while IFS= read -r item; do
    approved_source_matches "$item" || die "Environment changed since selection: $(jq -r .prefix <<<"$item"). Start a new run to review it; no environments updated."
  done < <(jq -c '.plan[]|select(.kind!="conda" and .action=="update" and .approval=="confirmed")' "$plan")
  if ((INTERACTIVE == 0)); then
    confirm_plan "$plan" "$WORK/confirmed-plan.json"
    plan="$WORK/confirmed-plan.json"
  fi
  cp -- "$plan" "$LOG_DIR/approved-plan.json"
  mkdir -p -- "$journal.entries"
  jq -n --arg created "$(now)" --arg path "$journal" --arg log_file "$LOG_FILE" --slurpfile plan "$plan" \
    '{schema:2,engine:"bash",created:$created,path:$path,log_file:$log_file,complete:false,failures:0,entries:[],failed_snapshots:[],
      skipped:[$plan[0].plan[]|select(.action=="skip")|{prefix,version,reason}],
      end_of_support:[$plan[0].plan[]|select((.eol//"")!="")|{prefix,version,eol}],discovery_warnings:$plan[0].inventory.warnings}' | atomic_write "$journal"
  : >"$WORK/prepared-plan.ndjson"
  while IFS= read -r item; do
    [[ $(jq -r .action <<<"$item") == update && $(jq -r .kind <<<"$item") != conda ]] || {
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
  if ((INTERACTIVE && failed)); then
    json_edit "$journal" --argjson failures "$failed" '.complete=true|.failures=$failures'
    die 'Package snapshots failed; no environments updated'
  fi
  while IFS= read -r item; do
    prefix="$(jq -r .prefix <<<"$item")"
    if [[ $(jq -r .kind <<<"$item") != venv && ${blocked[$prefix]+yes} ]]; then
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
    jq --arg stage "$stage" --arg backup "$backup" --arg entry_file "$path" '
      .+{entry_file:$entry_file,status:"pending",old_version:.version} |
      if .kind=="conda" then . else .+{stage:$stage,backup:$backup} end' <<<"$item" | atomic_write "$path"
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
  local -a check
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
    result="$(mktemp "$WORK/result.XXXXXX")"
    if [[ $(jq -r .kind <<<"$entry") == conda ]]; then
      load_conda_support || die 'Conda verification requires python_updater_conda.sh'
      check=(conda_verify_entry "$entry" "$CHECKS" "$result")
    else
      packages_file="$(mktemp "$WORK/expected.XXXXXX")"
      manifest="$(mktemp "$WORK/manifest.XXXXXX")"
      jq .package_snapshot <<<"$entry" >"$packages_file"
      jq .runtime_hashes <<<"$entry" >"$manifest"
      check=(validate "$prefix" "$(jq -r .target.version <<<"$entry")" "$packages_file" "$manifest" "$prefix" final "$CHECKS" "$result" "$(jq -r '.required_base//empty' <<<"$entry")")
    fi
    if "${check[@]}" 2>"$WORK/verify-error"; then
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
  if (($# == 0)); then
    INTERACTIVE=1
    SKIP_APT=1
    NO_SUDO=1
  fi
  while [[ ${1:-} == -Y ]]; do
    ASSUME_YES=1
    shift
  done
  COMMAND=${1:---help}
  ((INTERACTIVE == 0)) || COMMAND=apply
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
      RUNTIME_DIR="$(realpath -m -- "$RUNTIME_DIR")"
      load_storage
      if ((INTERACTIVE)); then
        automatic_roots
        ((${#ROOTS[@]})) || return 0
      else
        ((${#ROOTS[@]})) || ROOTS=("$(canonical "$HOME")")
      fi
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
      if ((INTERACTIVE)); then
        confirm_interactive "$WORK/plan.json"
        [[ -s $WORK/approved-intent.json ]] && jq -e 'length>0' "$WORK/approved-intent.json" >/dev/null || return 0
      fi
      if [[ $COMMAND == apply ]]; then
        cp -- "$WORK/plan.json" "$LOG_DIR/plan.json"
        prepare_targets "$WORK/plan.json"
        make_plan "$WORK/inventory.json" "$WORK/plan.json"
        ((INTERACTIVE == 0)) || check_interactive_plan "$WORK/plan.json"
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
