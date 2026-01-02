# venv_requirements_dump.sh

Scan a directory for Python virtual environments and export each venv’s installed packages via `pip freeze`.

## What it does
- Searches under `~/program_self_guest/` for files named `activate`.
- For each found venv:
  - `source` the `activate` script (activates the venv)
  - Prints disk usage of the parent project folder (`du -sh <venv>/../`)
  - Prints `pip --version`
  - Writes `pip freeze` output to a requirements file
  - Runs `deactivate`

## Requirements
- Bash
- Python venvs that provide an `activate` script
- `pip` available inside each venv

## Paths you must edit
- Search root:
  - `find ~/program_self_guest/ ...`
  Change this to your own projects root.

- Output file path:
  - `pip freeze > "$(dirname $activate_script)/../../../past/requirements.txt"`
  Update to where you want requirements saved.  
  Note: current script writes **all venv outputs to the same file**, so later venvs overwrite earlier ones.

## Usage
```bash
bash venv_requirements_dump.sh
````

## Notes / assumptions

* Assumes each `activate` belongs to a valid venv and supports `deactivate`.
* Assumes you are running interactively (sourcing in a subshell spawned by the script).
* If you want one file per venv, change the output path to include a unique name (e.g. based on folder name).

```
```
