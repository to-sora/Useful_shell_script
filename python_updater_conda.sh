# Conda owns the files in these prefixes. Use its solver and package transactions,
# including for base: its envs/ and pkgs/ directories are independent installations.
conda_command() {
  env -u VIRTUAL_ENV -u PYTHONHOME -u PYTHONPATH CONDA_AUTO_UPDATE_CONDA=false "$@" </dev/null
}

# Bound network/solver queries. An in-progress package link/unlink uses Conda's
# own transaction handling and is not killed on a wall-clock deadline.
conda_query() { conda_command timeout --kill-after=5 600 "$@"; }

conda_report_error() {
  local message=$1 response=$2 errors
  # Exception messages and URLs can carry private channel credentials. Names
  # and package archive basenames provide diagnostics without logging them.
  errors=$(jq -sr '[.. | objects |
    (.exception_name? | strings | select(test("^[A-Za-z][A-Za-z0-9_.]{0,100}$"))),
    (.path? | strings | split("/") | last | select(test("^[A-Za-z0-9_+.~-]+\\.(conda|tar\\.bz2)$")))]
    | unique | .[:12] | join(", ")' "$response" 2>/dev/null) || errors=''
  printf '%s%s\n' "$message" "${errors:+ ($errors)}" >&2
}

conda_valid_prefix() {
  local p=$1
  [[ $p == /* && $(realpath -e -- "$p") == "$p" && -d $p/conda-meta &&
     ! -L $p/conda-meta && -f $p/conda-meta/history && ! -L $p/conda-meta/history &&
     ! -f $p/info/index.json && $(stat -Lc %u -- "$p") == "$EUID" &&
     -w $p && -w $p/conda-meta && -w $p/conda-meta/history ]]
}

conda_valid_solver() {
  local exe=$1 root
  case "$exe" in /*/bin/conda | /*/condabin/conda) ;; *) return 1 ;; esac
  root=${exe%/*}
  root=${root%/*}
  [[ -x $exe && -f $root/conda-meta/history ]] || return 1
  within "$(realpath -e -- "$exe")" "$(realpath -e -- "$root")" || return 1
  jq -se --arg file "${exe#"$root"/}" 'any(.[];
    .name=="conda" and (.files|index($file)!=null))' "$root"/conda-meta/conda-[0-9]*.json >/dev/null 2>&1
}

conda_find_solver() {
  local p=$1 inventory=$2 path owner_root candidate=''
  local -a options=("$p/bin/conda")
  if [[ $p == */envs/* ]]; then options+=("${p%/envs/*}/bin/conda"); fi
  options+=("${CONDA_EXE:-}" "$(type -P conda || true)")
  for path in "${options[@]}"; do
    [[ -n $path && -x $path ]] || continue
    path=$(realpath -e -- "$path") || continue
    scan_path_allowed "$path" && conda_valid_solver "$path" || continue
    printf '%s\n' "$path"
    return 0
  done
  # External -p environments need not live below root/envs. With no configured
  # CLI, use an unambiguous manager from the trusted inventory.
  while IFS= read -r owner_root; do
    path="$owner_root/bin/conda"
    scan_path_allowed "$path" && conda_valid_solver "$path" || continue
    [[ -z $candidate || $candidate == "$path" ]] || return 1
    candidate=$path
  done < <(jq -r '.environments[]|select(.managed=="conda" and .kind=="raw")|.prefix' "$inventory")
  [[ -n $candidate ]] || return 1
  printf '%s\n' "$candidate"
}

# Digest sorted package identities, including source and build. Files belonging
# to nested environments or extracted packages never enter this inventory.
conda_state() {
  local record
  for record in "$1"/conda-meta/*.json; do [[ -f $record && ! -L $record ]] || return 1; done
  jq -cn '[inputs | select(.name? and .version? and .build?) |
    {name,version,build,channel:(if .url then (.url|sub("/[^/]+$";""))
      else ((.channel|rtrimstr("/"))+"/"+.subdir) end)}] | sort_by(.name) |
    if length>0 and (map(.name)|unique|length)==length then . else error("Invalid Conda records") end' "$1"/conda-meta/*.json
}

conda_digest() { sha256sum | cut -d' ' -f1; }

conda_revision() {
  conda_query "$1" list --json --revisions --prefix "$2" |
    jq -er 'last.rev | select(type=="number" and .>=0)'
}

# Resolve a solver LINK record to an exact URL and content hash. A package
# already in the package cache has no FETCH action in Conda's dry-run JSON.
conda_artifact() {
  local row=$1 dry=$2 caches=$3 name version build channel dist record cache meta
  IFS=$'\t' read -r name version build channel < <(jq -r '[.name,.version,.build,.channel]|@tsv' <<<"$row")
  dist="$name-$version-$build"
  [[ $dist != *'/'* && $dist != *$'\n'* && $dist != *$'\r'* ]] || return 1
  record=$(jq -c --arg name "$name" --arg version "$version" --arg build "$build" \
    'first(.actions.FETCH[]? | select(.name==$name and .version==$version and .build==$build)) // empty' "$dry") || return 1
  if [[ -z $record ]]; then
    while IFS= read -r cache; do
      meta="$cache/$dist/info/repodata_record.json"
      [[ -f $meta ]] || continue
      record=$(jq -c --arg source "$channel" 'select((.url|sub("/[^/]+$";""))==$source)' "$meta") || return 1
      [[ -z $record ]] || break
    done < <(jq -r '.[]' "$caches")
  fi
  [[ -n $record ]] || return 1
  jq -cer --arg dist "$dist" --arg channel "$channel" '
    select((.fn==$dist+".conda" or .fn==$dist+".tar.bz2") and .url==$channel+"/"+.fn) |
    (.sha256 // .md5) as $hash |
    select((.url|test("^(https?://|file://)")) and (.url|test("[[:cntrl:]#]")|not)
      and ($hash|type)=="string" and ($hash|test("^([a-f0-9]{64}|[a-f0-9]{32})$"))) |
    {url,hash:$hash}' <<<"$record"
}

conda_changes() {
  jq -ce --arg p "$2" '
    def identity: {name,version,build:(.build_string // .build),
      channel:((.base_url|rtrimstr("/"))+"/"+.platform)};
    select(.success and .actions.PREFIX==$p) | .actions |
    {unlink:([.UNLINK[]?|identity]|sort_by(.name)),link:([.LINK[]?|identity]|sort_by(.name))}' "$1"
}

conda_projected_state() {
  jq -ce --slurpfile delta "$2" '
    $delta[0] as $d | select(($d.unlink-.)==[]) |
    ((. - $d.unlink) + $d.link | sort_by(.name)) | select((map(.name)|unique|length)==length)' "$1"
}

# Replaying the reviewed, hashed artifacts with native Conda explicit mode
# avoids a *second* solve that could publish a newly released package between
# consent and installation. Reject removals that explicit mode cannot replay.
conda_transaction() {
  local exe=$1 p=$2 old=$3 goal=$4 lockfile=${5:-} dir revision row label failure
  dir=$(mktemp -d "$WORK/conda.XXXXXX") || return 1
  conda_valid_prefix "$p" && conda_valid_solver "$exe" || return 1
  conda_state "$p" >"$dir/before" || return 1
  jq -e --arg old "$old" 'any(.[];.name=="python" and .version==$old)' "$dir/before" >/dev/null || return 1
  revision=$(conda_revision "$exe" "$p") || return 1
  if ! conda_query "$exe" install --json --dry-run --freeze-installed --prefix "$p" "python==$goal" >"$dir/solve"; then
    failure=$(jq -r '.exception_name // empty' "$dir/solve") || return 1
    # A patch may require upgrading an installed native dependency. Retry
    # with the single Python spec; every resulting package is reviewed.
    if [[ $failure != *Unsatisfiable* ]] ||
       ! conda_query "$exe" install --json --dry-run --prefix "$p" "python==$goal" >"$dir/solve"; then
      jq -r '.exception_name // "Conda solve failed"' "$dir/solve" >&2; return 1
    fi
  fi
  conda_changes "$dir/solve" "$p" >"$dir/changes" || return 1
  jq -e --arg goal "$goal" '(.unlink|map(.name))-(.link|map(.name))==[]
    and any(.link[];.name=="python" and .version==$goal)' "$dir/changes" >/dev/null || return 1
  printf '[]\n' >"$dir/caches"
  if ! jq -e '[.actions.LINK[].name] - [.actions.FETCH[]?.name] == []' "$dir/solve" >/dev/null; then
    conda_query "$exe" info --json >"$dir/info" || {
      jq -r '.exception_name // "Conda could not locate its package caches"' "$dir/info" >&2; return 1
    }
    jq -ce '.pkgs_dirs|select(type=="array")' "$dir/info" >"$dir/caches" || return 1
  fi
  : >"$dir/artifacts"
  while IFS= read -r row; do
    conda_artifact "$row" "$dir/solve" "$dir/caches" >>"$dir/artifacts" || return 1
  done < <(jq -c '.link[]' "$dir/changes")
  conda_projected_state "$dir/before" "$dir/changes" >"$dir/after" || return 1
  jq -sr '"@EXPLICIT",(.[]|.url+"#"+.hash)' "$dir/artifacts" >"$dir/explicit" || return 1
  [[ -z $lockfile ]] || cp -- "$dir/explicit" "$lockfile" || return 1
  label=$(jq -r '(.unlink|INDEX(.name)) as $old | [.link[] |
    "\(.name) \(if $old[.name] then ($old[.name].version+"/"+$old[.name].build) else "(new)" end) -> \(.version)/\(.build)"]|join(", ")' "$dir/changes") || return 1
  jq -cn --arg exe "$exe" --argjson rev "$revision" --arg summary "$label" \
    --arg before "$(conda_digest <"$dir/before")" --arg after "$(conda_digest <"$dir/after")" \
    --slurpfile changes "$dir/changes" --arg artifact_digest "$(conda_digest <"$dir/explicit")" \
    '{executable:$exe,revision:$rev,before:$before,after:$after,summary:$summary,
      changes:($changes[0]|map_values(map(del(.channel)))),artifact_digest:$artifact_digest}'
}

conda_plan_item() {
  local item=$1 inventory=$2 p old mm goal exe transaction reason diagnostics detail requested=''
  p=$(jq -r .prefix <<<"$item")
  old=$(jq -r .version <<<"$item")
  mm=$(minor "$old")
  goal=${POLICY[$mm]:-}
  diagnostics=$(mktemp "$WORK/conda-solve-error.XXXXXX") || return 1
  if ! conda_valid_prefix "$p"; then
    reason='Conda prefix or writable owner metadata unavailable'
  elif [[ -z $goal ]]; then
    reason="No tested release policy for Python $mm"
  elif ((10#${old##*.} >= 10#${goal##*.})); then
    reason=up_to_date
    requested=$old
  elif ! exe=$(conda_find_solver "$p" "$inventory"); then
    reason='Include the genuine Conda installation containing bin/conda in the scan'
  elif transaction=$(conda_transaction "$exe" "$p" "$old" "$goal" 2>"$diagnostics"); then
    jq -c --arg goal "$goal" --arg eol "${EOL[$mm]:-}" --argjson transaction "$transaction" '
      .kind="conda"|.action="update"|.reason="Conda solver transaction"|
      .eol=$eol|.requested_version=$goal|.target={version:$goal,prefix:.prefix,source:"conda"}|.conda=$transaction' <<<"$item"
    return
  else
    reason="Conda could not resolve a reproducible Python $goal transaction with the configured channels and constraints"
    if [[ -s $diagnostics ]]; then
      cat "$diagnostics" >&2
      detail=$(tail -n 1 "$diagnostics")
      [[ $detail =~ ^[a-zA-Z][a-zA-Z0-9_]*$ ]] && reason+=" ($detail)"
    fi
  fi
  jq -c --arg reason "$reason" --arg requested "$requested" --arg eol "${EOL[$mm]:-}" \
    '.kind="conda"|.action="skip"|.reason=$reason|.target=null|.requested_version=$requested|.eol=$eol' <<<"$item"
}

conda_verify_entry() {
  local item=$1 checks=$2 result=$3 p expected binary info
  p=$(jq -r .prefix <<<"$item")
  expected=$(jq -r .target.version <<<"$item")
  conda_valid_prefix "$p" && [[ $(stat -Lc '%d:%i' -- "$p") == "$(jq -r .prefix_identity <<<"$item")" ]] || return 1
  [[ $(conda_state "$p" | conda_digest) == "$(jq -r .conda.after <<<"$item")" ]] || {
    printf 'Conda package records differ from the approved transaction: %s\n' "$p" >&2; return 1
  }
  binary=$(choose_binary "$p") && info=$(probe "$binary") || return 1
  jq -e --arg p "$p" --arg v "$expected" '.version==$v and .prefix==$p and .base_prefix==$p and .managed=="conda"' <<<"$info" >/dev/null || return 1
  healthy_target "$binary" || { printf 'Conda Python core-module checks failed: %s\n' "$binary" >&2; return 1; }
  application_checks "$p" "$p" "$binary" final "$checks" || return 1
  jq -n --arg version "$expected" '{version:$version,conda_packages_verified:true,unresolved_aliases:[]}' >"$result"
}

conda_apply_one() {
  local entry=$1 journal=$2 checks=$3 p exe old goal reviewed fresh specs result response
  trap 'worker_failure "$?" "$entry" "$journal"' ERR
  trap 'worker_failure 130 "$entry" "$journal"' INT TERM
  p=$(jq -r .prefix "$entry")
  exe=$(jq -r .conda.executable "$entry")
  old=$(jq -r .version "$entry")
  goal=$(jq -r .target.version "$entry")
  reviewed=$(jq -cS .conda "$entry")
  [[ $(stat -Lc '%d:%i' -- "$p") == "$(jq -r .prefix_identity "$entry")" ]]
  specs=$(mktemp "$WORK/conda-specs.XXXXXX")
  if ! fresh=$(conda_transaction "$exe" "$p" "$old" "$goal" "$specs"); then
    printf 'Could not revalidate the approved Conda transaction for %s\n' "$p" >&2; return 1
  fi
  [[ $(jq -cS . <<<"$fresh") == "$reviewed" ]] || { printf 'Conda plan changed for %s. Start a new run.\n' "$p" >&2; return 1; }
  [[ $(conda_state "$p" | conda_digest) == "$(jq -r .before <<<"$reviewed")" &&
     $(conda_revision "$exe" "$p") == "$(jq -r .revision <<<"$reviewed")" ]] || {
    printf 'Conda prefix changed during revalidation: %s\n' "$p" >&2; return 1
  }
  checkpoint "$entry" "$journal" '.status="backed_up"|.publication_started=true'
  event publish "$p" "Conda $old -> $goal"
  response=$(mktemp "$WORK/conda-install.XXXXXX")
  if ! conda_command "$exe" install --json --yes --prefix "$p" --file "$specs" >"$response"; then
    conda_report_error "Conda install failed for $p" "$response"; return 1
  fi
  # Some Conda releases print no JSON for a successful explicit transaction.
  if [[ -s $response ]]; then jq -es 'all(.[]; .success!=false)' "$response" >/dev/null; fi
  checkpoint "$entry" "$journal" '.status="installed"'
  result=$(mktemp "$WORK/conda-verify.XXXXXX")
  conda_verify_entry "$(cat "$entry")" "$checks" "$result"
  checkpoint "$entry" "$journal" --arg at "$(now)" --slurpfile result "$result" '.status="verified"|.finished=$at|.validation=$result[0]'
  event verified "$p" "$goal"
  trap - ERR INT TERM
}

conda_restore_one() {
  local entry=$1 journal=$2 p exe before after state revision current dir binary info
  p=$(jq -r .prefix "$entry")
  exe=$(jq -r .conda.executable "$entry")
  before=$(jq -r .conda.before "$entry")
  after=$(jq -r .conda.after "$entry")
  revision=$(jq -r .conda.revision "$entry")
  jq -e '.publication_started==true' "$entry" >/dev/null
  conda_valid_prefix "$p" && conda_valid_solver "$exe" || return 1
  [[ $(stat -Lc '%d:%i' -- "$p") == "$(jq -r .prefix_identity "$entry")" ]] || return 1
  state=$(conda_state "$p" | conda_digest) || return 1
  if [[ $state != "$before" ]]; then
    current=$(conda_revision "$exe" "$p") || return 1
    [[ $state == "$after" && $current == "$((revision + 1))" ]] || {
      printf 'Conda prefix differs from the recorded transaction. Preserving subsequent changes: %s\n' "$p" >&2; return 1
    }
    dir=$(mktemp -d "$WORK/conda-revert.XXXXXX") || return 1
    conda_state "$p" >"$dir/current" || return 1
    if ! conda_query "$exe" install --json --dry-run --prefix "$p" --revision "$revision" >"$dir/solve"; then
      conda_report_error "Cannot resolve Conda revision $revision for $p from the configured channels and caches" "$dir/solve"; return 1
    fi
    conda_changes "$dir/solve" "$p" >"$dir/delta" || {
      printf 'Conda supplied no rollback transaction for %s\n' "$p" >&2; return 1
    }
    [[ $(conda_projected_state "$dir/current" "$dir/delta" | conda_digest) == "$before" ]] || {
      printf 'Conda revision would restore different packages: %s\n' "$p" >&2; return 1
    }
    conda_command "$exe" install --json --yes --prefix "$p" --revision "$revision" >"$dir/result" || {
      conda_report_error "Conda revision restore failed for $p" "$dir/result"; return 1
    }
    [[ $(conda_state "$p" | conda_digest) == "$before" ]] || return 1
  fi
  binary=$(choose_binary "$p") && info=$(probe "$binary") || return 1
  jq -e --arg p "$p" --arg v "$(jq -r .version "$entry")" \
    '.version==$v and .prefix==$p and .base_prefix==$p and .managed=="conda"' <<<"$info" >/dev/null || return 1
  checkpoint "$entry" "$journal" --arg at "$(now)" '.status="rolled_back"|.rolled_back_at=$at'
  event rolled_back "$p" "Conda revision $revision"
}
