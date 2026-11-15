#!/usr/bin/env bash
# Storage fixtures exercise real find/pruning without mounting or probing disks.
# Optional old/patched private CPython binaries enable the complete Enter workflow.
set -Eeuo pipefail
[[ $# == 0 || $# == 2 ]] || {
  echo 'Usage: bash tests/python-updater-interactive.bash [OLD_BIN PATCHED_BIN]' >&2
  exit 2
}
updater=$(realpath -e -- "$(dirname "$0")/../update_python_envs.sh")
lab=$(mktemp -d)
trap 'status=$?; if ((status)); then tail -n 25 "$lab/"*-output >&2; fi; rm -rf -- "$lab"' EXIT
mkdir -p "$lab/tools" "$lab/scripts" "$lab/ssd/hdd" "$lab/ssd/unknown" "$lab/ssd/raid" "$lab/ssd/loop" "$lab/hdd/ssd" "$lab/alias-hdd" "$lab/memory"
cp -- "$updater" "$lab/scripts/update_python_envs.sh"
export DISCOVERY_MOUNTS="$lab/mounts.json" DISCOVERY_DISKS="$lab/disks.json"
export DISCOVERY_PROBES="$lab/probes" DISCOVERY_TIMEOUT
export DISCOVERY_FIND DISCOVERY_VISITS="$lab/visits"
DISCOVERY_TIMEOUT=$(command -v timeout)
DISCOVERY_FIND=$(command -v find)
cat >"$lab/tools/findmnt" <<'TOOL'
#!/usr/bin/env bash
cat "$DISCOVERY_MOUNTS"
TOOL
cat >"$lab/tools/lsblk" <<'TOOL'
#!/usr/bin/env bash
cat "$DISCOVERY_DISKS"
TOOL
cat >"$lab/tools/timeout" <<'TOOL'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$DISCOVERY_PROBES"
exec "$DISCOVERY_TIMEOUT" "$@"
TOOL
cat >"$lab/tools/find" <<'TOOL'
#!/usr/bin/env bash
if [[ ${1:-} == -P && ${3:-} == -xdev ]]; then
  root=$2
  shift 3
  "$DISCOVERY_FIND" -P "$root" -xdev -fprintf "$DISCOVERY_VISITS.$$" '%p\n' '(' "$@" ')'
  status=$?
  cat "$DISCOVERY_VISITS.$$" >>"$DISCOVERY_VISITS"
  rm -f -- "$DISCOVERY_VISITS.$$"
  exit "$status"
fi
exec "$DISCOVERY_FIND" "$@"
TOOL
chmod +x "$lab/tools/"*
cat >"$DISCOVERY_DISKS" <<'JSON'
{"blockdevices":[
 {"maj:min":"8:1","rota":false,"type":"part","children":[{"maj:min":"8:0","rota":false,"type":"disk"}]},
 {"maj:min":"8:17","rota":true,"type":"part","children":[{"maj:min":"8:16","rota":true,"type":"disk"}]},
 {"maj:min":"253:0","rota":false,"type":"lvm","children":[{"maj:min":"8:17","rota":true,"type":"part"}]},
 {"maj:min":"9:0","rota":false,"type":"raid1","children":[{"maj:min":"8:0","rota":false,"type":"disk"},{"maj:min":"8:16","rota":true,"type":"disk"}]},
 {"maj:min":"7:0","rota":false,"type":"loop"}
]}
JSON
jq -n --arg p "$lab" '{filesystems:[
 {target:"/",fstype:"overlay","maj:min":"0:1"},
 {target:($p+"/ssd"),fstype:"ext4","maj:min":"8:1"},
 {target:($p+"/ssd/hdd"),fstype:"ext4","maj:min":"253:0"},
 {target:($p+"/ssd/disk [hdd]*?\\volume"),fstype:"ext4","maj:min":"8:17"},
 {target:($p+"/hdd"),fstype:"ext4","maj:min":"8:17"},
 {target:($p+"/hdd/ssd"),fstype:"ext4","maj:min":"8:1"},
 {target:($p+"/alias-hdd"),fstype:"ext4","maj:min":"8:17"},
 {target:($p+"/ssd/raid"),fstype:"xfs","maj:min":"9:0"},
 {target:($p+"/ssd/loop"),fstype:"ext4","maj:min":"7:0"},
 {target:($p+"/ssd/unknown"),fstype:"nfs4","maj:min":"0:99"},
 {target:($p+"/memory"),fstype:"tmpfs","maj:min":"0:88"}
]}' >"$DISCOVERY_MOUNTS"
run() { PATH="$lab/tools:$PATH" bash "$lab/scripts/update_python_envs.sh" "$@"; }
bad() { if "$@"; then
  echo "Expected failure: $*" >&2
  exit 1
fi; }
output_path() { sed -n 's/^Output: //p' "$1"; }
canary() {
  mkdir -p "$1/bin"
  : >"$1/pyvenv.cfg"
  cp /bin/true "$1/bin/python"
}
for path in ssd/local ssd/hdd/env hdd/env alias-hdd/env ssd/unknown/env ssd/raid/env ssd/loop/env hdd/ssd/local memory/local; do canary "$lab/$path"; done
canary "$lab/ssd/disk [hdd]*?\\volume/env"
ln -s "$lab/hdd/env" "$lab/ssd/hdd-link"
ln -s "$lab/hdd/env/bin/python" "$lab/ssd/local/bin/python999"
canary "$lab/ssd/copied"
printf 'home = %s/hdd/env/bin\n' "$lab" >"$lab/ssd/copied/pyvenv.cfg"
canary "$lab/ssd/linked-config"
rm "$lab/ssd/linked-config/pyvenv.cfg"
ln -s "$lab/hdd/env/pyvenv.cfg" "$lab/ssd/linked-config/pyvenv.cfg"
run scan "$lab/ssd" "$lab/memory" --output "$lab/scan.json" >"$lab/scan-output" 2>&1
grep -F "$lab/ssd/local/bin/python -I" "$DISCOVERY_PROBES" >/dev/null
grep -F "$lab/memory/local/bin/python -I" "$DISCOVERY_PROBES" >/dev/null
bad grep -E '/(hdd|raid|loop|unknown|copied|linked-config)/|python999' "$DISCOVERY_PROBES"
bad grep -F "$lab/ssd/disk [hdd]*?\\volume/env" "$DISCOVERY_VISITS"
bad grep -E '/ssd/(hdd|raid|loop|unknown)/' "$DISCOVERY_VISITS"
storage=$(sed -n 's/^Log: //p' "$lab/scan-output")
storage=${storage%/*}/storage.json
jq -e --arg p "$lab" '
  any(.[];.path==($p+"/ssd") and .class=="ssd") and
  all(.[]|select(.path==($p+"/ssd/hdd") or .path==($p+"/ssd/raid") or .path==($p+"/alias-hdd"));.class=="hdd") and
  all(.[]|select(.path==($p+"/ssd/loop") or .path==($p+"/ssd/unknown"));.class=="unknown")' "$storage" >/dev/null
jq -e 'any(.warnings[];.reason=="Storage excluded: hdd")' "$lab/scan.json" >/dev/null
: >"$DISCOVERY_PROBES"
run scan "$lab/ssd/hdd-link" "$lab/alias-hdd" --output "$lab/hdd.json" >"$lab/hdd-output" 2>&1
[[ ! -s $DISCOVERY_PROBES ]]
jq -e '.environments==[] and any(.warnings[];.reason=="Storage excluded: hdd")' "$lab/hdd.json" >/dev/null

# Unknown device information is fail-closed, including a failed lsblk query.
cp "$lab/tools/lsblk" "$lab/lsblk.original"
printf '#!/usr/bin/env bash\nexit 1\n' >"$lab/tools/lsblk"
run scan "$lab/ssd" --output "$lab/unknown.json" >"$lab/unknown-output" 2>&1
[[ ! -s $DISCOVERY_PROBES ]]
jq -e '.environments==[] and any(.warnings[];.reason=="Storage excluded: unknown")' "$lab/unknown.json" >/dev/null
cp "$lab/lsblk.original" "$lab/tools/lsblk"
echo 'PASS: SSD/memory, HDD links and mounts, LVM, mixed RAID, bind aliases, unknown devices and copied-venv bases'
(($# == 2)) || exit 0

old=$(realpath -e -- "$1")
target=$(realpath -e -- "$2")
old_version=$("$old" -I --version)
version=$("$target" -I --version)
minor=${version#Python }
minor=${minor%.*}
[[ $old_version == "Python $minor."* && $old_version != "$version" ]]
export DISCOVERY_TARGET="$target" DISCOVERY_INSTALLER="${updater%/*}/install_python.sh"
export DISCOVERY_CALLS="$lab/build-calls"
export XDG_DATA_HOME="$lab/ssd/data"
cat >"$lab/scripts/install_python.sh" <<'INSTALLER'
#!/usr/bin/env bash
set -Eeuo pipefail
if [[ $# == 1 && $1 == --print-pins ]]; then exec bash "$DISCOVERY_INSTALLER" --print-pins; fi
printf 'build\n' >>"$DISCOVERY_CALLS"
if IFS= read -r answer; then echo 'Build consumed confirmation input' >&2; exit 1; fi
destination=$1
shift
selected=''
while (($#)); do
  case "$1" in
    --py) selected=$2; shift 2 ;;
    --jobs) shift 2 ;;
    --reuse|--skip-conda|--no-bashrc|--skip-apt|--no-sudo) shift ;;
    *) exit 1 ;;
  esac
done
version=$("$DISCOVERY_TARGET" -I --version)
version=${version#Python }
[[ $selected == "${version%.*}" ]]
mkdir -p "$destination/opt"
cp -a -- "${DISCOVERY_TARGET%/bin/*}" "$destination/opt/python-$version"
INSTALLER

# Legacy layouts, no registry, no PATH entry and no bashrc edits. One copy sits
# on a separate SSD mount below an HDD mount; no directory walk enters the HDD.
for place in ssd/install hdd/ssd/old-install; do
  base="$lab/$place"
  mkdir -p "$base/opt" "$base/bin" "$base/CACHE" "$base/shims"
  cp -a -- "${old%/bin/*}" "$base/opt/python-${old_version#Python }"
  binary="$base/opt/python-${old_version#Python }/bin/${old##*/}"
  ln -s "$binary" "$base/bin/python-$minor"
  "$binary" -I -m venv --copies --without-pip "$base/env with spaces"
