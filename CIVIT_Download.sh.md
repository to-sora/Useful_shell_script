# CIVIT_Download.sh

Download one or more Civitai model files using an API token from the environment.

## Requirements
- `curl`
- `CIVIT_API` environment variable set to your Civitai API key

## Usage
```bash
export CIVIT_API=YOUR_KEY
./CIVIT_Download.sh <URL1> [URL2] ...
```

## Notes
- Each URL is fetched with a Bearer token header.
- Output filenames are determined by the server via `-J -O`.
