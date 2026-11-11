# update_python_envs.sh

Patch private CPython installations and virtual environments on Linux with one
native Bash script. Discovery, planning, metadata parsing, copying, validation,
and rollback use Bash and Unix utilities. There is no embedded/generated Python
source, Python `-c` command, companion Python file, or Python control interpreter.
The installed Python binaries are invoked through `--version` and existing
modules (`sysconfig`, `venv`, `pip`, and `pydoc`).

## Quick start

Stop applications using the selected environments, then run as their owner:

```bash
bash update_python_envs.sh apply "$HOME"
```

This scans the root, reads the existing version pins from `install_python.sh`,
reuses healthy cached or discovered private Python installations, and builds
missing targets for branches that need an update. It then asks for `y` for each
venv, backs up approved environments, applies the update and verifies the batch.
Failed update validation triggers rollback. `--target` and `--output` are optional.

Omitting roots defaults to `$HOME`. To bypass venv confirmations:

```bash
bash update_python_envs.sh -Y apply
```

The console prints `Log:` and `Output:` paths. The default recovery journal is
`log/<UTC timestamp>.<unique suffix>/journal.json` next to the script. The same
directory contains `process.log`. `--print-pins` on the installer only prints
version numbers; it does not install Python or update environments.

## Requirements and scope

Use Bash 4+, GNU findutils/coreutils (including `tee`), awk, jq, rsync, and util-linux `flock`.
Use trusted roots owned by the invoking account: discovery executes candidate
interpreters. Run without sudo. Host-root execution is rejected; a disposable
container with the sole UID mapping `0 0 1` is the test exception.

On Ubuntu, `apply` installs missing `jq`/`rsync` through apt and invokes the
adjacent installer for missing target runtimes. Building requires network access,
disk space and the installer's compilation dependencies. Sudo may request a
password. `-Y` bypasses venv confirmations; sudo authentication follows the host
configuration. `--skip-apt` uses preinstalled dependencies, and `--no-sudo` also
implies `--skip-apt`. `--jobs N` controls compilation workers (default: 4).
Other Linux distributions can use compatible preinstalled targets; the bundled
source installer expects Ubuntu.

The scan resolves each supplied root and walks its physical directories. It prunes
`.git`, `node_modules`, exclusions, and updater work directories. A directory link
under a root is recorded in the inventory. To include an external environment,
supply its directory or the link to it as another root. This handles aliases
and cycles without entering other trees. An interpreter link to an external
base also requires that base as a root, except for validated explicit targets
and updater-managed cached targets. A copied venv can be updated when its
original base is outside the scan. Cache, log and selected target directories
are pruned from the physical walk.

Discovery requires a venv configuration or a CPython standard library in the
prefix. It checks the resolved binary's scope before invoking it through its
`bin/python*` path and checks that its reported prefix matches the directory
being inspected. `python -I -m sysconfig` supplies the identity and ABI.

Updates preserve the Python minor branch, installed package versions, console
scripts, and activation paths. The tool rejects downgrades and ABI mismatches;
it skips distribution/runtime-managed prefixes, Conda prefixes/package caches,
shared raw builds, and prefixes with linked `bin`, `lib`, or `pyvenv.cfg`.
Linked `pyvenv.cfg` files require a separate rebuild: staging must not write
through a configuration link to the live environment or a shared file.
System directories and the runtime tree named by `CODEX_PRIMARY_RUNTIME_ROOT`
are protected. Use `--exclude` for other managed installations. Conda needs its
own solver. Legacy or unusable environments need a rebuild.

Package records are read from `*.dist-info/METADATA` and `*.egg-info/PKG-INFO`
in the prefix's standard site-packages/dist-packages directories. Inherited base
packages are included for `include-system-site-packages`. Empty metadata trees
are recorded; populated metadata with no name/version fails the snapshot. Custom
package paths supplied through `.pth` code, plugins, or environment variables need
application-specific validation. This tool does not upgrade third-party packages.

