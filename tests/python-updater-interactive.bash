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
export DISCOVERY_FIND DISCOVERY_VISITS="$lab/visits" DISCOVERY_WALKS="$lab/walks"
DISCOVERY_TIMEOUT=$(command -v timeout)
DISCOVERY_FIND=$(command -v find)
cat >"$lab/tools/findmnt" <<'TOOL'
#!/usr/bin/env bash
case " $* " in *" --uniq "*) ;; *) exit 2 ;; esac
cat "$DISCOVERY_MOUNTS"
TOOL
cat >"$lab/tools/lsblk" <<'TOOL'
#!/usr/bin/env bash
# Match lsblk's JSON contract: flat output drops the backing-device relationships.
case " $* " in *" --inverse "*) ;; *) exit 2 ;; esac
case " $* " in
  *" --tree "* | *" NAME,"*) cat "$DISCOVERY_DISKS" ;;
  *) jq '{blockdevices:[.blockdevices[] | recurse(.children[]?) | del(.children)]}' "$DISCOVERY_DISKS" ;;
esac
TOOL
cat >"$lab/tools/systemd-detect-virt" <<'TOOL'
#!/usr/bin/env bash
[[ $* == '--vm --quiet' && ${DISCOVERY_TEST_VM:-0} == 1 ]]
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
  printf '%s\n' "$root" >>"$DISCOVERY_WALKS"
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
 {"maj:min":"7:0","rota":false,"type":"loop"},
 {"maj:min":"253:1","rota":false,"type":"lvm","children":[{"maj:min":"252:1","rota":false,"type":"part","children":[{"maj:min":"252:0","rota":false,"type":"disk"}]}]},
 {"maj:min":"253:2","rota":false,"type":"lvm"}
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
 {target:($p+"/memory"),fstype:"tmpfs","maj:min":"0:88"},
 {target:($p+"/guest-ssd"),fstype:"ext4","maj:min":"253:1"},
 {target:($p+"/guest-ssd/file-mount"),fstype:"tmpfs","maj:min":"0:89"},
 {target:($p+"/hidden-backing"),fstype:"ext4","maj:min":"253:2"}
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
for path in ssd/local ssd/hdd/env hdd/env alias-hdd/env ssd/unknown/env ssd/raid/env ssd/loop/env hdd/ssd/local memory/local guest-ssd/env hidden-backing/env; do canary "$lab/$path"; done
touch "$lab/guest-ssd/file-mount"
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
  any(.[];.path==($p+"/ssd/raid") and .class=="hdd") and
  any(.[];.path==($p+"/guest-ssd") and .class=="ssd" and .device=="253:1") and
  any(.[];.path==($p+"/hidden-backing") and .class=="unknown") and
  all(.[]|select(.path==($p+"/ssd/hdd") or .path==($p+"/alias-hdd"));.class=="hdd") and
  all(.[]|select(.path==($p+"/ssd/loop") or .path==($p+"/ssd/unknown"));.class=="unknown")' "$storage" >/dev/null
jq -e 'any(.warnings[];.reason=="Storage excluded: hdd")' "$lab/scan.json" >/dev/null
: >"$DISCOVERY_PROBES"
run scan "$lab/ssd/hdd-link" "$lab/alias-hdd" --output "$lab/hdd.json" >"$lab/hdd-output" 2>&1
[[ ! -s $DISCOVERY_PROBES ]]
jq -e '.environments==[] and any(.warnings[];.reason=="Storage excluded: hdd")' "$lab/hdd.json" >/dev/null

