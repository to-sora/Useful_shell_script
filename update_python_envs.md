# update_python_envs.sh

Discover and patch private CPython installations and venvs on Linux. The updater
is one executable Bash file containing its Python standard-library engine. It
requires a control Python 3.8 or newer; no companion `.py` file or pip dependency
is required. `PY_ENV_UPDATER_PYTHON=/path/to/python3` selects the control interpreter.

## Scope

- Searches hidden directories and arbitrary environment names.
- Follows directory links, including targets outside the supplied starting roots.
- Tracks directory device/inode identities to terminate link cycles.
- Executes each candidate `bin/python*` through its invocation path, preserving
  venv identity when the executable is a symlink to a raw installation.
- Uses `sys.prefix`, `sys.base_prefix`, architecture, SOABI, and build settings.
- Preserves third-party package versions, activation paths, and console scripts.
- Records missing binaries, broken links, malformed environments, and skip reasons.
- Keeps backups and a journal; supports validation and rollback.

Use trusted roots owned by the invoking account: discovery executes candidate
interpreters. Run without sudo. Host-root execution is rejected; the disposable
single-UID test container is the documented exception. The updater excludes the
interpreter running the updater, distribution/runtime-managed locations, and
Conda-managed prefixes/caches. Existing Conda environments require the Conda solver.

Updates stay within the same Python minor branch. Cross-minor migration, shared
raw builds requiring prefix-specific rebuilding, and legacy environments without
usable metadata need a separate rebuild. Unsupported ABI combinations and
interpreter downgrades are rejected.

## Build patched target interpreters

Use a separate installation directory. The updated installer defaults to 3.11
and 3.13; explicit selections include the final 3.8 and 3.10 releases.

```bash
bash install_python.sh /path/to/patched-runtimes \
  --py "3.8 3.10 3.11 3.13" --skip-conda --jobs 4 --no-bashrc
```

Policy date: 2026-11-01. Target minimum versions are 3.8.20, 3.10.22, 3.11.18,
and 3.13.18. Newer stable patch releases in the same minor branch can be supplied.
Python 3.8 and 3.10 are end-of-life. A patch update within those branches cannot
provide ongoing upstream security maintenance; migrate applications to a supported
branch. The tested 3.8.20 target retains the two security issues described below.

## Scan and plan

```bash
bash update_python_envs.sh scan /path/to/projects /path/to/raw-installs \
  --output inventory.json

bash update_python_envs.sh plan /path/to/projects /path/to/raw-installs \
  --target 3.8=/path/to/patched-runtimes/opt/python-3.8.20/bin/python3.8 \
  --target 3.10=/path/to/patched-runtimes/opt/python-3.10.22/bin/python3.10 \
  --target 3.11=/path/to/patched-runtimes/opt/python-3.11.18/bin/python3.11 \
  --target 3.13=/path/to/patched-runtimes/opt/python-3.13.18/bin/python3.13 \
  --output plan.json
```

Review canonical paths, aliases, findings, and skip reasons. Supply `--exclude
/path` to exclude a tree. A raw base referenced outside the scanned trees is
reported and skipped until its path is supplied as a root. A directory link in a
supplied tree authorizes traversal to its target.

Broken nonstandard aliases such as `python999 -> /missing/python` retain an
unresolved finding because the intended interpreter is unknown. Standard aliases
(`python`, `python3`, and `python<minor>`) must pass validation. A formerly working
alias that disappears fails its recorded integrity check.

## Apply and verify

Stop applications using the selected environments. Allow space for staging,
backups, and failed-state copies during rollback. Publication spans multiple file
operations; the prefix directory retains its identity. Insufficient disk space
can prevent recovery. Successful backups remain beside their original prefixes.

```bash
bash update_python_envs.sh apply /path/to/projects /path/to/raw-installs \
  --target 3.11=/path/to/patched-runtimes/opt/python-3.11.18/bin/python3.11 \
  --target 3.13=/path/to/patched-runtimes/opt/python-3.13.18/bin/python3.13 \
  --checks application-checks.json --output update-journal.json

bash update_python_envs.sh verify update-journal.json \
  --checks application-checks.json --output verification.json

bash update_python_envs.sh rollback update-journal.json
```

