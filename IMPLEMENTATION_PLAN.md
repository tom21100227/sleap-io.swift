# sleap-io.swift Implementation Plan

Date: March 11, 2026

## Overview

This is a detailed implementation plan for building a native Swift library that reads and writes SLEAP pose tracking data. The library is the foundation layer for downstream apps: `sleap.swift` (training/inference) and `sleap-label.swift` (annotation GUI on macOS/iPadOS).

The plan is organized into implementation steps within each phase, ordered by dependency. Each step lists the files to create, the key decisions, and acceptance criteria.

See also:
- [FEASIBILITY.md](./FEASIBILITY.md) — Technical feasibility assessment
- [API_DESIGN.md](./API_DESIGN.md) — Full public API surface specification
- [PHASE3_SPEC.md](./PHASE3_SPEC.md) — Phase 3 interchange codec behavior
- [PHASE4_SPEC.md](./PHASE4_SPEC.md) — Phase 4 advanced I/O + CLI behavior
- [HDF5_IPADOS_STRATEGY.md](./HDF5_IPADOS_STRATEGY.md) — HDF5 deployment options for downstream iPad apps
- [RELEASE_CHECKLIST.md](./RELEASE_CHECKLIST.md) — Release gate and go/no-go checklist

---

## Architecture

### Module Structure

```
sleap-io.swift/
├── Package.swift
├── Sources/
│   ├── CHDF5/                    # System library target (C shim for libhdf5)
│   │   ├── module.modulemap
│   │   └── shim.h
│   ├── SleapIO/                  # Core model + codecs + transforms
│   │   ├── Model/
│   │   ├── Codecs/
│   │   └── Transforms/
│   ├── SleapHDF5/                # HDF5 wrapper + SLP codec + lazy loading
│   │   ├── HDF5/                 # Thin C wrapper
│   │   └── SLP/                  # SLP read/write
│   ├── SleapVideo/               # Video abstraction + AVFoundation backend
│   └── SleapRendering/           # 2D pose overlay rendering
└── Tests/
    ├── SleapIOTests/
    ├── SleapHDF5Tests/
    ├── SleapVideoTests/
    └── SleapRenderingTests/
```

### Dependency Graph

```
SleapRendering --> SleapVideo --> SleapIO
SleapHDF5     --> SleapIO
SleapHDF5     --> CHDF5
```

All modules target Apple platforms (macOS + iPadOS). A downstream app like `sleap-label.swift` imports all four modules.

---

## Phase 1: Core — SLP Read/Write with Lazy Loading

This is the critical path. Everything else builds on this.

### Step 1.1: Package Structure + CHDF5 System Library

**Files:**
- `Package.swift`
- `Sources/CHDF5/module.modulemap`
- `Sources/CHDF5/shim.h`

**Details:**

The CHDF5 target wraps the system-installed libhdf5 via pkgConfig. The `shim.h` provides inline C functions for HDF5 macros that Swift cannot import directly:

```c
// shim.h — ~60 lines
#include <hdf5.h>

// HDF5 "constants" are actually function calls in newer versions
static inline hid_t shim_H5T_NATIVE_INT32(void)  { return H5T_NATIVE_INT32; }
static inline hid_t shim_H5T_NATIVE_INT64(void)  { return H5T_NATIVE_INT64; }
static inline hid_t shim_H5T_NATIVE_UINT8(void)  { return H5T_NATIVE_UINT8; }
static inline hid_t shim_H5T_NATIVE_UINT32(void) { return H5T_NATIVE_UINT32; }
static inline hid_t shim_H5T_NATIVE_UINT64(void) { return H5T_NATIVE_UINT64; }
static inline hid_t shim_H5T_NATIVE_FLOAT(void)  { return H5T_NATIVE_FLOAT; }
static inline hid_t shim_H5T_NATIVE_DOUBLE(void) { return H5T_NATIVE_DOUBLE; }
static inline hid_t shim_H5P_DEFAULT(void)        { return H5P_DEFAULT; }
static inline hid_t shim_H5S_ALL(void)            { return H5S_ALL; }
// ... etc for H5T_VARIABLE, H5T_C_S1, H5F_ACC_RDONLY, H5F_ACC_TRUNC
```

The `module.modulemap` uses `pkgConfig: "hdf5"` for automatic header/library discovery.

**Acceptance criteria:**
- `swift build` succeeds with an empty SleapHDF5 target that `import CHDF5`
- Works on macOS with Homebrew-installed HDF5 (`brew install hdf5`)

---

### Step 1.2: HDF5 Swift Wrapper

**Files:**
- `Sources/SleapHDF5/HDF5/HDF5File.swift`
- `Sources/SleapHDF5/HDF5/HDF5Group.swift`
- `Sources/SleapHDF5/HDF5/HDF5Dataset.swift`
- `Sources/SleapHDF5/HDF5/HDF5Datatype.swift`
- `Sources/SleapHDF5/HDF5/HDF5Dataspace.swift`
- `Sources/SleapHDF5/HDF5/HDF5Attribute.swift`
- `Sources/SleapHDF5/HDF5/HDF5Error.swift`

**Estimated size:** ~850-1000 lines of Swift

This is a purpose-built thin wrapper, not a general-purpose HDF5 library. It covers exactly the features SLP files need:

**Required HDF5 features and their C API calls:**

