#!/usr/bin/env bash
# Native Bash CPython patch updater. No embedded or generated Python source.
# See update_python_envs.md for trusted roots, backups, and examples.
set -Eeuo pipefail
umask 077
export LC_ALL=C
SELF="$(realpath -e -- "${BASH_SOURCE[0]}")"
MARKER='.pyenv-update-'
WORK=''
declare -a ROOTS=() EXCLUDES=() TARGET_SPECS=() LOCK_FDS=()
OUTPUT='' CHECKS='' COMMAND='' JOURNAL=''
declare -A FLOORS=([3.8]=3.8.20 [3.10]=3.10.22 [3.11]=3.11.18 [3.13]=3.13.18)
declare -A EOL=([3.8]=2024-10-07 [3.9]=2025-10-31 [3.10]=2026-10-01)
die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 2
}
now() { date -u +%FT%TZ; }
cleanup() { [[ -z "$WORK" ]] || rm -rf -- "$WORK"; }
trap cleanup EXIT
usage() {
  cat <<'HELP'
Usage:
  update_python_envs.sh scan ROOT... --output inventory.json
  update_python_envs.sh plan ROOT... --target MINOR=/patched/bin/python --output plan.json
  update_python_envs.sh apply ROOT... --target MINOR=/patched/bin/python --output journal.json
  update_python_envs.sh verify JOURNAL --output verification.json
  update_python_envs.sh rollback JOURNAL

Options: --exclude PATH (repeatable), --checks checks.json (apply/verify).
Discovery follows directory links and probes actual ELF interpreter binaries.
All control flow, discovery, JSON, copying, validation, and recovery use Bash and
Unix utilities. Python is invoked through existing version/module commands.
Stop applications before apply or rollback. Use trusted private installation roots.
HELP
}
require_tools() {
  local tool
  [[ ${BASH_VERSINFO[0]} -ge 4 ]] || die 'Bash 4 or newer is required'
  for tool in jq find realpath stat readlink sha256sum rsync cp mv mktemp flock timeout awk sort sync od; do
    command -v "$tool" >/dev/null || die "Required utility missing: $tool"
  done
}
root_guard() {
  if [[ $EUID -eq 0 ]]; then
    local mapping=''
    [[ ! -r /proc/self/uid_map ]] || mapping="$(awk '{$1=$1;print}' /proc/self/uid_map)"
    [[ $mapping == '0 0 1' ]] || die 'Run as the installation owner, without sudo'
  fi
}
safe_path() { [[ $1 != *$'\n'* && $1 != *$'\r'* && $1 != *$'\t'* ]] || die 'Paths containing tabs or line breaks are unsupported'; }
absolute() {
  safe_path "$1"
  realpath -ms -- "$1"
}
canonical() {
  safe_path "$1"
  realpath -e -- "$1"
}
within() { [[ $1 == "$2" || $1 == "$2/"* ]]; }
stable_version() { [[ $1 =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; }
minor() { printf '%s\n' "${1%.*}"; }
is_python_name() { [[ $1 =~ ^python([0-9]+(\.[0-9]+)*)?$ ]]; }
is_standard() { [[ $1 == python || $1 == python3 || $1 == "python$2" ]]; }
is_elf() {
  [[ -f $1 && -x $1 ]] || return 1
  [[ $(od -An -N4 -tx1 -- "$1" 2>/dev/null | tr -d ' \n') == 7f454c46 ]]
}
runpy() {
  local name
  local -a environment=(env -u VIRTUAL_ENV -u CONDA_PREFIX)
  for name in ${!PYTHON@}; do environment+=(-u "$name"); done
  timeout --kill-after=5 "${PY_TIMEOUT:-120}" "${environment[@]}" PIP_DISABLE_PIP_VERSION_CHECK=1 PIP_NO_INPUT=1 "$@"
}
config_value() {
  awk -v key="$2" '$1==key && $2=="=" {sub(/^[^=]*= \"/, "");sub(/\"$/, "");print;exit}' "$1"
}
# The sysconfig module CLI supplies identity and ABI without inline code.
probe() {
  local binary version report prefix base abi shared bits pure plat machine configured managed='private'
  binary="$(absolute "$1")"
  is_elf "$binary" || return 1
  version="$(PY_TIMEOUT=45 runpy "$binary" -I --version 2>/dev/null)" || return 1
  version=${version#Python }
  stable_version "$version" || return 1
  report="$(mktemp "$WORK/sysconfig.XXXXXX")"
  if ! PY_TIMEOUT=45 runpy "$binary" -I -m sysconfig >"$report" 2>/dev/null; then
    rm -f -- "$report"
    return 1
  fi
  prefix="$(config_value "$report" base)"
  base="$(config_value "$report" installed_base)"
  configured="$(config_value "$report" prefix)"
  abi="$(config_value "$report" SOABI)"
  shared="$(config_value "$report" Py_ENABLE_SHARED)"
  bits="$(config_value "$report" SIZEOF_VOID_P)"
  pure="$(config_value "$report" purelib)"
  plat="$(config_value "$report" platlib)"
  machine="$(awk '/^Platform:/ {sub(/^Platform: \"/, "");sub(/\"$/, "");print;exit}' "$report")"
  rm -f -- "$report"
  [[ $prefix == /* && $base == /* && $abi == cpython-* && $bits =~ ^[0-9]+$ && $shared =~ ^[01]$ ]] || return 1
  prefix="$(canonical "$prefix")"
  base="$(canonical "$base")"
  if [[ -d $prefix/conda-meta ]]; then
    managed=conda
  elif [[ -f $prefix/info/index.json ]] && jq -e '.name=="python"' "$prefix/info/index.json" >/dev/null 2>&1; then managed=conda-package-cache; fi
  jq -cn --arg binary "$binary" --arg resolved "$(canonical "$binary")" --arg version "$version" \
    --arg prefix "$prefix" --arg base "$base" --arg soabi "$abi" --argjson shared "$shared" \
    --argjson bytes "$bits" --arg machine "$machine" --arg managed "$managed" --arg purelib "$pure" --arg platlib "$plat" --arg configured_prefix "$configured" \
    '{binary:$binary,resolved:$resolved,version:$version,prefix:$prefix,base_prefix:$base,soabi:$soabi,
      shared:$shared,pointer_bits:($bytes*8),machine:$machine,managed:$managed,purelib:$purelib,platlib:$platlib,configured_prefix:$configured_prefix,
      kind:(if $prefix==$base then "raw" else "venv" end)}'
}
atomic_write() {
  local destination=$1 temp
  mkdir -p -- "$(dirname -- "$destination")"
  temp="$(mktemp "${destination}.tmp.XXXXXX")"
  cat >"$temp"
  sync -d "$temp"
  mv -f -- "$temp" "$destination"
  sync -f "$(dirname -- "$destination")"
}
json_edit() {
  local destination=$1 temp
  shift
  temp="$(mktemp "$WORK/json.XXXXXX")"
  jq "$@" "$destination" >"$temp"
  atomic_write "$destination" <"$temp"
  rm -f -- "$temp"
}
event() { jq -cn --arg event "$1" --arg prefix "${2:-}" --arg detail "${3:-}" '{event:$event,prefix:$prefix,detail:$detail}'; }
warning() { jq -cn --arg path "$1" --arg reason "$2" '{path:$path,reason:$reason}' >>"$WORK/warnings.ndjson"; }
scan() {
  local destination=$1 root path name info base mm bin exclude line prefix skip status=0
  local -a find_roots=() canonical_excludes=() expression=('(' -name "*$MARKER*" -prune)
  local -A seen=() prefixes=()
  : >"$WORK/candidates"
  : >"$WORK/probes.ndjson"
  : >"$WORK/warnings.ndjson"
  : >"$WORK/links.ndjson"
  for exclude in "${EXCLUDES[@]}"; do
    canonical_excludes+=("$(realpath -m -- "$exclude")")
    expression+=(-o -path "$(absolute "$exclude")" -prune -o -path "${canonical_excludes[-1]}" -prune)
  done
  expression+=(')' -o '(' -name pyvenv.cfg -o -path '*/bin/python*' -o -xtype l ')' -print0)
  for root in "${ROOTS[@]}"; do
    root="$(absolute "$root")"
    if [[ -e $root || -L $root ]]; then find_roots+=("$root"); else warning "$root" 'Missing search root'; fi
    [[ ! -f $root ]] || printf '%s\0' "$root" >>"$WORK/candidates"
  done
  if ((${#find_roots[@]})); then
    find -L "${find_roots[@]}" "${expression[@]}" >"$WORK/found" 2>"$WORK/find-errors" || status=$?
    while IFS= read -r line; do warning '' "$line"; done <"$WORK/find-errors"
    while IFS= read -r -d '' path; do
      safe_path "$path"
      if [[ -L $path ]]; then
        jq -cn --arg path "$path" --arg target "$(realpath -m -- "$path")" '{path:$path,target:$target}' >>"$WORK/links.ndjson"
        [[ -e $path ]] || warning "$path" 'Broken link'
      fi
      name=${path##*/}
      if [[ $name == pyvenv.cfg && -f $path ]]; then
        bin=${path%/*}/bin
        if [[ -d $bin ]]; then
          find "$bin" -mindepth 1 -maxdepth 1 -name 'python*' -print0 >>"$WORK/candidates"
        else warning "${path%/*}" 'pyvenv.cfg has no bin directory'; fi
      elif is_python_name "$name"; then printf '%s\0' "$path" >>"$WORK/candidates"; fi
    done <"$WORK/found"
  fi
  while IFS= read -r -d '' path; do
    name=${path##*/}
    is_python_name "$name" || continue
    [[ ! ${seen[$path]+yes} ]] || continue
    seen[$path]=1
    if info="$(probe "$path")"; then
      prefix="$(jq -r .prefix <<<"$info")"
      skip=0
      for exclude in "${canonical_excludes[@]}"; do
        if within "$prefix" "$exclude"; then
          skip=1
          break
        fi
      done
      ((skip == 0)) || continue
      printf '%s\n' "$info" >>"$WORK/probes.ndjson"
      prefixes[$prefix]=1
    else warning "$path" 'Missing, non-ELF, or unusable CPython interpreter'; fi
  done <"$WORK/candidates"
  cp -- "$WORK/probes.ndjson" "$WORK/references.ndjson"
  while IFS= read -r info; do
    [[ $(jq -r .kind <<<"$info") == venv ]] || continue
    base="$(jq -r .base_prefix <<<"$info")"
    [[ ! ${prefixes[$base]+yes} ]] || continue
    mm="$(minor "$(jq -r .version <<<"$info")")"
    if info="$(probe "$base/bin/python$mm")"; then
      jq -c '.+{referenced_only:true}' <<<"$info" >>"$WORK/probes.ndjson"
      prefixes[$base]=1
    else warning "$base" 'Referenced raw base has no usable versioned binary'; fi
  done <"$WORK/references.ndjson"
  jq -s 'group_by(.prefix)|map(.[0] as $first|$first+{aliases:(map(.binary)|unique),
    binaries:map({path:.binary,version:.version,resolved:.resolved}),versions:(map(.version)|unique)})|sort_by(.prefix)' "$WORK/probes.ndjson" >"$WORK/environments.json"
  jq -n --arg created "$(now)" --argjson walk_status "$status" --slurpfile environments "$WORK/environments.json" \
    --slurpfile warnings "$WORK/warnings.ndjson" --slurpfile links "$WORK/links.ndjson" \
    '{created:$created,engine:"bash",walk_status:$walk_status,environments:$environments[0],warnings:$warnings,symlinks:$links}' | atomic_write "$destination"
}
load_targets() {
  local spec mm path info version prefix floor
  : >"$WORK/targets.ndjson"
  for spec in "${TARGET_SPECS[@]}"; do
    [[ $spec == *=* ]] || die 'Target syntax: MINOR=/absolute/path/bin/python'
    mm=${spec%%=*}
    path=${spec#*=}
    [[ ${FLOORS[$mm]+yes} ]] || die "No tested release policy for Python $mm"
    info="$(probe "$path")" || die "Target is not a working CPython ELF interpreter: $path"
    version="$(jq -r .version <<<"$info")"
    prefix="$(jq -r .prefix <<<"$info")"
    floor=${FLOORS[$mm]}
    [[ $(minor "$version") == "$mm" ]] || die 'Cross-minor target refused'
    [[ $(jq -r .kind <<<"$info") == raw ]] || die 'Target must be a raw installation'
    ((10#${version##*.} >= 10#${floor##*.})) || die "Target is below policy floor $floor"
    [[ $(jq -r .managed <<<"$info") == private ]] || die 'Conda cannot serve as a raw CPython patch target'
    jq -c --arg minor "$mm" '.+{minor:$minor}' <<<"$info" >>"$WORK/targets.ndjson"
    EXCLUDES+=("$prefix")
  done
  jq -s 'if ([.[].minor]|length)!=([.[].minor]|unique|length) then error("Duplicate target branch") else map({key:.minor,value:.})|from_entries end' "$WORK/targets.ndjson" >"$WORK/targets.json"
}
protected() {
  local root
  for root in /usr /bin /sbin /lib /lib64 /System /opt/codex; do within "$1" "$root" && return 0; done
  return 1
}
make_plan() {
  local inventory=$1 destination=$2 item prefix kind version mm target reason candidate newer flag unresolved name patch
  : >"$WORK/plan.ndjson"
  while IFS= read -r item; do
    prefix="$(jq -r .prefix <<<"$item")"
    kind="$(jq -r .kind <<<"$item")"
    version="$(jq -r .version <<<"$item")"
    mm=$(minor "$version")
    target="$(jq -c --arg mm "$mm" '.[$mm]//null' "$WORK/targets.json")"
    reason=''
    unresolved='[]'
    flag=0
    while IFS= read -r -d '' candidate; do
      name=${candidate##*/}
      is_python_name "$name" || continue
      if ! is_elf "$candidate"; then
        if is_standard "$name" "$mm"; then flag=1; else unresolved="$(jq -c --arg name "$name" '.+[$name]' <<<"$unresolved")"; fi
      fi
    done < <(find "$prefix/bin" -mindepth 1 -maxdepth 1 -name 'python*' -print0)
    if [[ $(jq -r .managed <<<"$item") != private ]]; then
      reason='Conda-managed prefix/cache: use the Conda solver'
    elif protected "$prefix"; then
      reason='Distribution/runtime-managed prefix'
    elif [[ -L $prefix/bin || -L $prefix/lib ]]; then
      reason='Linked bin/lib subdirectories require a separate rebuild'
    elif [[ $(jq -r '.referenced_only//false' <<<"$item") == true ]]; then
      reason='Referenced raw base outside searched trees; add it as a root'
    elif [[ $target == null ]]; then
      reason='Target interpreter missing'
    elif [[ $(jq '[.versions[]|split(".")[0:2]|join(".")]|unique|length' <<<"$item") != 1 ]]; then
      reason='Multiple minor branches share a prefix'
    elif [[ $(jq -c '[.soabi,.shared,.pointer_bits,.machine]' <<<"$item") != "$(jq -c '[.soabi,.shared,.pointer_bits,.machine]' <<<"$target")" ]]; then
      reason='Interpreter ABI/build mismatch'
    else
      newer=0
      patch="$(jq -r '.version|split(".")[-1]' <<<"$target")"
      while IFS= read -r candidate; do ((10#${candidate##*.} <= 10#$patch)) || newer=1; done < <(jq -r '.versions[]' <<<"$item")
      if ((newer)); then
        reason='Downgrade refused'
      elif [[ $(jq -c .versions <<<"$item") == "$(jq -c '[.version]' <<<"$target")" && $flag == 0 ]]; then
        reason=up_to_date
      elif [[ $kind == raw && $(jq -r .shared <<<"$item") != 0 ]]; then
        reason='Shared raw build requires a prefix-specific rebuild'
      elif [[ $kind == raw ]] && within "$(jq -r .prefix <<<"$target")" "$prefix"; then
        reason='Target is inside the source prefix'
      elif [[ $(stat -Lc %u -- "$prefix") != "$EUID" || ! -w $(dirname -- "$prefix") ]]; then reason='Prefix ownership or parent write access does not permit updating'; fi
    fi
    jq -c --arg reason "$reason" --arg eol "${EOL[$mm]:-}" --argjson target "$target" --argjson unresolved "$unresolved" \
      '.+{target:$target,eol:$eol,unresolved_aliases:$unresolved,action:(if $reason=="" then "update" else "skip" end),reason:$reason}' <<<"$item" >>"$WORK/plan.ndjson"
  done < <(jq -c '.environments[]' "$inventory")
  jq -n --slurpfile inventory "$inventory" --slurpfile plan "$WORK/plan.ndjson" \
    '{engine:"bash",inventory:$inventory[0],plan:($plan|sort_by(.kind!="raw",.prefix))}' | atomic_write "$destination"
}

# Read installed distribution records with awk/jq, including inherited packages.
packages() {
  local prefix=$1 destination=$2 info site scope metadata name version path metadata_file base mm index
  local -a sites=() scopes=()
  local -A seen_sites=()
  info="$(probe "$(choose_binary "$prefix")")" || return 1
  base="$(jq -r .base_prefix <<<"$info")"
  mm="$(minor "$(jq -r .version <<<"$info")")"
  sites+=("$prefix/lib/python$mm/site-packages" "$prefix/lib64/python$mm/site-packages" "$prefix/lib/python$mm/dist-packages")
  scopes+=(local local local)
  if [[ $base != "$prefix" && -f $prefix/pyvenv.cfg ]] && awk -F= '$1~/^include-system-site-packages *$/ && $2~/true/ {found=1} END{exit !found}' "$prefix/pyvenv.cfg"; then
    sites+=("$base/lib/python$mm/site-packages" "$base/lib64/python$mm/site-packages" "$base/lib/python$mm/dist-packages")
    scopes+=(base base base)
  fi
  : >"$WORK/packages.ndjson"
  : >"$WORK/empty-metadata.ndjson"
  for index in "${!sites[@]}"; do
    site=${sites[$index]}
    scope=${scopes[$index]}
    [[ -d $site ]] || continue
    site="$(canonical "$site")"
    [[ ! ${seen_sites[$site]+yes} ]] || continue
    seen_sites[$site]=1
    while IFS= read -r -d '' metadata; do
      if [[ -d $metadata ]]; then
        metadata_file=$metadata/METADATA
        [[ -f $metadata_file ]] || metadata_file=$metadata/PKG-INFO
      else metadata_file=$metadata; fi
      if [[ ! -f $metadata_file ]]; then
        path="$(find -P "$metadata" \( -type f -o -type l \) -print -quit)"
        if [[ -z $path ]]; then
          jq -cn --arg path "$metadata" '{path:$path}' >>"$WORK/empty-metadata.ndjson"
          continue
        fi
        printf 'Incomplete distribution metadata: %s\n' "$metadata" >&2
        return 1
      fi
      name="$(awk '/^Name: / {sub(/^Name: /, "");sub(/\r$/, "");print;exit}' "$metadata_file")"
      version="$(awk '/^Version: / {sub(/^Version: /, "");sub(/\r$/, "");print;exit}' "$metadata_file")"
      [[ -n $name && -n $version ]] || {
        printf 'Incomplete distribution metadata: %s\n' "$metadata" >&2
        return 1
      }
      jq -cn --arg name "$name" --arg version "$version" --arg scope "$scope" \
        '{name:($name|ascii_downcase|gsub("[-_.]+";"-")),version:$version,scope:$scope}' >>"$WORK/packages.ndjson"
    done < <(find "$site" -mindepth 1 -maxdepth 1 \( -name '*.dist-info' -o -name '*.egg-info' \) -print0)
  done
  jq -n --slurpfile packages "$WORK/packages.ndjson" --slurpfile ignored "$WORK/empty-metadata.ndjson" \
    '{packages:($packages|sort_by(.scope,.name,.version)),ignored_empty_metadata:$ignored}' >"$destination"
}
choose_binary() {
  local prefix=$1 path name
  for name in python python3; do is_elf "$prefix/bin/$name" && {
    printf '%s\n' "$prefix/bin/$name"
    return
  }; done
  while IFS= read -r -d '' path; do
    name=${path##*/}
    is_python_name "$name" || continue
    is_elf "$path" && {
      printf '%s\n' "$path"
      return
    }
  done < <(find "$prefix/bin" -mindepth 1 -maxdepth 1 -name 'python*' -print0)
  return 1
}
hashes() {
  local prefix=$1 kind=$2 destination=$3 path relative hash name
  : >"$WORK/hashes.ndjson"
  while IFS= read -r -d '' path; do
    name=${path##*/}
    if [[ $path == "$prefix/bin/"* ]]; then is_python_name "$name" || continue; fi
    [[ -f $path ]] || continue
    hash="$(sha256sum -- "$path")"
    hash=${hash%% *}
    relative=${path#"$prefix/"}
    jq -cn --arg path "$relative" --arg sha256 "$hash" '{path:$path,sha256:$sha256}' >>"$WORK/hashes.ndjson"
  done < <(
    find "$prefix/bin" -mindepth 1 -maxdepth 1 -name 'python*' -print0
    if [[ $kind == raw ]]; then find "$prefix/lib" -type f \( -path '*/lib-dynload/*.so' -o -path '*/python*/tarfile.py' -o -path '*/python*/ssl.py' -o -path '*/python*/urllib/request.py' \) -print0; fi
  )
  jq -s 'sort_by(.path)' "$WORK/hashes.ndjson" >"$destination"
}
check_hashes() {
  local prefix=$1 manifest=$2 record path expected actual
  while IFS= read -r record; do
    path="$(jq -r .path <<<"$record")"
    expected="$(jq -r .sha256 <<<"$record")"
    [[ -f $prefix/$path ]] || {
      printf 'Missing runtime file: %s\n' "$prefix/$path" >&2
      return 1
    }
    actual="$(sha256sum -- "$prefix/$path")"
    actual=${actual%% *}
    [[ $actual == "$expected" ]] || {
      printf 'Runtime integrity mismatch: %s\n' "$prefix/$path" >&2
      return 1
    }
  done < <(jq -c '.[]' "$manifest")
}
application_checks() {
  local prefix=$1 logical=$2 binary=$3 phase=$4 config=$5 pattern check argument output seconds
  local -a argv=()
  [[ -n $config ]] || return 0
  while IFS= read -r pattern; do
    [[ $logical == $pattern ]] || continue
    while IFS= read -r check; do
      [[ $phase == final || $(jq -r '.final_only//false' <<<"$check") != true ]] || continue
      argv=()
      while IFS= read -r -d '' argument; do
        argument=${argument//\{python\}/$binary}
        argument=${argument//\{prefix\}/$prefix}
        argv+=("$argument")
      done < <(jq -j '.argv[]|.,"\u0000"' <<<"$check")
      ((${#argv[@]})) || return 1
      seconds="$(jq -r '.timeout//120' <<<"$check")"
      [[ $seconds =~ ^[1-9][0-9]*$ ]] || return 1
      output="$(cd "$prefix" && timeout --kill-after=5 "$seconds" "${argv[@]}" 2>&1)" || {
        printf '%s\n' "$output" >&2
        return 1
      }
      if [[ $(jq -r '.contains//""' <<<"$check") != '' ]]; then [[ $output == *"$(jq -r .contains <<<"$check")"* ]] || return 1; fi
    done < <(jq -c --arg pattern "$pattern" '.[$pattern][]' "$config")
  done < <(jq -r 'keys[]' "$config")
}
validate() {
  local prefix=$1 expected=$2 package_file=$3 manifest=$4 logical=$5 phase=$6 checks=$7 destination=$8
  local path name info binary mm actual core count=0 unresolved='[]' pip_status='pip absent'
  mm=$(minor "$expected")
  : >"$WORK/validated.ndjson"
  [[ -z $manifest ]] || check_hashes "$prefix" "$manifest" || return 1
  while IFS= read -r -d '' path; do
    name=${path##*/}
    is_python_name "$name" || continue
    if ! is_elf "$path" && ! is_standard "$name" "$mm"; then
      unresolved="$(jq -c --arg path "$path" '.+[$path]' <<<"$unresolved")"
      continue
    fi
    info="$(probe "$path")" || {
      printf 'Interpreter failed: %s\n' "$path" >&2
      return 1
    }
    [[ $(jq -r .version <<<"$info") == "$expected" && $(jq -r .prefix <<<"$info") == "$(canonical "$prefix")" ]] || {
      printf 'Wrong version/prefix: %s\n' "$path" >&2
      return 1
    }
    printf '%s\n' "$info" >>"$WORK/validated.ndjson"
    count=$((count + 1))
  done < <(find "$prefix/bin" -mindepth 1 -maxdepth 1 -name 'python*' -print0)
  ((count > 0)) || return 1
  binary="$(choose_binary "$prefix")" || return 1
  actual="$(mktemp "$WORK/actual-packages.XXXXXX")"
  packages "$prefix" "$actual" || return 1
  [[ $(jq -c .packages "$package_file") == "$(jq -c .packages "$actual")" ]] || {
    printf 'Installed package inventory changed: %s\n' "$prefix" >&2
    return 1
  }
  if jq -e '.packages[]|select(.name=="pip")' "$actual" >/dev/null; then
    pip_status="$(runpy "$binary" -I -m pip check 2>&1)" || {
      printf '%s\n' "$pip_status" >&2
      return 1
    }
  fi
  core="$(mktemp -d "$WORK/core.XXXXXX")"
  (cd "$core" && runpy "$binary" -I -m pydoc -w ssl sqlite3 bz2 lzma ctypes venv >"$core/imports.log" 2>&1) || {
    printf 'Core module check failed for %s:\n' "$binary" >&2
    cat "$core/imports.log" >&2
    return 1
  }
  for name in ssl sqlite3 bz2 lzma ctypes venv; do [[ -s $core/$name.html ]] || {
    printf 'Core module failed to load: %s\n' "$name" >&2
    return 1
  }; done
  application_checks "$prefix" "$logical" "$binary" "$phase" "$checks" || return 1
  jq -n --slurpfile interpreters "$WORK/validated.ndjson" --slurpfile packages "$actual" --arg pip_check "$pip_status" --argjson unresolved "$unresolved" \
    '{interpreters:$interpreters,packages:$packages[0],pip_check:$pip_check,unresolved_aliases:$unresolved,core_modules:["ssl","sqlite3","bz2","lzma","ctypes","venv"]}' >"$destination"
}
replace_literal() {
  local file=$1 old=$2 new=$3 temp
  [[ -f $file && ! -L $file ]] || return 0
  temp="$(mktemp "${file}.rewrite.XXXXXX")"
  OLD_PREFIX=$old NEW_PREFIX=$new awk 'BEGIN{old=ENVIRON["OLD_PREFIX"];new=ENVIRON["NEW_PREFIX"]}
    {s=$0;out="";while((n=index(s,old))>0){out=out substr(s,1,n-1) new;s=substr(s,n+length(old))}print out s}' "$file" >"$temp"
  chmod --reference="$file" "$temp"
  mv -f -- "$temp" "$file"
}
patch_stage() {
  local entry=$1 stage prefix kind target target_prefix version mm path name base candidate info
  local -a names=() options=()
  stage="$(jq -r .stage "$entry")"
  prefix="$(jq -r .prefix "$entry")"
  kind="$(jq -r .kind "$entry")"
  target="$(jq -r .target.binary "$entry")"
  target_prefix="$(jq -r .target.prefix "$entry")"
  version="$(jq -r .target.version "$entry")"
  mm=$(minor "$version")
  if [[ $kind == venv ]]; then
    [[ -f $stage/pyvenv.cfg ]] || die 'Legacy venv has no pyvenv.cfg; rebuild required'
    while IFS= read -r -d '' path; do
      name=${path##*/}
      is_python_name "$name" || continue
      if is_elf "$path" || is_standard "$name" "$mm"; then
        names+=("$name")
        rm -f -- "$path"
      fi
    done < <(find "$stage/bin" -mindepth 1 -maxdepth 1 -name 'python*' -print0)
    base="$(jq -r .base_prefix "$entry")"
    candidate=$base/bin/python$mm
    if info="$(probe "$candidate")" && [[ $(jq -r .version <<<"$info") == "$version" ]]; then target=$candidate; fi
    if awk -F= '$1~/^include-system-site-packages *$/ && $2~/true/ {found=1} END{exit !found}' "$stage/pyvenv.cfg"; then options+=(--system-site-packages); fi
    runpy "$target" -I -m venv --upgrade --without-pip --copies "${options[@]}" "$stage"
    for name in "${names[@]}"; do [[ -f $stage/bin/$name ]] || cp -p --remove-destination -- "$stage/bin/python" "$stage/bin/$name"; done
    replace_literal "$stage/pyvenv.cfg" "$stage" "$prefix"
  else
    rsync -a --checksum --exclude='/bin/***' --exclude='/lib/python*/site-packages/***' --exclude='/lib/python*/dist-packages/***' \
      --exclude='/lib64/python*/site-packages/***' "$target_prefix/" "$stage/"
    while IFS= read -r -d '' path; do
      name=${path##*/}
      if is_python_name "$name" || [[ $name =~ ^python[0-9.]+-config$ ]]; then cp -a --remove-destination -- "$path" "$stage/bin/$name"; fi
    done < <(find "$target_prefix/bin" -mindepth 1 -maxdepth 1 -print0)
    while IFS= read -r -d '' path; do
      name=${path##*/}
      is_python_name "$name" || continue
      if is_elf "$path" || is_standard "$name" "$mm"; then cp -p --remove-destination -- "$target" "$path"; fi
    done < <(find "$stage/bin" -mindepth 1 -maxdepth 1 -name 'python*' -print0)
    while IFS= read -r -d '' path; do
      replace_literal "$path" "$target_prefix" "$prefix"
      candidate="$(jq -r .target.configured_prefix "$entry")"
      [[ -z $candidate || $candidate == "$target_prefix" ]] || replace_literal "$path" "$candidate" "$prefix"
    done < <(
      find "$stage/lib" -type f \( -name '_sysconfigdata_*.py' -o -path '*/config-*/Makefile' -o -path '*/pkgconfig/python*.pc' \) -print0
      find "$stage/bin" -maxdepth 1 -name 'python*-config' -type f -print0
    )
  fi
}
checkpoint() {
  local entry=$1 journal=$2
  shift 2
  json_edit "$entry" "$@"
  json_edit "$journal" --slurpfile entry "$entry" '.entries |= map(if .prefix==$entry[0].prefix then $entry[0] else . end)'
}
publish_tree() {
  local source=$1 destination=$2
  # Preserve the prefix directory; replace changed files and link types through
  # rsync's temporary-file/rename publication, with checksum-based comparison.
  rsync -a --checksum --delete "$source/" "$destination/"
  sync -f "$destination"
}
restore_one() {
  local entry=$1 journal=$2 prefix backup identity
  prefix="$(jq -r .prefix "$entry")"
  backup="$(jq -r .backup "$entry")"
  [[ -d $backup && ! -L $prefix && -d $prefix ]] || die 'Rollback requires the original prefix and its backup'
  identity="$(stat -Lc '%d:%i' -- "$prefix")"
  [[ $identity == "$(jq -r .identity "$entry")" ]] || die "Rollback prefix identity changed: $prefix"
  publish_tree "$backup" "$prefix"
  checkpoint "$entry" "$journal" --arg at "$(now)" '.status="rolled_back"|.rolled_back_at=$at'
  event rolled_back "$prefix"
}
worker_failure() {
  local status=$1 entry=$2 journal=$3 prefix backup publication
  trap - ERR INT TERM
  set +e
  prefix="$(jq -r .prefix "$entry")"
  backup="$(jq -r .backup "$entry")"
  publication="$(jq -r '.publication_started//false' "$entry")"
  checkpoint "$entry" "$journal" --argjson exit "$status" '.error=("Update worker exited with status "+($exit|tostring))|.status="failed"'
  if [[ $publication == true && -d $backup ]]; then bash "$SELF" _restore "$entry" "$journal" || checkpoint "$entry" "$journal" '.status="rollback_failed"'; fi
  event failed "$prefix" "Worker exit $status"
  exit "$status"
}
apply_one() {
  local entry=$1 journal=$2 checks=$3 prefix stage backup kind version available size needed identity manifest packages_file result
  trap 'worker_failure "$?" "$entry" "$journal"' ERR
  trap 'worker_failure 130 "$entry" "$journal"' INT TERM
  prefix="$(jq -r .prefix "$entry")"
  stage="$(jq -r .stage "$entry")"
  backup="$(jq -r .backup "$entry")"
  kind="$(jq -r .kind "$entry")"
  version="$(jq -r .target.version "$entry")"
  [[ ! -L $prefix && -d $prefix && ! -e $stage && ! -e $backup ]]
  [[ $(stat -Lc %u -- "$prefix") == "$EUID" ]]
  identity="$(stat -Lc '%d:%i' -- "$prefix")"
  available="$(df -PB1 -- "$prefix" | awk 'NR==2 {print $4}')"
  size="$(du -sB1 -- "$prefix" | awk '{print $1}')"
  needed=$((size * 3 + 104857600))
  ((available > needed)) || die "Insufficient free space for stage and backup: $prefix"
  checkpoint "$entry" "$journal" --arg identity "$identity" '.identity=$identity|.status="preparing"'
  event prepare "$prefix" "$version"
  cp -a --reflink=never -- "$prefix" "$stage"
  patch_stage "$entry"
  packages_file="$WORK/expected-packages.json"
  jq .package_snapshot "$entry" >"$packages_file"
  result="$WORK/staged-validation.json"
  validate "$stage" "$version" "$packages_file" '' "$prefix" stage "$checks" "$result"
  manifest="$WORK/runtime-hashes.json"
  hashes "$stage" "$kind" "$manifest"
  checkpoint "$entry" "$journal" --slurpfile hashes "$manifest" --slurpfile result "$result" '.runtime_hashes=$hashes[0]|.staged_validation=$result[0]|.status="prepared"'
  [[ $(stat -Lc '%d:%i' -- "$prefix") == "$identity" ]]
  cp -a --reflink=never -- "$prefix" "$backup"
  checkpoint "$entry" "$journal" '.status="backed_up"|.publication_started=true'
  publish_tree "$stage" "$prefix"
  checkpoint "$entry" "$journal" '.status="installed"'
  result="$WORK/final-validation.json"
  validate "$prefix" "$version" "$packages_file" "$manifest" "$prefix" final "$checks" "$result"
  checkpoint "$entry" "$journal" --slurpfile result "$result" --arg at "$(now)" '.validation=$result[0]|.status="verified"|.finished=$at'
  # Retain the staged tree with the backup until the owner removes the journal's
  # recovery artifacts. Verification must never depend on cleanup timing.
  trap - ERR INT TERM
  event verified "$prefix" "$version"
}
acquire_locks() {
  local list=$1 parent fd
  while IFS= read -r parent; do
    exec {fd}>"$parent/${MARKER}lock"
    flock -n "$fd" || die "Another updater holds $parent"
    LOCK_FDS+=("$fd")
  done < <(jq -r '.[]|.prefix|sub("/[^/]+$";"")' "$list" | sort -u)
}
rollback_entries() {
  local journal=$1 entry path status failed=0
  while IFS= read -r entry; do
    status="$(jq -r .status <<<"$entry")"
    path="$(jq -r .entry_file <<<"$entry")"
    case "$status" in verified | installed | backed_up | prepared | rollback_failed)
      if [[ -d $(jq -r .backup <<<"$entry") ]]; then bash "$SELF" _restore "$path" "$journal" || failed=1; fi
      ;;
    esac
  done < <(jq -c '.entries|reverse[]' "$journal")
  return "$failed"
}
apply_plan() {
  local plan=$1 journal=$2 item prefix snapshot path token stage backup count=0 failed=0 fatal=0 base
  local -A blocked=()
  [[ ! -e $journal && ! -e $journal.entries ]] || die 'Journal exists; choose a new output path'
  mkdir -p -- "$journal.entries"
  jq '[.plan[]|select(.action=="update")]' "$plan" >"$WORK/lock-list.json"
  acquire_locks "$WORK/lock-list.json"
  jq -n --arg created "$(now)" --arg path "$journal" --slurpfile plan "$plan" \
    '{schema:2,engine:"bash",created:$created,path:$path,complete:false,failures:0,entries:[],failed_snapshots:[],
      skipped:[$plan[0].plan[]|select(.action=="skip")|{prefix,version,reason}],
      end_of_support:[$plan[0].plan[]|select(.eol!="")|{prefix,version,eol}],discovery_warnings:$plan[0].inventory.warnings}' | atomic_write "$journal"
  : >"$WORK/prepared-plan.ndjson"
  while IFS= read -r item; do
    [[ $(jq -r .action <<<"$item") == update ]] || {
      printf '%s\n' "$item" >>"$WORK/prepared-plan.ndjson"
      continue
    }
    prefix="$(jq -r .prefix <<<"$item")"
    snapshot="$(mktemp "$WORK/snapshot.XXXXXX")"
    if packages "$prefix" "$snapshot" 2>"$WORK/snapshot-error"; then
      jq -c --slurpfile snapshot "$snapshot" '.+{package_snapshot:$snapshot[0]}' <<<"$item" >>"$WORK/prepared-plan.ndjson"
    else
      failed=$((failed + 1))
      base="$(jq -r .base_prefix <<<"$item")"
      [[ $(jq -r .kind <<<"$item") != venv ]] || blocked[$base]=1
      json_edit "$journal" --arg prefix "$prefix" --arg error "$(cat "$WORK/snapshot-error")" '.failed_snapshots += [{prefix:$prefix,error:$error}]'
      jq -c '.action="skip"|.reason="Package snapshot failed"' <<<"$item" >>"$WORK/prepared-plan.ndjson"
    fi
  done < <(jq -c '.plan[]' "$plan")
  while IFS= read -r item; do
    prefix="$(jq -r .prefix <<<"$item")"
    if [[ $(jq -r .kind <<<"$item") == raw && ${blocked[$prefix]+yes} ]]; then
      item="$(jq -c '.action="skip"|.reason="Dependent venv snapshot failed; raw base left unchanged"' <<<"$item")"
      json_edit "$journal" --arg prefix "$prefix" '.skipped += [{prefix:$prefix,reason:"Dependent venv snapshot failed; raw base left unchanged"}]'
    fi
    if [[ $(jq -r .action <<<"$item") != update ]]; then
      event skip "$prefix" "$(jq -r .reason <<<"$item")"
      continue
    fi
    count=$((count + 1))
    token="${BASHPID}-${RANDOM}-${count}"
    stage=$prefix$MARKER$token.stage
    backup=$prefix$MARKER$token.backup
    path="$journal.entries/$count.json"
    jq --arg stage "$stage" --arg backup "$backup" --arg entry_file "$path" '.+{stage:$stage,backup:$backup,entry_file:$entry_file,status:"pending",old_version:.version}' <<<"$item" | atomic_write "$path"
    json_edit "$journal" --slurpfile entry "$path" '.entries += [$entry[0]]'
    if ! bash "$SELF" _apply-one "$path" "$journal" "$CHECKS"; then
      failed=$((failed + 1))
      fatal=1
      rollback_entries "$journal" || failed=$((failed + 1))
      break
    fi
  done <"$WORK/prepared-plan.ndjson"
  json_edit "$journal" --argjson failures "$failed" --arg finished "$(now)" '.complete=true|.finished=$finished|.failures=$failures'
  if ((fatal == 0)); then
    local -a verify_args=(verify "$journal" --output "$journal.post-verify.json")
    [[ -z $CHECKS ]] || verify_args+=(--checks "$CHECKS")
    if ! bash "$SELF" "${verify_args[@]}"; then
      if [[ ! -s $journal.post-verify.json ]] || jq -e '.results[]|select(.passed==false and .snapshot_failed!=true)' "$journal.post-verify.json" >/dev/null; then rollback_entries "$journal" || true; fi
      failed=$((failed + 1))
      json_edit "$journal" --argjson failures "$failed" '.failures=$failures'
    fi
  fi
  ((failed == 0))
}
verify_journal() {
  local journal=$1 destination=$2 entry prefix packages_file manifest result failed=0
  : >"$WORK/verification.ndjson"
  while IFS= read -r entry; do
    jq -c '.+{passed:false,snapshot_failed:true}' <<<"$entry" >>"$WORK/verification.ndjson"
    failed=$((failed + 1))
  done < <(jq -c '.failed_snapshots[]?' "$journal")
  while IFS= read -r entry; do
    prefix="$(jq -r .prefix <<<"$entry")"
    if [[ $(jq -r .status <<<"$entry") != verified ]]; then
      jq -cn --arg prefix "$prefix" --arg status "$(jq -r .status <<<"$entry")" '{prefix:$prefix,passed:false,error:$status}' >>"$WORK/verification.ndjson"
      failed=$((failed + 1))
      continue
    fi
    packages_file="$(mktemp "$WORK/expected.XXXXXX")"
    manifest="$(mktemp "$WORK/manifest.XXXXXX")"
    result="$(mktemp "$WORK/result.XXXXXX")"
    jq .package_snapshot <<<"$entry" >"$packages_file"
    jq .runtime_hashes <<<"$entry" >"$manifest"
    if validate "$prefix" "$(jq -r .target.version <<<"$entry")" "$packages_file" "$manifest" "$prefix" final "$CHECKS" "$result" 2>"$WORK/verify-error"; then
      jq -cn --arg prefix "$prefix" --slurpfile validation "$result" '{prefix:$prefix,passed:true,validation:$validation[0]}' >>"$WORK/verification.ndjson"
    else
      failed=$((failed + 1))
      jq -cn --arg prefix "$prefix" --arg error "$(cat "$WORK/verify-error")" '{prefix:$prefix,passed:false,error:$error}' >>"$WORK/verification.ndjson"
    fi
  done < <(jq -c '.entries[]' "$journal")
  jq -n --arg created "$(now)" --slurpfile results "$WORK/verification.ndjson" '{created:$created,engine:"bash",results:$results}' | atomic_write "$destination"
  jq -c '{event:"verification",passed:([.results[]|select(.passed)]|length),failed:([.results[]|select(.passed==false)]|length),unresolved_aliases:([.results[].validation.unresolved_aliases[]?]|length)}' "$destination"
  ((failed == 0))
}
main() {
  require_tools
  WORK="$(mktemp -d)"
  COMMAND=${1:---help}
  shift || true
  case "$COMMAND" in
    -h | --help | help)
      usage
      return
      ;;
    _apply-one)
      root_guard
      apply_one "$@"
      return
      ;;
    _restore)
      root_guard
      restore_one "$@"
      return
      ;;
    scan | plan | apply) ;;
    verify | rollback)
      (($#)) || die 'Journal path required'
      JOURNAL="$(absolute "$1")"
      shift
      ;;
    *)
      usage >&2
      exit 2
      ;;
  esac
  root_guard
  while (($#)); do
    case "$1" in
      --output | --checks | --exclude | --target)
        (($# >= 2)) || die "Missing value for $1"
        case "$1" in
          --output) OUTPUT="$(absolute "$2")" ;;
          --checks) CHECKS="$(canonical "$2")" ;;
          --exclude) EXCLUDES+=("$(absolute "$2")") ;;
          --target) TARGET_SPECS+=("$2") ;;
        esac
        shift 2
        ;;
      --)
        shift
        ROOTS+=("$@")
        break
        ;;
      -*) die "Unknown option: $1" ;;
      *)
        ROOTS+=("$(absolute "$1")")
        shift
        ;;
    esac
  done
  if [[ -n $CHECKS ]]; then jq -e 'type=="object" and all(.[];type=="array" and all(.[];.argv|type=="array" and length>0 and all(.[];type=="string")))' "$CHECKS" >/dev/null || die 'Invalid application checks JSON'; fi
  if [[ -n $JOURNAL ]]; then
    jq -e '.schema==2 and .engine=="bash" and (.entries|type=="array")' "$JOURNAL" >/dev/null || die 'Expected a native Bash schema-2 journal'
  fi
  case "$COMMAND" in
    scan | plan | apply)
      ((${#ROOTS[@]})) || die 'At least one trusted search root is required'
      [[ -n $OUTPUT ]] || die '--output is required'
      if [[ $COMMAND != scan ]]; then
        ((${#TARGET_SPECS[@]})) || die '--target is required'
        load_targets
      fi
      scan "$WORK/inventory.json"
      if [[ $COMMAND == scan ]]; then
        atomic_write "$OUTPUT" <"$WORK/inventory.json"
        event scanned '' "$(jq '.environments|length' "$OUTPUT") environments"
        return
      fi
      make_plan "$WORK/inventory.json" "$WORK/plan.json"
      if [[ $COMMAND == plan ]]; then
        atomic_write "$OUTPUT" <"$WORK/plan.json"
        event planned '' "$(jq '[.plan[]|select(.action=="update")]|length' "$OUTPUT") updates"
        return
      fi
      apply_plan "$WORK/plan.json" "$OUTPUT"
      ;;
    verify)
      [[ -n $OUTPUT ]] || die '--output is required'
      verify_journal "$JOURNAL" "$OUTPUT"
      ;;
    rollback)
      jq .entries "$JOURNAL" >"$WORK/lock-list.json"
      acquire_locks "$WORK/lock-list.json"
      rollback_entries "$JOURNAL"
      ;;
  esac
}
main "$@"
