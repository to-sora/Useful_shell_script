#!/usr/bin/env bash
# Automatic orchestration with real CPython binaries; downloads/builds are replaced
# by an installer fixture that copies the supplied patched runtime into its layout.
set -Eeuo pipefail
[[ $# == 2 ]] || {
  echo 'Usage: bash tests/python-updater-auto.bash OLD_BIN PATCHED_BIN' >&2
  exit 2
}
old=$(realpath -e -- "$1")
target=$(realpath -e -- "$2")
updater=$(realpath -e -- "$(dirname "$0")/../update_python_envs.sh")
old_version=$("$old" -I --version)
version=$("$target" -I --version)
minor=${version#Python }
minor=${minor%.*}
[[ $old_version == "Python $minor."* && $old_version != "$version" ]]
lab=$(mktemp -d)
trap 'rm -rf -- "$lab"' EXIT
mkdir -p "$lab/scripts" "$lab/elsewhere" "$lab/projects"
cp -- "$updater" "$lab/scripts/update_python_envs.sh"
export AUTO_TEST_INSTALLER="${updater%/*}/install_python.sh" AUTO_TEST_TARGET="$target"
export AUTO_TEST_CALLS="$lab/installer-calls" AUTO_TEST_ARGS="$lab/installer-args" AUTO_TEST_FAIL=0
export XDG_DATA_HOME="$lab/data"
cache=$XDG_DATA_HOME/python-env-updater
cat >"$lab/scripts/install_python.sh" <<'INSTALLER'
#!/usr/bin/env bash
set -Eeuo pipefail
if [[ $# == 1 && $1 == --print-pins ]]; then
  exec bash "$AUTO_TEST_INSTALLER" --print-pins
fi
printf 'build\n' >>"$AUTO_TEST_CALLS"
printf '%s\n' "$@" >"$AUTO_TEST_ARGS"
# Preparation must not consume a venv confirmation.
if IFS= read -r answer; then echo 'Installer received confirmation input' >&2; exit 25; fi
((AUTO_TEST_FAIL == 0)) || { echo 'fixture build failed' >&2; exit 19; }
destination=$1
shift
selected=''
while (($#)); do
  case "$1" in
    --py) selected=$2; shift 2 ;;
    --jobs) [[ $2 =~ ^[1-9][0-9]*$ ]]; shift 2 ;;
    --reuse | --skip-conda | --no-bashrc | --skip-apt | --no-sudo) shift ;;
    *) echo "Unexpected installer option: $1" >&2; exit 26 ;;
  esac
done
version=$("$AUTO_TEST_TARGET" -I --version)
version=${version#Python }
[[ $selected == "${version%.*}" ]]
mkdir -p "$destination/opt"
cp -a -- "${AUTO_TEST_TARGET%/bin/*}" "$destination/opt/python-$version"
echo 'fixture: prepared real patched CPython'
INSTALLER
run() { (cd "$lab/elsewhere" && bash "$lab/scripts/update_python_envs.sh" "$@"); }
bad() { if "$@"; then echo "Expected failure: $*" >&2; exit 1; fi; }
venv() { "$old" -I -m venv --copies --without-pip "$1"; }
check_version() { [[ $("$1/bin/python" -I --version) == "$2" ]]; }
output_path() { sed -n 's/^Output: //p' "$1"; }
for name in a b; do venv "$lab/projects/$name"; done

# Planning reports the pinned build and leaves the installer and venvs untouched.
run plan "$lab/projects" >"$lab/plan-output" 2>&1
plan=$(output_path "$lab/plan-output")
jq -e --arg version "${version#Python }" '(.plan|length)==2 and
  all(.plan[];.action=="prepare_target" and .target==null and .requested_version==$version)' "$plan" >/dev/null
[[ ! -e $AUTO_TEST_CALLS && ! -e $cache ]]
check_version "$lab/projects/a" "$old_version"

# A journal under a source prefix fails before any target preparation.
bad run apply -Y "$lab/projects/a" --output "$lab/projects/a/update.json" >"$lab/control-error" 2>&1
grep -F 'Control path must be outside updated prefixes' "$lab/control-error" >/dev/null
[[ ! -e $AUTO_TEST_CALLS && ! -e $lab/projects/a/update.json ]]

# No --target, --output or --runtime-dir: the defaults prepare one needed branch,
# retain both prompt responses, and save the journal beside the process log.
printf 'y\nN\n' | run apply "$lab/projects" --no-sudo --jobs 2 >"$lab/cold-output" 2>&1
journal=$(output_path "$lab/cold-output")
[[ $journal == "$lab/scripts/log/"*/journal.json ]]
jq -e '(.entries|length)==1 and .entries[0].approval=="confirmed" and
  .entries[0].target.source=="installed" and (.skipped|length)==1' "$journal" >/dev/null
check_version "$lab/projects/a" "$version"
check_version "$lab/projects/b" "$old_version"
[[ $(wc -l <"$AUTO_TEST_CALLS") == 1 ]]
for option in --reuse --skip-conda --no-bashrc --skip-apt --no-sudo; do grep -Fx -- "$option" "$AUTO_TEST_ARGS" >/dev/null; done
grep -Fx -- "$minor" "$AUTO_TEST_ARGS" >/dev/null
grep -Fx -- 2 "$AUTO_TEST_ARGS" >/dev/null
grep -F 'fixture: prepared real patched CPython' "${journal%/*}/process.log" >/dev/null
grep -F 'target_build_finished' "${journal%/*}/process.log" >/dev/null
cached=$(jq -r --arg mm "$minor" '.[$mm]' "$cache/targets.json")
[[ $cached == "$cache/build-"*/opt/python-*/bin/python"$minor" ]]

# A second update reuses the cache, even when a build would fail.
AUTO_TEST_FAIL=1 run -Y apply "$lab/projects/b" >"$lab/reuse-output" 2>&1
reuse_journal=$(output_path "$lab/reuse-output")
jq -e '(.entries|length)==1 and .entries[0].target.source=="cache"' "$reuse_journal" >/dev/null
check_version "$lab/projects/b" "$version"
[[ $(wc -l <"$AUTO_TEST_CALLS") == 1 ]]
run plan "$lab/projects" >"$lab/repeat-output" 2>&1
jq -e '(.plan|length)==2 and all(.plan[];.action=="skip" and .reason=="up_to_date")' "$(output_path "$lab/repeat-output")" >/dev/null
run verify "$reuse_journal" >"$lab/verify-output" 2>&1
jq -e 'all(.results[];.passed)' "$(output_path "$lab/verify-output")" >/dev/null

# An existing healthy private runtime in the scan is preferred over a new build.
mkdir "$lab/existing"
cp -a -- "${target%/bin/*}" "$lab/existing/patched"
venv "$lab/existing/env"
AUTO_TEST_FAIL=1 run apply -Y "$lab/existing" --runtime-dir "$lab/unused-cache" >"$lab/existing-output" 2>&1
jq -e --arg p "$lab/existing/patched" '(.entries|length)==1 and
  .entries[0].target.prefix==$p and .entries[0].target.source=="discovered"' "$(output_path "$lab/existing-output")" >/dev/null
check_version "$lab/existing/env" "$version"
[[ ! -e $lab/unused-cache && $(wc -l <"$AUTO_TEST_CALLS") == 1 ]]

# Explicit targets win over automatic cache/discovery choices.
venv "$lab/override"
AUTO_TEST_FAIL=1 run apply -Y "$lab/override" --target "$minor=$target" >"$lab/override-output" 2>&1
jq -e --arg p "$target" '.entries[0].target.binary==$p and .entries[0].target.source=="explicit"' "$(output_path "$lab/override-output")" >/dev/null
[[ $(wc -l <"$AUTO_TEST_CALLS") == 1 ]]

# An up-to-date environment needs no build even with an empty runtime cache.
"$target" -I -m venv --copies --without-pip "$lab/current"
AUTO_TEST_FAIL=1 run apply -Y "$lab/current" --runtime-dir "$lab/unused-cache" >"$lab/current-output" 2>&1
jq -e '.entries==[] and .skipped[0].reason=="up_to_date"' "$(output_path "$lab/current-output")" >/dev/null
[[ ! -e $lab/unused-cache && $(wc -l <"$AUTO_TEST_CALLS") == 1 ]]

# Build failures stop before any journal or source environment changes.
venv "$lab/build-failure"
cp "$lab/build-failure/pyvenv.cfg" "$lab/before.cfg"
AUTO_TEST_FAIL=1 bad run apply -Y "$lab/build-failure" --runtime-dir "$lab/failed-cache" >"$lab/failed-output" 2>&1
[[ ! -e $(output_path "$lab/failed-output") && $(wc -l <"$AUTO_TEST_CALLS") == 2 ]]
check_version "$lab/build-failure" "$old_version"
cmp "$lab/before.cfg" "$lab/build-failure/pyvenv.cfg"
grep -F 'Target preparation failed; existing environments were not updated' "$lab/failed-output" >/dev/null

# Never repair an unhealthy cached runtime in place underneath its dependents.
cached_prefix=${cached%/bin/*}
rm -- "$cached_prefix"/lib/python"$minor"/lib-dynload/_sqlite3*.so
sha256sum "$cached" >"$lab/cache-hash"
cp "$lab/projects/a/pyvenv.cfg" "$lab/cache-dependent.cfg"
venv "$lab/new-env"
printf 'n\n' | run apply "$lab/new-env" --no-sudo >"$lab/fresh-output" 2>&1
fresh=$(jq -r --arg mm "$minor" '.[$mm]' "$cache/targets.json")
[[ $fresh != "$cached" && $(wc -l <"$AUTO_TEST_CALLS") == 3 ]]
sha256sum -c "$lab/cache-hash" >/dev/null
cmp "$lab/cache-dependent.cfg" "$lab/projects/a/pyvenv.cfg"
check_version "$lab/new-env" "$old_version"
jq -e '.entries==[] and .skipped[0].reason=="Venv update declined"' "$(output_path "$lab/fresh-output")" >/dev/null

# Omitting roots uses HOME; exclude that root to avoid probing the test account.
run scan --exclude "$HOME" >"$lab/default-roots-output" 2>&1
jq -e '.environments==[] and .walk_status==0' "$(output_path "$lab/default-roots-output")" >/dev/null
echo 'PASS: automatic plans, cold preparation, stdin isolation, cached/discovered targets, overrides, defaults, repeat runs and build failures'