| Feature | C API Functions | SLP Usage |
|---------|----------------|-----------|
| File open/create | `H5Fopen`, `H5Fcreate`, `H5Fclose` | Read/write .slp |
| Groups | `H5Gcreate2`, `H5Gopen2`, `H5Gclose` | `/metadata`, `/video0/`, `/video0/source_video/` |
| Attributes (string) | `H5Acreate2`, `H5Aopen`, `H5Aread`, `H5Awrite` | `format_id`, `json` on `/metadata`; `format`, `channel_order` on video datasets |
| Datasets (simple) | `H5Dcreate2`, `H5Dread`, `H5Dwrite`, `H5Dclose` | `/roi_wkb`, `/mask_rle` (flat uint8 arrays) |
| Compound datasets | `H5Tcreate(H5T_COMPOUND)`, `H5Tinsert` | `/frames`, `/instances`, `/points`, `/pred_points`, `/rois`, `/masks` |
| Variable-length datasets | `H5Tvlen_create`, `hvl_t`, `H5Treclaim` | `/videos_json`, `/tracks_json`, `/suggestions_json` (vlen byte strings) |
| Hyperslab selection | `H5Sselect_hyperslab` | Partial reads for lazy loading (future optimization) |
| Chunked creation | `H5Pset_chunk` | Writing large datasets |

**Key design decisions:**

1. **All HDF5 access serialized through a Swift actor** (`HDF5FileActor`). The HDF5 C library is not thread-safe (even with `--enable-threadsafe`, it uses a global mutex). The actor ensures compile-time safety.

2. **Compound dataset read strategy: field-by-field extraction.** Instead of reading the entire compound dataset into an AoS buffer and transposing, use HDF5's ability to read individual fields of a compound type. This writes directly into the final SoA column arrays, halving peak memory during load (no temporary AoS buffer).

   ```
   For pred_points (14.4M rows):
   - AoS approach: 460 MB temp buffer + 200 MB final SoA = 660 MB peak
   - Field-by-field: 200 MB final SoA only = 200 MB peak
   ```

   Implementation: Create a memory compound type with a single field matching the target field, then `H5Dread` directly into the target array.

3. **Variable-length data lifecycle:** Read fills `hvl_t` structs (HDF5-allocated). Copy each `hvl_t.p` into Swift `Data`/`[UInt8]`. Call `H5Treclaim` to free HDF5 memory. Must copy before reclaiming.

4. **Error handling:** Every HDF5 call returns a status code. Wrap in a `try hdf5Call { H5Dread(...) }` helper that throws `HDF5Error` on negative return.

**Acceptance criteria:**
- Can open an existing .slp file and read `/metadata` attributes
- Can read compound datasets field-by-field into separate Swift arrays
- Can read variable-length string datasets (`/videos_json`, `/tracks_json`)
- Can create a new HDF5 file, write compound datasets, and read them back
- All operations go through the actor (no direct C calls from outside)

---

### Step 1.3: Core Model Types

**Files:**
- `Sources/SleapIO/Model/Node.swift`
- `Sources/SleapIO/Model/Edge.swift`
- `Sources/SleapIO/Model/Symmetry.swift`
- `Sources/SleapIO/Model/Skeleton.swift`
- `Sources/SleapIO/Model/Point.swift`
- `Sources/SleapIO/Model/PointsArray.swift`
- `Sources/SleapIO/Model/Track.swift`
- `Sources/SleapIO/Model/Instance.swift`
- `Sources/SleapIO/Model/PredictedInstance.swift`
- `Sources/SleapIO/Model/Video.swift`
- `Sources/SleapIO/Model/LabeledFrame.swift`
- `Sources/SleapIO/Model/SuggestionFrame.swift`
- `Sources/SleapIO/Model/Labels.swift`
- `Sources/SleapIO/Model/Camera.swift`
- `Sources/SleapIO/Model/RecordingSession.swift`
- `Sources/SleapIO/Model/ROI.swift`
- `Sources/SleapIO/Model/SegmentationMask.swift`

See `API_DESIGN.md` for the full type specification. Key decisions:

**Class vs struct:** See API_DESIGN.md summary table. Classes for identity types in the object graph (Labels, LabeledFrame, Instance, Skeleton, Node, Track, Video, Camera, RecordingSession). Structs for data types (Point, PointsArray, Edge, Symmetry, ROI, SegmentationMask, SuggestionFrame).

**Point storage — interleaved Float32 coordinate buffer:**

```swift
public struct PointsArray: Sendable {
    /// Interleaved [x0, y0, x1, y1, ...]. Length = count * 2.
    public var coordinates: ContiguousArray<Float>
    /// Per-point visibility. Length = count.
    public var visibility: ContiguousArray<Bool>
    /// Per-point completeness. Length = count.
    public var completeness: ContiguousArray<Bool>
}
```

Rationale (from performance analysis):
- **Float32 not Float64**: all downstream consumers (Metal, CoreML) are float32. HDF5 stores float64; convert on read.
- **Interleaved xy (not separate x/y arrays)**: keeps each point's x,y on the same cache line, matches Metal's `packed_float2` layout for zero-copy GPU upload, halves array count vs separate x/y.
- **Separate visibility/completeness**: different types (Bool vs Float), different access patterns than coordinates.
- **`ContiguousArray`**: guarantees no bridging overhead (unlike `Array` which may bridge to NSArray).

