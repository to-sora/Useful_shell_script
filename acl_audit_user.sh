#!/usr/bin/env bash
set -euo pipefail

SCRIPT_NAME="$(basename "$0")"
VERSION="3.0"

usage() {
  cat <<'EOF'
Usage:
  acl_audit_user.sh DIR [--users u1,u2,...] [--debug-file FILE] [--no-xclip] [--show-others-placeholder]

Description:
  Scan:
    - target directory itself
    - first-layer child directories only

  Output:
    1) USER -> GROUP mapping
    2) DIR x USER access matrix
    3) DIR x USER default ACL matrix
    4) directory info
EOF
}

TARGET_DIR=""
USER_FILTER=""
DEBUG_FILE=""
NO_XCLIP=0
SHOW_OTHERS_PLACEHOLDER=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    --users)
      shift
      [[ $# -gt 0 ]] || { echo "missing value for --users" >&2; exit 1; }
      USER_FILTER="$1"
      shift
      ;;
    --debug-file)
      shift
      [[ $# -gt 0 ]] || { echo "missing value for --debug-file" >&2; exit 1; }
      DEBUG_FILE="$1"
      shift
      ;;
    --no-xclip)
      NO_XCLIP=1
      shift
      ;;
    --show-others-placeholder)
      SHOW_OTHERS_PLACEHOLDER=1
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
  DEBUG_FILE="/tmp/acl_matrix_${TS}.log"
fi

for cmd in find getfacl stat getent awk sed sort; do
  command -v "$cmd" >/dev/null 2>&1 || {
    echo "missing required command: $cmd" >&2
    exit 1
  }
done

TMP_DIRS="$(mktemp)"
TMP_ACL="$(mktemp)"
TMP_PASSWD="$(mktemp)"
TMP_GROUP="$(mktemp)"
TMP_RESULT_RAW="$(mktemp)"
TMP_RESULT_SORTED="$(mktemp)"
TMP_ERR="$(mktemp)"
trap 'rm -f "$TMP_DIRS" "$TMP_ACL" "$TMP_PASSWD" "$TMP_GROUP" "$TMP_RESULT_RAW" "$TMP_RESULT_SORTED" "$TMP_ERR"' EXIT

START_EPOCH="$(date +%s)"

find -P "${TARGET_DIR}" -mindepth 0 -maxdepth 1 -type d -print0 \
  | while IFS= read -r -d '' d; do
      printf '%s\n' "$d"
    done \
  | sort > "${TMP_DIRS}"

getent passwd > "${TMP_PASSWD}"
getent group > "${TMP_GROUP}"

{
  echo "=== ACL MATRIX DEBUG BUNDLE ==="
  echo "script=${SCRIPT_NAME}"
  echo "version=${VERSION}"
  echo "time=$(date -Is)"
  echo "target_dir=${TARGET_DIR}"
  echo "user_filter=${USER_FILTER}"
  echo "show_others_placeholder=${SHOW_OTHERS_PLACEHOLDER}"
  echo "user=$(id -un 2>/dev/null || true)"
  echo "uid=$(id -u 2>/dev/null || true)"
  echo "groups=$(id 2>/dev/null || true)"
  echo "hostname=$(hostname 2>/dev/null || true)"
  echo "kernel=$(uname -a 2>/dev/null || true)"
  echo "pwd=$(pwd)"
  echo "display=${DISPLAY:-}"
  echo "xdg_session_type=${XDG_SESSION_TYPE:-}"
  echo
  echo "=== SCAN DIRS ==="
  cat "${TMP_DIRS}"
  echo
  echo "=== ACL RAW ==="
} > "${DEBUG_FILE}"

while IFS= read -r dir; do
  owner="$(stat -c '%U' -- "$dir" 2>>"$TMP_ERR" || echo '?')"
  ogroup="$(stat -c '%G' -- "$dir" 2>>"$TMP_ERR" || echo '?')"
  mode="$(stat -c '%A' -- "$dir" 2>>"$TMP_ERR" || echo '?')"
  label="$(basename "$dir")"
  [[ "$dir" == "$TARGET_DIR" || "$dir" == "${TARGET_DIR%/}" ]] && label="$(basename "${TARGET_DIR%/}")"

  {
    echo "DIR|$dir|$label|$owner|$ogroup|$mode"
    getfacl -p -c -e --absolute-names -- "$dir" 2>>"$TMP_ERR" \
      | sed '/^#/d;/^$/d' \
      | while IFS= read -r line; do
          echo "ACL|$dir|$line"
        done
    echo "ENDDIR|$dir"
  } >> "${TMP_ACL}"

  {
    echo "DIR=$dir"
    echo "LABEL=$label"
    echo "OWNER=$owner"
    echo "GROUP=$ogroup"
    echo "MODE=$mode"
    getfacl -p -c -e --absolute-names -- "$dir" 2>>"$TMP_ERR" || true
    echo
  } >> "${DEBUG_FILE}"
done < "${TMP_DIRS}"

awk -F'|' -v user_filter="${USER_FILTER}" -v show_others_placeholder="${SHOW_OTHERS_PLACEHOLDER}" '
BEGIN {
  OFS="\t"
}

function trim(s) {
  sub(/^[ \t\r\n]+/, "", s)
  sub(/[ \t\r\n]+$/, "", s)
  return s
}

function perm_norm(p, c1, c2, c3, out) {
  p = trim(p)
  if (p == "") return "---"
  c1 = substr(p,1,1)
  c2 = substr(p,2,1)
  c3 = substr(p,3,1)

  out = ""
  out = out ((c1 == "r") ? "r" : "-")
  out = out ((c2 == "w") ? "w" : "-")
  out = out ((c3 == "x" || c3 == "s" || c3 == "t") ? "x" : "-")
  return out
}

function perm_and(a, b, out, i, ca, cb) {
  a = perm_norm(a)
  b = perm_norm(b)
  out = ""
  for (i=1; i<=3; i++) {
    ca = substr(a,i,1)
    cb = substr(b,i,1)
    if (ca != "-" && cb != "-") out = out ca
    else out = out "-"
  }
  return out
}

function perm_or(a, b, out, i, ca, cb) {
  a = perm_norm(a)
  b = perm_norm(b)
  out = ""
  for (i=1; i<=3; i++) {
    ca = substr(a,i,1)
    cb = substr(b,i,1)
    if (ca != "-") out = out ca
    else if (cb != "-") out = out cb
    else out = out "-"
  }
  return out
}

function add_group(g) {
  if (g == "" || g == "?") return
  groups_seen[g] = 1
}

function mark_candidate_user(u) {
  if (u == "" || u == "?") return
  candidate_user[u] = 1
}

function add_user_group(u, g) {
  if (u == "" || g == "" || u == "?" || g == "?") return
  user_group[u SUBSEP g] = 1
  all_users[u] = 1
  all_groups[g] = 1
}

function build_group_maps(line, parts, n, gname, gid, members, arr, i, user) {
  n = split(line, parts, ":")
  gname = parts[1]
  gid = parts[3]
  members = parts[4]
  gid_to_group[gid] = gname
  group_to_gid[gname] = gid
  all_groups[gname] = 1

  if (members != "") {
    split(members, arr, ",")
    for (i in arr) {
      user = trim(arr[i])
      if (user != "") add_user_group(user, gname)
    }
  }
}

function build_passwd_maps(line, parts, n, user, gid, gname) {
  n = split(line, parts, ":")
  user = parts[1]
  gid = parts[4]
  all_users[user] = 1
  passwd_gid[user] = gid
  gname = gid_to_group[gid]
  if (gname != "") add_user_group(user, gname)
}

function parse_acl_entry(dir, entry, raw, parts, n) {
  raw = entry
  sub(/[ \t]+#effective:.*/, "", raw)
  n = split(raw, parts, ":")

  if (parts[1] == "default") {
    has_default_acl[dir] = 1
    if (parts[2] == "user" && n == 4 && parts[3] == "") d_owner_perm[dir] = perm_norm(parts[4])
    else if (parts[2] == "user" && n == 4) { d_named_user_perm[dir SUBSEP parts[3]] = perm_norm(parts[4]); mark_candidate_user(parts[3]) }
    else if (parts[2] == "group" && n == 4 && parts[3] == "") d_group_obj_perm[dir] = perm_norm(parts[4])
    else if (parts[2] == "group" && n == 4) { d_named_group_perm[dir SUBSEP parts[3]] = perm_norm(parts[4]); add_group(parts[3]); relevant_group[parts[3]] = 1 }
    else if (parts[2] == "mask" && n == 4) d_mask_perm[dir] = perm_norm(parts[4])
    else if (parts[2] == "other" && n == 4) d_other_perm[dir] = perm_norm(parts[4])
    return
  }

  if (parts[1] == "user" && n == 3 && parts[2] == "") owner_perm[dir] = perm_norm(parts[3])
  else if (parts[1] == "user" && n == 3) { named_user_perm[dir SUBSEP parts[2]] = perm_norm(parts[3]); mark_candidate_user(parts[2]) }
  else if (parts[1] == "group" && n == 3 && parts[2] == "") group_obj_perm[dir] = perm_norm(parts[3])
  else if (parts[1] == "group" && n == 3) { named_group_perm[dir SUBSEP parts[2]] = perm_norm(parts[3]); add_group(parts[2]); relevant_group[parts[2]] = 1 }
  else if (parts[1] == "mask" && n == 2) mask_perm[dir] = perm_norm(parts[2])
  else if (parts[1] == "other" && n == 2) other_perm[dir] = perm_norm(parts[2])
}

function resolve_access(user, dir, og, gp, g, p, matched, k) {
  if (user == "__OTHER_USERS__") return other_perm[dir]
  if (user == dir_owner[dir]) return owner_perm[dir]

  k = dir SUBSEP user
  if (k in named_user_perm) {
    if (dir in mask_perm) return perm_and(named_user_perm[k], mask_perm[dir])
    return named_user_perm[k]
  }

  gp = "---"
  matched = 0
  og = dir_group[dir]

  if ((user SUBSEP og) in user_group) {
    matched = 1
    p = group_obj_perm[dir]
    if (dir in mask_perm) p = perm_and(p, mask_perm[dir])
    gp = perm_or(gp, p)
  }

  for (g in relevant_group) {
    if ((dir SUBSEP g) in named_group_perm && (user SUBSEP g) in user_group) {
      matched = 1
      p = named_group_perm[dir SUBSEP g]
      if (dir in mask_perm) p = perm_and(p, mask_perm[dir])
      gp = perm_or(gp, p)
    }
  }

  if (matched) return gp
  return other_perm[dir]
}

function resolve_default(user, dir, og, gp, g, p, matched) {
  if (!(dir in has_default_acl)) return "."
  if (user == "__OTHER_USERS__") return d_other_perm[dir]
  if (user == dir_owner[dir]) return d_owner_perm[dir]

  if ((dir SUBSEP user) in d_named_user_perm) {
    if (dir in d_mask_perm) return perm_and(d_named_user_perm[dir SUBSEP user], d_mask_perm[dir])
    return d_named_user_perm[dir SUBSEP user]
  }

  gp = "---"
  matched = 0
  og = dir_group[dir]

  if ((user SUBSEP og) in user_group) {
    matched = 1
    p = d_group_obj_perm[dir]
    if (dir in d_mask_perm) p = perm_and(p, d_mask_perm[dir])
    gp = perm_or(gp, p)
  }

  for (g in relevant_group) {
    if ((dir SUBSEP g) in d_named_group_perm && (user SUBSEP g) in user_group) {
      matched = 1
      p = d_named_group_perm[dir SUBSEP g]
      if (dir in d_mask_perm) p = perm_and(p, d_mask_perm[dir])
      gp = perm_or(gp, p)
    }
  }

  if (matched) return gp
  return d_other_perm[dir]
}

FNR == NR {
  build_group_maps($0)
  next
}

ARGIND == 2 {
  build_passwd_maps($0)
  next
}

{
  if ($1 == "DIR") {
    dir = $2
    label = $3
    owner = $4
    ogroup = $5
    mode = $6

    dir_list[++dir_count] = dir
    dir_label[dir] = label
    dir_owner[dir] = owner
    dir_group[dir] = ogroup
    dir_mode[dir] = mode

    mark_candidate_user(owner)
    relevant_group[ogroup] = 1
    add_group(ogroup)
  } else if ($1 == "ACL") {
    parse_acl_entry($2, $3)
  }
}

END {
  if (user_filter != "") {
    split(user_filter, arr, ",")
    for (i=1; i<=length(arr); i++) {
      u = trim(arr[i])
      if (u != "") filter_user[u] = 1
    }
  }

  for (g in relevant_group) {
    for (u in all_users) {
      if ((u SUBSEP g) in user_group) candidate_user[u] = 1
    }
  }

  for (u in candidate_user) {
    if (user_filter == "" || (u in filter_user)) {
      print "USERROW", u
    }
  }

  if (show_others_placeholder == 1) {
    print "USERROW", "__OTHER_USERS__"
  }

  print "SECTION", "USER_GROUP_MAPPING"
  print "HEADER", "USER", "GROUPS"

  for (u in candidate_user) {
    if (user_filter != "" && !(u in filter_user)) continue
    line = ""
    first = 1
    for (g in all_groups) {
      if ((u SUBSEP g) in user_group) {
        if (!first) line = line ","
        line = line g
        first = 0
      }
    }
    if (line == "") line = "-"
    print "MAP", u, line
  }

  if (show_others_placeholder == 1) {
    print "MAP", "__OTHER_USERS__", "(users not otherwise explicitly included)"
  }

  print "SECTION", "ACCESS_MATRIX"

  for (j=1; j<=dir_count; j++) {
    d = dir_list[j]
    for (u in candidate_user) {
      if (user_filter != "" && !(u in filter_user)) continue
      print "ACCESS", d, dir_label[d], u, resolve_access(u, d)
    }
    if (show_others_placeholder == 1) {
      print "ACCESS", d, dir_label[d], "__OTHER_USERS__", resolve_access("__OTHER_USERS__", d)
    }
  }

  has_any_default = 0
  for (d in has_default_acl) has_any_default = 1

  if (has_any_default) {
    print "SECTION", "DEFAULT_ACL_MATRIX"
    for (j=1; j<=dir_count; j++) {
      d = dir_list[j]
      for (u in candidate_user) {
        if (user_filter != "" && !(u in filter_user)) continue
        print "DEFAULT", d, dir_label[d], u, resolve_default(u, d)
      }
      if (show_others_placeholder == 1) {
        print "DEFAULT", d, dir_label[d], "__OTHER_USERS__", resolve_default("__OTHER_USERS__", d)
      }
    }
  }

  print "SECTION", "DIR_INFO"
  print "HEADER", "DIR", "OWNER", "GROUP", "MODE", "HAS_DEFAULT_ACL"
  for (j=1; j<=dir_count; j++) {
    d = dir_list[j]
    print "DIRINFO", dir_label[d], dir_owner[d], dir_group[d], dir_mode[d], ((d in has_default_acl) ? "yes" : "no")
  }
}
' "${TMP_GROUP}" "${TMP_PASSWD}" "${TMP_ACL}" > "${TMP_RESULT_RAW}"

sort "${TMP_RESULT_RAW}" > "${TMP_RESULT_SORTED}"

{
  echo "=== RESULT RAW ==="
  cat "${TMP_RESULT_RAW}"
  echo
  echo "=== RESULT SORTED ==="
  cat "${TMP_RESULT_SORTED}"
  echo
} >> "${DEBUG_FILE}"

if [[ -s "${TMP_ERR}" ]]; then
  {
    echo "=== STDERR / ERRORS ==="
    cat "${TMP_ERR}"
    echo
  } >> "${DEBUG_FILE}"
fi

USER_LIST="$(awk -F'\t' '$1=="USERROW"{print $2}' "${TMP_RESULT_SORTED}")"

echo "ACL Matrix Report"
echo "================================================================================"
echo "Target      : ${TARGET_DIR}"
echo "Scope       : target + first-layer child directories only"
echo "Duration    : $(( $(date +%s) - START_EPOCH ))s"
echo "Debug file  : ${DEBUG_FILE}"
echo "================================================================================"
echo

echo "USER -> GROUP Mapping"
echo "--------------------------------------------------------------------------------"
{
  printf 'USER\tGROUPS\n'
  awk -F'\t' '$1=="MAP"{print $2 "\t" $3}' "${TMP_RESULT_SORTED}" | sort
} | column -t -s $'\t'
echo

echo "Access Permission Matrix (DIR x USER)"
echo "--------------------------------------------------------------------------------"
{
  printf 'DIR'
  while IFS= read -r u; do
    [[ -n "$u" ]] && printf '\t%s' "$u"
  done <<< "${USER_LIST}"
  printf '\n'

  awk -F'\t' '$1=="ACCESS"{print $2 "\t" $3 "\t" $4 "\t" $5}' "${TMP_RESULT_SORTED}" \
  | awk -F'\t' '
    BEGIN { OFS="\t" }
    {
      dirkey=$1
      dirlabel=$2
      user=$3
      perm=$4
      dirs[dirkey]=dirlabel
      users[user]=1
      cell[dirkey SUBSEP user]=perm
    }
    END {
      user_count=0
      for (u in users) user_list[++user_count]=u

      dir_count=0
      for (d in dirs) dir_list[++dir_count]=d

      for (i=1; i<=dir_count; i++) {
        d=dir_list[i]
        row=dirs[d]
        for (j=1; j<=user_count; j++) {
          u=user_list[j]
          row=row OFS cell[d SUBSEP u]
        }
        print row
      }
    }'
} | column -t -s $'\t'
echo

if awk -F'\t' '$1=="DEFAULT"{found=1} END{exit !found}' "${TMP_RESULT_SORTED}"; then
  echo "Default ACL Matrix (DIR x USER)"
  echo "--------------------------------------------------------------------------------"
  {
    printf 'DIR'
    while IFS= read -r u; do
      [[ -n "$u" ]] && printf '\t%s' "$u"
    done <<< "${USER_LIST}"
    printf '\n'

    awk -F'\t' '$1=="DEFAULT"{print $2 "\t" $3 "\t" $4 "\t" $5}' "${TMP_RESULT_SORTED}" \
    | awk -F'\t' '
      BEGIN { OFS="\t" }
      {
        dirkey=$1
        dirlabel=$2
        user=$3
        perm=$4
        dirs[dirkey]=dirlabel
        users[user]=1
        cell[dirkey SUBSEP user]=perm
      }
      END {
        user_count=0
        for (u in users) user_list[++user_count]=u

        dir_count=0
        for (d in dirs) dir_list[++dir_count]=d

        for (i=1; i<=dir_count; i++) {
          d=dir_list[i]
          row=dirs[d]
          for (j=1; j<=user_count; j++) {
            u=user_list[j]
            row=row OFS cell[d SUBSEP u]
          }
          print row
        }
      }'
  } | column -t -s $'\t'
  echo
fi

echo "Directory Info"
echo "--------------------------------------------------------------------------------"
{
  printf 'DIR\tOWNER\tGROUP\tMODE\tHAS_DEFAULT_ACL\n'
  awk -F'\t' '$1=="DIRINFO"{print $2 "\t" $3 "\t" $4 "\t" $5 "\t" $6}' "${TMP_RESULT_SORTED}" | sort
} | column -t -s $'\t'
echo

echo "Legend"
echo "--------------------------------------------------------------------------------"
echo ".               = no default ACL on that directory"
echo "---             = no permission"
echo "--x             = traverse only"
echo "r-x             = read + traverse"
echo "rwx             = read + write + traverse"
echo "__OTHER_USERS__ = users not explicitly matched by owner / group / named ACL principals"
echo

if [[ "${NO_XCLIP}" -eq 0 ]] && command -v xclip >/dev/null 2>&1 && [[ -n "${DISPLAY:-}" ]]; then
  if xclip -selection clipboard -i < "${DEBUG_FILE}" 2>/dev/null; then
    echo "debug bundle copied to X clipboard via xclip"
  else
    echo "xclip found, but clipboard copy failed; debug file kept at ${DEBUG_FILE}"
  fi
else
  echo "xclip unavailable/disabled or DISPLAY missing; debug file kept at ${DEBUG_FILE}"
fi

echo
echo "Share debug"
echo "--------------------------------------------------------------------------------"
printf 'cat %q\n' "${DEBUG_FILE}"
echo "--------------------------------------------------------------------------------"
