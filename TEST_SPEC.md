# sleap-io.swift Test Spec

Date: March 11, 2026

## Purpose

This document defines the behavioral spec for implementation and test-driven development of `sleap-io.swift`.

It is intentionally written in behavior terms, not exact syntax terms. If the implementation API changes shape but still satisfies the behavior below, it is acceptable.

## Scope

This spec covers the Phase 1 core:

1. Model semantics
2. `.slp` read/write
3. Lazy loading
4. Dictionary codec
5. Core query/mutation behavior
6. Error behavior
7. Performance and memory budgets

It does not yet require:

1. Rendering
2. Video decoding beyond what is needed for embedded `.slp` support
3. CSV/COCO/YOLO/Label Studio
4. NWB, LEAP, DLC, JABS

## Fixture Set

Tests should be written against a fixed fixture set generated from Python `sleap-io`.

Required fixtures:

1. `sparse_v1_5.slp`
   - Multiple videos
   - Sparse labeled frames
   - User instances only

2. `dense_predictions_v1_5.slp`
   - One video
   - Large frame count
   - User and predicted instances
   - Tracks present

3. `packaged_frames_v1_5.pkg.slp`
   - Embedded JPEG or PNG frames
   - Sparse embedded frame numbers

4. `legacy_v1_0.slp`
   - Pre-1.1 coordinate adjustment case

5. `legacy_v1_1.slp`
   - Pre-1.2 instance schema case

6. `legacy_v1_3.slp`
   - Pre-1.4 embedded channel order default case

7. `multiview_v1_5.slp`
   - Sessions / cameras / frame groups

8. `roi_mask_v1_5.slp`
   - ROIs and segmentation masks present

Optional large benchmark fixture:

1. `dense_180k.slp`
   - Used only for performance and memory tests

## Core Invariants

These invariants must always hold.

### Identity semantics

1. `Node`, `Skeleton`, `Track`, `Video`, `Instance`, `PredictedInstance`, `LabeledFrame`, `Camera`, `RecordingSession`, `FrameGroup`, and `InstanceGroup` use identity equality.
2. Repeated references to the same logical shared object must resolve to the same Swift object instance after load.
3. Dictionary and SLP round-trips must preserve shared identity relationships, not just field equality.

### Value semantics

1. `Point`, `PredictedPoint`, `PointsArray`, `PredictedPointsArray`, `Edge`, `Symmetry`, `ROI`, `SegmentationMask`, `LabelsSet`, `RenderOptions`, and `SaveOptions` behave as values.
2. Materialized `PointsArray` instances own their storage.
3. Mutating one materialized `PointsArray` must not mutate any other instance or the lazy column store.

### Lazy loading semantics

1. `.slp` loads are lazy by default.
2. Lazy frame access is identity-stable.
3. Cached frames and instances are mutable.
4. Structural document mutations are blocked while lazy.
5. Identity-table mutations are blocked while lazy.
6. `materialize()` transitions the document to fully eager mutable state.

## Behavioral Spec

### M01: Node identity equality

Given two references to the same `Node` object
When they are compared
Then they are equal

Given two distinct `Node` objects with the same name
When they are compared
Then they are not equal

### M02: Skeleton shared identity

Given two `Instance` objects that reference the same skeleton in source data
When the file is loaded
Then both instances reference the exact same `Skeleton` object

### M03: LabeledFrame identity equality

Given a lazy `Labels`
When `labels[i]` is accessed twice
Then both references are the same object

### M04: PointsArray ownership

Given a lazy `Labels`
When a frame is materialized
Then each instance's `PointsArray` is copied from the column store into owned storage

Given two materialized instances
When one instance's points are mutated
Then the other instance's points do not change

### M05: PredictedInstance shape

Given a predicted instance from source data
When it is materialized
Then it exposes:

1. Base `Instance` semantics
2. Per-instance `score`
3. `PredictedPointsArray` with per-point scores

### Q01: Query semantics

Given a loaded `Labels`
When `frames(for:)` is called
Then it returns frames sorted by frame index for that video

Given a loaded `Labels`
When `frame(for:at:)` is called repeatedly for the same frame
Then it returns the same cached `LabeledFrame` object

Given a loaded `Labels`
When `instances(for:)` is called for a track
Then it returns all instances assigned to that track across all frames

### L01: Lazy load default

Given a `.slp` file
When `Labels.load(from:)` is called without overrides
Then the returned `Labels` is lazy

### L02: Lazy frame materialization

Given a lazy `Labels`
When a frame is accessed for the first time
Then that frame is materialized and cached

Given the same lazy `Labels`
When the same frame is accessed again
Then the cached object is returned

### L03: Cached frame mutation

Given a lazy `Labels`
When a cached frame is mutated by:

1. editing points
2. changing track assignment
3. adding an instance within that frame
4. removing an instance within that frame

Then the mutations persist across subsequent accesses to that frame

### L04: Structural mutation guard

Given a lazy `Labels`
When any of the following are attempted:

1. add frame
2. remove frame
3. clear predictions across all frames
4. remove track across all frames
5. merge labels

Then the operation throws `mutationWhileLazy`

### L05: Identity-table mutation guard

Given a lazy `Labels`
When mutation of the document's identity tables is attempted
Then the operation throws `mutationWhileLazy`

This applies to:

1. videos table replacement or reorder
2. skeletons table replacement or reorder
3. tracks table replacement or reorder