Paths containing spaces are supported. Tabs and line breaks are rejected.
Names containing `.pyenv-update-` are reserved and excluded from discovery.

## Default targets, scan, and plan

Plan and apply read the minimum target versions from the adjacent installer.
Run `bash install_python.sh --print-pins` to print them. These are repository
pins, not a query for the latest upstream release. Scan, verify, and rollback
can run with the updater alone. Newer stable patch releases in the
listed branches may be supplied. Python
3.8 and 3.10 have reached end of support. Their final releases do not provide
ongoing security maintenance; migration requires a supported minor branch.

Automatic selection uses an explicit `--target` override first, a healthy
cached target second, and a healthy private raw installation from the scan
third. Targets must meet the pinned minimum for the same minor branch. Among
discovered candidates, the newest patch is preferred. ABI and ownership checks
also apply before an environment can update.

If a required target is missing, `apply` calls `install_python.sh` with
`--reuse --skip-conda --no-bashrc --py "<needed branches>"`. Only branches with
eligible environments needing an update are built, including pinned legacy
branches when present. An already current environment needs no build. Unknown
branches are reported as skips. Existing package versions and minor branches
are preserved.

The managed runtime directory defaults to
`${XDG_DATA_HOME:-$HOME/.local/share}/python-env-updater`; `--runtime-dir DIR`
overrides it. Each build gets a permanent `build-<timestamp>.<suffix>` directory
and the cache's `targets.json` records its interpreter paths. Failed or unhealthy
builds are replaced by a new build directory, never repaired in place underneath
dependent venvs. Keep these directories while venvs reference them. Target
preparation happens before venv confirmations and receives EOF on stdin;
declining an update can leave a prepared target for future use. A build failure
aborts before modifying existing environments. A cache lock prevents concurrent
builds in the same runtime directory.

Scan and preview with the same defaults:

```bash
bash update_python_envs.sh scan "$HOME"
bash update_python_envs.sh plan "$HOME"
```

`plan` performs no installations. Its JSON uses `prepare_target` for an eligible
environment that needs a target build, `update` for a ready update, and `skip`
with a reason for other environments. `requested_version` records the policy
pin; a selected target can be a newer patch. Output defaults to `inventory.json`
or `plan.json` inside the run's log directory. `--output FILE` overrides it.

Review prefixes, binary aliases, discovery warnings, and skip reasons. Repeat
`--exclude /path` to exclude trees. Standard broken aliases (`python`, `python3`, `python<minor>`)
are repaired when another binary identifies the environment. Unknown broken
aliases such as `python999 -> /missing/python` remain unresolved findings.

## Apply, verify, and rollback

Stop applications and file synchronization jobs that write to the selected
environments. Publication and rollback
span multiple file operations; neither provides a live-process upgrade or crash
atomicity. Retain disk space for a full stage and backup. The prefix directory
keeps its identity. Rsync replaces changed files and link types through temporary
files and renames. Publication and rollback use rsync with hard links, ACLs and
extended attributes enabled. The filesystem and account must support those
attributes. Venv upgrades preserve the original `pyvenv.cfg` prompt record.

```bash
bash update_python_envs.sh apply "$HOME" \
  --checks application-checks.json --output update-journal.json

bash update_python_envs.sh verify update-journal.json \
  --checks application-checks.json --output verification.json

bash update_python_envs.sh rollback update-journal.json
```

Apply requires a separate `y` or `Y` for every venv selected for updating. Each
prompt shows its path and old/target versions. Enter, `n`, or any other response
skips that venv. End-of-input aborts the apply before any environment is changed,
including when earlier prompts received `y`. Responses come from the original
standard input; workers and application checks continue to receive EOF.

All venv confirmations are collected before updating raw bases. A skipped venv
blocks an update to its discovered raw base, so declining it cannot change its
runtime indirectly. Approved peers can use the separate patch target instead.
Raw installations do not receive a separate prompt. Roots and exclusions define
discovery scope; dependent environments outside that scope are not prompted.

