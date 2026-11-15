#!/usr/bin/env bash
# Use private, relocatable CPython prefixes. With one input a broken standard
# alias requires a repair even at the same patch, making the old base usable
# throughout and the choice of interpreter observable.
set -Eeuo pipefail
[[ $# == 1 || $# == 2 ]] || { echo 'Usage: bash tests/python-updater-base-choice.bash OLD_PRIVATE_BIN [PATCHED_PRIVATE_BIN]' >&2; exit 2; }
old=$(realpath -e -- "$1")
replacement=$(realpath -e -- "${2:-$1}")
old_tree=${old%/bin/*}
replacement_tree=${replacement%/bin/*}
for tree in "$old_tree" "$replacement_tree"; do
  [[ -n $tree && $tree != / && $tree != /usr && $tree != /usr/local && -d $tree/lib ]] ||
    { echo 'Use private Python installations for this test' >&2; exit 2; }
done
old_patch=$("$old" -I --version)
old_patch=${old_patch#Python }
patch=$("$replacement" -I --version)
patch=${patch#Python }
mm=${patch%.*}
[[ ${old_patch%.*} == "$mm" ]]
source_dir=$(dirname -- "$(realpath -e -- "$0")")/..
lab=$(mktemp -d)
trap 'status=$?; if ((status)); then tail -n 30 "$lab"/last.out >&2 || true; fi; rm -rf -- "$lab"' EXIT
user_dir="$lab/user"
export FIXTURE_USER_DIR="$user_dir" FIXTURE_ORIGINAL="$user_dir/install/opt/python-$old_patch"
export FIXTURE_PATCH="$patch" FIXTURE_TARGET="$replacement_tree" FIXTURE_BUILDS="$lab/builds"
export FIXTURE_STAT
FIXTURE_STAT=$(command -v stat)
export XDG_DATA_HOME="$user_dir/data"
runtime="$XDG_DATA_HOME/python-env-updater"
mkdir -p "$lab/tools" "$lab/scripts" "${FIXTURE_ORIGINAL%/*}" "$user_dir/project" "$runtime"
cp -- "$source_dir/update_python_envs.sh" "$lab/scripts/"
cp -a -- "$old_tree" "$FIXTURE_ORIGINAL"
cp -a -- "$replacement_tree" "$runtime/known-target"
jq -n --arg mm "$mm" --arg bin "$runtime/known-target/bin/python$mm" '{($mm):$bin}' >"$runtime/targets.json"

cat >"$lab/tools/findmnt" <<'TOOL'
#!/usr/bin/env bash
jq -n --arg path "$FIXTURE_USER_DIR" '{filesystems:[
  {target:"/",fstype:"overlay","maj:min":"0:1"},
  {target:$path,fstype:"ext4","maj:min":"253:1"}]}'
TOOL
cat >"$lab/tools/lsblk" <<'TOOL'
#!/usr/bin/env bash
echo '{"blockdevices":[{"name":"vda","type":"disk","maj:min":"253:1","rota":true}]}'
TOOL
cat >"$lab/tools/stat" <<'TOOL'
#!/usr/bin/env bash
# Simulate a readable installation owned by a different account.
if [[ $# == 4 && $1 == -Lc && $2 == %u && $3 == -- && $4 == "$FIXTURE_ORIGINAL" ]]; then
  echo "$((EUID + 1))"
  exit 0
fi
exec "$FIXTURE_STAT" "$@"
TOOL
cat >"$lab/scripts/install_python.sh" <<'TOOL'
#!/usr/bin/env bash
set -eu
if [[ $# == 1 && $1 == --print-pins ]]; then echo "$FIXTURE_PATCH"; exit 0; fi
echo "$1" >>"$FIXTURE_BUILDS"
mkdir -p "$1/opt"
cp -a -- "$FIXTURE_TARGET" "$1/opt/python-$FIXTURE_PATCH"
if [[ -n ${FIXTURE_CHANGED_HOME:-} ]]; then
  cfg="$FIXTURE_USER_DIR/project/venv/pyvenv.cfg"
  awk -v dir="$FIXTURE_CHANGED_HOME" '/^home = / {$0="home = " dir} {print}' "$cfg" >"$cfg.changed"
  mv -- "$cfg.changed" "$cfg"
fi
TOOL
chmod +x "$lab/tools/"*
run() { PATH="$lab/tools:$PATH" bash "$lab/scripts/update_python_envs.sh" "$@" >"$lab/last.out" 2>&1; }
output_path() { sed -n 's/^Output: //p' "$lab/last.out"; }
base_of() { "$1/bin/python" -I -m sysconfig | awk '$1=="installed_base" && $2=="=" {sub(/^[^=]*= "/,"");sub(/"$/,"");print;exit}'; }
venv="$user_dir/project/venv"
"$FIXTURE_ORIGINAL/bin/python$mm" -I -m venv --copies --without-pip "$venv"
ln -sfn repair-this-alias "$venv/bin/python3"
site="$venv/lib/python$mm/site-packages"
mkdir -p "$site/sample_project-1.2.3.dist-info"
printf 'Metadata-Version: 2.1\nName: sample-project\nVersion: 1.2.3\n' >"$site/sample_project-1.2.3.dist-info/METADATA"
printf 'package file\n' >"$site/project_data"
sha256sum "$FIXTURE_ORIGINAL/bin/python$mm" "$venv/bin/activate" "$site/project_data" "$site/sample_project-1.2.3.dist-info/METADATA" >"$lab/original-hashes"

printf 'y\n\n' | run
journal=$(output_path)
grep -F 'Prefix owned by another account' "$lab/last.out" >/dev/null
grep -F '"event":"no_updates"' "$lab/last.out" >/dev/null
jq -e --arg p "$venv" 'any(.plan[];.prefix==$p and .action=="skip" and .base_choice=="skipped")' "${journal%/*}/plan.json" >/dev/null
[[ ! -e $journal && ! -e $FIXTURE_BUILDS ]]
for replies in 'y\n' 'y\ny\n'; do
  status=0
  printf '%b' "$replies" | run || status=$?
  [[ $status == 2 && ! -e $(output_path) && ! -e $FIXTURE_BUILDS ]]
done
printf 'y\ninvalid\ny\nn\n' | run
grep -F 'Enter y to use the replacement' "$lab/last.out" >/dev/null
grep -F '"event":"cancelled"' "$lab/last.out" >/dev/null
[[ ! -e $(output_path) && $(base_of "$venv") == "$FIXTURE_ORIGINAL" ]]

other="$user_dir/z-project/venv"
"$FIXTURE_ORIGINAL/bin/python$mm" -I -m venv --copies --without-pip "$other"
ln -sfn keep-this-alias "$other/bin/python3"
for path_kind in cached prepared; do
  if [[ $path_kind == prepared ]]; then rm -- "$runtime/targets.json"; fi
  printf 'y\ny\nn\n\n' | run
  journal=$(output_path)
  if [[ $path_kind == cached ]]; then
    expected="$runtime/known-target"
    [[ ! -e $FIXTURE_BUILDS ]]
  else
    expected="$(cat "$FIXTURE_BUILDS")/opt/python-$patch"
    [[ $(wc -l <"$FIXTURE_BUILDS") == 1 ]]
  fi
  jq -e --arg p "$venv" --arg alt "$expected" --arg orig "$FIXTURE_ORIGINAL" --arg other "$other" '
    .complete and .failures==0 and (.entries|length)==1 and
    (.entries[0]|.prefix==$p and .base_choice=="replacement" and .base_prefix==$orig and
      .required_base==$alt and .target.prefix==$alt and .status=="verified" and
      any(.package_snapshot.packages[];.name=="sample-project" and .version=="1.2.3")) and
    any(.skipped[];.prefix==$other and .reason=="Replacement base declined")
  ' "$journal" >/dev/null
  [[ $(base_of "$venv") == "$expected" && $(base_of "$other") == "$FIXTURE_ORIGINAL" ]]
  [[ $("$venv/bin/python3" -I --version) == "Python $patch" && $(readlink -- "$other/bin/python3") == keep-this-alias ]]
  sha256sum --check --quiet "$lab/original-hashes"
  run verify "$journal" --output "$lab/verified.json"
  jq -e '(.results|length)==1 and .results[0].passed' "$lab/verified.json" >/dev/null
  jq --arg orig "$FIXTURE_ORIGINAL" '.entries[0].required_base=$orig' "$journal" >"$lab/wrong-base.json"
  if run verify "$lab/wrong-base.json" --output "$lab/wrong-result.json"; then exit 1; fi
  jq -e '.results[0].passed==false' "$lab/wrong-result.json" >/dev/null
  run rollback "$journal"
  [[ $(base_of "$venv") == "$FIXTURE_ORIGINAL" && $(readlink -- "$venv/bin/python3") == repair-this-alias ]]
  sha256sum --check --quiet "$lab/original-hashes"
done

# An independent reconfiguration during target preparation invalidates consent.
rm -- "$runtime/targets.json"
cp -a -- "$old_tree" "$runtime/other-original"
export FIXTURE_CHANGED_HOME="$runtime/other-original/bin"
status=0
printf 'y\ny\nn\n\n' | run || status=$?
[[ $status == 2 && ! -e $(output_path) && $(base_of "$venv") == "$runtime/other-original" ]]
grep -F 'Venv changed since base selection' "$lab/last.out" >/dev/null
echo 'PASS: skip/EOF, independent base and batch consent, cached and built replacement, verify/rollback and concurrent base changes'
