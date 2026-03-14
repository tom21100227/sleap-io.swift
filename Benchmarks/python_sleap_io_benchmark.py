#!/usr/bin/env python3
"""Benchmark the published Python sleap-io package on local stress fixtures.

This script is intended to be run via:

    uv run --with sleap-io python3 Benchmarks/python_sleap_io_benchmark.py

By default, `uv run --with sleap-io` resolves the latest published version.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import tempfile
import time
from pathlib import Path


FIXTURE_SPECS = [
    {
        "fixture": "single_predictions",
        "filename": "single_predictions.slp",
        "description": "Single predictions (2.2 MB, 5k frames)",
        "random_indices": [0, 4999, 2500, 100, 4000, 1, 3333],
        "scan_count": 0,
        "save": True,
    },
    {
        "fixture": "training_mixed",
        "filename": "training_mixed.pkg.slp",
        "description": "Training mixed (2.5 MB, 540 frames, 183 videos)",
        "random_indices": [],
        "scan_count": 0,
        "save": True,
    },
    {
        "fixture": "training_embedded",
        "filename": "training_embedded.pkg.slp",
        "description": "Training embedded (472 MB, 540 frames, all embedded)",
        "random_indices": [],
        "scan_count": 0,
        "save": False,
    },
    {
        "fixture": "large_predictions",
        "filename": "large_predictions.slp",
        "description": "Large predictions (123 MB, 90k frames, 280k instances)",
        "random_indices": [0, 89999, 45000, 1000, 80000, 10, 60000, 25000, 75000, 50000],
        "scan_count": 1000,
        "save": False,
    },
]


def emit_benchmark(source: str, fixture: str, metric: str, seconds: float, **extra: object) -> None:
    fields = [
        "BENCHMARK",
        f"source={source}",
        f"fixture={fixture}",
        f"metric={metric}",
        f"seconds={seconds:.6f}",
    ]
    for key in sorted(extra):
        value = extra[key]
        fields.append(f"{key}={value}")
    print(" ".join(fields))


def emit_meta(source: str, **fields: object) -> None:
    parts = ["BENCHMARK_META", f"source={source}"]
    for key in sorted(fields):
        parts.append(f"{key}={fields[key]}")
    print(" ".join(parts))


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--fixtures-dir",
        type=Path,
        default=Path("Tests/Fixtures/stress"),
        help="Directory containing local stress fixtures.",
    )
    parser.add_argument(
        "--fixture",
        action="append",
        dest="fixtures",
        help="Benchmark only a specific fixture key (repeatable).",
    )
    parser.add_argument(
        "--format",
        choices=["bench", "json"],
        default="bench",
        help="Output mode.",
    )
    parser.add_argument(
        "--include-save",
        action="store_true",
        help="Also benchmark save for fixtures that enable it.",
    )
    return parser.parse_args()


def selected_specs(selected: set[str] | None) -> list[dict[str, object]]:
    if not selected:
        return FIXTURE_SPECS
    return [spec for spec in FIXTURE_SPECS if spec["fixture"] in selected]


def build_report(sio, fixtures_dir: Path, specs: list[dict[str, object]], include_save: bool) -> dict[str, object]:
    report: dict[str, object] = {
        "source": "python",
        "version": sio.__version__,
        "fixtures_dir": str(fixtures_dir.resolve()),
        "results": [],
    }

    for spec in specs:
        fixture = spec["fixture"]
        filename = spec["filename"]
        path = fixtures_dir / filename
        if not path.exists():
            continue

        t0 = time.perf_counter()
        labels = sio.load_slp(str(path))
        load_seconds = time.perf_counter() - t0

        n_frames = len(labels)
        n_videos = len(labels.videos)
        n_skeletons = len(labels.skeletons)
        n_tracks = len(labels.tracks)
        n_instances = sum(len(lf.instances) for lf in labels)
        n_predicted = sum(
            1
            for lf in labels
            for inst in lf.instances
            if isinstance(inst, sio.PredictedInstance)
        )

        metrics: dict[str, float] = {"load": load_seconds}

        random_indices = [
            i for i in spec["random_indices"] if 0 <= i < n_frames
        ]
        if random_indices:
            t0 = time.perf_counter()
            for i in random_indices:
                lf = labels[i]
                _ = lf.instances
                for inst in lf.instances:
                    _ = inst.points
            metrics["random_access"] = time.perf_counter() - t0

        scan_count = min(int(spec["scan_count"]), n_frames)
        if scan_count > 0:
            total_instances = 0
            t0 = time.perf_counter()
            for i in range(scan_count):
                lf = labels[i]
                total_instances += len(lf.instances)
                for inst in lf.instances:
                    _ = inst.numpy()
            metrics["scan_1000"] = time.perf_counter() - t0
        else:
            total_instances = None

        if include_save and spec["save"]:
            with tempfile.NamedTemporaryFile(suffix=".slp", delete=False) as tmp:
                tmp_path = Path(tmp.name)
            try:
                t0 = time.perf_counter()
                labels.save(str(tmp_path))
                metrics["save"] = time.perf_counter() - t0
            finally:
                tmp_path.unlink(missing_ok=True)

        report["results"].append(
            {
                "fixture": fixture,
                "filename": filename,
                "description": spec["description"],
                "counts": {
                    "frames": n_frames,
                    "videos": n_videos,
                    "skeletons": n_skeletons,
                    "tracks": n_tracks,
                    "instances": n_instances,
                    "predicted_instances": n_predicted,
                },
                "metrics": metrics,
                "scan_instances": total_instances,
            }
        )

    return report


def main() -> int:
    args = parse_args()
    os.environ.setdefault("OPENCV_LOG_LEVEL", "ERROR")

    try:
        import sleap_io as sio
    except ImportError as exc:
        print(
            "sleap-io is required. Run via `uv run --with sleap-io python3 "
            "Benchmarks/python_sleap_io_benchmark.py`.",
            file=sys.stderr,
        )
        raise SystemExit(2) from exc

    specs = selected_specs(set(args.fixtures or []))
    report = build_report(sio, args.fixtures_dir, specs, args.include_save)

    if args.format == "json":
        print(json.dumps(report, indent=2, sort_keys=True))
        return 0

    emit_meta("python", version=sio.__version__)
    for result in report["results"]:
        fixture = result["fixture"]
        metrics = result["metrics"]
        emit_benchmark("python", fixture, "load", metrics["load"])
        if "random_access" in metrics:
            emit_benchmark(
                "python",
                fixture,
                "random_access",
                metrics["random_access"],
                frames=len(
                    [i for i in next(spec for spec in specs if spec["fixture"] == fixture)["random_indices"]
                     if 0 <= i < result["counts"]["frames"]]
                ),
            )
        if "scan_1000" in metrics:
            emit_benchmark(
                "python",
                fixture,
                "scan_1000",
                metrics["scan_1000"],
                frames=min(
                    int(next(spec for spec in specs if spec["fixture"] == fixture)["scan_count"]),
                    result["counts"]["frames"],
                ),
                instances=result["scan_instances"],
            )
        if "save" in metrics:
            emit_benchmark("python", fixture, "save", metrics["save"])

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
