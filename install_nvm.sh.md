# install_nvm.sh

Install a per-user NVM setup, install the selected Node.js version, and make the NVM-managed Node/npm toolchain load from `~/.bashrc`.

## Requirements
- Run as the target normal user
- `curl`, `bash`, `grep`, `sed`, `awk`, and `tar`
- Internet access to download the pinned NVM installer and Node.js

## Usage
```bash
bash install_nvm.sh
```

Optional environment overrides:
```bash
NVM_VERSION=v0.40.4 NODE_VERSION=24 bash install_nvm.sh
```

## Notes
- Defaults to NVM `v0.40.4` and Node.js `24`.
- Installs NVM under `~/.nvm` and adds a guarded NVM loader block to `~/.bashrc`.
- Uses user-owned cache/temp directories under `~/.cache` instead of `/tmp` for tools that respect `TMPDIR`.
- Stores the downloaded NVM installer under `~/install_nvm/` so it can be inspected.
- Sets the requested Node.js version as the NVM default and verifies that `npm` resolves from `~/.nvm` rather than a system package.
- Re-running is intended to reuse an existing NVM installation and avoid duplicating the `.bashrc` loader block.
