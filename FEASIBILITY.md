# sleap-io.swift Feasibility

Date: March 11, 2026

## Verdict

Building a native Swift clone of the core `sleap-io` data model, `.slp` read/write, lazy loading, local video access, rendering, and geometric transforms is technically feasible.

Building full parity with everything the Python `sleap-io` package handles is feasible only in phases. The biggest blockers are:

- HDF5-heavy format support and packaging a stable Swift HDF5 stack
- NWB support, which currently depends on a mature Python ecosystem
- Replacing Python-native analytics surfaces such as NumPy/pandas/polars ergonomics

## Design Intent

This library targets **Apple platforms only** (macOS and iPadOS). It is the foundation layer for downstream apps like `sleap.swift` (training/inference) and `sleap-label.swift` (annotation GUI on macOS/iPadOS). It must:

- Support both sparse label files (100s of videos, few labeled frames each) and dense prediction files (one video, 180k frames, 4 instances per frame)
- Be performant enough for real-time scrubbing through dense prediction timelines on iPadOS
- Expose a clean public API that higher-level apps can build on without touching HDF5 internals
- Handle lazy loading as a first-class concern, not an afterthought

## What The Upstreams Actually Cover

### Python `sleap-io`

The Python package is the real superset. It covers:

- Multi-format I/O: SLP, NWB, COCO, DeepLabCut, Ultralytics YOLO, JABS, Label Studio, CSV, analysis HDF5, AlphaTracker, and LEAP
- CLI commands for showing, converting, rendering, and transforming datasets
- Rendering, merging, dataset splits, lazy loading, and multiple video backends
- Data codecs for NumPy, dictionaries, and DataFrames

#### Core Model Detail

All model classes use `attrs` (`@define`) with identity-based equality (`eq=False`). Key types:

| Class | Fields | Notes |
|---|---|---|
| `Labels` | `labeled_frames`, `videos`, `skeletons`, `tracks`, `suggestions`, `sessions`, `provenance`, `rois`, `masks` | ~2855 lines. Top-level container. |
| `LabeledFrame` | `video`, `frame_idx`, `instances`, `is_negative` | Merge strategies: auto, keep_original, keep_new, keep_both, update_tracks, replace_predictions |
| `Instance` | `points: PointsArray`, `skeleton`, `track`, `tracking_score`, `from_predicted` | `bbox`, `overlaps_with()`, numpy-like indexing by node |
| `PredictedInstance` | extends Instance + `score` | Per-point scores via `PredictedPointsArray` |
| `Skeleton` | `nodes`, `edges`, `symmetries`, `name` | Internal `_name_to_node_cache`, `_node_to_ind_cache` |
| `Track` | `name` | Identity-based equality |
| `Video` | `filename`, `backend`, `backend_metadata`, `source_video` | `shape` = (frames, H, W, C) |
| `Camera` | `matrix`, `dist`, `size`, `rvec`, `tvec`, `name` | Rodrigues rotation without OpenCV |
| `RecordingSession` | cameras -> videos mapping, `FrameGroup`s | Multi-camera support |
| `ROI` | Shapely `geometry`, `annotation_type`, metadata | WKB serialization, scanline rasterization |
| `SegmentationMask` | `rle_counts`, dimensions, metadata | RLE-encoded binary masks |
| `LabelsSet` | dict-like container of named `Labels` | For train/val/test splits |

Points are stored as structured numpy arrays (`PointsArray` subclassing `np.ndarray`) with dtype fields: `xy: float64[2]`, `visible: bool`, `complete: bool`, `name: object`. `PredictedPointsArray` adds `score: float64`.

#### I/O Formats