Memory per instance (20 nodes): `40 * 4 + 20 + 20 = 200 bytes` (coordinates + visibility + completeness) + array overhead ~170 bytes = **~370 bytes**.

**HDF5 read path**: HDF5 stores x and y as separate compound fields (float64). On read, extract both fields into temporary Float64 buffers, then interleave and truncate into the Float32 coordinate buffer in a single pass.

For the lazy column store, the bulk `coordinates` buffer stores all points for all instances contiguously. When a frame is materialized, the PointsArray for each instance is **copied** from the column store into owned `ContiguousArray` storage (~200 bytes per instance for 20 nodes). This is a trivial cost — materializing one frame with 4 instances copies ~800 bytes. The owned storage means materialized instances can be freely mutated without affecting the column store or other instances.

**Identity-based equality** for all classes:

```swift
public static func == (lhs: Node, rhs: Node) -> Bool {
    lhs === rhs
}
public func hash(into hasher: inout Hasher) {
    hasher.combine(ObjectIdentifier(self))
}
```

**Acceptance criteria:**
- All model types compile with correct class/struct semantics
- `Skeleton` conforms to `RandomAccessCollection<Node>` with O(1) node/index lookup
- `Labels` conforms to `RandomAccessCollection<LabeledFrame>`
- Point subscripting by `Node` works
- All value types are `Sendable`; all reference types are `@unchecked Sendable`

---

### Step 1.4: SLP Reader (Eager)

**Files:**
- `Sources/SleapHDF5/SLP/SLPReader.swift`
- `Sources/SleapHDF5/SLP/SLPMetadata.swift`
- `Sources/SleapHDF5/SLP/SkeletonCodec.swift`

**Details:**

Implements the full SLP read path matching Python's `read_labels()`. Read order (same as Python):

1. Read `/metadata` attrs → `format_id` (Float) + `json` (String)
2. Parse metadata JSON → extract skeletons via `SkeletonSLPDecoder` (NetworkX graph format)
3. Read `/tracks_json` → create `Track` objects
4. Read `/videos_json` → create `Video` objects (resolve paths, detect embedded videos)
5. Read `/points` compound dataset → field-by-field into SoA arrays
6. Read `/pred_points` compound dataset → field-by-field into SoA arrays
7. Read `/instances` compound dataset → create `Instance`/`PredictedInstance` objects
8. Read `/frames` compound dataset → create `LabeledFrame` objects
9. Link `from_predicted` references (second pass)
10. Read `/suggestions_json` → create `SuggestionFrame` objects
11. Read `/negative_frames` → mark frames as negative
12. Read `/sessions_json` → create `RecordingSession` objects (if present)
13. Read `/rois` + `/roi_wkb` → create `ROI` objects (format >= 1.5)
14. Read `/masks` + `/mask_rle` → create `SegmentationMask` objects (format >= 1.5)
15. Handle video ID remapping (sparse vs sequential IDs)

**Format version handling:**

| Version | Read Behavior |
|---------|--------------|
| < 1.1 | Apply `points.xy -= 0.5` coordinate adjustment |
| < 1.2 | `/instances` has 9 fields (no `tracking_score`), default to 0.0 |
| >= 1.2 | `/instances` has 10 fields |
| < 1.4 | No `channel_order` on embedded video, default to `"BGR"` |
| >= 1.5 | `/rois` and `/masks` datasets may be present |

**Compound dataset field mapping:**

`/frames`:
| Field | HDF5 Type | Swift Type |
|-------|-----------|------------|
| `frame_id` | uint64 | Int |
| `video` | uint32 | Int |
| `frame_idx` | uint64 | Int |
| `instance_id_start` | uint64 | Int |
| `instance_id_end` | uint64 | Int |

`/instances`:
| Field | HDF5 Type | Swift Type |
|-------|-----------|------------|
| `instance_id` | int64 | Int |
| `instance_type` | uint8 | UInt8 (0=user, 1=predicted) |
| `frame_id` | uint64 | Int |
| `skeleton` | uint32 | Int |
| `track` | int32 | Int (-1 = none) |
| `from_predicted` | int64 | Int (-1 = none) |
| `score` | float32 | Float |
| `point_id_start` | uint64 | Int |
| `point_id_end` | uint64 | Int |
| `tracking_score` | float32 | Float (format >= 1.2 only) |

`/points`:
| Field | HDF5 Type | Swift Type |
|-------|-----------|------------|
| `x` | float64 | Float (truncated from f64) |
| `y` | float64 | Float (truncated from f64) |
| `visible` | bool | Bool |
| `complete` | bool | Bool |

`/pred_points`:
Same as `/points` plus `score: float64 → Float`.

**Acceptance criteria:**
- Can read a real .slp file produced by SLEAP and reconstruct the full object graph
- Handles format versions 1.0 through 1.5
- Handles sparse video IDs correctly
- Round-trip: read → write → read produces identical data

---

### Step 1.5: SLP Writer

**Files:**
- `Sources/SleapHDF5/SLP/SLPWriter.swift`

**Details:**

Implements `write_labels()`. Write order:

