#!/usr/bin/env bash
# Integration regressions for control files, confirmation and process logs.
set -Eeuo pipefail
[[ $# == 2 ]] || {
  echo 'Usage: bash tests/python-updater-controls.bash OLD_BIN PATCHED_BIN' >&2
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
target_arg=(--target "$minor=$target")
run() { bash "$updater" "$@" --log-dir "$lab/logs"; }
bad() {
  if "$@"; then
    printf 'Expected failure: %s\n' "$*" >&2
    exit 1
  fi
}
venv() { "$old" -I -m venv --copies --without-pip "$1"; }
check_version() { [[ $("$1/bin/python" -I --version) == "$2" ]]; }

# Reject journals inside prefixes, including paths through directory aliases.
env_path=$lab/control-env
venv "$env_path"
cp "$env_path/pyvenv.cfg" "$lab/original.cfg"
bad run apply -Y "$env_path" "${target_arg[@]}" --output "$env_path/update.json" >"$lab/inside-error" 2>&1
grep -F 'Control path must be outside updated prefixes' "$lab/inside-error" >/dev/null
[[ ! -e $env_path/update.json && ! -e $env_path/update.json.entries ]]
ln -s "$env_path" "$lab/control-alias"
bad run apply -Y "$env_path" "${target_arg[@]}" --output "$lab/control-alias/alias.json" >"$lab/alias-error" 2>&1
grep -F 'Control path must be outside updated prefixes' "$lab/alias-error" >/dev/null
[[ ! -e $env_path/alias.json && ! -e $env_path/alias.json.entries ]]
check_version "$env_path" "$old_version"
cmp "$lab/original.cfg" "$env_path/pyvenv.cfg"

# A linked config is skipped without writing through to the shared file.
mv "$env_path/pyvenv.cfg" "$lab/shared.cfg"
ln -s ../shared.cfg "$env_path/pyvenv.cfg"
run apply -Y "$lab" "${target_arg[@]}" --output "$lab/linked.json"
jq -e --arg p "$env_path" '.entries==[] and any(.skipped[];
  .prefix==$p and .reason=="Linked pyvenv.cfg requires a separate rebuild")' "$lab/linked.json" >/dev/null
cmp "$lab/original.cfg" "$lab/shared.cfg"
[[ -L $env_path/pyvenv.cfg ]]
check_version "$env_path" "$old_version"

# Confirm each venv using the caller's stdin; an empty line and N both decline.
for name in a b c; do venv "$lab/choices/$name"; done
printf 'y\n\nN\n' | run apply "$lab/choices" "${target_arg[@]}" --output "$lab/choices.json" >"$lab/choices-output" 2>&1
check_version "$lab/choices/a" "$version"
check_version "$lab/choices/b" "$old_version"
check_version "$lab/choices/c" "$old_version"
jq -e '(.entries|length)==1 and .entries[0].approval=="confirmed" and
  .entries[0].publication_started==true and (.entries[0].runtime_hashes|length)>0 and
  ([.skipped[]|select(.reason=="Venv update declined")]|length)==2' "$lab/choices.json" >/dev/null
log=$(jq -r .log_file "$lab/choices.json")
[[ $(grep -c '^Update venv ' "$log") == 3 ]]
grep -F 'approved' "$log" >/dev/null
grep -F 'declined' "$log" >/dev/null
grep -F 'Finished apply (exit 0)' "$log" >/dev/null
grep -F '"event":"verification"' "$log" >/dev/null
test -s "${log%/*}/inventory.json"
test -s "${log%/*}/plan.json"
test -s "${log%/*}/approved-plan.json"

# Missing confirmations abort the whole preflight, even after an earlier y.
for name in a b; do venv "$lab/eof/$name"; done
printf 'y\n' | bad run apply "$lab/eof" "${target_arg[@]}" --output "$lab/eof.json" >"$lab/eof-output" 2>&1
grep -F 'Confirmation input ended' "$lab/eof-output" >/dev/null
check_version "$lab/eof/a" "$old_version"
check_version "$lab/eof/b" "$old_version"
[[ ! -e $lab/eof.json && ! -e $lab/eof.json.entries ]]

# -Y works before the subcommand and needs no stdin; nested verification shares
# the outer log instead of making a second run directory.
bash "$updater" -Y apply "$lab/eof" "${target_arg[@]}" --output "$lab/bypass.json" --log-dir "$lab/bypass-logs" </dev/null >"$lab/bypass-output" 2>&1
check_version "$lab/eof/a" "$version"
check_version "$lab/eof/b" "$version"
jq -e '(.entries|length)==2 and all(.entries[];.approval=="bypassed")' "$lab/bypass.json" >/dev/null
bad grep -F 'Update venv ' "$lab/bypass-output"
[[ $(find "$lab/bypass-logs" -mindepth 1 -maxdepth 1 -type d | wc -l) == 1 ]]
log=$(jq -r .log_file "$lab/bypass.json")
grep -F '"event":"verification"' "$log" >/dev/null
grep -F 'Finished apply (exit 0)' "$log" >/dev/null

# Refusing one dependent venv must also hold its raw base at the old version.
# An approved sibling can move to the separate target instead.
cp -a -- "${old%/bin/*}" "$lab/raw-base"
for name in a b; do "$lab/raw-base/bin/${old##*/}" -I -m venv --without-pip "$lab/dependents/$name"; done
printf 'n\nY\n' | run apply "$lab/raw-base" "$lab/dependents" "${target_arg[@]}" --output "$lab/dependents.json" >"$lab/dependents-output" 2>&1
[[ $("$lab/raw-base/bin/${old##*/}" -I --version) == "$old_version" ]]
check_version "$lab/dependents/a" "$old_version"
check_version "$lab/dependents/b" "$version"
jq -e --arg base "$lab/raw-base" '(.entries|length)==1 and
  any(.skipped[];.prefix==$base and .reason=="Dependent venv is skipped; raw base left unchanged")' "$lab/dependents.json" >/dev/null

# Empty runtime hashes are a verification error, not an empty successful loop.
jq '.entries[0].runtime_hashes=null' "$lab/choices.json" >"$lab/damaged.json"
bad run verify "$lab/damaged.json" --output "$lab/damaged-result.json" >"$lab/damaged-output" 2>&1
grep -F 'Missing or invalid runtime hash manifest' "$lab/damaged-output" >/dev/null
jq -e 'any(.results[];.passed==false)' "$lab/damaged-result.json" >/dev/null

# External journals retain publication state and support explicit rollback.
run rollback "$lab/choices.json"
check_version "$lab/choices/a" "$old_version"
jq -e 'all(.entries[];.status=="rolled_back" and .publication_started==true)' "$lab/choices.json" >/dev/null

# Failed final validation restores both the failing prefix and an earlier one,
# and the independent log keeps application stderr and all rollback events.
for name in a b; do venv "$lab/failure/$name"; done
jq -n --arg p "$lab/failure/b" '{($p):[{final_only:true,
  argv:["bash","-c","printf \"control-check-failure\\n\" >&2; exit 9"]}]}' >"$lab/checks.json"