| Format | Module | Read | Write | Key Dependencies |
|---|---|---|---|---|
| SLEAP (.slp) | `slp.py`, `slp_lazy.py` | Yes | Yes | `h5py`, `simplejson`, `imageio` |
| NWB (.nwb) | `nwb.py` | Yes | Yes | `pynwb`, `ndx-pose`, `ndx-multisubjects` |
| COCO (.json) | `coco.py` | Yes | Yes | stdlib `json` |
| DeepLabCut (.h5/.csv) | `dlc.py` | Yes | No | `pandas`, `h5py` |
| Ultralytics YOLO | `ultralytics.py` | Yes | Yes | `yaml`, `imageio` |
| JABS (.h5) | `jabs.py` | Yes | Yes | `h5py` |
| Label Studio (.json) | `labelstudio.py` | Yes | Yes | `simplejson` |
| CSV | `csv.py` | Yes | Yes | `pandas` |
| Analysis HDF5 (.h5) | `analysis_h5.py` | Yes | Yes | `h5py` |
| AlphaTracker (.json) | `alphatracker.py` | Yes | No | stdlib `json` |
| LEAP (.mat) | `leap.py` | Yes | No | `pymatreader` |

#### Video Backends

- `MediaVideo`: mp4/avi/mov/mj2/mkv via OpenCV, FFmpeg subprocess, or PyAV
- `HDF5Video`: .h5/.hdf5/.slp — rank-4 datasets or embedded binary-encoded images (png/jpg in variable-length int8 datasets)
- `ImageVideo`: png/jpg/tif/bmp sequences
- `TiffVideo`: multi-page TIFF stacks via `tifffile`

#### Rendering

Uses `skia-python` (Google Skia bindings) for 2D rendering. Modules: `core.py`, `colors.py` (colorcet palettes), `shapes.py`, `callbacks.py` (RenderContext/InstanceContext).

### JavaScript `sleap-io.js`

The JavaScript package is narrower and is best treated as the SLP/browser-friendly reference implementation, not the full format superset.

Its current public surface covers:

- SLP read/write (the only I/O format)
- Browser and Node loading paths
- Lazy loading via `LazyDataStore` + `LazyFrameList`
- Embedded video frame handling
- Core labels model (same classes as Python)
- Lite metadata-only SLP parsing via jsfive (pure JS, no WASM)
- Rendering via Canvas API / skia-canvas
- Skeleton codecs (JSON/YAML) and numpy/dictionary helpers

#### HDF5 Strategy in JS

Two engines:

1. **h5wasm** (primary): HDF5 C library compiled to WebAssembly. ~2MB WASM binary. Full compound dataset support.
2. **jsfive** (lite fallback): Pure JS HDF5 reader. No WASM needed (works in Cloudflare Workers). Cannot read compound datasets — metadata only.

Three entry points: Node.js (full), Browser (tree-shaken), Lite (no WASM).

Web Worker streaming with HTTP range requests for large files. `normalizeStructDataset()` handles multiple compound type representations.

## SLP File Format Deep Dive

The SLP format is HDF5-based (format version 1.5). Understanding its internal structure is critical because it is the primary I/O target.

### HDF5 Layout

