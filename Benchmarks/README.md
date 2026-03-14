# Benchmarks

These scripts compare `sleap-io.swift` against the latest published Python
`sleap-io` package on the same local stress fixtures.

They are intentionally local-only right now:

- the stress fixtures live in `Tests/Fixtures/stress/`
- that directory is gitignored because the files are large real-world assets
- a default CI runner does not have those assets available

## Requirements

- `uv`
- `python3`
- `swift`
- local stress fixtures in `Tests/Fixtures/stress/`

## Compare Swift And Python

This runs the Swift stress suite in release mode and the latest published
Python `sleap-io` through `uv`.

```bash
python3 Benchmarks/compare_with_python.py \
  --fixtures-dir Tests/Fixtures/stress \
  --include-save
```

The Python side uses:

```bash
uv run --with sleap-io python3 Benchmarks/python_sleap_io_benchmark.py
```

That resolves the latest published Python package unless you override it:

```bash
python3 Benchmarks/compare_with_python.py \
  --python-spec sleap-io==0.6.5
```

## Notes

- The Swift side reuses `StressTests`, so the comparison exercises the same
  correctness-checked paths that already gate the local test suite.
- This is not wired into default GitHub Actions yet because the repo does not
  ship the large stress fixtures needed to run it meaningfully in CI.
- Embedded packaged `.pkg.slp` load timings are currently not fully
  apples-to-apples. Swift currently does more embedded backend work during
  `load()` than Python `sleap-io`, so embedded comparisons should be read with
  care.
- The intended follow-up is to add equivalent-work metrics for embedded files:
  metadata-only load, first embedded frame access, and a short embedded frame
  scan.
