
#!/usr/bin/env bash
if [[ "${EUID:-$(id -u)}" -eq 0 && -n "${SUDO_USER:-}" ]]; then
  echo "FATAL: do not run under sudo; run as a normal user." >&2; exit 1
fi


set -euo pipefail
umask 022

# ===== pinned versions (your previous working set) =====
PY38="3.8.19"
PY310="3.10.18"
PY311="3.11.13"
PY_VERSIONS=("${PY311}" "${PY310}" "${PY38}")   # build newest first

MINIFORGE_VER="25.9.1-0"
MINIFORGE_FN="Miniforge3-${MINIFORGE_VER}-Linux-x86_64.sh"

# Python OpenPGP keys (branch release managers); fetched from keyserver (not a dead URL)
PY_PGP_KEYS=("B26995E310250568" "64E628F8D684696D")
KEYSERVERS=("hkps://keyserver.ubuntu.com" "hkps://keys.openpgp.org" "hkp://pgp.mit.edu")

usage() {
  cat >&2 <<EOF
Usage:
  bash $0 <BASE_DIR> [--reuse] [--skip-apt] [--skip-gpg]

Notes:
- BASE_DIR is any directory (can be on /). Script will create subdirs under it.
- --reuse allows running again when BASE_DIR already exists.
EOF
  exit 2
}

log(){ printf "\n[%s] %s\n" "$(date -Is)" "$*" >&2; }
die(){ echo "FATAL: $*" >&2; exit 1; }
have(){ command -v "$1" >/dev/null 2>&1; }

BASE_DIR="${1:-}"; [[ -z "${BASE_DIR}" ]] && usage; shift || true
REUSE=0; SKIP_APT=0; SKIP_GPG=0
while [[ "${#}" -gt 0 ]]; do
  case "$1" in
    --reuse) REUSE=1 ;;
    --skip-apt) SKIP_APT=1 ;;
    --skip-gpg) SKIP_GPG=1 ;;
    *) usage ;;
  esac
  shift || true
done

as_root() {
  if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then "$@"; else have sudo || die "sudo missing"; sudo "$@"; fi
}

if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
  REAL_USER="${SUDO_USER:-root}"
else
  REAL_USER="$(id -un)"
fi
REAL_GROUP="$(id -gn "${REAL_USER}" 2>/dev/null || true)"
[[ -n "${REAL_GROUP}" ]] || die "Cannot determine group for ${REAL_USER}"

as_real_user() {
  if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then sudo -u "${REAL_USER}" "$@"; else "$@"; fi
}

diag_dir() {
  local d="$1"
  echo "---- diagnostics for ${d} ----" >&2
  ls -ld "${d}" >&2 || true
  id "${REAL_USER}" >&2 || true
  df -h "${d}" >&2 || true
  mount | head -n 80 >&2 || true
  have getfacl && getfacl -p "${d}" >&2 || true
  echo "--------------------------------" >&2
}

assert_user_writable() {
  local d="$1"
  local t="${d}/.write_test_${RANDOM}_$$"
  if ! as_real_user bash -lc "touch '${t}' && rm -f '${t}'" >/dev/null 2>&1; then
    diag_dir "${d}"
    die "Not writable by ${REAL_USER}: ${d}"
  fi
}

ensure_user_tree() {
  local d="$1"
  as_root mkdir -p "${d}"
  if ! as_root chown -R "${REAL_USER}:${REAL_GROUP}" "${d}" 2>/dev/null; then
    diag_dir "${d}"
    die "chown failed for ${d} (filesystem/mount may forbid ownership changes)"
  fi
  as_root find "${d}" -type d -exec chmod 0755 {} + || true
  as_root find "${d}" -type f -exec chmod u+rw,go+r {} + || true
  assert_user_writable "${d}"
}

detect_ubuntu() {
  [[ -r /etc/os-release ]] || die "Missing /etc/os-release"
  . /etc/os-release
  [[ "${ID:-}" == "ubuntu" ]] || die "This script expects Ubuntu (ID=${ID:-unknown})"
}

