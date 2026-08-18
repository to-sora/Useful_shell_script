#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$repo_root"

mkdir -p coverage
: > coverage/bash.trace

while IFS= read -r -d '' script; do
  bash -n "$script"
done < <(git ls-files -z '*.sh' 'ltree')

temp_root="$(mktemp -d)"
trap 'rm -rf "$temp_root"' EXIT
mkdir -p "$temp_root/destination" "$temp_root/source-a/nested" "$temp_root/source-b/nested"
printf 'first\n' > "$temp_root/source-a/nested/shared.txt"
printf 'second\n' > "$temp_root/source-b/nested/shared.txt"
mkdir -p "$temp_root/fake-venv/bin" "$temp_root/fake-venv/lib"
: > "$temp_root/fake-venv/bin/activate"
git init -q "$temp_root/repository"

trace() {
  BASH_XTRACEFD=3 \
    PS4='+TRACE:${BASH_SOURCE[0]}:${LINENO}:' \
    bash -x "$@" 3>> coverage/bash.trace
}

trace ./syslink_builder.sh \
  "$temp_root/destination" \
  "$temp_root/source-a" \
  "$temp_root/source-b"
test -L "$temp_root/destination/nested/shared.txt"
test "$(readlink "$temp_root/destination/nested/shared.txt")" = \
  "$temp_root/source-b/nested/shared.txt"

trace ./ltree -D 2 -L 2 "$temp_root/source-b" -o "$temp_root/tree.txt"
grep -q 'shared.txt' "$temp_root/tree.txt"

trace ./get_vev_size.sh "$temp_root"
trace ./get_repo_size.sh "$temp_root"

mapfile -t source_files < <(git ls-files '*.sh' 'ltree')
python3 .github/scripts/bash-trace-to-sonar.py \
  coverage/bash.trace \
  coverage/sonar-generic-coverage.xml \
  "${source_files[@]}"