```
/
├── metadata/                (group)
│   ├── format_id            (attribute, float — 1.0 through 1.5)
│   └── json                 (attribute, bytes — JSON with skeletons, nodes, provenance)
│
├── videos_json              (dataset, vlen bytes — one JSON blob per video)
├── tracks_json              (dataset, vlen bytes — one JSON entry per track: [0, "name"])
├── suggestions_json         (dataset, vlen bytes — one JSON entry per suggestion)
├── sessions_json            (dataset, vlen bytes, optional — multi-camera sessions)
│
├── frames                   (compound dataset)
│   Fields: frame_id (u8), video (u4), frame_idx (u8),
│           instance_id_start (u8), instance_id_end (u8)
│
├── instances                (compound dataset)
│   Fields: instance_id (i8), instance_type (u1), frame_id (u8),
│           skeleton (u4), track (i4), from_predicted (i8),
│           score (f4), point_id_start (u8), point_id_end (u8),
│           tracking_score (f4)  [format >= 1.2 only]
│
├── points                   (compound dataset)
│   Fields: x (f8), y (f8), visible (?), complete (?)
│
├── pred_points              (compound dataset)
│   Fields: x (f8), y (f8), visible (?), complete (?), score (f8)
│
├── negative_frames          (compound dataset, optional)
│   Fields: video_id (u4), frame_idx (u8)
│
├── rois                     (compound dataset, optional, format >= 1.5)
│   Fields: annotation_type (u1), video (i4), frame_idx (i8),
│           track (i4), score (f4), wkb_start (u8), wkb_end (u8)
│   Attributes: categories, names, sources (JSON-encoded lists)
├── roi_wkb                  (uint8 flat array — packed WKB geometry bytes)
│
├── masks                    (compound dataset, optional, format >= 1.5)
│   Fields: height (u4), width (u4), annotation_type (u1), video (i4),
│           frame_idx (i8), track (i4), score (f4),
│           rle_start (u8), rle_end (u8)
│   Attributes: categories, names, sources (JSON-encoded lists)
├── mask_rle                 (uint8 flat array — packed RLE counts as uint32→uint8)
│
├── video0/                  (group, optional — embedded video frames)
│   ├── video                (dataset — rank-4 uint8 or vlen int8 encoded images)
│   │   Attributes: format ("png"/"jpg"/"hdf5"), channel_order (format >= 1.4),
│   │               frames, height, width, channels, fps
│   ├── frame_numbers        (dataset — maps embedded row to source frame index)
│   └── source_video/        (group — json attribute with source video metadata)
│
├── video1/                  (group, optional)
│   └── ...
└── ...
```

Note: The `/metadata` group's `json` attribute contains skeletons (in legacy NetworkX graph format), a superset node list, and provenance metadata. Videos, tracks, and suggestions are stored in **separate datasets** (`/videos_json`, `/tracks_json`, `/suggestions_json`), not inside the metadata JSON.

### Scale Characteristics

| Scenario | frames rows | instances rows | points rows | Typical file size |
|---|---|---|---|---|
| Sparse label file (100 videos, ~10 frames each) | ~1,000 | ~2,000 | ~40,000 | 1–50 MB |
| Dense predictions (1 video, 180k frames, 4 instances) | 180,000 | 720,000 | ~14.4M | 500 MB–2 GB |
| Packaged `.pkg.slp` with embedded frames | varies | varies | varies | Up to 10+ GB |

### Critical Performance Observations

1. **Compound datasets are the bottleneck**: Each of `frames`, `instances`, `points`, `pred_points` is a compound HDF5 dataset with named fields. Reading these requires compound type support — the most advanced HDF5 feature needed.

2. **Indirection via ID ranges**: Frames reference instances via `instance_id_start`/`instance_id_end`. Instances reference points the same way. This enables efficient slicing without loading everything.

3. **Metadata is split**: The `/metadata` group's `json` attribute contains skeletons and provenance. Videos, tracks, and suggestions are in separate vlen byte datasets (`/videos_json`, `/tracks_json`, `/suggestions_json`). All are JSON and trivially parseable.

4. **Embedded video is variable-length**: Embedded frames can be stored as either:
   - Rank-4 uint8 arrays `(N, H, W, C)` — uncompressed, large
   - Variable-length int8 datasets where each entry is a PNG/JPEG-encoded image — compressed, smaller

5. **Lazy loading path**: Python and JS both support loading only the raw column arrays (`frames`, `instances`, `points`, `pred_points`) as flat buffers and materializing `LabeledFrame` objects on demand. For a 180k-frame file, this means loading ~180k × 6 fields for frames + ~720k × 11 fields for instances as contiguous arrays, then slicing into them on access.

## Swift Feasibility By Area

### 1. Core data model

High confidence.

Swift maps well to all model types. Key design decisions for Swift:

