#!/usr/bin/env bash
set -u
set -o pipefail

SCRIPT_NAME="$(basename "$0")"
VERSION="1.1"

usage() {
  cat <<'EOF'
Usage:
  acl_audit_first_layer.sh DIR [--no-color] [--debug-file FILE]

Description:
  Audit only:
    - the target directory itself
    - direct children under that directory

  Show:
    - path
    - type
    - owner
    - group
    - mode
    - ACL entries
    - default ACL entries
    - effective permissions comments from getfacl

Examples:
  ./acl_audit_first_layer.sh /mnt/DATA9
  ./acl_audit_first_layer.sh /mnt/DATA9 --no-color
EOF
}

NO_COLOR=0
DEBUG_FILE=""
TARGET_DIR=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    --no-color)
      NO_COLOR=1
      shift
      ;;
    --debug-file)
      shift
      [[ $# -gt 0 ]] || { echo "missing value for --debug-file" >&2; exit 1; }
      DEBUG_FILE="$1"
      shift
      ;;
    *)
      if [[ -z "${TARGET_DIR}" ]]; then
        TARGET_DIR="$1"
        shift
      else
        echo "unknown argument: $1" >&2
        usage
        exit 1
      fi
      ;;
  esac
done

[[ -n "${TARGET_DIR}" ]] || { usage; exit 1; }
[[ -d "${TARGET_DIR}" ]] || { echo "not a directory: ${TARGET_DIR}" >&2; exit 1; }

if [[ -z "${DEBUG_FILE}" ]]; then
  TS="$(date +%Y%m%d_%H%M%S)"
  DEBUG_FILE="/tmp/acl_audit_first_layer_${TS}.log"
fi

for cmd in find getfacl stat awk sed sort; do
  command -v "$cmd" >/dev/null 2>&1 || {
    echo "missing required command: $cmd" >&2
    exit 1
  }
done

if [[ "${NO_COLOR}" -eq 0 ]] && [[ -t 1 ]]; then
  C_RESET=$'\033[0m'
  C_BOLD=$'\033[1m'
  C_RED=$'\033[31m'
  C_GREEN=$'\033[32m'
  C_YELLOW=$'\033[33m'
  C_CYAN=$'\033[36m'
else
  C_RESET=""
  C_BOLD=""
  C_RED=""
  C_GREEN=""
  C_YELLOW=""
  C_CYAN=""
fi

line() {
  printf '%s\n' "----------------------------------------------------------------------------------------------------"
}

title() {
  printf '%b%s%b\n' "${C_BOLD}${C_CYAN}" "$1" "${C_RESET}"
}

kv() {
  printf '%b%-18s%b %s\n' "${C_BOLD}" "$1:" "${C_RESET}" "$2"
}

TMP_SUMMARY="$(mktemp)"
TMP_ACL="$(mktemp)"
TMP_ERR="$(mktemp)"
trap 'rm -f "$TMP_SUMMARY" "$TMP_ACL" "$TMP_ERR"' EXIT

START_EPOCH="$(date +%s)"

{
  echo "=== ACL AUDIT DEBUG BUNDLE ==="
  echo "script=${SCRIPT_NAME}"
  echo "version=${VERSION}"
  echo "time=$(date -Is)"
  echo "user=$(id -un 2>/dev/null || true)"
  echo "uid=$(id -u 2>/dev/null || true)"
  echo "groups=$(id 2>/dev/null || true)"
  echo "hostname=$(hostname 2>/dev/null || true)"
  echo "kernel=$(uname -a 2>/dev/null || true)"
  echo "target_dir=${TARGET_DIR}"
  echo "scan_scope=target + first-layer children only"
  echo "pwd=$(pwd)"
  echo "display=${DISPLAY:-}"
  echo "xdg_session_type=${XDG_SESSION_TYPE:-}"
  echo
  echo "=== TOOL VERSIONS ==="
  bash --version 2>/dev/null | head -n 1
  getfacl --version 2>/dev/null | head -n 1
  stat --version 2>/dev/null | head -n 1
  xclip -version 2>/dev/null | head -n 1 || true
  echo
  echo "=== MOUNT INFO ==="
  df -T "${TARGET_DIR}" 2>/dev/null || true
  echo
  echo "=== AUDIT OUTPUT ==="
} > "${DEBUG_FILE}"

TOTAL=0
DIRS=0
FILES=0
LINKS=0
ACL_OBJECTS=0
DEFAULT_ACL_DIRS=0
ERRORS=0

while IFS= read -r -d '' path; do
  TOTAL=$((TOTAL + 1))

  type_char="$(stat -c '%F' -- "$path" 2>>"$TMP_ERR" || echo '?')"
  mode_octal="$(stat -c '%a' -- "$path" 2>>"$TMP_ERR" || echo '?')"
  mode_human="$(stat -c '%A' -- "$path" 2>>"$TMP_ERR" || echo '?')"
  owner="$(stat -c '%U' -- "$path" 2>>"$TMP_ERR" || echo '?')"
  group="$(stat -c '%G' -- "$path" 2>>"$TMP_ERR" || echo '?')"

  case "$type_char" in
    directory) DIRS=$((DIRS + 1)) ;;
    "regular file") FILES=$((FILES + 1)) ;;
    "symbolic link") LINKS=$((LINKS + 1)) ;;
  esac

  ACL_OUT="$(getfacl -p -c -e --absolute-names -- "$path" 2>>"$TMP_ERR" || true)"

  has_acl=0
  has_default_acl=0

  if printf '%s\n' "$ACL_OUT" | grep -Eq '^(user:[^:]+:|group:[^:]+:|mask:)' ; then
    has_acl=1
    ACL_OBJECTS=$((ACL_OBJECTS + 1))
  fi

  if printf '%s\n' "$ACL_OUT" | grep -Eq '^default:' ; then
    has_default_acl=1
    DEFAULT_ACL_DIRS=$((DEFAULT_ACL_DIRS + 1))
  fi

  {
    echo "PATH=${path}"
    echo "TYPE=${type_char}"
    echo "OWNER=${owner}"
    echo "GROUP=${group}"
    echo "MODE=${mode_human} (${mode_octal})"
    echo "HAS_ACL=${has_acl}"
    echo "HAS_DEFAULT_ACL=${has_default_acl}"
    echo "--- GETFACL BEGIN ---"
    printf '%s\n' "$ACL_OUT"
    echo "--- GETFACL END ---"
    echo
  } >> "${DEBUG_FILE}"

  {
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "${path}" "${type_char}" "${owner}" "${group}" "${mode_human}" "${has_acl}" "${has_default_acl}"
  } >> "${TMP_SUMMARY}"

  {
    printf 'PATH: %s\n' "${path}"
    printf '  %-14s %s\n' "TYPE" "${type_char}"
    printf '  %-14s %s\n' "OWNER" "${owner}"
    printf '  %-14s %s\n' "GROUP" "${group}"
    printf '  %-14s %s (%s)\n' "MODE" "${mode_human}" "${mode_octal}"
    printf '  %-14s %s\n' "HAS_ACL" "${has_acl}"
    printf '  %-14s %s\n' "DEFAULT_ACL" "${has_default_acl}"

    acl_lines="$(printf '%s\n' "$ACL_OUT" | sed '/^#/d' | sed '/^$/d')"
    if [[ -n "${acl_lines}" ]]; then
      printf '  ACL\n'
      printf '%s\n' "${acl_lines}" | while IFS= read -r acl_line; do
        printf '    %s\n' "${acl_line}"
      done
    else
      printf '  ACL\n'
      printf '    %s\n' "(no acl output)"
    fi
    echo
  } >> "${TMP_ACL}"

