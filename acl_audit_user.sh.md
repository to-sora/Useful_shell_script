# acl_audit_user.sh

Build a first-layer ACL access matrix showing which users can access the target directory and each direct child directory, including default ACL inheritance information.

## Requirements
- Bash
- `find`, `getfacl`, `stat`, `getent`, `awk`, `sed`, and `sort`
- Optional: `xclip` for clipboard output

## Usage
```bash
./acl_audit_user.sh DIR [--users u1,u2,...] [--debug-file FILE] [--no-xclip] [--show-others-placeholder]
```

Examples:
```bash
./acl_audit_user.sh /mnt/DATA9
./acl_audit_user.sh /mnt/DATA9 --users alice,bob
./acl_audit_user.sh /mnt/DATA9 --no-xclip --debug-file /tmp/data9-user-acl.log
```

## Notes
- Scan depth is limited to the target directory and its first-layer child directories.
- Output includes user-to-group mapping, effective access permissions by directory/user, default ACL permissions, and directory ownership/mode information.
- `--users` limits the matrix to the supplied comma-separated usernames.
- `--show-others-placeholder` adds a row representing users that fall through to the ACL `other` entry.
- A debug bundle is written to the requested file or to a timestamped file under `/tmp`.
- The script reads ACL and account information only; it does not change permissions or ACLs.
