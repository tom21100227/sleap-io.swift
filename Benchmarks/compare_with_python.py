#!/usr/bin/env python3
"""Compare sleap-io.swift stress benchmarks against the latest Python sleap-io."""

from __future__ import annotations

import argparse
import json
import shutil
import subprocess
import sys
from pathlib import Path


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--fixtures-dir",
        type=Path,
        default=Path("Tests/Fixtures/stress"),
        help="Directory containing local stress fixtures.",
    )
    parser.add_argument(
        "--python-spec",
        default="sleap-io",
        help="Package spec passed to `uv run --with ...` for the Python side.",
    )
    parser.add_argument(
        "--swift-configuration",
        choices=["debug", "release"],
        default="release",
        help="Swift test build configuration used for stress benchmarks.",
    )
    parser.add_argument(
        "--swift-filter",
        default="StressTests",
        help="Test filter passed to `swift test`.",
    )
    parser.add_argument(
        "--fixture",
        action="append",
        dest="fixtures",
        help="Limit the reported comparison to a specific fixture key (repeatable).",
    )
    parser.add_argument(
        "--include-save",
        action="store_true",
        help="Also run save benchmarks where both sides expose them.",
    )
    parser.add_argument(
        "--output",
        choices=["markdown", "json"],
        default="markdown",
        help="Output mode.",
    )
    return parser.parse_args()


def repo_root() -> Path:
    return Path(__file__).resolve().parent.parent


def run_command(cmd: list[str], cwd: Path) -> str:
    result = subprocess.run(
        cmd,
        cwd=cwd,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        check=False,
    )
    if result.returncode != 0:
        print(result.stdout, file=sys.stderr, end="")
        raise SystemExit(result.returncode)
    return result.stdout


def parse_benchmark_output(output: str) -> tuple[dict[str, str], dict[str, dict[str, float]]]:
    metadata: dict[str, str] = {}
    metrics: dict[str, dict[str, float]] = {}

    for line in output.splitlines():
        if line.startswith("BENCHMARK_META "):
            fields = parse_fields(line.split()[1:])
            metadata.update(fields)
        elif line.startswith("BENCHMARK "):
            fields = parse_fields(line.split()[1:])
            fixture = fields["fixture"]
            metric = fields["metric"]
            seconds = float(fields["seconds"])
            metrics.setdefault(fixture, {})[metric] = seconds

    return metadata, metrics


def parse_fields(tokens: list[str]) -> dict[str, str]:
    fields: dict[str, str] = {}
    for token in tokens:
        if "=" not in token:
            continue
        key, value = token.split("=", 1)
        fields[key] = value
    return fields


def format_seconds(value: float | None) -> str:
    if value is None:
        return "-"
    return f"{value:.3f}s"


def format_speedup(python_value: float | None, swift_value: float | None) -> str:
    if python_value is None or swift_value is None or swift_value <= 0:
        return "-"
    return f"{python_value / swift_value:.1f}x"


def build_rows(
    fixtures: list[str],
    python_metrics: dict[str, dict[str, float]],
    swift_metrics: dict[str, dict[str, float]],
) -> list[list[str]]:
    rows: list[list[str]] = []
    for fixture in fixtures:
        py = python_metrics.get(fixture, {})
        sw = swift_metrics.get(fixture, {})
        rows.append(
            [
                fixture,
                format_seconds(py.get("load")),
                format_seconds(sw.get("eager_load")),
                format_seconds(sw.get("lazy_load")),
                format_speedup(py.get("load"), sw.get("eager_load")),
                format_speedup(py.get("load"), sw.get("lazy_load")),
                format_seconds(py.get("random_access")),
                format_seconds(sw.get("random_access")),
                format_seconds(py.get("scan_1000")),
                format_seconds(sw.get("scan_1000")),
                format_seconds(py.get("save")),
                format_seconds(sw.get("save")),
            ]
        )
    return rows


def markdown_table(headers: list[str], rows: list[list[str]]) -> str:
    lines = [
        "| " + " | ".join(headers) + " |",
        "| " + " | ".join(["---"] * len(headers)) + " |",
    ]
    lines.extend("| " + " | ".join(row) + " |" for row in rows)
    return "\n".join(lines)


def main() -> int:
    args = parse_args()
    root = repo_root()
    fixtures_dir = (root / args.fixtures_dir).resolve()

    if not fixtures_dir.exists():
        print(f"Fixtures directory not found: {fixtures_dir}", file=sys.stderr)
        return 2

    if not shutil.which("uv"):
        print("uv is required for the Python comparison benchmark.", file=sys.stderr)
        return 2

    swift_cmd = ["swift", "test", "-c", args.swift_configuration, "--filter", args.swift_filter]
    python_cmd = [
        "uv",
        "run",
        "--with",
        args.python_spec,
        "python3",
        "Benchmarks/python_sleap_io_benchmark.py",
        "--fixtures-dir",
        str(fixtures_dir),
        "--format",
        "bench",
    ]
    if args.include_save:
        python_cmd.append("--include-save")
    for fixture in args.fixtures or []:
        python_cmd.extend(["--fixture", fixture])

    swift_output = run_command(swift_cmd, root)
    python_output = run_command(python_cmd, root)

    swift_meta, swift_metrics = parse_benchmark_output(swift_output)
    python_meta, python_metrics = parse_benchmark_output(python_output)

    if not swift_metrics:
        print("No Swift benchmark lines were found in `swift test` output.", file=sys.stderr)
        return 2
    if not python_metrics:
        print("No Python benchmark lines were found in Python benchmark output.", file=sys.stderr)
        return 2

    fixtures = sorted(set(swift_metrics) | set(python_metrics))
    if args.fixtures:
        selected = set(args.fixtures)
        fixtures = [fixture for fixture in fixtures if fixture in selected]

    payload = {
        "fixtures_dir": str(fixtures_dir),
        "python_spec": args.python_spec,
        "python_version": python_meta.get("version"),
        "swift_configuration": args.swift_configuration,
        "swift_filter": args.swift_filter,
        "swift_metrics": swift_metrics,
        "python_metrics": python_metrics,
        "fixtures": fixtures,
    }

    if args.output == "json":
        print(json.dumps(payload, indent=2, sort_keys=True))
        return 0

    headers = [
        "Fixture",
        "Python load",
        "Swift eager",
        "Swift lazy",
        "Eager speedup",
        "Lazy speedup",
        "Python random",
        "Swift random",
        "Python scan",
        "Swift scan",
        "Python save",
        "Swift save",
    ]
    rows = build_rows(fixtures, python_metrics, swift_metrics)

    print(f"Python spec: {args.python_spec}")
    if python_meta.get("version"):
        print(f"Python sleap-io version: {python_meta['version']}")
    print(f"Swift command: {' '.join(swift_cmd)}")
    print(f"Fixtures: {fixtures_dir}")
    print()
    print(markdown_table(headers, rows))

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