done < <(find -P "${TARGET_DIR}" -mindepth 0 -maxdepth 1 -print0 2>>"$TMP_ERR")

if [[ -s "$TMP_ERR" ]]; then
  ERRORS="$(wc -l < "$TMP_ERR" | awk '{print $1}')"
  {
    echo "=== STDERR / ERRORS ==="
    cat "$TMP_ERR"
    echo
  } >> "${DEBUG_FILE}"
fi

END_EPOCH="$(date +%s)"
DURATION=$((END_EPOCH - START_EPOCH))

title "ACL Audit Report (First Layer Only)"
line
kv "Target" "${TARGET_DIR}"
kv "Scope" "target + direct children only"
kv "Duration" "${DURATION}s"
kv "Debug file" "${DEBUG_FILE}"
kv "Total objects" "${TOTAL}"
kv "Directories" "${DIRS}"
kv "Files" "${FILES}"
kv "Symlinks" "${LINKS}"
kv "Objects with ACL" "${ACL_OBJECTS}"
kv "Dirs with default ACL" "${DEFAULT_ACL_DIRS}"
kv "Error lines" "${ERRORS}"
line
echo

title "Compact Summary"
line
printf '%-56s %-14s %-12s %-12s %-11s %-7s %-11s\n' \
  "PATH" "TYPE" "OWNER" "GROUP" "MODE" "ACL" "DEF_ACL"
line
awk -F'\t' '
{
  path=$1; type=$2; owner=$3; group=$4; mode=$5; acl=$6; dacl=$7;
  if (length(path) > 56) path="..." substr(path, length(path)-52, 53);
  printf "%-56s %-14s %-12s %-12s %-11s %-7s %-11s\n", path, type, owner, group, mode, acl, dacl;
}
' "${TMP_SUMMARY}"
line
echo

title "Detailed ACL View"
line
cat "${TMP_ACL}"
line
echo

if command -v xclip >/dev/null 2>&1 && [[ -n "${DISPLAY:-}" ]]; then
  if xclip -selection clipboard -i < "${DEBUG_FILE}" 2>/dev/null; then
    printf '%b%s%b\n' "${C_GREEN}" "debug bundle copied to X clipboard via xclip" "${C_RESET}"
  else
    printf '%b%s%b\n' "${C_YELLOW}" "xclip found, but clipboard copy failed; debug file kept at ${DEBUG_FILE}" "${C_RESET}"
  fi
else
  printf '%b%s%b\n' "${C_YELLOW}" "xclip unavailable or DISPLAY missing; debug file kept at ${DEBUG_FILE}" "${C_RESET}"
fi

echo
title "Shareable Debug Command"
line
printf 'cat %q\n' "${DEBUG_FILE}"
line