- Use `class` with identity-based equality (like Python's `eq=False`) for `Skeleton`, `Track`, `Video`, `Instance` — these are reference types that get shared across the object graph
- Use `struct` for value types like points, edges, symmetries
- `PointsArray` equivalent: a contiguous interleaved `[Float32]` buffer (`[x0, y0, x1, y1, ...]`) with separate visibility/completeness arrays. Matches Metal's `packed_float2` layout for GPU upload. Copied from the HDF5 column store on materialization (~200 bytes per instance for 20 nodes).
- Explicit codec functions (`toDictionary()` / `fromDictionary()`) for serialization instead of Swift's `Codable`, since identity-based reference types in the object graph cannot safely round-trip through naive Codable encoding

### 2. `.slp` read/write

Feasible, but this is the first hard subsystem.

`SLP` is HDF5-based, so a real Swift implementation needs:

- attributes (for `/metadata` JSON string)
- groups (for embedded video: `video0/`, `video1/`, ...)
- datasets (for all data arrays)
- **compound dataset support** (for `frames`, `instances`, `points`, `pred_points`)
- **variable-length data support** (for embedded encoded image frames)
- chunked/lazy reads (for accessing subsets without loading entire datasets)

The pragmatic route is wrapping the C HDF5 library in Swift.

#### Available Swift HDF5 Libraries

| Library | Status | Notes |
|---|---|---|
| [swift-hdf5](https://github.com/open-meteo/swift-hdf5) (open-meteo) | Active (Jan 2026) | macOS + Linux, type-safe, SPM. Early-stage but architecturally sound. |
| [HDF5Kit](https://github.com/alejandro-isaza/HDF5Kit) | Unmaintained (2018) | Has [trueb2 fork](https://swiftpackageregistry.com/trueb2/HDF5Kit) updated Feb 2026. SPM via CHDF5 module map. |
| DIY C wrapper | Always available | Swift C interop is well-documented. Create `CHDF5` system library target in SPM. |

**Critical gap**: Compound datasets and variable-length data are advanced HDF5 features. Existing wrappers likely need extension. This is the highest-risk technical item in Phase 1.

### 3. Lazy loading

Feasible. Critical for the dense prediction use case.

Both Python and JS now support lazy materialization of frames. Swift can model the same design with:

- an HDF5-backed store of raw columns (flat arrays of frame/instance/point data)
- custom `RandomAccessCollection` wrappers for lazy frame lists
- on-demand materialization of `LabeledFrame` from column indices

For the 180k-frame case, lazy loading is not optional — it's the difference between a 100ms open and a 30-second open. The raw column arrays (~50 MB for frames+instances metadata) load fast; materializing 720k Instance objects does not.

### 4. Video I/O

Feasible. This library targets Apple platforms only.

- `AVAssetImageGenerator`: random-access frame extraction at specific timestamps
- `AVAssetReader` + `AVAssetReaderTrackOutput`: sequential frame-by-frame reading
- `CoreMedia` / `CVPixelBuffer`: zero-copy frame pipeline
- `ImageIO`: image sequence handling and embedded JPEG/PNG decoding

These cover local files, remote URLs, and embedded HDF5 frames.

### 5. Rendering

Feasible.

On Apple platforms this is arguably easier in Swift than in Python/JS:

- `CoreGraphics` for 2D drawing (nodes, edges, labels)
- `CoreImage` for image processing
- `AVAssetWriter` for encoded video output
- optionally `Metal` for GPU-accelerated rendering of dense overlays

### 6. Geometric transforms

Feasible.

The transform layer in Python is conceptually portable:

- crop, scale, rotate, pad, flip, coordinate remapping

This is math and image-processing work, not an ecosystem blocker. `Accelerate` (vDSP/BLAS) handles matrix operations.

### 7. Simple interchange formats

Moderate difficulty, good candidates after SLP:

- CSV, COCO JSON, Label Studio JSON, Ultralytics YOLO, AlphaTracker

These are mostly schema-mapping problems. Swift's `Codable` handles JSON formats natively.

### 8. HDF5-derived secondary formats

Moderate to high difficulty:

- analysis HDF5, JABS H5, DeepLabCut H5, embedded video datasets

Once the base HDF5 layer is solid, these become realistic.

### 9. LEAP `.mat`

Higher difficulty. MATLAB files need either a MAT parser, `matio`, or limiting support to HDF5-backed MAT variants. Not a good phase-1 target.

### 10. NWB

This is the biggest parity risk.

Python relies on `pynwb`, `ndx-pose`, `ndx-multisubjects`. There is **no Swift NWB ecosystem** — zero libraries found on GitHub. A native implementation would mean implementing the relevant NWB/HDMF schema handling over HDF5.

That makes NWB the strongest reason to treat full parity as phased rather than immediate.

## Swift Ecosystem Dependencies

| Area | Library | Status |
|---|---|---|
| HDF5 | DIY C wrapper (purpose-built, ~1000 LOC) | Needed; existing libs lack compound dataset support |
| Numerics | Accelerate (vDSP/BLAS) | Built-in on Apple platforms |
| Video | AVFoundation | Built-in on Apple platforms |
| Rendering | CoreGraphics / Metal | Built-in on Apple platforms |
| JSON | Foundation JSONSerialization | Built-in |
| CLI | [swift-argument-parser](https://github.com/apple/swift-argument-parser) | First-party, Phase 4 |

## Recommended Scope

### Phase 1

- Swift package structure
- Core model types
- HDF5 wrapper (with compound dataset support)
- SLP read/write
- Lazy loading (critical for dense files)
- Local video access (AVFoundation)
- Rendering (CoreGraphics)
- Transforms
- Dictionary codec
- Array/tensor codec

### Phase 2

- CSV
- COCO
- Label Studio
- YOLO
- AlphaTracker

### Phase 3

- Analysis HDF5
- JABS
- DLC H5
- Embedded video round-tripping
- CLI via swift-argument-parser

### Phase 4

- LEAP `.mat`
- NWB

## Recommendation

This library targets Apple platforms (macOS + iPadOS). All modules may freely use Apple frameworks (Foundation, AVFoundation, CoreGraphics, Metal, Accelerate, ImageIO). There is no platform-neutral core.

This gives:

- a strong video stack (AVFoundation)
- a strong rendering stack (CoreGraphics/Metal)
- a realistic path to SLP parity
- immediate usefulness as a foundation for sleap.swift and sleap-label.swift

Trying to ship immediate parity with Python's full format matrix, especially NWB, would add disproportionate risk very early.

## Sources

- Python repo: https://github.com/talmolab/sleap-io
- Python README: https://raw.githubusercontent.com/talmolab/sleap-io/main/README.md
- Python package metadata: https://raw.githubusercontent.com/talmolab/sleap-io/main/pyproject.toml
- Python docs: https://io.sleap.ai/
- JavaScript repo: https://github.com/talmolab/sleap-io.js
- JavaScript README: https://raw.githubusercontent.com/talmolab/sleap-io.js/main/README.md
- JavaScript package metadata: https://raw.githubusercontent.com/talmolab/sleap-io.js/main/package.json
- JavaScript docs: https://iojs.sleap.ai/latest/
- JavaScript API docs: https://iojs.sleap.ai/latest/api/
- JavaScript lite docs: https://iojs.sleap.ai/latest/lite/
- JavaScript rendering docs: https://iojs.sleap.ai/latest/rendering/
- JavaScript release notes: https://raw.githubusercontent.com/talmolab/sleap-io.js/main/RELEASE_NOTES.md
- HDF5Kit: https://github.com/alejandro-isaza/HDF5Kit
- swift-hdf5: https://github.com/open-meteo/swift-hdf5
- msgpack-swift: https://github.com/fumoboy007/msgpack-swift
- swift-protobuf: https://github.com/apple/swift-protobuf
- Matft: https://github.com/jjjkkkjjj/Matft
