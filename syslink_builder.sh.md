# syslink_builder.sh

Create symlinks in a destination directory mirroring files from multiple source directories.

## Requirements
- Bash
- Write access to the destination directory

## Usage
```bash
./syslink_builder.sh <DIR_A> <SRC_ROOT_1> [SRC_ROOT_2 ... SRC_ROOT_N]
```

## Example
```bash
./syslink_builder.sh ~/Comfyui/models /mnt/disk1/Comfyui/models /mnt/disk2/Comfyui/models /mnt/disk3/Comfyui/models
```

## Behavior
- Finds all files (recursively) in each `SRC_ROOT`
- Creates corresponding symlinks in `DIR_A` preserving relative paths
- Creates intermediate directories as needed in `DIR_A`
- If multiple sources contain the same relative path, later sources win (overwrites earlier symlinks)

## Notes
- All source roots must exist before running (fail-fast validation)
- Uses `ln -sfn` to force-replace existing symlinks
- Useful for aggregating model files from multiple disks into a single directory structure
