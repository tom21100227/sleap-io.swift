# CLAUDE.md — sleap-io.swift

## Project Overview

Native Swift adaptation of [sleap-io](https://github.com/talmolab/sleap-io) for reading/writing SLEAP pose tracking data. Foundation layer for `sleap.swift` (training/inference) and `sleap-label.swift` (annotation GUI).

**Target platforms:** Apple only (macOS + iPadOS). All modules may use Apple frameworks freely.

## Build & Test

```bash
# Prerequisites
brew install hdf5

# Build
swift build

# Test
swift test

# Generate test fixtures (required for SLP reader/writer/lazy tests)
uv run --with sleap-io --with h5py --with Pillow python3 Tests/Fixtures/generate_fixtures.py
```

## Architecture

### Module Structure

```
Sources/
├── CHDF5/                    # C system library target wrapping libhdf5
│   ├── module.modulemap      # pkgConfig: "hdf5"
│   └── shim.h                # Inline C functions for HDF5 macros
├── SleapIO/                  # Core model types + codecs (no HDF5 dependency)
│   ├── Model/                # 17 model types
│   └── Codecs/               # DictionaryCodec, TensorCodec
├── SleapHDF5/                # HDF5 wrapper + SLP read/write + lazy loading
│   ├── HDF5/                 # Thin C wrapper (7 files, ~1000 LOC)
│   └── SLP/                  # SLP codec, lazy store, embedded video
├── SleapVideo/               # Video abstraction (placeholder — Phase 2)
└── SleapRendering/           # 2D rendering (placeholder — Phase 2)
```

### Dependency Graph

```
SleapRendering --> SleapVideo --> SleapIO
SleapHDF5     --> SleapIO
SleapHDF5     --> CHDF5
```

## Key Design Decisions

### Class vs Struct

- **Classes** (identity semantics, `===` equality via `ObjectIdentifier`): Labels, LabeledFrame, Instance, PredictedInstance, Skeleton, Node, Track, Video, Camera, RecordingSession, FrameGroup, InstanceGroup
- **Structs** (value semantics): Point, PredictedPoint, PointsArray, PredictedPointsArray, Edge, Symmetry, ROI, SegmentationMask, SuggestionFrame

### PointsArray Storage

Interleaved Float32 coordinates: `[x0, y0, x1, y1, ...]` in `ContiguousArray<Float>`. Separate `visibility` and `completeness` arrays. Matches Metal's `packed_float2` layout for zero-copy GPU upload.

HDF5 stores Float64 — conversion to Float32 happens on read.

### Lazy Loading

- `.slp` files load lazily by default via `Labels.load(from:)`
- `LazyFrameList` conforms to `RandomAccessCollection<LabeledFrame>` with identity-stable materialization cache
- Cached frames are mutable (edit points, change tracks, add/remove instances within a frame)
- Structural mutations (addFrame, removeFrame, clearPredictions, merge) throw `SleapIOError.mutationWhileLazy` — call `materialize()` first
- Identity table mutations (videos, skeletons, tracks) also throw while lazy

### Serialization

Identity types do NOT use Codable. Serialization goes through explicit codecs:
- `DictionaryCodec` — encode/decode Labels to/from `[String: Any]` with identity preservation
- `SkeletonCodec` — legacy NetworkX graph JSON format (for SLP `/metadata`)
- `SLPReader` / `SLPWriter` — HDF5-based SLP format

### Concurrency

- All model classes are `@unchecked Sendable` — NOT thread-safe internally
- All HDF5 access serialized through `HDF5FileActor` (Swift actor)
- File I/O (`load`/`save`) is `async`
- Downstream apps serialize access via `@MainActor` document model

## HDF5 Gotchas (Important for Future Work)

These caused real bugs during Phase 1. Future agents must understand them:

1. **Fixed-length string off-by-one**: `H5Tget_size()` for null-terminated strings includes the null. When reading into a buffer, allocate `size + 1` bytes so HDF5 has room for the null without overwriting the last content byte. See `HDF5Attribute.swift` fixed-string path.

2. **h5py charset mismatch**: h5py >= 3.0 writes Python `str` as UTF-8 vlen strings. Our vlen reader must use the file's own type (`HDF5Datatype.copy(fileType.id)`) instead of creating a new ASCII vlen type, or HDF5 2.x will refuse the conversion.

3. **h5py fixed-length datasets**: h5py writes `videos_json`, `tracks_json`, `suggestions_json` as fixed-length byte strings (`|S<N>`), not variable-length. The dataset reader handles both paths — check `readVLenBytes()` in `HDF5Dataset.swift`.

4. **Unaligned memory access on arm64e**: Never use `withMemoryRebound` on `UInt8` pointers to read `UInt32`/`Double`. Apple Silicon with pointer authentication enforces strict alignment. Use `copyBytes` pattern instead. See WKB/RLE parsing in `SLPReader.swift`.

5. **Generic vlen vs string vlen**: `H5T_VLEN` (e.g., vlen byte arrays for embedded video) uses `hvl_t` structs. `H5T_STRING` with variable length uses `char*` pointers. These require different read strategies — see `readVLenBytes()`.

## SLP Format Reference

The SLP format is HDF5-based (versions 1.0–1.5). Key datasets:

| Dataset | Type | Fields |
|---------|------|--------|
| `/metadata` | group | `format_id` (float attr), `json` (string attr with skeletons, provenance) |
| `/frames` | compound | frame_id, video, frame_idx, instance_id_start, instance_id_end |
| `/instances` | compound | instance_id, instance_type, frame_id, skeleton, track, from_predicted, score, point_id_start, point_id_end, tracking_score (>=1.2) |
| `/points` | compound | x, y, visible, complete |
| `/pred_points` | compound | x, y, visible, complete, score |
| `/videos_json` | string array | One JSON blob per video |
| `/tracks_json` | string array | `[0, "track_name"]` per track |

### Version-Specific Behaviors

- **< 1.1**: Apply `points.xy -= 0.5` coordinate adjustment on read
- **< 1.2**: `/instances` has 9 fields (no `tracking_score`), default to 0.0
- **< 1.4**: No `channel_order` attribute on embedded video, default to `"BGR"`
- **>= 1.5**: `/rois` and `/masks` datasets may be present

### Skeleton JSON Format (sleap-io 0.6.5+)

The newer format stores skeleton nodes as `{"id": N}` (integer indices into the top-level `nodes` array), not as `{"py/state": {"name": "..."}}`. The `SkeletonCodec` handles both formats — it receives the top-level `nodeNames` array from `SLPMetadata.parse()`.

## Known Issues

1. **Frame lookup is O(n)**: `Labels.frame(for:at:)` scans all frames linearly. The implementation plan specifies a binary search / dictionary index but it's not implemented yet. ~1.8ms worst case for 180k frames.

2. **Lazy cache is unbounded**: Materializing all frames keeps them cached forever. No eviction strategy.

## Test Fixtures

Generated by `Tests/Fixtures/generate_fixtures.py` using Python sleap-io. Required fixtures:

| File | Purpose |
|------|---------|
| `sparse_v1_5.slp` | Multi-video, sparse frames, user instances |
| `dense_predictions_v1_5.slp` | 50 frames, user + predicted instances, tracks, from_predicted |
| `packaged_frames_v1_5.pkg.slp` | Embedded PNG frames |
| `legacy_v1_0.slp` | Pre-1.1 coordinate adjustment |
| `legacy_v1_1.slp` | Pre-1.2 no tracking_score |
| `legacy_v1_3.slp` | Pre-1.4 no channel_order |
| `multiview_v1_5.slp` | Sessions / cameras |
| `roi_mask_v1_5.slp` | ROIs and segmentation masks |

Fixtures are not checked into git. Regenerate with the Python script.

## Design Docs

- `API_DESIGN.md` — Full public API surface as Swift declarations (source of truth for API shape)
- `IMPLEMENTATION_PLAN.md` — Step-by-step build plan with internal architecture decisions
- `TEST_SPEC.md` — Behavioral spec with 23 test cases (M01-M05, Q01, L01-L06, S01-S07, D01-D02, E01-E04, P01-P04)
- `FEASIBILITY.md` — Technical assessment, SLP format deep dive, phasing rationale
- `REVIEW.md` — Review notes confirming doc alignment

## Phase Roadmap

- **Phase 1** (DONE): Package structure, model types, HDF5 wrapper, SLP read/write, lazy loading, embedded video, dictionary/tensor codecs
- **Phase 2** (NEXT): Video backends (AVFoundation), rendering (CoreGraphics), geometric transforms (Accelerate)
- **Phase 3**: COCO JSON, CSV, Label Studio, YOLO, AlphaTracker
- **Phase 4**: Analysis HDF5, JABS, DLC, CLI (swift-argument-parser)
- **Phase 5**: NWB, LEAP .mat (deferred — no Swift ecosystem)
