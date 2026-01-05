# get_vev_size.sh

Finds Python virtual environments under a directory and prints their sizes.

## Usage

```bash
./get_vev_size.sh [SEARCH_DIR]
```

## Notes

- Defaults to the current directory if no `SEARCH_DIR` is provided.
- Detects venvs by checking for `bin/activate` and `lib/`.