done
sha256sum "$DISCOVERY_INSTALLER" >"$lab/installer-hash"
bad run </dev/null >"$lab/eof-output" 2>&1
grep -F 'Confirmation input ended' "$lab/eof-output" >/dev/null
[[ ! -e $DISCOVERY_CALLS && ! -e $(output_path "$lab/eof-output") ]]
printf 'n\n' | run >"$lab/cancel-output" 2>&1
[[ ! -e $DISCOVERY_CALLS ]]

# Enter is the complete input, with zero CLI arguments. It approves both raw
# installations and venvs before preparing any target runtime.
: >"$DISCOVERY_PROBES"
printf '\n' | run >"$lab/enter-output" 2>&1
journal=$(output_path "$lab/enter-output")
jq -e '.failures==0 and (.entries|length)==4 and all(.entries[];.status=="verified") and
  all(.entries[]|select(.kind=="venv");.required_base==.base_prefix and .approval=="confirmed")' "$journal" >/dev/null
[[ $(wc -l <"$DISCOVERY_CALLS") == 1 ]]
bad grep -E '/(hdd/env|ssd/hdd|ssd/raid|ssd/loop|ssd/unknown)/|python999' "$DISCOVERY_PROBES"
for place in ssd/install hdd/ssd/old-install; do
  base="$lab/$place"
  [[ $("$base/bin/python-$minor" -I --version) == "$version" ]]
  [[ $("$base/env with spaces/bin/python" -I --version) == "$version" ]]