install_deps() {
  [[ "${SKIP_APT}" -eq 1 ]] && { log "Skipping apt (--skip-apt)"; return 0; }
  have apt-get || die "apt-get missing"
  log "Installing dependencies via apt"
  as_root apt-get update -y
  as_root apt-get install -y \
    build-essential ca-certificates curl wget xz-utils pkg-config gpg dirmngr \
    libssl-dev zlib1g-dev libbz2-dev libreadline-dev libsqlite3-dev libffi-dev \
    liblzma-dev libncurses-dev tk-dev uuid-dev \
    libgdbm-dev libgdbm-compat-dev libdb-dev libnsl-dev rpcsvc-proto \
    acl
}

preflight() {
  log "Preflight"
  for c in bash; do have "$c" || die "Missing command: $c"; done
  if [[ "${SKIP_APT}" -eq 0 ]]; then
    have sudo || die "sudo missing"
  fi
}

prepare_layout() {
  local parent; parent="$(dirname "${BASE_DIR}")"
  [[ -d "${parent}" ]] || die "Parent dir does not exist: ${parent}"

  if [[ -e "${BASE_DIR}" && "${REUSE}" -eq 0 ]]; then
    die "BASE_DIR exists: ${BASE_DIR} (use --reuse)"
  fi

  log "Preparing layout under ${BASE_DIR}"
  as_root mkdir -p "${BASE_DIR}"
  # do NOT chown BASE_DIR recursively; only user trees
  as_root mkdir -p "${BASE_DIR}/opt"
  ensure_user_tree "${BASE_DIR}/CACHE"
  ensure_user_tree "${BASE_DIR}/src"
  ensure_user_tree "${BASE_DIR}/bin"
  ensure_user_tree "${BASE_DIR}/shims"

  as_root mkdir -p \
    "${BASE_DIR}/CACHE/tmp" \
    "${BASE_DIR}/CACHE/pip" \
    "${BASE_DIR}/CACHE/xdg" \
    "${BASE_DIR}/CACHE/hf" \
    "${BASE_DIR}/CACHE/torch" \
    "${BASE_DIR}/CACHE/ollama/models" \
    "${BASE_DIR}/CACHE/conda/envs" \
    "${BASE_DIR}/CACHE/conda/pkgs" \
    "${BASE_DIR}/CACHE/conda"
  as_root chown -R "${REAL_USER}:${REAL_GROUP}" "${BASE_DIR}/CACHE"
  assert_user_writable "${BASE_DIR}/CACHE"
}

download_file() {
  local url="$1" out="$2"
  local dir; dir="$(dirname "${out}")"
  assert_user_writable "${dir}"
  rm -f "${out}.part" 2>/dev/null || true
  curl -fL --retry 6 --retry-delay 2 -o "${out}.part" "${url}"
  mv -f "${out}.part" "${out}"
}

import_python_keys() {
  [[ "${SKIP_GPG}" -eq 1 ]] && return 0
  have gpg || die "gpg missing"
  local keyring="${BASE_DIR}/CACHE/py_release_keys.gpg"
  for kid in "${PY_PGP_KEYS[@]}"; do
    if gpg --batch --no-default-keyring --keyring "${keyring}" --list-keys "${kid}" >/dev/null 2>&1; then
      continue
    fi
    local got=0
    for ks in "${KEYSERVERS[@]}"; do
      log "Fetching Python OpenPGP key ${kid} from ${ks}"
      for attempt in 1 2 3 4 5; do
        if gpg --batch --no-default-keyring --keyring "${keyring}" \
            --keyserver "${ks}" --keyserver-options timeout=20,retry=3 \
            --recv-keys "${kid}" >/dev/null 2>&1; then
          got=1; break
        fi
        sleep 2
      done
      [[ "${got}" -eq 1 ]] && break
    done
    [[ "${got}" -eq 1 ]] || die "Failed to fetch OpenPGP key ${kid} from all keyservers"
  done
}