`--checks` is optional. Its JSON maps absolute-prefix glob patterns to argument
arrays. Commands run without a shell. `{python}` expands to the environment's
Python; `{prefix}` expands to its path. Use `final_only` for console scripts whose
existing shebang names the original prefix.

```json
{
  "*/LLaMA-Factory/.venv": [
    {"argv": ["{python}", "-I", "-c", "import torch, llamafactory"]},
    {"argv": ["{prefix}/bin/llamafactory-cli", "version"], "final_only": true}
  ]
}
```

Package inventories are captured before updating shared raw bases. Each prefix
is staged and checked for interpreter version, prefix identity, core imports,
package versions, `pip check`, and supplied commands. The installed prefix is
checked again, followed by a complete batch recheck using interpreter and native
module hashes. Bash then launches a second process to verify the persisted state;
that report is written to `<journal>.post-verify.json`. A failure returns nonzero. A per-prefix install/validation failure restores its backup. A
batch recheck failure records the affected prefix and returns a nonzero status;
retained backups support explicit rollback.

The journal separates successful updates, skipped prefixes, end-of-support
findings, and unresolved aliases. Empty metadata directory trees left by pip are
recorded and ignored; populated, incomplete metadata fails the snapshot. Snapshot
failures return nonzero, appear in verification results, and block updating the
affected venv's raw base. Other healthy venvs can use the separate patched target. Directories containing `.pyenv-update-` are
reserved for locks, staging, backups, and failed-state copies and are excluded
from discovery. Third-party package vulnerability upgrades are outside this tool.

## Validation

Tested on 2026-11-01 in an Ubuntu 24.04 x86-64 CPU container. The old installer
at commit `868050ea7617e49710df890e335c33443ab2c4a0` built the baseline runtimes.
The updated installer built 3.11.18 and 3.13.18 and installed Miniforge 26.9.4-1.
Both installer runs used a container-only adapter that removed the root guard
and added `tar --no-same-owner`; the distributed installer retains its guard.
Source signatures were checked. `--skip-conda` reuse, a tampered cached archive,
and a prefix containing the wrong Python version were tested.

### Environment matrix

| Branch | Old runtime | Patched runtime | Venvs |
|---|---|---|---:|
| 3.8 | 3.8.19 | 3.8.20 | 8 |
| 3.10 | 3.10.18 | 3.10.22 | 8 |
| 3.11 | 3.11.13 | 3.11.18 | 8 |
| 3.13 | 3.13.11 | 3.13.18 | 8 |

All 32 venvs and four raw prefixes passed the shell updater's verification.
Fixtures used `.venv`, `venv`, `virtual-env`, `vitral-env`, `env`, a path with
spaces, `banana-42`, and an external directory reached through a symlink.
Packages included requests, pytest, rich, typer, black, httpx, PyYAML, and numpy.
The run checked 100 working interpreter entries, 104 path invocations, 32
activations, eight installer entry points, package inventories, `pip check`, and
tool imports/CLIs. A second plan proposed zero updates. Four pre-existing,
nonstandard broken `python999` links remained explicit unresolved findings.

Additional cases covered standard broken interpreter links, copied binaries,
directory-link cycles, system-site-packages, forced failure recovery, explicit
rollback, empty/corrupt metadata, refusal of cross-minor and below-policy targets,
and verification from a fresh process after publication. A corrupt venv snapshot
was confirmed to leave its raw base unchanged. The fresh-process check was added
after an earlier reused fixture exposed a stale interpreter-link view after the
updating process exited; that fixture passed the added check and a caller-side
version check on the final run.

### Application boot checks

Applications were installed using the old runtimes, started and tested, stopped,
patched through this `.sh`, and started again. The table records successful
before/after checks; these are CPU compatibility checks, not GPU validation.

