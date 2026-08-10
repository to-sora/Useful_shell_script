#!/usr/bin/env bash

set -u
set -o pipefail

# ============================================================
# Configuration
# ============================================================

# These directories are searched recursively.
RECURSIVE_DIRS=(
    "$HOME/.private_repo/AI_note/AIC"
    "$HOME/.private_repo/AI_note/other"
)

# These directories are searched only at the top level.
FLAT_DIRS=(
    "$HOME/.private_repo/AI_note/"
   
)

# LaTeX compiler options.
LATEX_COMMAND=(pdflatex)
LATEX_OPTIONS=(
    -interaction=nonstopmode
    -halt-on-error
    -file-line-error
)

# ============================================================
# Functions
# ============================================================

usage() {
    cat <<'USAGE'
Usage:
  latex-build.sh
      Find and compile the newest outdated .tex file.

  latex-build.sh file1.tex [file2.tex ...]
      Compile the specified .tex files.

Configuration:
  Edit RECURSIVE_DIRS and FLAT_DIRS in this script.
USAGE
}

die() {
    printf 'Error: %s\n' "$*" >&2
    exit 1
}

is_tex_file() {
    [[ "$1" == *.tex ]]
}

pdf_for_tex() {
    local tex_file="$1"
    printf '%s.pdf\n' "${tex_file%.tex}"
}

is_outdated() {
    local tex_file="$1"
    local pdf_file

    pdf_file="$(pdf_for_tex "$tex_file")"

    # The PDF must be rebuilt when it does not exist or the TEX file
    # has a newer modification time than the PDF.
    [[ ! -f "$pdf_file" || "$tex_file" -nt "$pdf_file" ]]
}

open_pdf() {
    local pdf_file="$1"
    local windows_path

    if [[ ! -f "$pdf_file" ]]; then
        printf 'Warning: PDF was not found: %s\n' "$pdf_file" >&2
        return 1
    fi

    if ! command -v explorer.exe >/dev/null 2>&1; then
        printf 'PDF created: %s\n' "$pdf_file"
        printf 'explorer.exe is not available in this WSL environment.\n' >&2
        return 0
    fi

    windows_path="$(wslpath -w "$pdf_file")" || {
        printf 'Warning: cannot convert path: %s\n' "$pdf_file" >&2
        return 1
    }

    explorer.exe "$windows_path" >/dev/null 2>&1 &
}

compile_tex() {
    local tex_file="$1"
    local tex_dir
    local tex_name
    local pdf_file
    local exit_code

    [[ -f "$tex_file" ]] || {
        printf 'Error: file does not exist: %s\n' "$tex_file" >&2
        return 1
    }

    is_tex_file "$tex_file" || {
        printf 'Error: not a .tex file: %s\n' "$tex_file" >&2
        return 1
    }

    tex_file="$(realpath "$tex_file")"
    tex_dir="$(dirname "$tex_file")"
    tex_name="$(basename "$tex_file")"
    pdf_file="$(pdf_for_tex "$tex_file")"

    printf '\nCompiling: %s\n' "$tex_file"

    (
        cd "$tex_dir" || exit 1
        "${LATEX_COMMAND[@]}" \
            "${LATEX_OPTIONS[@]}" \
            "$tex_name"
    )

    exit_code=$?

    if [[ "$exit_code" -ne 0 ]]; then
        printf 'Compilation failed: %s\n' "$tex_file" >&2
        return "$exit_code"
    fi

    if [[ ! -f "$pdf_file" ]]; then
        printf 'Compilation reported success, but PDF was not found: %s\n' \
            "$pdf_file" >&2
        return 1
    fi

    printf 'Created: %s\n' "$pdf_file"
    open_pdf "$pdf_file"
}

collect_files() {
    local directory
    local file

    # Recursive directories.
    for directory in "${RECURSIVE_DIRS[@]}"; do
        [[ -d "$directory" ]] || {
            printf 'Warning: recursive directory not found: %s\n' \
                "$directory" >&2
            continue
        }

        while IFS= read -r -d '' file; do
            printf '%s\0' "$file"
        done < <(
            find "$directory" \
                -type f \
                -name '*.tex' \
                -print0
        )
    done

    # Flat directories: do not descend into subdirectories.
    for directory in "${FLAT_DIRS[@]}"; do
        [[ -d "$directory" ]] || {
            printf 'Warning: flat directory not found: %s\n' \
                "$directory" >&2
            continue
        }

        while IFS= read -r -d '' file; do
            printf '%s\0' "$file"
        done < <(
            find "$directory" \
                -maxdepth 1 \
                -type f \
                -name '*.tex' \
                -print0
        )
    done
}

find_newest_outdated() {
    local file
    local newest_file=''
    local newest_timestamp=0
    local timestamp

    # Associative array prevents duplicate files when directories overlap.
    declare -A seen=()

    while IFS= read -r -d '' file; do
        file="$(realpath "$file")"

        [[ -n "${seen["$file"]+yes}" ]] && continue
        seen["$file"]=1

        is_outdated "$file" || continue

        timestamp="$(stat -c '%Y' "$file")"

        if [[ "$timestamp" -gt "$newest_timestamp" ]]; then
            newest_timestamp="$timestamp"
            newest_file="$file"
        fi
    done < <(collect_files)

    printf '%s' "$newest_file"
}

# ============================================================
# Main
# ============================================================

if ! command -v pdflatex >/dev/null 2>&1; then
    die "pdflatex was not found. Install a LaTeX distribution in WSL."
fi

# With arguments: compile every explicitly supplied file.
if [[ "$#" -gt 0 ]]; then
    [[ "$1" != '-h' && "$1" != '--help' ]] || {
        usage
        exit 0
    }

    failed=0

    for tex_file in "$@"; do
        if ! compile_tex "$tex_file"; then
            failed=1
        fi
    done

    exit "$failed"
fi

# Without arguments: compile the newest outdated file.
selected_file="$(find_newest_outdated)"

if [[ -z "$selected_file" ]]; then
    printf 'No outdated .tex file was found.\n'
    exit 0
fi

compile_tex "$selected_file"