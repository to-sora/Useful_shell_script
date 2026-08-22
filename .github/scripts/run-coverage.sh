#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$repo_root"

mkdir -p coverage
: >coverage/bash.trace

while IFS= read -r -d '' script; do
  bash -n "$script"
done < <(git ls-files -z '*.sh' 'ltree')

temp_root="$(mktemp -d)"
trap 'rm -rf "$temp_root"' EXIT
mkdir -p "$temp_root/destination" "$temp_root/source-a/nested" "$temp_root/source-b/nested"
printf 'first\n' >"$temp_root/source-a/nested/shared.txt"
printf 'second\n' >"$temp_root/source-b/nested/shared.txt"
mkdir -p "$temp_root/source-a/path with spaces"
printf 'spaced\n' >"$temp_root/source-a/path with spaces/file name.txt"
printf 'hidden\n' >"$temp_root/source-b/.hidden.txt"
mkdir -p "$temp_root/fake-venv/bin" "$temp_root/fake-venv/lib"
: >"$temp_root/fake-venv/bin/activate"
git init -q "$temp_root/repository"
git -C "$temp_root/repository" remote add origin https://example.test/repository.git
printf 'repository payload\n' >"$temp_root/repository/payload.txt"

trace() {
  BASH_XTRACEFD=3 \
    PS4='+TRACE:${BASH_SOURCE[0]}:${LINENO}:' \
    bash -x "$@" 3>>coverage/bash.trace
}

trace ./syslink_builder.sh \
  "$temp_root/destination" \
  "$temp_root/source-a" \
  "$temp_root/source-b"
test -L "$temp_root/destination/nested/shared.txt"
test "$(readlink "$temp_root/destination/nested/shared.txt")" = \
  "$temp_root/source-b/nested/shared.txt"
test -L "$temp_root/destination/path with spaces/file name.txt"

mkdir -p "$temp_root/preflight-destination" "$temp_root/preflight-source"
if trace ./syslink_builder.sh \
  "$temp_root/preflight-destination" \
  "$temp_root/preflight-source" \
  "$temp_root/missing-source" >"$temp_root/preflight-error.txt" 2>&1; then
  printf 'Expected source preflight to reject a missing directory\n' >&2
  exit 1
fi
test -z "$(find "$temp_root/preflight-destination" -mindepth 1 -print -quit)"
grep -q 'Directory not found' "$temp_root/preflight-error.txt"

trace ./ltree -D 2 -L 2 "$temp_root/source-b" -o "$temp_root/tree.txt"
grep -q 'shared.txt' "$temp_root/tree.txt"
! grep -Fq '.hidden.txt' "$temp_root/tree.txt"

trace ./ltree -a -D 2 -L 5 "$temp_root/source-b" -o "$temp_root/tree-hidden.txt"
grep -Fq '.hidden.txt' "$temp_root/tree-hidden.txt"

mkdir -p "$temp_root/wide-tree"
for index in 1 2 3 4 5 6; do
  mkdir -p "$temp_root/wide-tree/item-$index"
  printf '%s\n' "$index" >"$temp_root/wide-tree/item-$index/value.txt"
done
for index in 1 2 3; do
  printf '%s\n' "$index" >"$temp_root/wide-tree/item-3/extra-$index.txt"
  printf '%s\n' "$index" >"$temp_root/wide-tree/item-4/extra-$index.txt"
  printf '%s\n' "$index" >"$temp_root/wide-tree/item-5/extra-$index.txt"
  printf '%s\n' "$index" >"$temp_root/wide-tree/item-6/extra-$index.txt"
done
printf 'metadata\n' >"$temp_root/wide-tree/item-6/meta.nfo"
trace ./ltree -S -K 'meta*' -P 20 -D 2 -L 2 \
  "$temp_root/wide-tree" -o "$temp_root/tree-smart.txt"
grep -q 'item-6/' "$temp_root/tree-smart.txt"
grep -q 'more entries omitted' "$temp_root/tree-smart.txt"

trace ./ltree -D 1 -L 3 "$temp_root/source-a" -o "$temp_root/tree.txt"
test "$(grep -c '^===\s*$' "$temp_root/tree.txt")" = "1"
grep -q 'source-a' "$temp_root/tree.txt"

trace ./get_vev_size.sh "$temp_root" >"$temp_root/venv-report.txt"
grep -q "Found virtual environment: $temp_root/fake-venv" "$temp_root/venv-report.txt"

trace ./get_repo_size.sh "$temp_root" >"$temp_root/repository-report.txt"
grep -q "Found Git repository: $temp_root/repository" "$temp_root/repository-report.txt"
grep -q 'https://example.test/repository.git' "$temp_root/repository-report.txt"

mkdir -p "$temp_root/acl-root/direct" "$temp_root/acl-root/second"
printf 'acl payload\n' >"$temp_root/acl-root/direct/data.txt"
getent passwd nobody >/dev/null
setfacl -m u:nobody:r-x "$temp_root/acl-root/direct"
setfacl -m d:u:nobody:r-x "$temp_root/acl-root/direct"
trace ./acl_audit.sh "$temp_root/acl-root" --no-color \
  --debug-file "$temp_root/acl-audit.log" >"$temp_root/acl-report.txt"
grep -q 'Objects with ACL:.*1' "$temp_root/acl-report.txt"
grep -q 'Dirs with default ACL:.*1' "$temp_root/acl-report.txt"
grep -q 'user:nobody:r-x' "$temp_root/acl-audit.log"

trace ./acl_audit_user.sh "$temp_root/acl-root" --users nobody \
  --debug-file "$temp_root/acl-user-audit.log" --no-xclip \
  >"$temp_root/acl-user-report.txt"
grep -q 'nobody' "$temp_root/acl-user-report.txt"
grep -q "$temp_root/acl-root/direct" "$temp_root/acl-user-audit.log"

mapfile -t source_files < <(git ls-files '*.sh' 'ltree')
python3 .github/scripts/bash-trace-to-sonar.py \
  coverage/bash.trace \
  coverage/sonar-generic-coverage.xml \
  "${source_files[@]}"