1. Delete existing file if present
2. Write `/metadata` group with `format_id` attr (1.5 if ROIs/masks, else 1.4) and `json` attr
3. Write `/tracks_json` — JSON array `[0, "track_name"]` per track
4. Write `/videos_json` — JSON blob per video with backend metadata
5. Iterate all labeled frames, collecting:
   - points into flat arrays (separate user/predicted)
   - instance metadata with point_id offsets
   - frame metadata with instance_id offsets
6. Write `/points`, `/pred_points`, `/instances`, `/frames` as compound datasets
7. Write `/negative_frames` if any
8. Write `/suggestions_json`
9. Write `/sessions_json` if any
10. Write `/rois` + `/roi_wkb` if any
11. Write `/masks` + `/mask_rle` if any

**Always writes format version >= 1.4** (10-field instances with tracking_score).

**Acceptance criteria:**
- Files written by Swift can be read by Python sleap-io
- Files written by Python sleap-io can be read by Swift
- Lazy fast-path: if Labels is lazy and no modifications, copy raw column arrays directly

---

### Step 1.6: Lazy Loading

**Files:**
- `Sources/SleapHDF5/SLP/LazyDataStore.swift`
- `Sources/SleapHDF5/SLP/LazyFrameList.swift`

**Details:**

`LazyDataStore` holds raw column arrays read from HDF5:

```swift
final class LazyDataStore {
    // Raw column arrays — the lazy backing store
    let framesData: FrameColumns      // 180k rows, ~4 MB
    let instancesData: InstanceColumns // 720k rows, ~29 MB
    let pointsData: PointColumns       // user points
    let predPointsData: PredPointColumns // 14.4M rows, ~200 MB

    // Shared reference objects (eagerly loaded, small)
    let videos: [Video]
    let skeletons: [Skeleton]
    let tracks: [Track]
    let formatId: Float
}
```

Where `FrameColumns`, `InstanceColumns`, etc. are structs holding `ContiguousArray<Int32>`, `ContiguousArray<Float>`, etc. — one array per compound field. Point columns store coordinates as interleaved Float32 (`[x0, y0, x1, y1, ...]`) with separate visibility and score arrays.

`LazyFrameList` conforms to `RandomAccessCollection<LabeledFrame>` with an identity-stable materialization cache:

```swift
final class LazyFrameList: RandomAccessCollection {
    let store: LazyDataStore
    /// Cache of already-materialized frames. Keyed by row index.
    /// Ensures identity stability: labels[i] always returns the same object.
    private var cache: [Int: LabeledFrame] = [:]

    var startIndex: Int { 0 }
    var endIndex: Int { store.framesData.count }

    subscript(position: Int) -> LabeledFrame {
        if let cached = cache[position] { return cached }
        let frame = store.materializeFrame(at: position)
        cache[position] = frame
        return frame
    }
}
```

The cache ensures that repeated access to the same index returns the same `LabeledFrame` object, preserving identity semantics. The cache grows lazily — only frames that have been accessed are materialized. For the dense 180k-frame case, a full cache adds ~22 MB (180k × 128 bytes per LabeledFrame shell) plus the Instance objects for accessed frames.

**Frame lookup index:**

At load time, build an index for O(1) `Labels.frame(for:at:)` queries:

- Single-video dense files (detected by checking if all video IDs are the same): binary search on the sorted `frame_idx` column. Zero extra memory.
- Multi-video sparse files: `Dictionary<FrameKey, Int>` where `FrameKey` packs `(videoIndex, frameIdx)` into an `Int64`. Cost: ~9 MB for 180k frames.

**Materialization on access:**

```swift
func materializeFrame(at index: Int) -> LabeledFrame {
    let frameRow = framesData[index]
    let instances = (frameRow.instanceIdStart..<frameRow.instanceIdEnd).map { instIdx in
        materializeInstance(at: instIdx)
    }
    return LabeledFrame(video: videos[frameRow.video], frameIndex: frameRow.frameIdx, instances: instances)
}

func materializeInstance(at index: Int) -> Instance {
    let row = instancesData[index]
    let isUser = row.instanceType == 0
    let pointStart = row.pointIdStart
    let pointEnd = row.pointIdEnd

    // Copy point data from column store into an owned PointsArray.
    // For 20 nodes this is ~200 bytes — trivial cost per instance.
    let points = isUser
        ? pointsData.copySlice(pointStart..<pointEnd)
        : predPointsData.copySlice(pointStart..<pointEnd)

    // ... construct Instance/PredictedInstance
}
```

Note: `copySlice` extracts interleaved xy coordinates plus visibility/completeness from the column store into a new owned `PointsArray`. This is a copy, not a view — the materialized `PointsArray` owns its `ContiguousArray` storage and can be freely mutated without affecting the column store or other instances. The copy cost is negligible (~200 bytes per instance for 20 nodes).

**Performance characteristics (dense 180k-frame file):**

| Operation | Lazy | Eager |
|-----------|------|-------|
| File open | ~70-80 ms | ~460-680 ms |
| Memory at open | ~234 MB (column arrays) | ~280-460 MB (full object graph) |
| Single frame access | ~1-5 us | O(1) array lookup |
| `Labels.numpy()` | Fast path, no object creation | Must iterate all objects |
| Save (unmodified) | Copy raw arrays (~1s) | Serialize all objects (~30-60s) |

**Lazy mutation semantics:**

