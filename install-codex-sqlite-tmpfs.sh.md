# install-codex-sqlite-tmpfs.sh

Configure Codex SQLite storage under `/dev/shm` so each eligible local user gets a private tmpfs-backed SQLite directory.

## Requirements
- Run as `root` or with `sudo`
- Linux with `/dev/shm` mounted as `tmpfs`
- `getent`, `runuser`, `findmnt`, `systemd-tmpfiles`, `awk`, `stat`, and standard core utilities
- Existing user home directories for the accounts to configure

## Usage
```bash
sudo bash install-codex-sqlite-tmpfs.sh
```

After installation, restart Codex sessions and verify the tmpfs files with:
```bash
find /dev/shm/codex-sqlite -maxdepth 2 -type f -printf '%p %s bytes\n'
```

## Notes
- Creates `/dev/shm/codex-sqlite` and one mode-`0700` directory per eligible user UID.
- Writes `/etc/tmpfiles.d/codex-sqlite-tmpfs.conf` so the directories can be recreated by `systemd-tmpfiles`.
- Writes `/etc/profile.d/90-codex-sqlite-tmpfs.sh` as a login-shell fallback for `CODEX_SQLITE_HOME`.
- Updates each user's `~/.codex/config.toml` with a top-level `sqlite_home` value and creates a timestamped backup first.
- The script refuses symlinked target directories/config files in several sensitive locations.
- Because `/dev/shm` is memory-backed, its contents do not persist like normal disk storage; the tmpfiles configuration recreates directories, not previous database contents.
