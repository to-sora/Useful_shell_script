---
name: use-installed-python
description: Use an existing Python/Miniforge installation created by install_python.sh on another PC; apply when locating the BASE_DIR layout, activating shims/entrypoints, setting PATH, or validating the install without re-running the installer.
---

# Use an existing install_python.sh setup

## What to collect
- The original BASE_DIR (top-level folder that contains `bin/`, `opt/`, `CACHE/`, `shims/`).
- Whether you will use shell PATH or call entry scripts directly.

## Quick start (most reliable)
1. Set PATH for the session:
   `export PATH="<BASE_DIR>/bin:$PATH"`
2. Use entrypoints:
   - `py38`, `py10`, `py11` for CPython shells or commands.
   - `python38`, `python3-10`, `python3-11` to run specific versions.
   - `pip38`, `pip3-10`, `pip3-11` for versioned pip.
   - `conda`, `cbase`, `cenv` for Miniforge/conda.

## Verify installation (non-destructive)
- `python3-11 -V`
- `py11 bash -lc 'python -V; pip --version'`
- `conda --version`

## Conda usage
- Base shell: `cbase`
- Activate env: `cenv <envname>`
- Optional command: `cenv <envname> <command...>`

## Troubleshooting
- If entrypoints missing, check `<BASE_DIR>/bin` and `<BASE_DIR>/shims/*/bin`.
- If `conda` fails, verify `<BASE_DIR>/opt/conda` exists and `conda` is linked in `<BASE_DIR>/bin`.
- If caches are not writable, ensure the user owns `<BASE_DIR>/CACHE`.

## Notes
- The install is per-BASE_DIR; multiple BASE_DIRs can coexist.
- No system-wide `conda init` is required; wrappers avoid shell modification.