Cached frames and their instances are fully mutable. You can edit points, change track assignments, add/remove instances within a frame. These edits persist in the cache.

Structural mutations on `Labels` (addFrame, removeFrame, clearPredictions, removeTrack, merge) throw `mutationWhileLazy` because they alter the frame list, which cannot be reconciled with the partially-materialized column store. Setting the identity tables (`videos`, `skeletons`, `tracks`) also throws `mutationWhileLazy` because uncached column store rows contain raw integer indices into these arrays — mutating them would corrupt uncached data. Call `materialize()` first for any of these operations.

**Lazy save semantics:**

On save, the writer must handle the hybrid state:
- **Uncached frames** (never accessed): serialize directly from column store arrays. These are guaranteed unmodified.
- **Cached frames** (accessed, possibly mutated): serialize from the materialized object graph.

If zero frames have been cached, the fast path applies: copy raw column arrays directly (~1s for a dense file). Otherwise, the writer iterates the frame list, choosing the column store or object path per frame.

**Acceptance criteria:**
- `Labels.load(from:)` returns in <200 ms for a 180k-frame file
- Iterating 100 random frames takes <1 ms total
- `labels.isLazy` returns true; `labels.materialize()` converts to eager
- Identity stability: `labels[i] === labels[i]` (same object on repeated access)
- Cached frame mutations persist across accesses and through save
- Structural mutation APIs throw `mutationWhileLazy` when lazy
- Setting `videos`, `skeletons`, `tracks` throws `mutationWhileLazy` when lazy
- After `materialize()`, all mutation APIs work normally
- Lazy save with no cached frames copies raw arrays without materialization
- Memory stays under 250 MB at open time for a 1 GB file

---

### Step 1.7: Embedded Video Support

**Files:**
- `Sources/SleapHDF5/SLP/EmbeddedVideo.swift`

**Details:**

Embedded video frames live in HDF5 groups: `/video0/video`, `/video0/frame_numbers`, `/video0/source_video/`.

**Reading embedded frames:**

The `/video{N}/video` dataset can be:
- **Encoded images** (png/jpg): variable-length or fixed-length int8 dataset. Each row is one JPEG/PNG blob. Decode with `ImageIO` on Apple platforms.
- **Raw arrays** (hdf5 format): rank-4 uint8 dataset `(N, H, W, C)` with gzip compression.

The `frame_numbers` dataset maps dataset row index → source video frame index. Build a reverse map: `sourceFrameIdx → datasetRowIdx` for O(1) frame lookup.

The `channel_order` attribute (format >= 1.4) indicates RGB or BGR encoding. If BGR, swap channels on decode.

**Writing embedded frames:**

When `SaveOptions.embedFrames == true`:
1. Group frames by video
2. For each frame, encode via `ImageIO` (CGImage → JPEG/PNG Data)
3. Write as variable-length int8 dataset
4. Write `frame_numbers` mapping
5. Write `source_video` group with JSON attribute
6. Update `/videos_json` to point at embedded video (`filename = "."`)

**Acceptance criteria:**
- Can read `.pkg.slp` files with embedded JPEG frames
- Can write embedded frames and read them back
- `frame_numbers` mapping is correct for sparse frame sets

---

### Step 1.8: Dictionary Codec

**Files:**
- `Sources/SleapIO/Codecs/DictionaryCodec.swift`

**Details:**

Provides a `DictionaryCodec` struct with static methods for converting between the object graph and untyped dictionaries. This is not a per-type protocol — it is a codec object because graph types (Skeleton, Instance, Video) require shared identity tables during encode/decode to avoid duplicating objects.

```swift
public struct DictionaryCodec {
    static func encode(_ labels: Labels) -> [String: Any]
    static func decode(_ dict: [String: Any]) throws -> Labels
    static func encodeSkeleton(_ skeleton: Skeleton) -> [String: Any]
    static func decodeSkeleton(_ dict: [String: Any]) throws -> Skeleton
}
```

Internally, encode builds index tables (skeleton → index, track → index, video → index) and writes index-based references. Decode builds the shared objects first, then resolves references by index.

The skeleton codec must handle the legacy SLEAP/NetworkX graph serialization format used in the `/metadata` JSON.

**Acceptance criteria:**
- Skeleton round-trips through dictionary representation
- Can decode skeleton JSON from existing .slp files
- Encoding and decoding a Labels preserves object identity (same skeleton instance shared across all instances that use it)

---

### Step 1.9: Tensor Codec

**Files:**
- `Sources/SleapIO/Codecs/TensorCodec.swift`

**Details:**

`Labels.numpy()` equivalent — converts Labels to a 4D array `[frames, tracks, nodes, 2+]`.