verify_python() {
  [[ "${SKIP_GPG}" -eq 1 ]] && return 0
  local tar="$1" asc="$2"
  local keyring="${BASE_DIR}/CACHE/py_release_keys.gpg"
  import_python_keys
  gpg --batch --no-default-keyring --keyring "${keyring}" --verify "${asc}" "${tar}"
}

download_python() {
  local ver="$1"
  local fn="Python-${ver}.tar.xz"
  local asc="${fn}.asc"
  local base="https://www.python.org/ftp/python/${ver}"
  local tar="${BASE_DIR}/src/${fn}"
  local sig="${BASE_DIR}/src/${asc}"

  if [[ -f "${tar}" && -f "${sig}" ]]; then
    log "Python ${ver} tarball already present; skipping download"
    return 0
  fi

  log "Downloading Python ${ver}"
  download_file "${base}/${fn}"  "${tar}"
  download_file "${base}/${asc}" "${sig}"
  (cd "${BASE_DIR}/src" && sha256sum "${fn}" | tee "${fn}.sha256.local" >/dev/null)
  verify_python "${tar}" "${sig}"
}

build_install_python() {
  local ver="$1"
  local majmin="$2"
  local prefix="${BASE_DIR}/opt/python-${ver}"
  local pybin="${prefix}/bin/python${majmin}"
  local src_dir="${BASE_DIR}/src/Python-${ver}"
  local tar="${BASE_DIR}/src/Python-${ver}.tar.xz"

  if [[ -x "${pybin}" ]]; then
    log "Python ${ver} already installed at ${pybin}; skipping build"
    "${pybin}" -V
    return 0
  fi

  log "Extracting Python ${ver}"
  [[ -d "${src_dir}" ]] || tar -C "${BASE_DIR}/src" -xf "${tar}"

  log "Building Python ${ver}"
  cd "${src_dir}"
  [[ -f Makefile ]] && make distclean >/dev/null 2>&1 || true
  ./configure --prefix="${prefix}" --with-ensurepip=upgrade
  make -j "$(nproc)"
  as_root make altinstall

  log "Sanity check Python ${ver}"
  "${pybin}" -V
  "${pybin}" -c "import ssl,sqlite3,lzma,bz2,readline; print('ssl=',ssl.OPENSSL_VERSION)"
  "${pybin}" -m pip --version
}

write_env_common() {
  cat > "${BASE_DIR}/CACHE/env_common.sh" <<EOF
export TMPDIR="${BASE_DIR}/CACHE/tmp"
export XDG_CACHE_HOME="${BASE_DIR}/CACHE/xdg"
export PIP_CACHE_DIR="${BASE_DIR}/CACHE/pip"
export HF_HOME="${BASE_DIR}/CACHE/hf"
export TRANSFORMERS_CACHE="${BASE_DIR}/CACHE/hf/transformers"
export HF_DATASETS_CACHE="${BASE_DIR}/CACHE/hf/datasets"
export HUGGINGFACE_HUB_CACHE="${BASE_DIR}/CACHE/hf/hub"
export TORCH_HOME="${BASE_DIR}/CACHE/torch"
export OLLAMA_HOME="${BASE_DIR}/CACHE/ollama"
export OLLAMA_MODELS="${BASE_DIR}/CACHE/ollama/models"
EOF
  as_root chown "${REAL_USER}:${REAL_GROUP}" "${BASE_DIR}/CACHE/env_common.sh"
  chmod 0644 "${BASE_DIR}/CACHE/env_common.sh"
}
mkshim() {
  local tag="$1" pybin="$2"
  local version_suffix="${pybin##*python}" # Extracts "3.10" from path
  local d="${BASE_DIR}/shims/${tag}/bin"
  
  as_root mkdir -p "${d}"
  as_root chown -R "${REAL_USER}:${REAL_GROUP}" "${BASE_DIR}/shims"

  # 1. Wrapper content
  local wrap_py="#!/usr/bin/env bash
exec \"${pybin}\" \"\$@\""

  local wrap_pip="#!/usr/bin/env bash
source \"${BASE_DIR}/CACHE/env_common.sh\"
exec \"${pybin}\" -m pip \"\$@\""

  # 2. Write wrappers
  echo "$wrap_py" > "${d}/python"
  echo "$wrap_py" > "${d}/python3"
  echo "$wrap_py" > "${d}/python${version_suffix}" # e.g. python3.10

  echo "$wrap_pip" > "${d}/pip"
  echo "$wrap_pip" > "${d}/pip3"
  echo "$wrap_pip" > "${d}/pip${version_suffix}" # e.g. pip3.10

  chmod +x "${d}/"*{python,pip}*
}
mkentry() {
  local name="$1" tag="$2"
  # Create a custom RC file for this environment
  local rcfile="${BASE_DIR}/CACHE/rc_${name}.bash"
  
  cat > "${rcfile}" <<EOF
# 1. Source the user's standard bashrc first
if [ -f ~/.bashrc ]; then source ~/.bashrc; fi

# 2. Force our settings AFTER .bashrc runs
export PATH="${BASE_DIR}/shims/${tag}/bin:${BASE_DIR}/bin:\$PATH"
export PS1="[${name}] \${PS1-}"
EOF

  # Create the entry script
  cat > "${BASE_DIR}/bin/${name}" <<EOF
#!/usr/bin/env bash
set -euo pipefail
source "${BASE_DIR}/CACHE/env_common.sh"

# If user provides args, run command. If not, start shell with custom RC.
if [ "\$#" -gt 0 ]; then 
  export PATH="${BASE_DIR}/shims/${tag}/bin:${BASE_DIR}/bin:\$PATH"
  exec "\$@"
else 
  exec bash --rcfile "${rcfile}" -i
fi
EOF
  chmod +x "${BASE_DIR}/bin/${name}"
}

