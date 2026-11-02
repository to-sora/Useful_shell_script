# update_python_envs.sh

Patch private CPython installations and virtual environments on Linux with one
native Bash script. Discovery, planning, metadata parsing, copying, validation,
and rollback use Bash and Unix utilities. There is no embedded/generated Python
source, Python `-c` command, companion Python file, or Python control interpreter.
The installed Python binaries are invoked through `--version` and existing
modules (`sysconfig`, `venv`, `pip`, and `pydoc`).

## Requirements and scope

Use Bash 4+, GNU findutils/coreutils, awk, jq, rsync, and util-linux `flock`.
Use trusted roots owned by the invoking account: discovery executes candidate
interpreters. Run without sudo. Host-root execution is rejected; a disposable
container with the sole UID mapping `0 0 1` is the test exception.

The scan follows directory links, including links to targets outside the supplied
roots. GNU find reports link cycles. Environment names do not determine detection:
`pyvenv.cfg` and actual ELF `bin/python*` executables identify candidates. Each
binary is invoked through its discovered path, so interpreter symlinks retain
venv identity. `python -I -m sysconfig` supplies the prefix, base prefix, SOABI,
architecture, and build settings. Canonical prefixes deduplicate aliases.

Updates preserve the Python minor branch, installed package versions, console
scripts, and activation paths. The tool rejects downgrades and ABI mismatches;
it skips distribution/runtime-managed prefixes, Conda prefixes/package caches,
shared raw builds, and prefixes with linked `bin` or `lib` subdirectories.
Directory links to whole environments are supported. Conda needs its own solver.
Legacy or unusable environments need a rebuild. A referenced raw base outside the
scanned trees is reported and skipped until its path is supplied as a root.

Package records are read from `*.dist-info/METADATA` and `*.egg-info/PKG-INFO`
in the prefix's standard site-packages/dist-packages directories. Inherited base
packages are included for `include-system-site-packages`. Empty metadata trees
are recorded; populated metadata with no name/version fails the snapshot. Custom
package paths supplied through `.pth` code, plugins, or environment variables need
application-specific validation. This tool does not upgrade third-party packages.

Paths containing spaces are supported. Tabs and line breaks are rejected.
Names containing `.pyenv-update-` are reserved and excluded from discovery.

## Targets, scan, and plan

Policy checked on 2026-11-02: minimum targets are 3.8.20, 3.10.22, 3.11.18, and
3.13.18. Newer stable patch releases in these branches may be supplied. Python
3.8 and 3.10 have reached end of support. Their final releases do not provide
ongoing security maintenance; migration requires a supported minor branch.

Build targets in a separate directory:

```bash
bash install_python.sh /path/to/patched-runtimes \
  --py "3.8 3.10 3.11 3.13" --skip-conda --jobs 4 --no-bashrc

bash update_python_envs.sh scan /path/to/projects /path/to/raw-installs \
  --output inventory.json

bash update_python_envs.sh plan /path/to/projects /path/to/raw-installs \
  --target 3.8=/path/to/patched-runtimes/opt/python-3.8.20/bin/python3.8 \
  --target 3.10=/path/to/patched-runtimes/opt/python-3.10.22/bin/python3.10 \
  --target 3.11=/path/to/patched-runtimes/opt/python-3.11.18/bin/python3.11 \
  --target 3.13=/path/to/patched-runtimes/opt/python-3.13.18/bin/python3.13 \
  --output plan.json
```

Review prefixes, binary aliases, discovery warnings, and skip reasons. Repeat
`--exclude /path` to exclude trees. Supplying a directory link authorizes traversal
to its target. Standard broken aliases (`python`, `python3`, `python<minor>`)
are repaired when another binary identifies the environment. Unknown broken
aliases such as `python999 -> /missing/python` remain unresolved findings.

## Apply, verify, and rollback

Stop applications and file synchronization jobs that write to the selected
environments. Publication and rollback
span multiple file operations; neither provides a live-process upgrade or crash
atomicity. Retain disk space for a full stage and backup. The prefix directory
keeps its identity. Rsync replaces changed files and link types through temporary
files and renames, including transitions between symlinks and copied binaries.

```bash
bash update_python_envs.sh apply /path/to/projects /path/to/raw-installs \
  --target 3.11=/path/to/patched-runtimes/opt/python-3.11.18/bin/python3.11 \
  --target 3.13=/path/to/patched-runtimes/opt/python-3.13.18/bin/python3.13 \
  --checks application-checks.json --output update-journal.json

bash update_python_envs.sh verify update-journal.json \
  --checks application-checks.json --output verification.json

bash update_python_envs.sh rollback update-journal.json
```

`--checks` is optional. JSON keys are absolute-prefix glob patterns; values are
lists of argument arrays. Commands run without an implicit shell. `{python}`
expands to the environment's Python binary; `{prefix}` expands to the current
prefix. Use `final_only` for existing console scripts that name the live prefix
in their shebang. Checks must have no unwanted side effects.

