from pathlib import Path
import re
import sys
import xml.etree.ElementTree as ET


TRACE_PATTERN = re.compile(r"^\++TRACE:(.*?):(\d+):")


def executable_lines(path: Path) -> set[int]:
    result = set()
    for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        stripped = line.strip()
        if stripped and not stripped.startswith("#"):
            result.add(number)
    return result


def main() -> int:
    if len(sys.argv) < 4:
        raise SystemExit("usage: bash-trace-to-sonar.py TRACE OUTPUT SOURCE...")

    root = Path.cwd().resolve()
    trace_path = Path(sys.argv[1])
    output_path = Path(sys.argv[2])
    sources = [Path(value) for value in sys.argv[3:]]
    covered: dict[Path, set[int]] = {}

    for line in trace_path.read_text(encoding="utf-8", errors="replace").splitlines():
        match = TRACE_PATTERN.match(line)
        if not match:
            continue
        traced_path = Path(match.group(1))
        absolute_path = traced_path if traced_path.is_absolute() else root / traced_path
        try:
            relative_path = absolute_path.resolve().relative_to(root)
        except ValueError:
            continue
        covered.setdefault(relative_path, set()).add(int(match.group(2)))

    report = ET.Element("coverage", version="1")
    for source in sources:
        source = Path(source.as_posix())
        file_element = ET.SubElement(report, "file", path=source.as_posix())
        hit_lines = covered.get(source, set())
        for line_number in sorted(executable_lines(root / source)):
            ET.SubElement(
                file_element,
                "lineToCover",
                lineNumber=str(line_number),
                covered="true" if line_number in hit_lines else "false",
            )

    output_path.parent.mkdir(parents=True, exist_ok=True)
    ET.ElementTree(report).write(output_path, encoding="utf-8", xml_declaration=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
