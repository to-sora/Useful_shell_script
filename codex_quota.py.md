# codex_quota.py

Export Codex daily token usage to private JSON and CSV files, then render a recent daily-usage scatter plot directly in the terminal.

## Requirements
- Python 3
- A working `codex` executable that supports `app-server --listen stdio://`
- No third-party Python packages are required

## Usage
```bash
python3 codex_quota.py
```

Common options:
```bash
python3 codex_quota.py -o usage.json
python3 codex_quota.py --csv usage.csv --plot-days 30
python3 codex_quota.py --codex /path/to/codex --timeout 60
```

## Notes
- Default JSON output is `codex-usage.json`; the CSV defaults to the same basename with a `.csv` extension.
- Output files are created with private permissions (`0600`) and replaced atomically.
- The script requests token-usage data only through the Codex app server; it intentionally does not request or persist rate-limit reset/credit information.
- CSV columns include date, token count, token count in millions, and percentage change versus the previous day when available.
- The CLI plot defaults to the most recent 14 calendar days and accepts `--plot-days` values of 2 or greater.
- If `--codex` is omitted, the script searches `PATH`, `/proc/1/exe`, and common NVM-installed Codex package locations.