bad run apply -Y "$lab/failure" "${target_arg[@]}" --checks "$lab/checks.json" --output "$lab/failure.json" >"$lab/failure-output" 2>&1
check_version "$lab/failure/a" "$old_version"
check_version "$lab/failure/b" "$old_version"
jq -e 'all(.entries[];.status=="rolled_back")' "$lab/failure.json" >/dev/null
log=$(jq -r .log_file "$lab/failure.json")
grep -F 'control-check-failure' "$log" >/dev/null
[[ $(grep -c '"event":"rolled_back"' "$log") == 2 ]]
grep -F 'Finished apply (exit 1)' "$log" >/dev/null

# The default log root is next to the script, regardless of the current directory.
mkdir "$lab/script-copy" "$lab/elsewhere" "$lab/empty"
cp -- "$updater" "$lab/script-copy/update_python_envs.sh"
(cd "$lab/elsewhere" && bash "$lab/script-copy/update_python_envs.sh" scan "$lab/empty" --output "$lab/empty.json") >"$lab/default-output" 2>&1
log=$(find "$lab/script-copy/log" -name process.log -print -quit)
test -s "$log"
[[ ! -e $lab/elsewhere/log ]]
grep -F 'Finished scan (exit 0)' "$log" >/dev/null
[[ $(stat -c %a -- "$log") == 600 ]]
[[ $(stat -c %a -- "${log%/*}") == 700 ]]
bad bash "$lab/script-copy/update_python_envs.sh" apply "$lab/empty" --output "$lab/no-target.json" >"$lab/error-output" 2>&1
grep -RF 'Finished apply (exit 2)' "$lab/script-copy/log" >/dev/null
grep -RF -- '--target is required' "$lab/script-copy/log" >/dev/null

echo 'PASS: journal placement, linked configs, per-venv confirmation, EOF, -Y, shared bases, log success/failure and rollback'
