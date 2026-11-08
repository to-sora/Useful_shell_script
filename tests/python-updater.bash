#!/usr/bin/env bash
# Run against two private CPython builds from install_python.sh, old then patched.
set -Eeuo pipefail
[[ $# == 2 ]] || {
  echo 'Usage: bash tests/python-updater.bash OLD_BIN PATCHED_BIN' >&2
  exit 2
}
old=$(realpath -e -- "$1")
target=$(realpath -e -- "$2")
updater=$(realpath -e -- "$(dirname "$0")/../update_python_envs.sh")
installer=${updater%/*}/install_python.sh
old_version=$("$old" -I --version)
version=$("$target" -I --version)
minor=${version#Python }
minor=${minor%.*}
[[ $old_version == "Python $minor."* && $old_version != "$version" ]]
lab=$(mktemp -d)
trap 'rm -rf -- "$lab"' EXIT
journal=$lab/update.json
root=$lab/projects
mkdir -p "$root" "$lab/tools"
target_arg=(--target "$minor=$target")
prompt='a "quoted" label with \ and $literal'
run() { bash "$updater" "$@"; }
bad() { if "$@"; then
  printf 'Expected failure: %s\n' "$*" >&2
  exit 1
fi; }
check_version() { [[ $("$1/bin/python" -I --version) == "$2" ]]; }

a="$root/unusual name"
b="$root/venv"
"$old" -I -m venv --copies --prompt "$prompt" "$a"
"$old" -I -m venv --copies "$b"
ln -s "$a" "$root/alias"
ln -s . "$root/cycle"
awk '/^prompt = /' "$a/pyvenv.cfg" >"$lab/prompt"
test -s "$lab/prompt"
sha256sum "$a/bin/activate" >"$lab/activation"

# Monitor probe invocations, including unsuccessful ones. All canaries are ELF.
outside="$lab/outside"
for path in "$root/.git/nested" "$root/node_modules/nested" "$outside"; do
  mkdir -p "$path/bin"
  touch "$path/pyvenv.cfg"
  cp /bin/true "$path/bin/python"
done
mkdir -p "$root/unrelated/bin"
cp /bin/true "$root/unrelated/bin/python"
ln -s "$outside" "$root/external-link"
ln -s "$outside/bin/python" "$a/bin/python999"
export TEST_TIMEOUT TEST_PROBES
TEST_TIMEOUT=$(command -v timeout)
TEST_PROBES=$lab/probes
cat >"$lab/tools/timeout" <<'WRAPPER'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$TEST_PROBES"
exec "$TEST_TIMEOUT" "$@"
WRAPPER
chmod +x "$lab/tools/timeout"
PATH="$lab/tools:$PATH" run scan "$root" --output "$lab/scan"
jq -e --arg a "$a" --arg b "$b" '([.environments[].prefix]|sort)==([$a,$b]|sort) and .walk_status==0' "$lab/scan" >/dev/null
bad grep -Eq '/(\.git|node_modules|unrelated|external-link)/|/bin/python999( |$)' "$TEST_PROBES"
run plan "$root" "${target_arg[@]}" --output "$lab/mixed"
jq -e --arg p "$a" '.plan[]|select(.prefix==$p and .action=="skip")' "$lab/mixed" >/dev/null
rm "$a/bin/python999"
"$old" -I -m venv --copies "$outside/linked-env"
ln -s "$outside/linked-env" "$root/opt-in"
run scan "$root/opt-in" --output "$lab/opt-in"
jq -e --arg p "$outside/linked-env" '[.environments[].prefix]==[$p]' "$lab/opt-in" >/dev/null
CODEX_PRIMARY_RUNTIME_ROOT="$b" run plan "$root" "${target_arg[@]}" --output "$lab/protected"
jq -e --arg p "$b" '.plan[]|select(.prefix==$p and .reason=="Distribution/runtime-managed prefix")' "$lab/protected" >/dev/null

# Interrupt the worker while the backup is partial, before publication begins.
export TEST_CP
TEST_CP=$(command -v cp)
cat >"$lab/tools/cp" <<'WRAPPER'
#!/usr/bin/env bash
destination=${!#}
if [[ $destination == *.backup ]]; then
  mkdir -- "$destination"
  printf 'partial\n' >"$destination/partial"
  kill -KILL "$PPID"
  exit 137
fi
exec "$TEST_CP" "$@"
WRAPPER
chmod +x "$lab/tools/cp"
printf 'must survive\n' >"$a/sentinel"
bad env PATH="$lab/tools:$PATH" bash "$updater" apply "$a" "${target_arg[@]}" --output "$lab/interrupted"
jq -e '.entries[0]|.status=="prepared" and (.publication_started!=true)' "$lab/interrupted" >/dev/null
run rollback "$lab/interrupted"
bad run _restore "$lab/interrupted.entries/1.json" "$lab/interrupted"
check_version "$a" "$old_version"
[[ $(cat "$a/sentinel") == 'must survive' && ! -e $a/partial ]]

# Record a real pre-existing pip conflict and filesystem metadata.
dist="$a/lib/python$minor/site-packages/review_fixture-1.dist-info"
mkdir "$dist"
printf 'Metadata-Version: 2.1\nName: review-fixture\nVersion: 1\nRequires-Dist: review-missing==1\n' >"$dist/METADATA"
bad "$a/bin/python" -I -m pip check
ln "$a/sentinel" "$a/linked-sentinel"
setfacl -m "u:$(id -u):r--" "$a/sentinel"
setfattr -n user.review -v keep "$a/sentinel"
getfacl -cp "$a/sentinel" >"$lab/acl"
check_metadata() {
  cmp "$lab/acl" <(getfacl -cp "$a/sentinel")
  [[ $(getfattr --only-values -n user.review "$a/sentinel") == keep ]]
  [[ $a/sentinel -ef $a/linked-sentinel ]]
}
jq -n '{"*":[{"argv":["bash","-c","cat >/dev/null; test \"$(readlink /proc/self/fd/0)\" = /dev/null"]},{"argv":["true"]}]}' >"$lab/checks"
run apply "$root" "${target_arg[@]}" --checks "$lab/checks" --output "$journal"
jq -e '.failures==0 and (.entries|length)==2 and all(.entries[];.status=="verified")' "$journal" >/dev/null
jq -e --arg p "$a" '.entries[]|select(.prefix==$p)|(.package_snapshot.pip_conflicts|length)==1 and (.validation.pip_conflicts==.package_snapshot.pip_conflicts)' "$journal" >/dev/null
while IFS= read -r stage; do [[ ! -e $stage ]]; done < <(jq -r '.entries[].stage' "$journal")
check_version "$a" "$version"
check_version "$b" "$version"
cmp "$lab/prompt" <(awk '/^prompt = /' "$a/pyvenv.cfg")
sha256sum -c "$lab/activation"
check_metadata
run verify "$journal" --checks "$lab/checks" --output "$lab/good"

printf 'Requires-Dist: second-review-missing==1\n' >>"$dist/METADATA"
bad run verify "$journal" --output "$lab/bad"
jq -e '.results[]|select(.passed==false and (.error|contains("New pip conflicts")))' "$lab/bad" >/dev/null
# Restore even when content, but neither size nor mtime, was changed.
stamp=$(mktemp "$lab/stamp.XXXXXX")
touch -r "$a/sentinel" "$stamp"
printf 'must perish!\n' >"$a/sentinel"
touch -r "$stamp" "$a/sentinel"
rm "$a/linked-sentinel"
setfattr -x user.review "$a/sentinel"
setfacl -b "$a/sentinel"
run rollback "$journal"
check_version "$a" "$old_version"
check_version "$b" "$old_version"
[[ $(cat "$a/sentinel") == 'must survive' ]]
check_metadata

# Exercise installer diagnostics against a private prefix missing a real module.
base=${target%/bin/*}
cp -a -- "$base" "$lab/missing-module"
rm -- "$lab"/missing-module/lib/python"$minor"/lib-dynload/_sqlite3*.so
BASE_DIR=$lab
mkdir -p "$BASE_DIR/CACHE/tmp"
source <(sed -n '/^check_python_modules() {/,/^}/p' "$installer")
bad check_python_modules "$lab/missing-module/bin/${target##*/}" 2>"$lab/module-errors"
grep -F 'Module check failed: sqlite3' "$lab/module-errors" >/dev/null

# Changing the single policy source changes the updater's rejection threshold.
mkdir "$lab/policy"
cp "$updater" "$lab/policy/"
v=${version#Python }
printf 'printf "%%s\\\\n" %s\n' "$minor.$((${v##*.} + 1))" >"$lab/policy/install_python.sh"
bad bash "$lab/policy/update_python_envs.sh" plan "$a" "${target_arg[@]}" --output "$lab/below" 2>"$lab/policy-error"
grep -F 'below policy floor' "$lab/policy-error" >/dev/null
echo 'PASS: discovery scope, interrupted backup, dependency baseline, prompt, module errors, filesystem metadata, cleanup, stdin and shared policy'
