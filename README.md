# sleap-io.swift

Native Swift library for reading, writing, and manipulating [SLEAP](https://sleap.ai) pose tracking data. Foundation layer for `sleap.swift` (training/inference) and `sleap-label.swift` (annotation GUI).

**Platforms:** Apple platforms. `v0.3.0` treats HDF5-backed `.slp` support on iPad as an official downstream release target through the vendored `CHDF5.xcframework` path, with final signoff gated on real downstream app validation.

## Supported Formats

| Format | Read | Write | Notes |
|--------|------|-------|-------|
| SLP (`.slp`, `.pkg.slp`) | Lazy + Eager | Yes | Full v1.0–1.5 support, embedded video |
| COCO JSON | Yes | Yes | Keypoint format |
| CSV | Yes | Yes | |
| Label Studio | Yes | Yes | Requires skeleton mapping |
| YOLO | Yes | Yes | Requires config |
| AlphaTracker | Yes | No | |
| Analysis HDF5 | Yes | Yes | Dense array format |
| JABS | Yes | Yes | Requires node names config |
| DeepLabCut | Yes | No | Single + multi-animal |

**Not supported:** NWB, LEAP `.mat` (no Swift ecosystem)

## Quick Start

```swift
import SleapHDF5
import SleapIO

// Lazy load (metadata only, frames materialized on access)
let labels = try await Labels.load(from: URL(fileURLWithPath: "predictions.slp"))

print(labels.frameCount)          // 90000
print(labels.predictedInstanceCount)  // 280438
print(labels.isLazy)              // true

// Access a frame (materialized from HDF5 on first access, cached after)
let frame = labels[0]
for instance in frame.instances {
    let points = instance.points
    print("Node count: \(points.count), visible: \(points.visibility.filter { $0 }.count)")
}

// Eager load (all frames in memory)
let eager = try await Labels.loadEager(from: URL(fileURLWithPath: "labels.slp"))

// Save
try await eager.save(to: URL(fileURLWithPath: "output.slp"))
```

## CLI

```bash
# Build the CLI
swift build

# Inspect a file
.build/debug/sleap-io info predictions.h5
.build/debug/sleap-io show labels.slp --limit 10

# Convert between formats
.build/debug/sleap-io convert input.h5 output.csv
```

## Build & Test

```bash
# Build (default: vendored CHDF5 XCFramework, no Homebrew required)
swift build

# Test (requires generating fixtures first)
uv run --with sleap-io --with h5py --with Pillow python3 Tests/Fixtures/generate_fixtures.py
swift test

# Optional: macOS-only system HDF5 path for local benchmarking/dev
USE_SYSTEM_HDF5=1 swift build
```

For local real-world stress assets in `Tests/Fixtures/stress/`, there is also
a reproducible Swift-vs-Python benchmark harness:

```bash
python3 Benchmarks/compare_with_python.py \
  --fixtures-dir Tests/Fixtures/stress \
  --include-save
```

## Architecture

```
Sources/
├── CHDF5/          # C shim wrapping libhdf5
├── SleapIO/        # Core model types + interchange codecs (no HDF5 dep)
├── SleapHDF5/      # HDF5 wrapper + SLP read/write + Analysis/JABS/DLC codecs
├── SleapVideo/     # Video abstraction (AVFoundation backend)
├── SleapRendering/ # 2D pose rendering (CoreGraphics)
└── SleapCLI/       # Command-line tool (swift-argument-parser)
```

**Dependency graph:** `SleapRendering → SleapVideo → SleapIO ← SleapHDF5 → CHDF5`

## Key Design Decisions

- **Lazy by default** — `Labels.load()` reads only metadata; frames materialize on access via `LazyFrameList`
- **Identity semantics** — `Skeleton`, `Node`, `Track`, `Video`, `Instance` are reference types (`===` equality)
- **Metal-ready points** — `PointsArray` stores interleaved Float32 `[x0, y0, x1, y1, ...]` matching `packed_float2`
- **Actor-isolated HDF5** — All HDF5 access serialized through `HDF5FileActor`
- **Persisted video relocation** — `Video.originalFilename` preserves provenance; `Video.persistedFilename` enables permanent relocation that survives save/reopen. Temporary relocation is session-only via `backendOpener`.

## Performance

A reproducible local benchmark harness lives in [Benchmarks/README.md](Benchmarks/README.md).

It compares the current Swift tip against the latest published Python
`sleap-io` package on the same local stress fixtures:

```bash
python3 Benchmarks/compare_with_python.py \
  --fixtures-dir Tests/Fixtures/stress \
  --include-save
```

The benchmark is local-only for now because the large stress fixtures are
gitignored real-world assets rather than checked-in test data.

For embedded packaged `.pkg.slp` files, current load-time comparisons should be
treated cautiously: Swift currently does more embedded backend work during
`load()` than Python `sleap-io`, so follow-up benchmarks should compare
equivalent work such as first-frame access as well as raw load time.

## Known Limitations

- Frame lookup is O(n) (binary search index planned but not implemented)
- Lazy cache is unbounded (no eviction strategy)
- NWB and LEAP `.mat` formats are out of scope

## License

[MIT](LICENSE)