create_python_entrypoints() {
  log "Creating python shims + entrypoints"
  write_env_common

  local p38="${BASE_DIR}/opt/python-${PY38}/bin/python3.8"
  local p10="${BASE_DIR}/opt/python-${PY310}/bin/python3.10"
  local p11="${BASE_DIR}/opt/python-${PY311}/bin/python3.11"
  [[ -x "${p38}" && -x "${p10}" && -x "${p11}" ]] || die "Python binaries missing; build step failed earlier"

  ln -sf "${p38}" "${BASE_DIR}/bin/python38"
  ln -sf "${p10}" "${BASE_DIR}/bin/python3-10"
  ln -sf "${p11}" "${BASE_DIR}/bin/python3-11"

  cat > "${BASE_DIR}/bin/pip38" <<EOF
#!/usr/bin/env bash
source "${BASE_DIR}/CACHE/env_common.sh"
exec "${BASE_DIR}/bin/python38" -m pip "\$@"
EOF
  cat > "${BASE_DIR}/bin/pip3-10" <<EOF
#!/usr/bin/env bash
source "${BASE_DIR}/CACHE/env_common.sh"
exec "${BASE_DIR}/bin/python3-10" -m pip "\$@"
EOF
  cat > "${BASE_DIR}/bin/pip3-11" <<EOF
#!/usr/bin/env bash
source "${BASE_DIR}/CACHE/env_common.sh"
exec "${BASE_DIR}/bin/python3-11" -m pip "\$@"
EOF
  chmod +x "${BASE_DIR}/bin/pip38" "${BASE_DIR}/bin/pip3-10" "${BASE_DIR}/bin/pip3-11"

  mkshim "py38" "${p38}"
  mkshim "py10" "${p10}"
  mkshim "py11" "${p11}"
  mkentry "py38" "py38"
  mkentry "py10" "py10"
  mkentry "py11" "py11"
}

ensure_user_can_create_conda_prefix() {
  local optdir="${BASE_DIR}/opt"
  # Prefer ACL: do not change ownership of optdir if possible
  if have setfacl; then
    as_root setfacl -m "u:${REAL_USER}:rwx" "${optdir}" || true
  fi
  if ! as_real_user bash -lc "test -w '${optdir}'" >/dev/null 2>&1; then
    # Fallback: change ownership of optdir itself (NOT recursive)
    as_root chown "${REAL_USER}:${REAL_GROUP}" "${optdir}"
    as_root chmod 0755 "${optdir}"
  fi
  as_real_user bash -lc "test -w '${optdir}'" >/dev/null 2>&1 || { diag_dir "${optdir}"; die "Cannot make ${optdir} writable for ${REAL_USER}"; }
}