done
run verify "$journal" --output "$lab/verified.json" >"$lab/verify-output" 2>&1
jq -e 'all(.results[];.passed)' "$lab/verified.json" >/dev/null
sha256sum -c "$lab/installer-hash"
run </dev/null >"$lab/repeat-output" 2>&1
grep -F '"event":"no_updates"' "$lab/repeat-output" >/dev/null
[[ $(wc -l <"$DISCOVERY_CALLS") == 1 ]]

# Verification enforces the stored original-base requirement.
jq '(.entries[]|select(.kind=="venv")).required_base="/wrong/base"' "$journal" >"$lab/wrong-base.json"
bad run verify "$lab/wrong-base.json" --output "$lab/wrong-base-result.json" >"$lab/wrong-base-output" 2>&1
grep -F 'Original base changed' "$lab/wrong-base-output" >/dev/null
run rollback "$journal" >"$lab/rollback-output" 2>&1
for place in ssd/install hdd/ssd/old-install; do
  base="$lab/$place"
  [[ $("$base/bin/python-$minor" -I --version) == "$old_version" ]]
  [[ $("$base/env with spaces/bin/python" -I --version) == "$old_version" ]]
done

echo 'PASS: no-argument Enter workflow, legacy installs, separate SSD mounts, EOF/cancel before builds, original bases, entrypoints, verification and rollback'