The exact API shape is implementation-defined, but this behavior is mandatory.

### L06: Materialize transition

Given a lazy `Labels`
When `materialize()` completes
Then:

1. `isLazy == false`
2. all frames are represented as in-memory objects
3. structural mutation APIs no longer throw because of lazy state
4. identity-table mutation APIs no longer throw because of lazy state

### S01: Read `.slp` v1.5

Given a valid v1.5 `.slp`
When it is loaded
Then the full object graph is reconstructed, including:

1. videos
2. tracks
3. skeletons
4. labeled frames
5. user instances
6. predicted instances
7. suggestions
8. sessions if present
9. ROIs if present
10. masks if present

### S02: Read legacy format behaviors

Given a pre-1.1 `.slp`
When it is loaded
Then point coordinates are adjusted by `-0.5`

Given a pre-1.2 `.slp`
When it is loaded
Then missing `tracking_score` is handled without failure

Given a pre-1.4 packaged `.slp`
When it is loaded
Then embedded video channel order defaults to `BGR`

### S03: Sparse video ID remapping

Given an `.slp` with sparse or non-sequential video IDs
When it is loaded
Then all frame-video references resolve to the correct `Video` objects

### S04: SLP round-trip fidelity

Given any supported `.slp` fixture
When it is loaded, saved, and loaded again
Then the resulting document is behaviorally equivalent to the first load

Behavioral equivalence means:

1. same frame count
2. same instance count
3. same predicted instance count
4. same videos, tracks, skeleton topology, and suggestions
5. same point coordinates and flags within expected numeric tolerance
6. same identity-sharing relationships after load

### S05: Hybrid lazy save

Given a lazy `Labels` with zero cached frames
When it is saved
Then the writer may use the raw column-store fast path

Given a lazy `Labels` with some cached frames modified
When it is saved
Then:

1. cached frames serialize from the materialized object graph
2. uncached frames serialize from the column store
3. modifications to cached frames are present in the output
4. uncached frames remain identical to source data

### S06: Embedded frame support

Given a packaged `.slp` with embedded image frames
When it is loaded
Then:

1. embedded frames can be resolved by source frame index
2. sparse `frame_numbers` mappings are respected
3. channel order metadata is respected or defaulted by format version

### S07: `from_predicted` link resolution

Given an `.slp` containing user instances derived from predicted instances
When it is loaded
Then:

1. `from_predicted` references are resolved in a second pass after instances are created
2. each user instance with a source prediction references the correct `PredictedInstance` object
3. the linked prediction is identity-equal to the corresponding predicted instance already present in the frame graph
4. missing or sentinel `from_predicted` values produce `nil` without failure

Given such a document
When it is saved and loaded again
Then the same `from_predicted` relationships are preserved

### D01: Dictionary codec identity preservation

Given a `Labels` object graph with shared skeletons, tracks, and videos
When it is encoded to a dictionary and decoded back
Then shared references remain shared after decode

### D02: Skeleton codec compatibility

Given metadata JSON from an existing `.slp`
When the skeleton codec decodes it
Then the resulting `Skeleton` matches the source graph structure

### E01: Corrupt data handling

Given a malformed or truncated `.slp`
When load is attempted
Then the operation throws `SleapIOError.corruptData` or `SleapIOError.hdf5Error`

### E02: Unsupported format handling

Given an unsupported file extension or format
When load is attempted
Then the operation throws `SleapIOError.unsupportedFormat`

### E03: Missing file handling

Given a nonexistent path
When load is attempted
Then the operation throws `SleapIOError.fileNotFound`

### E04: Too-new format handling

Given an `.slp` with a `format_id` newer than the maximum supported version
When load is attempted
Then the operation throws `SleapIOError.formatVersionTooNew`

## Performance Spec

These are target budgets, not microbenchmarks.

### P01: Dense open latency

Given `dense_180k.slp`
When loaded lazily on a representative development machine
Then open time should be under 200 ms

### P02: Dense memory budget

Given `dense_180k.slp`
When loaded lazily
Then memory at open should remain under 250 MB

### P03: Random frame access

Given `dense_180k.slp`
When 100 random frames are accessed after load
Then total access time should remain under 1 ms excluding initial file open

### P04: Fast-path save

Given a lazy `dense_180k.slp` with zero cached frames
When saved
Then the implementation should use the raw-column fast path

## Suggested Test Suite Layout

1. `ModelIdentityTests`
   - M01
   - M02
   - M03
   - M04
   - M05

2. `LabelsQueryTests`
   - Q01

3. `LazyLoadingTests`
   - L01
   - L02
   - L03
   - L04
   - L05
   - L06

4. `SLPReaderTests`
   - S01
   - S02
   - S03
   - S06
   - S07

5. `SLPWriterTests`
   - S04
   - S05

6. `DictionaryCodecTests`
   - D01
   - D02

7. `ErrorHandlingTests`
   - E01
   - E02
   - E03
   - E04

8. `PerformanceTests`
   - P01
   - P02
   - P03
   - P04

## Definition Of Done

Phase 1 is complete when:

1. All behavioral specs in this document pass
2. All fixtures round-trip where write support is promised
3. Legacy-version compatibility behavior is covered by tests
4. Lazy-mode mutation and save semantics are covered by tests
5. Performance budgets are met or any misses are documented and accepted explicitly
