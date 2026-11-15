#!/usr/bin/env bash
# Offline integration with real Conda and two working private CPython patch
# builds. The local channel adds one dependency when upgrading Python.
set -Eeuo pipefail

make_channel() (
  local old=$1 new=$2 channel=$3 mm ver name tree path root pkg fn info deps lib
  local -a files=()
  mkdir -p "$channel"/{linux-64,noarch}
  local tmp
  tmp=$(mktemp -d)
  trap 'rm -rf -- "$tmp"' EXIT
  for path in "$old" "$new" dependency library-old library-new unrelated; do
    root="$tmp/pkg"
    rm -rf -- "$root"
    mkdir -p "$root/info"
    if [[ $path != "$old" && $path != "$new" ]]; then
      case "$path" in
        dependency) name=updater-check-dep ver=1 ;;
        library-old) name=updater-runtime-lib ver=1 ;;
        library-new) name=updater-runtime-lib ver=2 ;;
        unrelated) name=updater-external ver=1 ;;
      esac
      mkdir -p "$root/share/$name"
      printf '%s\n' "$ver" >"$root/share/$name/content"
      deps='[]'
    else
      name=python
      tree=${path%/bin/*}
      ver=$("$path" -I --version)
      ver=${ver#Python }
      mm=${ver%.*}
      mkdir -p "$root/bin" "$root/lib"
      cp -L -- "$path" "$root/bin/python$mm"
      ln -s "python$mm" "$root/bin/python"
      ln -s "python$mm" "$root/bin/python3"
      for lib in "$tree"/lib/libpython*.so*; do
        [[ ! -e $lib ]] || cp -a -- "$lib" "$root/lib/"
      done
      tar -C "$tree/lib" --exclude='__pycache__' --exclude='site-packages/*' \
        --exclude="python$mm/test" -cf - "python$mm" | tar -C "$root/lib" -xf -
      deps='["updater-runtime-lib ==1"]'
      [[ $path != "$new" ]] || deps='["updater-runtime-lib ==2","updater-check-dep ==1"]'
    fi
    fn="$name-$ver-0.tar.bz2"
    jq -n --arg name "$name" --arg v "$ver" --argjson deps "$deps" \
      '{name:$name,version:$v,build:"0",build_number:0,subdir:"linux-64",depends:$deps}' >"$root/info/index.json"
    (cd "$root" && find . -path './info' -prune -o \( -type f -o -type l \) -printf '%P\n' | LC_ALL=C sort) >"$root/info/files"
    BZIP2=-1 tar -C "$root" -cjf "$channel/linux-64/$fn" .
    pkg="$channel/linux-64/$fn"
    info="$tmp/$fn.json"
    jq --arg fn "$fn" --arg sha "$(sha256sum "$pkg" | cut -d' ' -f1)" \
      --arg md5 "$(md5sum "$pkg" | cut -d' ' -f1)" --argjson size "$(stat -Lc %s "$pkg")" \
      '{key:$fn,value:(.+{sha256:$sha,md5:$md5,size:$size})}' "$root/info/index.json" >"$info"
    files+=("$info")
  done
  jq -s '{info:{subdir:"linux-64"},packages:from_entries,"packages.conda":{},removed:[],repodata_version:1}' "${files[@]}" >"$channel/linux-64/repodata.json"
  jq -n '{info:{subdir:"noarch"},packages:{},"packages.conda":{},removed:[],repodata_version:1}' >"$channel/noarch/repodata.json"
)

if [[ ${1:-} == --channel && $# == 4 ]]; then make_channel "$2" "$3" "$4"; exit; fi
[[ $# == 3 ]] || { echo 'Usage: python-updater-conda.bash CONDA_BIN OLD_PRIVATE_PYTHON NEW_PRIVATE_PYTHON' >&2; exit 2; }
solver=$(realpath -e -- "$1")
old_python=$(realpath -e -- "$2")
new_python=$(realpath -e -- "$3")
repo=$(dirname -- "$(dirname -- "$(realpath -e -- "$0")")")
lab=$(mktemp -d)
clean_test() {
  local status=$? log
  if ((status)); then
    for log in "$lab/"{interactive,verify,rollback,second,after-change}.log; do
      [[ ! -s $log ]] || tail -n 15 "$log" >&2
    done
  fi
  rm -rf -- "$lab"
}
trap clean_test EXIT
if [[ -n ${UPDATER_TEST_CHANNEL:-} ]]; then
  channel=$(realpath -e -- "$UPDATER_TEST_CHANNEL")
else
  channel="$lab/channel"
  make_channel "$old_python" "$new_python" "$channel"
fi
base="$lab/environments/base"
named="$base/envs/named"
sibling="$lab/external-envs/sibling"
goal=$("$new_python" -I --version); goal=${goal#Python }
old=$("$old_python" -I --version); old=${old#Python }
export CONDARC="$lab/condarc" CONDA_PKGS_DIRS="$lab/pkgs" CONDA_ENVS_PATH="$lab/external-envs" CONDA_EXE="$solver"
export CONDA_OFFLINE=true CONDA_SOLVER=classic CONDA_ADD_PIP_AS_PYTHON_DEPENDENCY=false CONDA_REGISTER_ENVS=false
cat >"$CONDARC" <<RC
channels: [file://$channel]
default_channels: []
offline: true
RC
for p in "$base" "$named" "$sibling"; do
  "$solver" create --json --yes --prefix "$p" "python==$old" >"$lab/create.json"
  "$p/bin/python" -I --version | grep -Fx "Python $old"
done

# Source the real engine and transaction implementation without starting main.
sed '$d' "$repo/update_python_envs.sh" >"$lab/engine.sh"
source "$lab/engine.sh"
trap clean_test EXIT
source "$repo/python_updater_conda.sh"
WORK="$lab/work"
mkdir -p "$WORK"
SCAN_ROOTS=("$lab" "${solver%/bin/conda}")
POLICY[${old%.*}]=$goal
jq -n --arg p "${solver%/bin/conda}" '{environments:[{prefix:$p,managed:"conda",kind:"raw"}]}' >"$lab/inv"
for p in "$base" "$named" "$sibling"; do
  info=$(probe "$p/bin/python")
  item=$(jq -c --arg id "$(stat -Lc '%d:%i' "$p")" '.+{prefix_identity:$id}' <<<"$info")
  plan=$(conda_plan_item "$item" "$lab/inv")
  jq -e --arg goal "$goal" '.kind=="conda" and .action=="update" and .target.version==$goal and
    (.conda.changes.link|map(.name)|sort)==["python","updater-check-dep","updater-runtime-lib"] and
    any(.conda.changes.unlink[];.name=="updater-runtime-lib" and .version=="1")' <<<"$plan" >/dev/null
  printf '%s\n' "$plan" >"$lab/$(basename "$p").plan"
done
# Updating the outer prefix must not replace the named environment below it.
entry="$lab/entry.json" journal="$lab/journal.json"
jq --arg f "$entry" '.+{entry_file:$f,status:"pending"}' "$lab/base.plan" >"$entry"
jq -n --slurpfile e "$entry" '{entries:$e}' >"$journal"
( conda_apply_one "$entry" "$journal" '' )
jq -e '.entries[0].status=="verified"' "$journal" >/dev/null
conda_verify_entry "$(cat "$entry")" '' "$lab/verified.json"
[[ $("$named/bin/python" -I --version) == "Python $old" && $("$sibling/bin/python" -I --version) == "Python $old" ]]
conda_restore_one "$entry" "$journal"
[[ $("$base/bin/python" -I --version) == "Python $old" && ! -f $base/share/updater-check-dep/content &&
   $(cat "$base/share/updater-runtime-lib/content") == 1 ]]

# Approve an external named environment separately. A changed revision makes
# a stale approval fail before publication and its unrelated package survives.
jq --arg f "$entry" '.+{entry_file:$f,status:"pending"}' "$lab/sibling.plan" >"$entry"
jq -n --slurpfile e "$entry" '{entries:$e}' >"$journal"
"$solver" install --json --yes --prefix "$sibling" updater-check-dep >"$lab/external.json"
status=0
( set -e; conda_apply_one "$entry" "$journal" '' ) >"$lab/stale.log" 2>&1 || status=$?
[[ $status != 0 && $("$sibling/bin/python" -I --version) == "Python $old" && -f $sibling/share/updater-check-dep/content ]]

# Public zero-argument workflow: three true Conda prefixes and an extracted
# Python cache. Expose the real manager to the solver but never walk/update
# the operator's existing installation or its environments in this test.
mkdir -p "$lab/cli" "$lab/tools"
cp -- "$repo"/{update_python_envs.sh,install_python.sh,python_updater_conda.sh} "$lab/cli/"
export CONDA_TEST_LAB="$lab" CONDA_TEST_MANAGER=${solver%/bin/conda} CONDA_TEST_FIND
CONDA_TEST_FIND=$(type -P find)
cat >"$lab/tools/findmnt" <<'TOOL'
#!/usr/bin/env bash
jq -cn --arg p "$CONDA_TEST_LAB" --arg mgr "$CONDA_TEST_MANAGER" '{filesystems:[
  {target:"/",fstype:"overlay","maj:min":"0:1"},
  {target:$p,fstype:"ext4","maj:min":"8:1"},
  {target:$mgr,fstype:"ext4","maj:min":"8:2"}]}'
TOOL
cat >"$lab/tools/lsblk" <<'TOOL'
#!/usr/bin/env bash
echo '{"blockdevices":[{"name":"vda","type":"disk","maj:min":"8:1","rota":false},{"name":"vdb","type":"disk","maj:min":"8:2","rota":false}]}'
TOOL
cat >"$lab/tools/find" <<'TOOL'
#!/usr/bin/env bash
if [[ ${1:-} == -P && ${2:-} == "$CONDA_TEST_MANAGER" ]]; then exit 0; fi
exec "$CONDA_TEST_FIND" "$@"
TOOL
chmod +x "$lab/tools/"*
export PATH="$lab/tools:$PATH"
printf 'no\nyes\n\n' | bash "$lab/cli/update_python_envs.sh" >"$lab/interactive.log" 2>&1
cli_journal=$(sed -n 's/^Output: //p' "$lab/interactive.log")
jq -e --arg p "$named" '.complete and .failures==0 and (.entries|length)==1 and
  .entries[0].prefix==$p and .entries[0].kind=="conda" and .entries[0].status=="verified"' "$cli_journal" >/dev/null
jq -e 'any(.plan[]; .managed=="conda-package-cache" and .action=="skip")' "${cli_journal%/*}/plan.json" >/dev/null
[[ $("$base/bin/python" -I --version) == "Python $old" && $("$sibling/bin/python" -I --version) == "Python $old" ]]
[[ $("$named/bin/python" -I --version) == "Python $goal" ]]
bash "$lab/cli/update_python_envs.sh" verify "$cli_journal" >"$lab/verify.log" 2>&1
bash "$lab/cli/update_python_envs.sh" rollback "$cli_journal" >"$lab/rollback.log" 2>&1
[[ $("$named/bin/python" -I --version) == "Python $old" && ! -e $named/share/updater-check-dep/content ]]
# A later, independent transaction must not be erased by rollback.
printf 'no\nyes\nno\n' | bash "$lab/cli/update_python_envs.sh" >"$lab/second.log" 2>&1
cli_journal=$(sed -n 's/^Output: //p' "$lab/second.log")
"$solver" install --json --yes --prefix "$named" updater-external >"$lab/unrelated.json"
if bash "$lab/cli/update_python_envs.sh" rollback "$cli_journal" >"$lab/after-change.log" 2>&1; then
  echo 'Unexpected rollback over a later Conda transaction' >&2; exit 1
fi
[[ -f $named/share/updater-external/content && $("$named/bin/python" -I --version) == "Python $goal" ]]
printf 'Conda solve, individual CLI approvals, cache and sibling isolation, verify, revision rollback and stale approval tests passed\n'