For lazy Labels, this has a fast path that operates directly on the column store without materializing any Instance objects (matching Python's `LazyDataStore.to_numpy()`).

**Acceptance criteria:**
- Output shape matches Python `labels.numpy()` for the same file
- Fast path works for lazy Labels

---

## Phase 1 Tests

**Files:**
- `Tests/SleapHDF5Tests/HDF5WrapperTests.swift` — Low-level HDF5 read/write
- `Tests/SleapIOTests/ModelTests.swift` — Model type construction, equality, hashing
- `Tests/SleapHDF5Tests/SLPReaderTests.swift` — Read real .slp files
- `Tests/SleapHDF5Tests/SLPWriterTests.swift` — Write + read-back round-trip
- `Tests/SleapHDF5Tests/LazyLoadingTests.swift` — Lazy vs eager equivalence
- `Tests/SleapHDF5Tests/EmbeddedVideoTests.swift` — .pkg.slp round-trip
- `Tests/SleapIOTests/CodecTests.swift` — Dictionary and tensor codecs

**Test fixtures:** Include small .slp files (sparse and dense) in `Tests/Fixtures/`. Generate with Python sleap-io to ensure cross-compatibility.

---

## Phase 2: Video + Rendering (Apple-native)

### Step 2.1: Video Backend Protocol + AVFoundation Backend

**Files:**
- `Sources/SleapVideo/VideoBackend.swift`
- `Sources/SleapVideo/AVFoundationBackend.swift`
- `Sources/SleapVideo/ImageSequenceBackend.swift`
- `Sources/SleapVideo/HDF5VideoBackend.swift`
- `Sources/SleapVideo/VideoExtensions.swift`

**Details:**

```swift
public protocol VideoBackend: Sendable {
    var frameCount: Int? { get }
    var frameSize: (height: Int, width: Int, channels: Int)? { get }
    var fps: Double? { get }
    func frame(at index: Int) async throws -> CGImage
    func frames(at indices: Range<Int>) async throws -> [CGImage]
    func prefetch(indices: IndexSet)
}
```

**AVFoundation backend** uses `AVAssetImageGenerator` for random access and `AVAssetReader` for sequential reads:

- **Scrubbing mode:** Set `requestedTimeTolerance` to allow nearest-keyframe during active scrubbing (~5-15 ms). Settle on exact frame when scrubbing stops (~20-80 ms).
- **Sequential mode:** Use `AVAssetReader` with pipeline-ahead decode for export/render workflows.

**Frame cache (dual-tier):**

| Tier | Storage | Count (1080p) | Memory | Latency |
|------|---------|---------------|--------|---------|
| Hot | `MTLTexture` (GPU) | 8-16 frames | 66-133 MB | 0 ms (already on GPU) |
| Warm | `CVPixelBuffer` (CPU) | 24-48 frames | 200-400 MB | ~0.5-1 ms (GPU upload) |

Use `NSCache` for auto-eviction under memory pressure (critical for iPadOS). Prefetch 4-8 frames ahead in scrub direction.

**iPadOS memory budget:**
- Column store: ~234 MB
- Frame cache: ~300-500 MB
- Working set: ~50-100 MB
- Total: ~600-850 MB (within iPad Air ~3 GB limit)

**Acceptance criteria:**
- Can extract frames from mp4/avi/mov by index
- Frame cache improves repeated access latency to <1 ms
- Memory stays within budget on iPadOS
- `Video[42]` async subscript works

---

### Step 2.2: Rendering

**Files:**
- `Sources/SleapRendering/PoseRenderer.swift`
- `Sources/SleapRendering/Colors.swift`
- `Sources/SleapRendering/RenderOptions.swift`

**Details:**

CoreGraphics-based 2D rendering:
- Draw edges as antialiased lines between connected node pairs
- Draw nodes as filled circles at point coordinates
- Optional: labels, track names, bounding boxes
- Color by track (consistent color per identity) or by node (body part coloring)

For `sleap-label.swift`, the renderer draws into a `CGContext` overlaid on the video frame, with a `CGAffineTransform` for zoom/pan.

**Acceptance criteria:**
- Can render a `LabeledFrame`'s instances onto a `CGImage`
- Can render into a `CGContext` with arbitrary transform (for zoom/pan)
- Color palettes match Python/JS rendering

---

### Step 2.3: Geometric Transforms

**Files:**
- `Sources/SleapIO/Transforms/AffineTransform.swift`
- `Sources/SleapIO/Transforms/InstanceTransforms.swift`
- `Sources/SleapIO/Transforms/PointsArrayTransforms.swift`

**Details:**

Transform operations on points and instances:
- Translate, scale, rotate, crop, flip
- Arbitrary 3x3 affine matrix application
- `PointsArray.apply(transform:)` mutates in-place using `Accelerate` (vDSP) for batch operations on the coordinate buffer

**Acceptance criteria:**
- Transform results match Python sleap-io for the same inputs
- In-place transform on 14.4M points completes in <50 ms (Accelerate)

---

## Phase 3: Interchange Formats

Detailed behavioral requirements, supported subsets, lossy-field rules, and
acceptance criteria for this phase are defined in `PHASE3_SPEC.md`.

### Step 3.1: COCO JSON

**Files:**
- `Sources/SleapIO/Codecs/COCOCodec.swift`

Read and write COCO keypoints JSON format. Uses Swift's `Codable` for JSON handling.

### Step 3.2: CSV

**Files:**
- `Sources/SleapIO/Codecs/CSVCodec.swift`

Canonical long-table CSV format. The exact schema is defined in
`PHASE3_SPEC.md` and includes explicit `instance` and `skeleton` columns so
reconstruction is unambiguous.

### Step 3.3: Label Studio JSON

**Files:**
- `Sources/SleapIO/Codecs/LabelStudioCodec.swift`

Image-based keypoint tasks only in the first pass. Skeleton mapping is supplied
explicitly by codec configuration; it is not inferred from Label Studio labels.

### Step 3.4: Ultralytics YOLO

**Files:**
- `Sources/SleapIO/Codecs/YOLOCodec.swift`

Directory-based pose dataset with images + label text files. The first pass is
single-class and requires explicit node order configuration as defined in
`PHASE3_SPEC.md`.

### Step 3.5: AlphaTracker JSON (read-only)

**Files:**
- `Sources/SleapIO/Codecs/AlphaTrackerCodec.swift`

Read-only import aligned to the Python `sleap-io` supported subset and the
fixture contract defined in `PHASE3_SPEC.md`.

---

## Phase 4: Advanced I/O

Behavioral contract for this phase lives in [PHASE4_SPEC.md](./PHASE4_SPEC.md).

### Step 4.1: Analysis HDF5

**Files:**
- `Sources/SleapHDF5/AnalysisHDF5Codec.swift`

Read/write analysis-only HDF5 files (location data without video references).

### Step 4.2: JABS H5

**Files:**
- `Sources/SleapHDF5/JABSCodec.swift`

### Step 4.3: DeepLabCut H5 (read-only)

**Files:**
- `Sources/SleapHDF5/DLCCodec.swift`

### Step 4.4: CLI

**Files:**
- `Sources/SleapCLI/main.swift`

Using `swift-argument-parser`. Commands: `show`, `convert`, `info`.

---

## Phase 5: NWB + LEAP — Out of Scope

Not implemented. NWB requires implementing a subset of HDMF schema handling over HDF5 with zero existing Swift ecosystem support. LEAP requires MAT file parsing. These formats are out of scope for this project; attempting to load them will throw a "not implemented" error.

---

## Post-Release Roadmap

These items are intentionally deferred. They are not required to complete
Phases 1 through 4, but they are important follow-up work for performance and
benchmark credibility.

### Embedded Packaged Video Load Path

- Make embedded `.pkg.slp` backend setup metadata-only during `Labels.load()`
  and `Labels.loadEager()`.
- Defer reading embedded image payloads until `Video.open()` or first
  `frame(at:)`.
- Avoid reopening and rehydrating embedded HDF5 backends when the backend is
  already initialized.
- Goal: bring embedded packaged-file label load behavior closer to Python
  `sleap-io`, which appears to defer embedded frame hydration until frame
  access.

### Benchmark Parity

- Treat embedded packaged-file `load()` timings with care: current Swift and
  Python loaders are not measuring equivalent work on those files.
- Extend the benchmark harness to record equivalent embedded metrics on both
  sides:
  - metadata-only label load
  - first embedded frame access
  - small sequential embedded frame scan
- Only make public Swift-vs-Python claims from equivalent-work comparisons.

### Portable HDF5 And iPad Deployment

- Current HDF5 support is implemented through `CHDF5` as a system library
  target with a Homebrew-based macOS development setup.
- That is not, by itself, a shippable iPadOS packaging story for downstream
  apps like `sleap.swift` or `sleap-label.swift`.
- Before claiming iPad support for HDF5-backed formats, choose and implement
  one explicit deployment strategy:
  - vendor libhdf5 as an Apple-platform binary artifact / XCFramework
  - ship a statically linked HDF5 build for supported Apple mobile targets
  - or split the package so non-HDF5 modules remain iPad-ready while
    `SleapHDF5` is macOS-only until portable packaging exists
- Release notes and platform docs must distinguish:
  - Apple-platform model/rendering code
  - macOS-validated HDF5 I/O
  - true iPad-deployable HDF5 support
- Treat this as a downstream-integration blocker for `sleap.swift`, not as a
  minor packaging nicety.

---

## Cross-Cutting Concerns

### Concurrency Model

- All model classes are `@unchecked Sendable` — not internally thread-safe
- Downstream apps (sleap-label) serialize access via `@MainActor` document model
- HDF5 access is actor-isolated (`HDF5FileActor`)
- File I/O (`load`/`save`) and video frame access are `async`
- Value types (`Point`, `PointsArray`, etc.) are `Sendable`

### Error Handling

```swift
public enum SleapIOError: Error, Sendable {
    case fileNotFound(String)
    case unsupportedFormat(String)
    case corruptData(String)
    case hdf5Error(String)
    case videoError(String)
    case invalidSkeleton(String)
    case formatVersionTooNew(Float)
    case mutationWhileLazy(String)
}
```

All I/O operations `throw`. No `Result`, no optionals for error cases.

### Testing Strategy

1. **Unit tests** for model types, codecs, transforms
2. **Integration tests** with real .slp fixtures generated by Python sleap-io
3. **Round-trip tests**: Swift write → Python read, Python write → Swift read
4. **Performance tests** with dense files (measure load time, memory)
5. **Memory leak tests** for the lazy loading lifecycle (file handle, column store)

### Dependencies

| Package | Version | Purpose |
|---------|---------|---------|
| HDF5 C library | >= 1.10 | Via CHDF5 system library |
| swift-argument-parser | >= 1.3 | CLI (Phase 4) |

No other external Swift package dependencies. The library intentionally minimizes dependencies for downstream integration simplicity.
Read-only import aligned to the Python `sleap-io` supported subset and the
fixture contract defined in `PHASE3_SPEC.md`.

---

## iPad Compatibility Requirements (from sleap.swift GUI)

The following issues were identified during development of the native macOS/iPadOS
SLEAP labelling GUI (`sleap.swift`). They block iPadOS support and affect
large-file performance on macOS.

### 1. SLP I/O is not portable to iPadOS (CRITICAL — blocks iPad entirely)

**Problem:** All `.slp` load/save entry points live in `SleapHDF5`, which depends
on `CHDF5` (a system library target requiring `brew install hdf5`). There is no
way to install native HDF5 on iPadOS, so `.slp` files cannot be opened on iPad
at all — including `.pkg.slp` files with embedded frames.

**Impact:** The GUI app cannot ship an iPadOS target until this is resolved.

**Related decision doc:** See `HDF5_IPADOS_STRATEGY.md` for the packaging-focused
comparison of XCFramework vs static HDF5 build vs keeping `SleapHDF5`
macOS-only for now. The options below are broader product-level alternatives.

**Proposed solutions (in order of preference):**

1. **Portable bundle format** — Define a non-HDF5 file format (e.g., JSON
   metadata + embedded frame images in a directory or zip bundle) with load/save
   entry points in `SleapIO` (no native dependency). This would allow iPadOS to
   open a subset of SLEAP files without HDF5.

2. **Pure-Swift HDF5 reader** — Implement enough of the HDF5 spec in pure Swift
   to read `.slp` files. This eliminates the C dependency entirely but is a
   significant engineering effort.

3. **Mac-side export tool** — Add an "Export for iPad" command that converts
   `.slp` → portable format. This is a workaround, not a fix, but unblocks
   iPad viewing without changing the core I/O layer.

**Where the dependency chain is:**

- `Labels.load(from:)` and `Labels.save(to:)` are extensions in
  `Sources/SleapHDF5/SLP/LabelsIO.swift`
- `SleapHDF5` depends on `CHDF5` (system library) in `Package.swift:26`
- `CHDF5` requires `pkgConfig: "hdf5"` which needs `brew install hdf5`

### 2. Frame metadata without materialization (HIGH — blocks lazy-loading perf)

**Problem:** The GUI needs to build a `FrameIndex` mapping
`(video, frameIndex) → store position` for O(1) navigation. Currently the only
way to get video identity and frame index for each entry is
`labels.frameStore.frame(at: i)`, which materializes every lazy frame object.
This defeats lazy loading for large files.

**Impact:** Opening a 180k-frame `.slp` file forces full materialization at load
time (~200ms minimum), eliminating the memory and startup-time benefits of lazy
loading.

**Proposed API addition:**

```swift
// On FrameStore or Labels — return column-level metadata without materializing
// frame objects or their instances:
public func frameMetadata() -> [(videoIndex: Int, frameIndex: Int)]

// Or expose the video/frame index columns directly on LazyFrameList:
public var videoIndices: [Int] { get }   // column from the HDF5 frame table
public var frameIndices: [Int] { get }   // column from the HDF5 frame table
```

This would let the GUI build its index in O(n) time with O(n) memory for
metadata only, without touching the instance data or creating LabeledFrame
objects.

### 3. AVFoundation prefetch is a no-op (MEDIUM — scrubbing performance)

**Problem:** `Video.prefetch(indices:)` forwards to the backend, but
`AVFoundationBackend.prefetch(indices:)` does nothing. The GUI relies on
prefetching nearby frames during timeline scrubbing for smooth playback.

**Impact:** Scrubbing through video relies entirely on the `FrameCache` hit rate.
Sequential scrubbing works (cache is warm), but jumping or fast-dragging the
seekbar may stutter.

**Proposed fix:** Implement prefetch in `AVFoundationBackend` using
`AVAssetImageGenerator` with `requestedTimeToleranceBefore/After` set
appropriately for approximate frame generation.

### 4. Skeleton editing requires instance migration (MEDIUM — Phase 2 GUI)

**Problem:** `Skeleton` supports add/remove node/edge, but `PointsArray` has a
fixed point count set at initialization (from `skeleton.nodes.count`). When a
node is added or removed from the skeleton, all existing `Instance` objects have
misaligned point storage.

**Impact:** The GUI's skeleton editor (Phase 2) cannot add/remove nodes without
manually migrating every instance's `PointsArray`. This is error-prone and
should be a library-level operation.

**Proposed API additions:**

```swift
extension Skeleton {
    /// Add a node and migrate all instances that reference this skeleton.
    /// New points are initialized as invisible with NaN coordinates.
    public func addNode(_ node: Node, migratingInstances instances: [Instance])

    /// Remove a node and migrate all instances that reference this skeleton.
    /// Points at the removed index are dropped.
    public func removeNode(_ node: Node, migratingInstances instances: [Instance])
}
```

### 5. Lazy mutation rules documentation (LOW — correctness)

**Clarification needed:** Frame-local edits on already-materialized lazy frames
do work without calling `labels.materialize()`:
- Point edits (`instance[node] = point`)
- Track reassignment (`instance.track = newTrack`)
- Adding/removing instances within a cached frame (`frame.instances.append(...)`)

Only `Labels`-level structural mutations (addFrame, removeFrame, clearPredictions,
merge) require full materialization. The GUI exploits this distinction to keep
large files lazy for as long as possible during editing. It would be helpful to
document this in the `Labels` API or `CLAUDE.md`.
