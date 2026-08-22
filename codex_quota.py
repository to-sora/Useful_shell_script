#!/usr/bin/env python3
"""Export Codex token usage to JSON/CSV and plot recent daily usage in the CLI."""

from __future__ import annotations

import argparse
import csv
import json
import os
import selectors
import shutil
import subprocess
import sys
import tempfile
import time
from datetime import date, datetime, timedelta, timezone
from pathlib import Path
from typing import Any, TextIO


def find_codex(explicit_path: str | None) -> str:
    if explicit_path:
        candidate = Path(explicit_path).expanduser()
        if candidate.is_file() and os.access(candidate, os.X_OK):
            return str(candidate)
        raise RuntimeError(f"Codex binary is not executable: {candidate}")

    on_path = shutil.which("codex")
    if on_path:
        return on_path

    proc_one = Path("/proc/1/exe")
    try:
        if proc_one.exists():
            resolved = proc_one.resolve()
            if resolved.name == "codex" and os.access(resolved, os.X_OK):
                return str(resolved)
    except OSError:
        pass

    package_pattern = (
        ".nvm/versions/node/*/lib/node_modules/@openai/codex/node_modules/"
        "@openai/codex-*/vendor/*/bin/codex"
    )
    candidates = [
        path
        for path in Path.home().glob(package_pattern)
        if path.is_file() and os.access(path, os.X_OK)
    ]
    if candidates:
        return str(max(candidates, key=lambda path: path.stat().st_mtime))

    raise RuntimeError("Could not find the Codex binary; pass --codex /path/to/codex")


def send_message(stdin: TextIO, message: dict[str, Any]) -> None:
    stdin.write(json.dumps(message, separators=(",", ":")) + "\n")
    stdin.flush()


def read_responses(
    process: subprocess.Popen[str], expected_ids: set[int], timeout: float
) -> dict[int, dict[str, Any]]:
    if process.stdout is None:
        raise RuntimeError("Codex app-server stdout is unavailable")

    selector = selectors.DefaultSelector()
    selector.register(process.stdout, selectors.EVENT_READ)
    deadline = time.monotonic() + timeout
    responses: dict[int, dict[str, Any]] = {}

    try:
        while expected_ids - responses.keys():
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                missing = sorted(expected_ids - responses.keys())
                raise TimeoutError(f"Timed out waiting for response IDs: {missing}")

            if not selector.select(remaining):
                continue

            line = process.stdout.readline()
            if not line:
                status = process.poll()
                raise RuntimeError(f"Codex app-server exited early (status {status})")

            try:
                message = json.loads(line)
            except json.JSONDecodeError:
                continue

            message_id = message.get("id")
            if message_id in expected_ids:
                responses[message_id] = message
    finally:
        selector.close()

    return responses


def require_result(response: dict[str, Any], method: str) -> dict[str, Any]:
    if "error" in response:
        raise RuntimeError(f"{method} failed: {response['error']}")
    result = response.get("result")
    if not isinstance(result, dict):
        raise RuntimeError(f"{method} returned no result object")
    return result


def write_private_json(output: Path, payload: dict[str, Any]) -> None:
    if not output.parent.is_dir():
        raise RuntimeError(f"Output directory does not exist: {output.parent}")

    temporary = output.with_name(f".{output.name}.{os.getpid()}.tmp")
    descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
            json.dump(payload, handle, indent=2, sort_keys=True)
            handle.write("\n")
        os.replace(temporary, output)
    finally:
        if temporary.exists():
            temporary.unlink()


def daily_usage(usage: dict[str, Any]) -> list[tuple[date, int]]:
    raw_buckets = usage.get("dailyUsageBuckets")
    if not isinstance(raw_buckets, list):
        raise RuntimeError("usage.dailyUsageBuckets is missing or is not a list")

    by_day: dict[date, int] = {}
    for index, bucket in enumerate(raw_buckets):
        if not isinstance(bucket, dict):
            raise RuntimeError(f"dailyUsageBuckets[{index}] is not an object")

        raw_date = bucket.get("startDate")
        raw_tokens = bucket.get("tokens")
        if not isinstance(raw_date, str) or not isinstance(raw_tokens, int):
            raise RuntimeError(
                f"dailyUsageBuckets[{index}] must contain string startDate and integer tokens"
            )
        if raw_tokens < 0:
            raise RuntimeError(f"dailyUsageBuckets[{index}].tokens cannot be negative")

        try:
            day = date.fromisoformat(raw_date)
        except ValueError as error:
            raise RuntimeError(
                f"dailyUsageBuckets[{index}].startDate is not YYYY-MM-DD: {raw_date!r}"
            ) from error

        if day in by_day:
            raise RuntimeError(f"Duplicate daily usage bucket for {day.isoformat()}")
        by_day[day] = raw_tokens

    return sorted(by_day.items())


def pct_change_vs_yesterday(
    day: date, tokens: int, tokens_by_day: dict[date, int]
) -> float | None:
    previous = tokens_by_day.get(day - timedelta(days=1))
    if previous is None or previous == 0:
        return None
    return (tokens - previous) / previous * 100.0


def write_private_csv(output: Path, usage: dict[str, Any]) -> None:
    if not output.parent.is_dir():
        raise RuntimeError(f"CSV output directory does not exist: {output.parent}")

    rows = daily_usage(usage)
    tokens_by_day = dict(rows)

    temporary = output.with_name(f".{output.name}.{os.getpid()}.tmp")
    descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8", newline="") as handle:
            writer = csv.writer(handle)
            writer.writerow(
                ["date", "tokens", "tokens_millions", "pct_change_vs_yesterday"]
            )
            for day, tokens in rows:
                change = pct_change_vs_yesterday(day, tokens, tokens_by_day)
                writer.writerow(
                    [
                        day.isoformat(),
                        tokens,
                        f"{tokens / 1_000_000:.6f}",
                        "" if change is None else f"{change:.2f}",
                    ]
                )
        os.replace(temporary, output)
    finally:
        if temporary.exists():
            temporary.unlink()


