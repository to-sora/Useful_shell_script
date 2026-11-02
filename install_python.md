# install_python.sh

Install multiple Python versions from source and Miniforge (conda) on Ubuntu.

## Requirements
- Ubuntu 20.04 or newer
- Run as normal user (not root/sudo)
- Internet access for downloads
- `sudo` access for apt package installation (unless using `--skip-apt` and `--no-sudo`)

## What it installs
- **Python versions**: 3.11.18 and 3.13.18 by default; 3.8.20 and 3.10.22 through explicit `--py` selection (compiled from source)
- **Miniforge**: 26.9.4-1 (conda/mamba package manager)
- **Entry scripts**: `py38`, `py10`, `py11`, `py13`, `python3-8`, `pip3-11`, etc.
- **Conda wrappers**: `cbase` (base environment), `cenv <envname>` (activate environment)
- **Cache directories**: Pre-configured for pip, HuggingFace, torch, ollama

## Usage
```bash
./install_python.sh <BASE_DIR> [OPTIONS]
```

### Basic example
```bash
./install_python.sh /path/to/myenv
```

### Options
| Flag | Description |
|------|-------------|
| `--reuse` | Allow running when BASE_DIR already exists (skip completed steps) |
| `--skip-apt` | Skip apt dependency installation |
| `--skip-gpg` | Skip OpenPGP signature verification for Python downloads |
| `--no-bashrc` | Do not modify `~/.bashrc` with PATH additions |
| `--no-sudo` | Do not use sudo (for environments without sudo access) |
| `--py "3.13 3.11"` | Select Python branches; 3.11 and 3.13 are the default |
| `--skip-conda` | Build CPython without installing or updating Miniforge |
| `--jobs N` | Set compilation workers; default is `nproc` |

### Selective installation example
```bash
# Install only Python 3.13 and 3.11
./install_python.sh /path/to/myenv --py "3.13 3.11"
```

## Directory structure
After installation, `BASE_DIR` will contain:
```
BASE_DIR/
├── bin/           # Entry scripts: py38, py11, py13, cbase, cenv, conda
├── opt/           # Installed Python versions and Miniforge
│   ├── python-3.8.20/
│   ├── python-3.10.22/
│   ├── python-3.11.18/
│   ├── python-3.13.18/
│   └── conda/     # Miniforge installation
├── src/           # Python source tarballs
├── shims/         # Version-specific entry points
└── CACHE/         # Cache directories
    ├── pip/
    ├── hf/        # HuggingFace
    ├── torch/
    ├── ollama/
    └── conda/
```

## Using installed Python versions
After adding `BASE_DIR/bin` to your PATH (done automatically unless `--no-bashrc` is used):

### Direct version commands
```bash
python3-11 --version       # Run Python 3.11 directly
pip3-13 install requests   # Use pip for Python 3.13
```

### Shell wrappers (recommended)
```bash
py11 bash -c 'python -V'              # Opens shell with Python 3.11
py13 python script.py                 # Run script with Python 3.13
py38 pip install -r requirements.txt  # Install packages with Python 3.8
```

### Conda usage
```bash
cbase                           # Activate conda base environment
cenv myenv                      # Activate conda environment 'myenv'
cenv myenv jupyter lab          # Run command in conda environment
conda create -n myenv python=3.11
```

## Notes
- Script validates Python downloads with OpenPGP signatures from keyservers
- Builds use `--with-ensurepip=upgrade`; the script does not enable PGO.
- Cached source archives pass OpenPGP verification before use, including on `--reuse`.
- Existing prefixes must report the pinned version before the build is skipped.
- Conda is configured to NOT auto-activate base environment on shell startup
- If installation is interrupted, use `--reuse` to resume without re-downloading/rebuilding
- The `--py` flag is useful for faster installs when you only need specific versions
- PATH modifications are appended to `~/.bashrc` automatically (disable with `--no-bashrc`)

## Uninstalling
```bash
sudo rm -rf /path/to/BASE_DIR
# Then manually remove the PATH block from ~/.bashrc if added
```

## Security
- Downloads from python.org and github.com (Miniforge)
- Python tarballs are verified with GPG signatures from official Python release managers
- Keys fetched from: keyserver.ubuntu.com, keys.openpgp.org, pgp.mit.edu

## Existing environments

Installing a new prefix leaves existing venv interpreter references in place. Use
[update_python_envs.sh](update_python_envs.sh) to find and patch private raw
installations and venvs. See [update_python_envs.md](update_python_envs.md) for
planning, validation, backups, rollback, and directory-link handling.

Both scripts use native Bash and Unix utilities, with no embedded Python source.
Interpreter checks use version and module command interfaces. Reuse validates
core imports and pip; an incomplete installation with the expected version is
rebuilt, while a prefix containing another version is rejected. Cached source
archives undergo signature verification on reuse.

```bash
bash install_python.sh /path/to/patched-runtimes --skip-conda --jobs 4 --no-bashrc
```

Release policy checked on 2026-11-02. Python 3.8 and 3.10 have reached end of
support. Their final patch releases require explicit selection and emit a
warning. Migration to a supported branch is required for ongoing security
maintenance. The CPython updater delegates existing Conda environments to the
Conda solver.