| Application revision | Python update | Before and after |
|---|---|---|
| [LLaMA-Factory `9997aa078b4d`](https://github.com/hiyouga/LLaMA-Factory/commit/9997aa078b4da35e04bb492a8a27d45141f4b80b) | 3.11.13 → 3.11.18 | CLI starts; Web UI `/` and `/config` return HTTP 200; 290 UI components |
| [ComfyUI `6d352802d8f8`](https://github.com/Comfy-Org/ComfyUI/commit/6d352802d8f8b9133f664a1757d6c6d26390c335) | 3.13.11 → 3.13.18 | CPU server starts; `/system_stats` and 1,033-node catalog work; `EmptyImage → SaveImage` produces a 64×64 PNG |
| [llama.cpp `dde879bc4f95`](https://github.com/ggml-org/llama.cpp/commit/dde879bc4f954b809892fd0d660515f42536394a) | 3.11.13 → 3.11.18 | Python converter help and GGUF reader work; native server health passes and generates eight tokens |

LLaMA-Factory used a symlinked venv interpreter and editable installation.
ComfyUI used a copied interpreter in an arbitrarily named external directory
reached through `ComfyUI/python-env`. llama.cpp used a copied interpreter in
`venv`, also invoked through a directory link. No application source was changed.
Installed distribution versions were preserved: 118 for LLaMA-Factory, 85 for
ComfyUI, and 29 for llama.cpp; all passed `pip check` and CPU tensor operations.
CPU torch was 2.15.0+cpu for the first two and 2.11.0+cpu for llama.cpp's converter.

ComfyUI's environment contained an empty `pip-25.3.dist-info` remnant. After the
update, `pip freeze` inferred 25.3 from that directory name even though the pip
module and valid metadata were 26.2.2. The comparison used valid distribution
metadata against the baseline inventory; every installed version matched. Empty
remnants are recorded rather than treated as installed packages.

llama.cpp's server is a native C++ program; its executable hash was unchanged.
The test model was the project's pinned
[stories15M.gguf fixture](https://huggingface.co/ggml-org/models/resolve/499bc8821c6b12b4e53c5bffcb21ec206f212d81/tinyllamas/stories15M.gguf),
SHA-256 `61b50d457809a5194818fd22e6724b456cd7bb9a6264c52c8110684c53f3704a`.
The Python GGUF reader found 57 tensors; the native completion was identical
before and after. This does not establish compatibility for GPU training,
diffusion-model inference, custom nodes, or every model conversion.

Boot commands used the existing environment paths:

```bash
GRADIO_SERVER_NAME=127.0.0.1 GRADIO_SERVER_PORT=17860 GRADIO_SHARE=0 \
  /path/to/LLaMA-Factory/runtime-link/bin/llamafactory-cli webui

cd /path/to/ComfyUI
./python-env/bin/python main.py --cpu --listen 127.0.0.1 \
  --port 18188 --disable-auto-launch

cd /path/to/llama.cpp
./runtime-link/bin/python convert_hf_to_gguf.py --help
/path/to/build/bin/llama-server -m /path/to/stories15M.gguf \
  --host 127.0.0.1 --port 18080 -t 2 -c 256 --n-gpu-layers 0
```

Local-only boot tests cleared proxy environment variables. Application dependencies
were resolved in one pip transaction per fresh environment before recording the
baseline. Some initial pip uninstall operations left stale metadata; those failed
setup attempts were excluded from the accepted application fixtures.

### Security regressions and limits

Local sentinel tests reproduced CVE-2026-15806 (credential scheme matching) and
CVE-2026-82049 (tar hard-link/symlink filtering) on all four old runtimes. Updated
3.10.22, 3.11.18, and 3.13.18 passed both regression checks. Python 3.8.20 still
failed both. These two checks are not a complete vulnerability audit. Python 3.8
and 3.10 remain end-of-life; installed packages and operating-system libraries
need their own maintenance.

Shell syntax, repository-wide ShellCheck at error severity, and the repository's
shfmt check passed. The local legacy ACL coverage suite was blocked by the
container's single-UID mapping (`setfacl` could not assign an ACL to `nobody`).

## Sources

- [CVE-2026-15806: credential scheme matching](https://mail.python.org/archives/list/security-announce%40python.org/message/3OKPE5S75KDNA7FY7AI3PL2MXM2X5RB3/)
- [CVE-2026-82049: archive link filtering](https://mail.python.org/archives/list/security-announce%40python.org/thread/EFJWGAZJA56AKSBR2WHMHQZO7RRLZPRH/)
- [Python branch status](https://devguide.python.org/versions/)
- [Python 3.11.18](https://www.python.org/downloads/release/python-31118/)
- [Python 3.13.18](https://www.python.org/downloads/release/python-31318/)
- [Python 3.10.22](https://www.python.org/downloads/release/python-31022/)
- [Python 3.8.20](https://www.python.org/downloads/release/python-3820/)