install_miniforge() {
  log "Installing/Updating Miniforge (no pre-create prefix)"

  local installer="${BASE_DIR}/src/Miniforge3-Linux-x86_64.sh"
  local sha_file="${installer}.sha256"
  local rel="https://github.com/conda-forge/miniforge/releases/download/${MINIFORGE_VER}"
  local prefix="${BASE_DIR}/opt/conda"

  download_file "${rel}/${MINIFORGE_FN}" "${installer}"
  download_file "${rel}/${MINIFORGE_FN}.sha256" "${sha_file}"

  local expected
  expected="$(awk '{print $1}' "${sha_file}" | head -n1)"
  [[ "${expected}" =~ ^[0-9a-fA-F]{64}$ ]] || die "Invalid sha256 file: ${sha_file}"
  echo "${expected}  ${installer}" | sha256sum -c -

  ensure_user_can_create_conda_prefix

  # Idempotent logic:
  if [[ -f "${prefix}/conda-meta/history" ]]; then
    log "Conda prefix exists -> updating with -u: ${prefix}"
    as_real_user bash "${installer}" -b -u -p "${prefix}"
  else
    if [[ -e "${prefix}" ]]; then
      # exists but not a conda install (or partial); wipe and fresh install
      log "Prefix exists but not a valid conda install -> wiping: ${prefix}"
      as_root rm -rf "${prefix}"
    fi
    log "Fresh install Miniforge to: ${prefix}"
    as_real_user bash "${installer}" -b -p "${prefix}"
  fi

  # wrappers (no conda init)
  ln -sf "${BASE_DIR}/opt/conda/bin/conda" "${BASE_DIR}/bin/conda"
  ln -sf "${BASE_DIR}/opt/conda/bin/mamba" "${BASE_DIR}/bin/mamba" 2>/dev/null || true

  cat > "${BASE_DIR}/CACHE/conda/condarc.yml" <<EOF
envs_dirs:
  - ${BASE_DIR}/CACHE/conda/envs
pkgs_dirs:
  - ${BASE_DIR}/CACHE/conda/pkgs
auto_activate_base: false
channels: [conda-forge]
channel_priority: strict
EOF
  as_root chown -R "${REAL_USER}:${REAL_GROUP}" "${BASE_DIR}/CACHE/conda"

  cat > "${BASE_DIR}/bin/cbase" <<EOF
#!/usr/bin/env bash
set -euo pipefail
source "${BASE_DIR}/CACHE/env_common.sh"
export PATH="${BASE_DIR}/opt/conda/bin:${BASE_DIR}/bin:\$PATH"
export CONDA_ENVS_PATH="${BASE_DIR}/CACHE/conda/envs"
export CONDA_PKGS_DIRS="${BASE_DIR}/CACHE/conda/pkgs"
export CONDARC="${BASE_DIR}/CACHE/conda/condarc.yml"
source "${BASE_DIR}/opt/conda/etc/profile.d/conda.sh"
conda activate base >/dev/null
exec bash -i
EOF

  cat > "${BASE_DIR}/bin/cenv" <<EOF
#!/usr/bin/env bash
set -euo pipefail
if [ "\$#" -lt 1 ]; then echo "usage: cenv <envname> [command...]" >&2; exit 2; fi
ENVNAME="\$1"; shift
source "${BASE_DIR}/CACHE/env_common.sh"
export PATH="${BASE_DIR}/opt/conda/bin:${BASE_DIR}/bin:\$PATH"
export CONDA_ENVS_PATH="${BASE_DIR}/CACHE/conda/envs"
export CONDA_PKGS_DIRS="${BASE_DIR}/CACHE/conda/pkgs"
export CONDARC="${BASE_DIR}/CACHE/conda/condarc.yml"
source "${BASE_DIR}/opt/conda/etc/profile.d/conda.sh"
conda activate "\$ENVNAME" >/dev/null
if [ "\$#" -gt 0 ]; then exec "\$@"; else exec bash -i; fi
EOF
  chmod +x "${BASE_DIR}/bin/cbase" "${BASE_DIR}/bin/cenv"
}

