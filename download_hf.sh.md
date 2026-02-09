# download_hf.sh

Downloads a Hugging Face dataset with retries.

## Usage

```bash
./download_hf.sh
```

## Notes

- Adjust `RETRY_LIMIT`, `WAIT_TIME`, and `COMMAND` inside the script to fit your dataset or target path.
- Requires `huggingface-cli` to be installed and authenticated.