```json
{
  "*/LLaMA-Factory/.venv": [
    {"argv": ["{prefix}/bin/llamafactory-cli", "version"], "final_only": true}
  ],
  "*/venv": [
    {"argv": ["{python}", "-I", "-m", "pip", "check"], "timeout": 120}
  ]
}
```

The script snapshots package metadata before changing any raw base. Staged and
installed environments must pass version/prefix checks for every interpreter,
core-module imports, package-inventory comparison, `pip check` when available,
and supplied application checks. Runtime binary/native-module hashes protect
verification. A fresh Bash process verifies the complete batch and writes
`<journal>.post-verify.json`.

A per-prefix installation or validation failure restores that prefix and prior
updates in the batch. A failed final batch verification triggers rollback.
Snapshot failures return nonzero and block the affected venv's raw base; healthy
peers may update using a separate target. Skips and EOL/unknown-alias findings
remain visible even when the supported updates pass. No claim of complete
vulnerability elimination is implied by a zero exit status.

Keep the journal, adjacent `<journal>.entries/` directory, and adjacent-prefix
`.pyenv-update-*.backup` and `.pyenv-update-*.stage` directories together for
recovery. Staged trees and backups are retained until removed by the owner.
Journal schema 2 is
for this Bash implementation; journals from the former Python engine are not
compatible. The locks prevent concurrent updater instances in the same parent
directories. Interrupted operations require journal review and rollback before
applications restart.

## Validation

Tested on 2026-11-02 in an Ubuntu 24.04 x86-64 CPU container. Baseline installer:
`868050ea7617e49710df890e335c33443ab2c4a0`. All eight old/target CPython releases
were compiled from source; all eight source signatures passed verification.
The old and updated installer flows, wrappers, and Miniforge installations
(25.9.1-0 and 26.9.4-1) were exercised.

The container-only installer adapters removed the root guard, added
`tar --no-same-owner`, and limited builds to four jobs. Configure used
`CONFIG_SHELL=/bin/bash`; incomplete build artifacts required clean build
restarts. CPython source code was unchanged. The distributed installer retains
its root guard. An incomplete 3.11 target was rebuilt through the updated reuse
path. Reuse with `--skip-conda`, cached-archive tampering, wrong-version prefixes,
invalid job counts, and unknown branches were checked.

A background workspace synchronizer reverted runtime files during initial runs.
The accepted runs used a temporary directory outside that synchronized tree.
The original runtime/package files were relocated, baseline activation paths
were repaired, and all 32 old-runtime activations and three baseline application
boots passed before the accepted update. Application source revisions were
unchanged.

### Environment matrix

| Branch | Baseline | Target | Test venvs |
|---|---|---|---:|
| 3.8 | 3.8.19 | 3.8.20 | 8 |
| 3.10 | 3.10.18 | 3.10.22 | 8 |
| 3.11 | 3.11.13 | 3.11.18 | 8 |
| 3.13 | 3.13.11 | 3.13.18 | 8 |

The accepted batch updated four raw prefixes, 32 test venvs, and three application
venvs: **39 updates**. Batch verification and verification from a separate command
session passed all 39 prefixes and **109 working interpreter entries**.

Independent matrix checks passed 104 path invocations, 32 activations, eight
original installer entry points, package-inventory comparisons, `pip check`, and
tool imports/CLIs. All 32 activation-file hashes matched the working baseline.
A second plan proposed **zero updates**; the Conda prefix and its Python package
cache were recorded as skips.

The eight names were `.venv`, `venv`, `virtual-env`, `vitral-env`, `env`,
`project with spaces/runtime`, `banana-42`, and a linked external runtime named
`unconventional-867`. Tools were requests, pytest, rich, typer, black, httpx,
PyYAML, and numpy. Fixtures included copied binaries, interpreter links,
directory links, parent-directory aliases, link cycles, and inherited base
packages. Four pre-existing broken `python999` aliases remain unresolved findings.

Additional tests passed for:

- Repairing a broken standard interpreter alias; updating and restoring custom
  copied `python313` binaries in raw and venv prefixes.
- Forced final-check failure, rollback of earlier updates in the batch, explicit
  rollback, and restoration of original interpreter/stdlib/configuration hashes.
- Empty metadata records, corrupt metadata blocking a dependent raw base, and
  updating a healthy peer through a separate target.
- Cross-minor and below-policy target rejection, concurrent-lock rejection,
  invalid journal rejection, and detection of a changed runtime-file hash.
- Conda exclusion and `--exclude` handling through a directory alias.

### Application boot checks

Applications were installed on old runtimes, booted, stopped, updated through the
same Bash batch, and booted again. Package inventories and `pip check` passed
before and after: 118 distributions for LLaMA-Factory, 85 for ComfyUI, and 29 for
llama.cpp's Python tooling. The venv paths and console entry points were retained.

