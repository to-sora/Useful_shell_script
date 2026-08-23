# acl_audit.sh

Audit POSIX permissions and ACLs for a target directory and its direct children, then print a compact summary and a detailed ACL view.

## Requirements
- Bash
- `find`, `getfacl`, `stat`, `awk`, `sed`, and `sort`
- Optional: `xclip` and an X11 `DISPLAY` to copy the debug bundle to the clipboard

## Usage
```bash
./acl_audit.sh DIR [--no-color] [--debug-file FILE]
```

Examples:
```bash
./acl_audit.sh /mnt/DATA9
./acl_audit.sh /mnt/DATA9 --no-color
./acl_audit.sh /mnt/DATA9 --debug-file /tmp/data9-acl.log
```

## Notes
- Scan depth is intentionally limited to the target directory plus first-layer children (`find -maxdepth 1`).
- The report includes path type, owner, group, mode, extended ACL entries, default ACL entries, and `getfacl` effective-permission comments.
- A debug bundle is always written. If `--debug-file` is omitted, the script creates a timestamped file under `/tmp`.
- If `xclip` and `DISPLAY` are available, the debug bundle is also copied to the X clipboard.
- The script is read-only with respect to filesystem permissions; it audits ACLs but does not modify them.
