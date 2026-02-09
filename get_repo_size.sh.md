# get_repo_size.sh

Finds Git repositories under a directory and reports the size of their `.git` history and upstream.

## Usage

```bash
./get_repo_size.sh [SEARCH_DIR]
```

## Notes

- Defaults to the current directory if no `SEARCH_DIR` is provided.
- Large histories (>25GB) are colored red.