Use `-Y` for unattended updates. The option is accepted before or after `apply`:

```bash
bash update_python_envs.sh -Y apply "$HOME"
```

Keep the journal, its `.entries` directory, the post-verification output and
the process log outside every prefix selected for updating. Apply rejects
overlapping paths before creating the journal or changing environments, including
paths reached through directory symlinks. Verification rejects missing or empty
runtime hash manifests rather than treating them as a successful integrity check.

`--checks` is optional. JSON keys are absolute-prefix glob patterns; values are
lists of argument arrays. Commands run without an implicit shell. `{python}`
expands to the environment's Python binary; `{prefix}` expands to the current
prefix. Checks receive EOF on standard input. Use `final_only` for existing console scripts that name the live prefix
in their shebang. Checks must have no unwanted side effects.

```json
{
  "*/LLaMA-Factory/.venv": [
    {"argv": ["{prefix}/bin/llamafactory-cli", "version"], "final_only": true}
  ],
  "*/venv": [
    {"argv": ["{python}", "-I", "-m", "pip", "--version"], "timeout": 120}
  ]
}
```

The script snapshots package metadata and the conflicts reported by `pip check`
before changing any raw base. Existing conflicts are recorded in the journal.
New conflicts or a failure to run pip fail validation. Each staged and installed
environment must pass version/prefix checks, core-module imports, package
inventory comparison, and supplied application checks. Runtime binary/native-module hashes protect
verification. A fresh Bash process verifies the complete batch and writes
`<journal>.post-verify.json`.

A per-prefix installation or validation failure restores that prefix and prior
updates in the batch. A failed final batch verification triggers rollback.
Snapshot failures return nonzero and block the affected venv's raw base; healthy
peers may update using a separate target. Skips and EOL/unknown-alias findings
remain visible even when the supported updates pass. No claim of complete
vulnerability elimination is implied by a zero exit status.

Keep the journal, adjacent `<journal>.entries/` directory and each
`.pyenv-update-*.backup` for recovery. Rollback restores a prefix only after
the worker has finished the backup and recorded `publication_started: true`.
A `prepared` entry can have a partial backup. Rollback leaves that prefix
untouched. Verification releases the stage. Interrupted runs can leave a stage
or partial backup for inspection.
Journal schema 2 is
for this Bash implementation; journals from the former Python engine are not
compatible. The locks prevent concurrent updater instances in the same parent
directories. Interrupted operations require journal review and rollback before
applications restart.

## Process logs

The JSON journal remains the recovery record. Each public command (`scan`,
`plan`, `apply`, `verify`, `rollback`) also creates an independent text log at:

```text
<repository>/log/<UTC timestamp>.<unique suffix>/process.log
```

The root is next to `update_python_envs.sh`, regardless of the working directory.
For example, `log/20261111T090000Z.ABC123/process.log`. The suffix prevents
collisions when commands start in the same second. The run directory uses mode
700 and the log uses mode 600. `/log/` is ignored by Git.

The log preserves stdout and stderr while keeping both visible on their original
terminal streams. It records the invocation, confirmations and skips, update
stages, application-check output, validation failures, rollbacks, and final exit
code. Target selection, dependency installation and target builds share this
log. The command waits for the log writers before returning. Apply workers and
the final batch verification share the outer log. An explicit later verification
or rollback starts a new log. The journal's `log_file` field locates its apply log.

Discovery and planning snapshots are saved alongside `process.log` as
`inventory.json` and `plan.json`; apply also saves `approved-plan.json` with the
confirmation decisions. Use `--log-dir /path/to/logs` to choose another log root;
the timestamp directory is created beneath it. A writable log destination is
required before the operation starts. Logs inside a prefix selected for updating
are rejected. Argument-parsing errors occur before log setup; missing updater
dependencies are reported after logging starts. Logging itself needs GNU
coreutils and Bash.

## Validation

The Bash regression suite takes two private interpreter binaries from the same
minor branch. It creates disposable venvs, a partial backup, and an installation
with a missing module. It requires `setfacl`, `getfacl`, `setfattr`, and
`getfattr` on a filesystem that supports ACLs and user xattrs.