def render_scatter(usage: dict[str, Any], days: int = 14, height: int = 10) -> str:
    if days < 2:
        raise ValueError("plot days must be at least 2")
    if height < 4:
        raise ValueError("plot height must be at least 4")

    rows = daily_usage(usage)
    if not rows:
        return "No daily usage data available."

    tokens_by_day = dict(rows)
    end_day = rows[-1][0]
    start_day = end_day - timedelta(days=days - 1)
    plot_days = [start_day + timedelta(days=offset) for offset in range(days)]
    values = [tokens_by_day.get(day) for day in plot_days]
    present = [value for value in values if value is not None]
    if not present:
        return "No daily usage data available in the requested plot window."

    max_millions = max(present) / 1_000_000
    scale_max = max(max_millions, 1.0)
    point_rows: list[int | None] = []
    for value in values:
        if value is None:
            point_rows.append(None)
            continue
        millions = value / 1_000_000
        point_rows.append(round((scale_max - millions) / scale_max * (height - 1)))

    label_width = max(8, len(f"{scale_max:.1f}"))
    lines = [
        f"Daily token usage — {start_day.isoformat()} to {end_day.isoformat()} (millions)"
    ]

    for row in range(height):
        y_value = scale_max * (height - 1 - row) / (height - 1)
        cells = [" * " if point_row == row else "   " for point_row in point_rows]
        lines.append(f"{y_value:{label_width}.1f} |" + "".join(cells))

    lines.append(" " * (label_width + 1) + "+" + "---" * days)
    lines.append(" " * (label_width + 2) + "".join(f" {day.day:02d}" for day in plot_days))
    lines.append(" " * (label_width + 2) + f"days ({start_day:%Y-%m})")

    latest_tokens = tokens_by_day[end_day]
    latest_change = pct_change_vs_yesterday(end_day, latest_tokens, tokens_by_day)
    latest_text = f"latest: {end_day.isoformat()} = {latest_tokens / 1_000_000:.3f}M"
    if latest_change is not None:
        latest_text += f" ({latest_change:+.2f}% vs yesterday)"
    lines.append(latest_text)

    missing = sum(value is None for value in values)
    if missing:
        lines.append(f"note: {missing} day(s) in this window had no usage bucket")

    return "\n".join(lines)


def export_usage(
    codex: str,
    json_output: Path,
    csv_output: Path,
    timeout: float,
    plot_days: int,
) -> str:
    with tempfile.TemporaryFile(mode="w+", encoding="utf-8") as stderr_log:
        process = subprocess.Popen(
            [codex, "app-server", "--listen", "stdio://"],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=stderr_log,
            text=True,
            bufsize=1,
        )

        try:
            if process.stdin is None:
                raise RuntimeError("Codex app-server stdin is unavailable")

            send_message(
                process.stdin,
                {
                    "method": "initialize",
                    "id": 0,
                    "params": {
                        "clientInfo": {
                            "name": "usage_export",
                            "title": "Usage Export",
                            "version": "2.0.0",
                        }
                    },
                },
            )
            initialization = read_responses(process, {0}, timeout)[0]
            require_result(initialization, "initialize")

            send_message(process.stdin, {"method": "initialized", "params": {}})

            # Intentionally request ONLY token usage.  We do not call
            # account/rateLimits/read, so reset windows/credits are neither
            # fetched nor persisted.
            send_message(process.stdin, {"method": "account/usage/read", "id": 1})
            response = read_responses(process, {1}, timeout)[1]
            usage = require_result(response, "account/usage/read")

            payload = {
                "capturedAt": datetime.now(timezone.utc)
                .isoformat(timespec="seconds")
                .replace("+00:00", "Z"),
                "usage": usage,
            }
            write_private_json(json_output, payload)
            write_private_csv(csv_output, usage)
            return render_scatter(usage, days=plot_days)
        except Exception:
            stderr_log.seek(0)
            diagnostics = stderr_log.read().strip()
            if diagnostics:
                print(diagnostics, file=sys.stderr)
            raise
        finally:
            if process.stdin is not None:
                process.stdin.close()
            process.terminate()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()


def main() -> int:
    parser = argparse.ArgumentParser(
        description=(
            "Export Codex daily token usage to JSON/CSV without saving rate-limit "
            "reset data, then show a recent CLI scatter plot."
        )
    )
    parser.add_argument(
        "-o", "--output", type=Path, default=Path("codex-usage.json"),
        help="JSON output path (default: codex-usage.json)",
    )
    parser.add_argument(
        "--csv", type=Path,
        help="CSV output path (default: same basename as --output with .csv)",
    )
    parser.add_argument("--codex", help="Path to the Codex executable")
    parser.add_argument("--timeout", type=float, default=30.0)
    parser.add_argument(
        "--plot-days", type=int, default=14,
        help="Number of calendar days to show in the CLI scatter plot (default: 14)",
    )
    arguments = parser.parse_args()

    csv_output = arguments.csv or arguments.output.with_suffix(".csv")

    try:
        codex = find_codex(arguments.codex)
        plot = export_usage(
            codex,
            arguments.output,
            csv_output,
            arguments.timeout,
            arguments.plot_days,
        )
    except (OSError, RuntimeError, TimeoutError, ValueError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 1

    print(f"Wrote {arguments.output}")
    print(f"Wrote {csv_output}")
    print()
    print(plot)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