| Application revision | Python update | Before and after |
|---|---|---|
| [LLaMA-Factory `9997aa078b4d`](https://github.com/hiyouga/LLaMA-Factory/commit/9997aa078b4da35e04bb492a8a27d45141f4b80b) | 3.11.13 → 3.11.18 | CLI version works; Web UI `/` and `/config` return HTTP 200; 290 components |
| [ComfyUI `6d352802d8f8`](https://github.com/Comfy-Org/ComfyUI/commit/6d352802d8f8b9133f664a1757d6c6d26390c335) | 3.13.11 → 3.13.18 | CPU server boots; 1,033-node catalog; `EmptyImage → SaveImage` produces a 64×64 PNG |
| [llama.cpp `dde879bc4f95`](https://github.com/ggml-org/llama.cpp/commit/dde879bc4f954b809892fd0d660515f42536394a) | 3.11.13 → 3.11.18 | Converter help and GGUF reader work; native server health succeeds and generates eight tokens |

LLaMA-Factory used an editable install and interpreter symlinks. ComfyUI used a
copied interpreter in an external, arbitrarily named directory reached through
`ComfyUI/python-env`. llama.cpp used a copied interpreter in `toolchain-python`,
with a `runtime-link` directory alias. Torch was 2.15.0+cpu for the first two and
2.11.0+cpu for llama.cpp's converter dependencies.

llama.cpp's server is native C++; its executable hash and generated completion
were unchanged. The GGUF reader found 57 tensors in the project's pinned
[stories15M.gguf fixture](https://huggingface.co/ggml-org/models/resolve/499bc8821c6b12b4e53c5bffcb21ec206f212d81/tinyllamas/stories15M.gguf),
SHA-256 `61b50d457809a5194818fd22e6724b456cd7bb9a6264c52c8110684c53f3704a`.
After relocating the lab, the native server used `LD_LIBRARY_PATH` pointing to
its build's `bin` directory in both baseline and updated runs.

Boot commands used the existing environment entry points:

```bash
GRADIO_SERVER_NAME=127.0.0.1 GRADIO_SERVER_PORT=17860 GRADIO_SHARE=0 \
  /path/to/LLaMA-Factory/runtime-link/bin/llamafactory-cli webui

cd /path/to/ComfyUI
./python-env/bin/python main.py --cpu --listen 127.0.0.1 \
  --port 18188 --disable-auto-launch

cd /path/to/llama.cpp
./runtime-link/bin/python convert_hf_to_gguf.py --help
LD_LIBRARY_PATH=/path/to/build/bin /path/to/build/bin/llama-server \
  -m /path/to/stories15M.gguf --host 127.0.0.1 --port 18080 \
  -t 2 -c 256 --n-gpu-layers 0
```

These checks cover CPU boot and the listed operations. GPU training, diffusion
model inference, custom nodes, and every model conversion were not tested.

### Security checks and static validation

Upstream CPython regression cases reproduced CVE-2026-15806 (credential scheme
matching) and CVE-2026-82049 (archive hard-link/symlink filtering) on all four old
runtimes. Updated 3.10.22, 3.11.18, and 3.13.18 passed both cases. Python 3.8.20
still failed both. The 3.8 test used compatible upstream test helpers; failures
were assertions about the vulnerable behavior, not import/setup errors. These
two checks do not establish that all vulnerabilities are fixed. Python 3.8 and
3.10 remain end-of-life.

Both shipped scripts passed Bash syntax and repository-wide ShellCheck at error
severity. The updater and repository-required shfmt checks passed. Source
inspection found no embedded Python, Python heredoc, Python `-c`, or Python
controller dependency in either script. Test drivers used Bash; security tests
invoked upstream test modules through the interpreter's module CLI.

The local legacy ACL coverage suite stops at `setfacl` because the single-UID
container cannot represent `nobody`. GitHub CI results are recorded in the PR.

## Sources

- [Python branch status](https://devguide.python.org/versions/)
- [Python 3.13 changelog and security fixes](https://docs.python.org/3.13/whatsnew/changelog.html)
- [CVE-2026-15806: credential scheme matching](https://mail.python.org/archives/list/security-announce%40python.org/message/3OKPE5S75KDNA7FY7AI3PL2MXM2X5RB3/)
- [CVE-2026-82049: archive link filtering](https://mail.python.org/archives/list/security-announce%40python.org/thread/EFJWGAZJA56AKSBR2WHMHQZO7RRLZPRH/)
- [Python 3.11.18](https://www.python.org/downloads/release/python-31118/)
- [Python 3.13.18](https://www.python.org/downloads/release/python-31318/)
- [Python 3.10.22](https://www.python.org/downloads/release/python-31022/)
- [Python 3.8.20](https://www.python.org/downloads/release/python-3820/)
