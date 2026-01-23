#!/usr/bin/env bash

###############################################################################
# USAGE:
#   mirror_links.sh <DIR_A> <SRC_ROOT_1> [SRC_ROOT_2 ... SRC_ROOT_N]
#
# Semantics:
#   - Create/overwrite symlinks under DIR_A mirroring files under each SRC_ROOT.
#   - If multiple SRC_ROOTs contain the same relative path, the later SRC_ROOT wins.
###############################################################################

err() { printf "ERROR: %s\n" "$*" >&2; exit 1; }

need_dir() {
  local d="$1"
  [[ -d "$d" ]] || err "Directory not found: $d"
}

link_tree() {
  local src_root="$1"
  local src_label="$2"
  local dst_root="$3"

  # Use process substitution to avoid pipefail dependency and keep exit status.
  while IFS= read -r -d '' src_path; do
    # Relative path within SRC_ROOT
    rel="${src_path#"$src_root"/}"

    # Destination path in A
    dst_path="$dst_root/$rel"
    dst_dir="$(dirname "$dst_path")"

    mkdir -p "$dst_dir" || err "mkdir failed: $dst_dir"

    # Force replace existing (so later passes can win)
    ln -sfn "$src_path" "$dst_path" || err "ln failed: $src_path -> $dst_path"
  done < <(find "$src_root" -type f -print0) || err "find failed under: $src_root"

  printf "Linked from %s: %s -> %s\n" "$src_label" "$src_root" "$dst_root"
}

###############################################################################
# MAIN
###############################################################################
[[ $# -ge 2 ]] || err "Usage: $0 <DIR_A> <SRC_ROOT_1> [SRC_ROOT_2 ...]"

DIR_A="$1"
shift

need_dir "$DIR_A"

# Validate all source roots first (fail fast)
i=1
for src in "$@"; do
  need_dir "$src"
  i=$((i + 1))
done

# Process sources in the given order; later sources overwrite earlier ones.
i=1
for src in "$@"; do
  link_tree "$src" "SRC#$i" "$DIR_A"
  i=$((i + 1))
done

echo "Done. Conflict policy: later sources win (later overwrote any same-path names from earlier)."
