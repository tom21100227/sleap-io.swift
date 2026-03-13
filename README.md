# sleap-io.swift

Native Swift library for reading, writing, and manipulating [SLEAP](https://sleap.ai) pose tracking data. Foundation layer for `sleap.swift` (training/inference) and `sleap-label.swift` (annotation GUI).

**Platforms:** macOS 14+ / iOS 17+ (Apple only)

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
.build/debug/sleapio info predictions.h5
.build/debug/sleapio show labels.slp --limit 10

# Convert between formats
.build/debug/sleapio convert input.h5 output.csv
```

## Build & Test

```bash
# Prerequisites
brew install hdf5

# Build
swift build

# Test (requires generating fixtures first)
uv run --with sleap-io --with h5py --with Pillow python3 Tests/Fixtures/generate_fixtures.py
swift test
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

## Performance

Benchmarked against Python sleap-io 0.6.5 on Apple M4 Max:

| File | Python | Swift (eager) | Swift (lazy) |
|------|--------|---------------|--------------|
| 5k frames, 2.2 MB | 1.65s | 0.03s (55x) | 0.007s (236x) |
| 540 frames, 183 videos | 0.70s | 0.02s (30x) | 0.02s (33x) |
| 90k frames, 123 MB | 3.14s | 1.39s (2.3x) | 0.32s (9.8x) |

## Known Limitations

- Frame lookup is O(n) (binary search index planned but not implemented)
- Lazy cache is unbounded (no eviction strategy)
- NWB and LEAP `.mat` formats are out of scope

## License

[TODO: Add license]