# Unknown device information is fail-closed, including a failed lsblk query.
cp "$lab/tools/lsblk" "$lab/lsblk.original"
printf '#!/usr/bin/env bash\necho "lsblk: test sysfs unavailable" >&2\nexit 1\n' >"$lab/tools/lsblk"
run scan "$lab/ssd" --output "$lab/unknown.json" >"$lab/unknown-output" 2>&1
[[ ! -s $DISCOVERY_PROBES ]]
jq -e '.environments==[] and any(.warnings[];.reason=="Storage excluded: unknown")' "$lab/unknown.json" >/dev/null
grep -F 'lsblk: test sysfs unavailable' "$(sed -n 's/^Log: //p' "$lab/unknown-output")" >/dev/null
cp "$lab/lsblk.original" "$lab/tools/lsblk"

# A machine may have only a physical HDD root, system tmpfs directories
# and file bind mounts. No directory walk, build, or journal should start.
cp "$DISCOVERY_MOUNTS" "$lab/eligible-mounts.json"
touch "$lab/file-mount"
jq -n --arg file "$lab/file-mount" '{filesystems:[
 {target:"/",fstype:"ext4","maj:min":"8:17"},
 {target:"/dev/shm",fstype:"tmpfs","maj:min":"0:11"},
 {target:"/run",fstype:"tmpfs","maj:min":"0:12"},
 {target:$file,fstype:"tmpfs","maj:min":"0:13"}
]}' >"$DISCOVERY_MOUNTS"
: >"$DISCOVERY_VISITS"
status=0
XDG_DATA_HOME="$lab/data" run </dev/null >"$lab/no-roots-output" 2>&1 || status=$?
[[ $status == 2 && ! -s $DISCOVERY_VISITS && ! -s $DISCOVERY_PROBES ]]
journal=$(output_path "$lab/no-roots-output")
[[ -n $journal && ! -e $journal ]]
storage=${journal%/*}/storage.json
grep -F "Storage inventory: $storage" "$lab/no-roots-output" >/dev/null
grep -F 'mount /, filesystem ext4, device 8:17, class hdd' "$lab/no-roots-output" >/dev/null
jq -e 'any(.[];.path=="/" and .class=="hdd" and .device=="8:17")' "$storage" >/dev/null
bad grep -E '"event":"(scan_started|target_build_started|prepare)"' "$lab/no-roots-output"

# HOME can be a separate mount whose device is hidden from the guest.
home_path=$(realpath -m -- "$HOME")
jq --arg path "$home_path" '.filesystems += [{target:$path,fstype:"ext4","maj:min":"252:99"}]' \
  "$DISCOVERY_MOUNTS" >"$lab/separate-home.json"
mv "$lab/separate-home.json" "$DISCOVERY_MOUNTS"
status=0
XDG_DATA_HOME="$lab/data" run </dev/null >"$lab/hidden-home-output" 2>&1 || status=$?
[[ $status == 2 && ! -s $DISCOVERY_VISITS && ! -s $DISCOVERY_PROBES ]]
grep -F "Scan $home_path for Python environments? [y/N]" "$lab/hidden-home-output" >/dev/null
grep -F 'mount device ID absent from the block device tree' "$lab/hidden-home-output" >/dev/null
grep -F 'Storage selection ended before discovery' "$lab/hidden-home-output" >/dev/null
journal=$(output_path "$lab/hidden-home-output")
[[ ! -e $journal ]]
jq -e --arg home "$home_path" 'any(.[];.path==$home and .class=="unknown" and .scan_choice=="input_ended")' "${journal%/*}/storage.json" >/dev/null
printf '\n' | XDG_DATA_HOME="$lab/data" run >"$lab/skip-home-output" 2>&1
grep -F '"event":"no_scan"' "$lab/skip-home-output" >/dev/null
[[ ! -s $DISCOVERY_VISITS && ! -s $DISCOVERY_PROBES && ! -e $(output_path "$lab/skip-home-output") ]]
mv "$lab/eligible-mounts.json" "$DISCOVERY_MOUNTS"

# The normal zero-argument entry point must reach discovery on a guest SSD.
cp -- "${updater%/*}/install_python.sh" "$lab/scripts/install_python.sh"
printf '\n' | XDG_DATA_HOME="$lab/data" run >"$lab/guest-ssd-output" 2>&1
grep -F "$lab/guest-ssd/env/bin/python -I" "$DISCOVERY_PROBES" >/dev/null
grep -Fx -- "$lab/guest-ssd" "$DISCOVERY_WALKS" >/dev/null
bad grep -Fx -- "$lab/guest-ssd/file-mount" "$DISCOVERY_WALKS"
bad grep -F "$lab/hidden-backing/env" "$DISCOVERY_VISITS"
grep -F '"event":"no_updates"' "$lab/guest-ssd-output" >/dev/null
echo 'PASS: guest SSD, hidden backing devices, and zero eligible directory mounts'
echo 'PASS: SSD/memory, HDD links and mounts, LVM, mixed RAID, bind aliases, unknown devices and copied-venv bases'

# The same virtual disk has three mounts. A yes on the parent must not grant
# access to its nested mount or another alias. The ordinary SSD does not
# start discovery until every choice has been answered.
cp "$DISCOVERY_MOUNTS" "$lab/normal-mounts.json"
cp "$DISCOVERY_DISKS" "$lab/normal-disks.json"
for path in ask/env ask/nested/env other-alias-long/env real-hdd/env mixed-raid/env loop-hidden/env loop-source/env network/env; do
  canary "$lab/$path"
done
ln -s "$lab/ask/nested/env/bin/python" "$lab/ask/env/bin/python777"
jq '.blockdevices += [
  {"maj:min":"252:0",name:"sda",type:"disk",rota:true,vendor:"QEMU",model:"QEMU HARDDISK",tran:"scsi"},
  {"maj:min":"8:32",name:"sdc",type:"disk",rota:true,vendor:"ATA",model:"ST1000",tran:"sata"},
  {"maj:min":"9:3",name:"md3",type:"raid1",rota:false,children:[
    {"maj:min":"252:0",name:"sda",type:"disk",rota:true,model:"QEMU HARDDISK"},
    {"maj:min":"8:32",name:"sdc",type:"disk",rota:true,vendor:"ATA",model:"ST1000",tran:"sata"}]}
]' "$lab/normal-disks.json" >"$DISCOVERY_DISKS"
jq -n --arg p "$lab" '{filesystems:[
  {target:"/",fstype:"overlay","maj:min":"0:1"},
  {target:($p+"/ask"),fstype:"ext4","maj:min":"252:0"},
  {target:($p+"/ask/nested"),fstype:"ext4","maj:min":"252:0"},
  {target:($p+"/other-alias-long"),fstype:"xfs","maj:min":"252:0"},
  {target:($p+"/guest-ssd"),fstype:"ext4","maj:min":"8:1"},
  {target:($p+"/real-hdd"),fstype:"ext4","maj:min":"8:32"},
  {target:($p+"/mixed-raid"),fstype:"xfs","maj:min":"9:3"},
  {target:($p+"/loop-hidden"),fstype:"ext4","maj:min":"7:29"},
  {target:($p+"/loop-source"),source:"/dev/loop29[/dir]",fstype:"ext4","maj:min":"0:70"},
  {target:($p+"/network"),fstype:"nfs4","maj:min":"0:77"},
  {target:($p+"/file-mount"),fstype:"ext4","maj:min":"0:71"},
  {target:"/run",fstype:"ext4","maj:min":"0:72"}
]}' >"$DISCOVERY_MOUNTS"
export DISCOVERY_TEST_VM=1
: >"$DISCOVERY_PROBES"
: >"$DISCOVERY_WALKS"
: >"$DISCOVERY_VISITS"
status=0
printf 'y\n' | XDG_DATA_HOME="$lab/data" run >"$lab/partial-output" 2>&1 || status=$?
journal=$(output_path "$lab/partial-output")
[[ $status == 2 && -n $journal && ! -e $journal && ! -s $DISCOVERY_WALKS && ! -s $DISCOVERY_PROBES ]]
bad grep -E '"event":"(scan_started|target_build_started|prepare)"' "$lab/partial-output"
jq -e 'any(.[];.scan_choice=="approved") and any(.[];.scan_choice=="input_ended")' "${journal%/*}/storage.json" >/dev/null

mkdir -p "$lab/ask/nested/cache/python-env-updater"
printf 'cache on a skipped mount\n' >"$lab/ask/nested/cache/python-env-updater/targets.json"
printf 'no\nN\ninvalid\nYES\n' | XDG_DATA_HOME="$lab/ask/nested/cache" run >"$lab/choices-output" 2>&1
journal=$(output_path "$lab/choices-output")
grep -F 'Enter y to scan or n to skip.' "$lab/choices-output" >/dev/null
grep -F "$lab/ask/env/bin/python -I" "$DISCOVERY_PROBES" >/dev/null
grep -Fx -- "$lab/guest-ssd" "$DISCOVERY_WALKS" >/dev/null
bad grep -E '/(nested|other-alias-long|real-hdd|mixed-raid|loop-hidden|loop-source|network)/|python777' "$DISCOVERY_PROBES"
bad grep -E '/(nested|other-alias-long|real-hdd|mixed-raid|loop-hidden|loop-source|network)/env' "$DISCOVERY_VISITS"
jq -e --arg p "$lab" '
  any(.[];.path==($p+"/ask") and .class=="hdd" and .ask and .scan_choice=="approved") and
  any(.[];.path==($p+"/ask/nested") and .scan_choice=="skipped") and
  any(.[];.path==($p+"/other-alias-long") and .scan_choice=="skipped") and
  ([.[]|select(has("scan_choice"))]|length)==3 and
  all(.[]|select(.path==($p+"/real-hdd") or .path==($p+"/mixed-raid"));.class=="hdd" and (.ask|not)) and
  all(.[]|select(.path==($p+"/loop-hidden") or .path==($p+"/loop-source"));.reason=="loop-backed mount" and (.ask|not))
' "${journal%/*}/storage.json" >/dev/null

# Accept a supported local directory whose device is invisible to lsblk.
jq --arg p "$lab/ask" '{filesystems:[.filesystems[]|select(.target=="/" or .target==$p)]}
  | (.filesystems[]|select(.target==$p))["maj:min"]="252:99"' "$DISCOVERY_MOUNTS" >"$lab/hidden.json"
mv "$lab/hidden.json" "$DISCOVERY_MOUNTS"
: >"$DISCOVERY_PROBES"
printf 'Y\n' | XDG_DATA_HOME="$lab/data" run >"$lab/hidden-yes-output" 2>&1
journal=$(output_path "$lab/hidden-yes-output")
jq -e --arg p "$lab/ask" 'any(.[];.path==$p and .class=="unknown" and .scan_choice=="approved")' "${journal%/*}/storage.json" >/dev/null
grep -F "$lab/ask/env/bin/python -I" "$DISCOVERY_PROBES" >/dev/null

: >"$DISCOVERY_PROBES"
: >"$DISCOVERY_WALKS"
for command in scan plan apply; do
  args=("$command" "$lab/ask")
  if [[ $command == apply ]]; then args=(-Y "${args[@]}" --no-sudo); fi
  XDG_DATA_HOME="$lab/data" run "${args[@]}" </dev/null >"$lab/explicit-$command-output" 2>&1
  bad grep -F 'for Python environments? [y/N]' "$lab/explicit-$command-output"
done
[[ ! -s $DISCOVERY_PROBES && ! -s $DISCOVERY_WALKS ]]
jq -e '.environments==[]' "$(output_path "$lab/explicit-scan-output")" >/dev/null
jq -e '.plan==[]' "$(output_path "$lab/explicit-plan-output")" >/dev/null
jq -e '.entries==[] and .failures==0' "$(output_path "$lab/explicit-apply-output")" >/dev/null
# A transport label does not establish physical backing for a guest disk.
jq '(.blockdevices[]|select(.["maj:min"]=="8:17")|.children[0]) += {name:"sdb",vendor:"",model:"",tran:"sata"}
  | .blockdevices += [{"maj:min":"8:48",name:"sdd",type:"disk",rota:true,vendor:"Google",model:"PersistentDisk",tran:"scsi"}]' "$DISCOVERY_DISKS" >"$lab/cloud-disks.json"
mv "$lab/cloud-disks.json" "$DISCOVERY_DISKS"
jq --arg p "$lab/ask" '(.filesystems[]|select(.target==$p))["maj:min"]="8:17"' "$DISCOVERY_MOUNTS" >"$lab/unidentified.json"
jq --arg p "$lab/other-alias-long" '.filesystems += [{target:$p,fstype:"ext4","maj:min":"8:48"}]' "$lab/unidentified.json" >"$DISCOVERY_MOUNTS"
printf '\n\n' | XDG_DATA_HOME="$lab/data" run >"$lab/vm-identity-output" 2>&1
journal=$(output_path "$lab/vm-identity-output")
jq -e '([.[]|select(.class=="hdd" and .scan_choice=="skipped")]|length)==2' "${journal%/*}/storage.json" >/dev/null
[[ ! -e $journal && ! -s $DISCOVERY_WALKS ]]
echo 'PASS: mount-specific yes/no/default, incomplete inputs, hard exclusions and explicit commands'
unset DISCOVERY_TEST_VM
mv "$lab/normal-disks.json" "$DISCOVERY_DISKS"
# The remaining Enter-only scenarios exercise automatic, known media.
jq --arg hidden "$lab/hidden-backing" '.filesystems |= map(select(.target!=$hidden))' "$lab/normal-mounts.json" >"$DISCOVERY_MOUNTS"
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
# Agreeing to scan an unknown mount does not approve its updates.
cp "$DISCOVERY_MOUNTS" "$lab/known-only.json"
jq --arg path "$lab/ssd" '(.filesystems[]|select(.target==$path))["maj:min"]="252:99"' "$lab/known-only.json" >"$DISCOVERY_MOUNTS"
printf 'y\nn\n' | run >"$lab/ask-then-cancel-output" 2>&1
journal=$(output_path "$lab/ask-then-cancel-output")
jq -e --arg path "$lab/ssd" 'any(.[];.path==$path and .scan_choice=="approved")' "${journal%/*}/storage.json" >/dev/null
jq -e --arg prefix "$lab/ssd/install/env with spaces" 'any(.plan[];.prefix==$prefix and (.action=="prepare_target" or .action=="update"))' "${journal%/*}/plan.json" >/dev/null
grep -F '"event":"cancelled"' "$lab/ask-then-cancel-output" >/dev/null
[[ ! -e $DISCOVERY_CALLS && ! -e $journal ]]
[[ $("$lab/ssd/install/env with spaces/bin/python" -I --version) == "$old_version" ]]
status=0
printf 'y\n' | run >"$lab/ask-then-eof-output" 2>&1 || status=$?
[[ $status == 2 && ! -e $DISCOVERY_CALLS && ! -e $(output_path "$lab/ask-then-eof-output") ]]
grep -F 'Confirmation input ended' "$lab/ask-then-eof-output" >/dev/null
mv "$lab/known-only.json" "$DISCOVERY_MOUNTS"
status=0
XDG_DATA_HOME="$lab/alias-hdd/cache" run </dev/null >"$lab/denied-cache-output" 2>&1 || status=$?
[[ $status == 2 && ! -e $DISCOVERY_CALLS && ! -e $lab/alias-hdd/cache && ! -e $(output_path "$lab/denied-cache-output") ]]
grep -F 'A target build needs an eligible cache mount' "$lab/denied-cache-output" >/dev/null
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