```bash
bash tests/python-updater.bash /path/to/old/bin/python3.11 /path/to/patched/bin/python3.11
```

The suite includes `tests/python-updater-controls.bash`, which can also run with
the same two interpreter arguments. It covers journal placement through physical
and linked paths, linked configuration preservation, affirmative/negative/empty
responses, EOF before publication, `-Y`, protection of declined venvs' raw bases,
hash-manifest rejection, explicit and automatic rollback, and log contents,
location, permissions, and exit status. These tests are local regression commands;
this change does not modify CI/CD configuration.

The suite also includes `tests/python-updater-auto.bash`. It uses real old and
patched CPython interpreters while replacing the installer's network/build step
with a fixture that copies the patched installation into the requested layout.
It covers planning without builds, automatic preparation and output paths,
confirmation input isolation, cache and discovered-target reuse, explicit
overrides, repeat runs, failed builds, and replacing unhealthy caches without
mutating their existing dependents. This fixture tests orchestration; it does
not exercise Ubuntu apt, source downloads or compilation.

The November 11 automatic-update revision passed the complete suite with private
CPython 3.8.19 and 3.8.20 builds, including the control/log and automatic-flow
tests. Bash syntax checks and ShellCheck 0.10.0 at error severity passed for the
modified scripts. Ubuntu dependency installation and source builds were not
rerun for this revision; the earlier installer validation is recorded below.

### November 8 review and compatibility tests

The original installer at `868050e` and the revised installer built all eight
releases in the matrix below on Ubuntu 24.04 x86-64. Source signatures passed
for all eight archives. Test copies adapted the installer root guard, tar
ownership and build parallelism for the single-UID container. Both Miniforge
installations completed. A damaged archive and wrong-version prefix were
rejected. Removing the SQLite extension from a private 3.11 installation
produced a diagnostic naming `sqlite3`, a successful rebuild and a successful
reuse check.

The regression suite passed on 3.8, 3.10, 3.11 and 3.13. A backup-copy fixture
created a partial backup and sent `SIGKILL` to the update worker. Rollback
preserved the live sentinel and interpreter. Direct restore rejected the
unpublished entry. An existing unsatisfied pip dependency passed the update,
and adding another dependency to the same distribution caused verification
to fail. Probe tracing found zero invocations of the external, `.git`,
`node_modules` or unrelated executable fixtures. A linked environment supplied
as a root was discovered. Prompt records, ACLs, user xattrs and hard links
survived publication and rollback. A check reading stdin received EOF, its
next check ran, and both venvs in that batch were updated.

An edit to the running test copy interrupted the first full batch. Its rollback
restored all 30 published prefixes. Restored versions, package lists, prompts,
activation files and application boots matched the baseline. The repeat used
fixed copies of the release scripts and verified their SHA-256 hashes.

The repeat updated four raw installations, eight tool venvs on each of the four
branches, and three application venvs. **All 39 prefixes and 109 working
interpreter entries passed independent verification.** All 32 tool venvs
activated and retained their package versions and prompt records. The eight
installer entry points passed. Every verified stage had been removed, and
the next plan proposed zero updates. The inventory reported four pre-existing
broken `python999` links and skipped two Conda-managed prefixes.

| Application | CPU checks before and after the update | Package versions preserved |
|---|---|---:|
| LLaMA-Factory | CLI and Web UI, HTTP 200 for the page and configuration, 290 components | 111 |
| ComfyUI | Server, 1,033 nodes, 64×64 PNG from EmptyImage and SaveImage | 85 |
| llama.cpp | Converter help, 57 GGUF tensors, server health, identical eight-token completion | 29 |

All four original releases failed the upstream regression cases for
CVE-2026-15806 and CVE-2026-82049. The updated 3.10.22, 3.11.18 and 3.13.18
releases passed both cases. Python 3.8.20 failed both.

### November 2 installation and application tests

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