tests() {
  log "Testing python shims"
  "${BASE_DIR}/bin/py38" bash -lc 'python -V; pip --version; python -c "import sys; print(sys.executable)"'
  "${BASE_DIR}/bin/py10" bash -lc 'python -V; pip --version; python -c "import sys; print(sys.executable)"'
  "${BASE_DIR}/bin/py11" bash -lc 'python -V; pip --version; python -c "import sys; print(sys.executable)"'

  log "Testing conda wrappers"
  bash -lc "
    set -euo pipefail
    source \"${BASE_DIR}/CACHE/env_common.sh\"
    export PATH=\"${BASE_DIR}/opt/conda/bin:${BASE_DIR}/bin:\$PATH\"
    export CONDA_ENVS_PATH=\"${BASE_DIR}/CACHE/conda/envs\"
    export CONDA_PKGS_DIRS=\"${BASE_DIR}/CACHE/conda/pkgs\"
    export CONDARC=\"${BASE_DIR}/CACHE/conda/condarc.yml\"
    source \"${BASE_DIR}/opt/conda/etc/profile.d/conda.sh\"
    conda activate base >/dev/null
    conda --version
    python -V
    conda info | egrep 'envs directories|package cache' -A2
  "
}


main() {
  detect_ubuntu
  preflight
  install_deps

  # Hard requirement checks AFTER apt
  for c in curl tar sha256sum make gcc; do have "$c" || die "Missing command: $c"; done
  [[ "${SKIP_GPG}" -eq 1 ]] || have gpg || die "Missing gpg (use --skip-gpg to bypass)"

  prepare_layout

  for ver in "${PY_VERSIONS[@]}"; do download_python "${ver}"; done
  build_install_python "${PY311}" "3.11"
  build_install_python "${PY310}" "3.10"
  build_install_python "${PY38}"  "3.8"

  create_python_entrypoints
  install_miniforge
  tests

  log "DONE. Add to PATH if you want:"
  log "export PATH=\"${BASE_DIR}/bin:\$PATH\""
}

main "$@"


${BASE_DIR}/bin/conda init
echo "conda deactivate" >> ~/.bashrc 
get_real_home() {
  local home
  home="$(getent passwd "${REAL_USER}" | cut -d: -f6 || true)"
  [[ -n "${home}" && -d "${home}" ]] || die "Cannot determine HOME for ${REAL_USER}"
  echo "${home}"
}

ensure_base_bin_exists() {
  local base canon bin
  base="$1"
  canon="$(readlink -f "${base}" 2>/dev/null || realpath "${base}" 2>/dev/null || echo "${base}")"
  bin="${canon}/bin"
  [[ -d "${bin}" ]] || die "Expected bin dir missing: ${bin}"
  echo "${canon}"
}

ensure_path_in_bashrc() {
  local home rc begin end canon line
  home="$(get_real_home)"
  rc="${home}/.bashrc"

  canon="$(ensure_base_bin_exists "${BASE_DIR}")"
  begin="# >>> managed by bootstrap: add BASE_DIR/bin to PATH >>>"
  end="# <<< managed by bootstrap <<<"

  # 用 guard：只有 PATH 未包含時先 prepend
  line="if [[ \":\$PATH:\" != *\":${canon}/bin:\"* ]]; then export PATH=\"${canon}/bin:\$PATH\"; fi"

  as_real_user bash -lc "touch \"${rc}\""

  # 已存在就唔再寫（檢查 block 標記）
  if as_real_user bash -lc "grep -qsF \"${begin}\" \"${rc}\""; then
    return 0
  fi

  # 追加 block（清晰可逆）
  as_real_user bash -lc "cat >> \"${rc}\" <<'EOF'

${begin}
${line}
${end}
EOF"
}

ensure_path_in_bashrc

exit
