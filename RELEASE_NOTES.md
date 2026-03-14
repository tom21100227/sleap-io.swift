# sleap-io.swift 0.2.1 — GUI Integration Improvements

Targeted improvements for sleap.swift GUI integration: smoother playback, faster startup, and better editing ergonomics.

## What's New

### LabeledFrame.addInstance convenience
New `@discardableResult` method for adding instances to frames:
```swift
let instance = frame.addInstance(skeleton: skeleton, track: track)
```
Replaces the manual `Instance(skeleton:)` + `frame.instances.append()` pattern used throughout sleap.swift.

### Video.frameCount from SLP metadata
Frame count and dimensions are now extracted from the video backend `shape` field in SLP files during load — no need to call `video.open()` first. This enables sleap.swift to display video metadata (frame count, resolution) immediately in the sidebar without opening the video backend.

Shape is round-tripped through save/load, and is written back from `Video.frameCount`/`frameSize` if missing from the original metadata.

### AVFoundation seek tolerance control
New `SeekTolerance` enum controls the accuracy/speed trade-off when extracting video frames:
```swift
let exact = try await video.frame(at: idx, tolerance: .exact)      // annotation
let fast  = try await video.frame(at: idx, tolerance: .adaptive)   // scrubbing
```
- `.exact` — zero tolerance, frame-accurate seeking. Uses the frame cache. Default behavior, backward-compatible.
- `.adaptive` — half-frame tolerance, faster approximate seeking. Bypasses the cache so approximate frames don't pollute exact entries.

Prefetch uses adaptive tolerance automatically.

### Unified prefetch cache
`AVFoundationBackend` no longer maintains a private prefetch cache. Prefetched frames are stored directly in the shared `FrameCache` (per-Video NSCache), eliminating double-storage and making prefetched frames immediately available via `video.frame(at:)`.

### Lazy frame cache eviction (LRU)
`LazyFrameList` now uses an LRU cache (capacity: 10,000 frames) instead of an unbounded dictionary. This bounds memory for large annotation files (180k+ frames) on iPadOS while preserving identity stability for frames within the working set.

## API Changes

| API | Change |
|-----|--------|
| `LabeledFrame.addInstance(skeleton:track:)` | Added |
| `Video.frame(at:tolerance:)` | Added |
| `SeekTolerance` | Added (enum) |
| `VideoBackend.frame(at:tolerance:)` | Added (protocol, default impl) |

All changes are additive — no breaking API changes.

## For sleap.swift

- **addInstance**: Replace `Instance(skeleton:)` + `frame.instances.append()` with `frame.addInstance(skeleton:)` in `ProjectState.addInstance()`.
- **frameCount**: `VideoListView` can now show frame counts immediately after `Labels.load()` for SLP files that have shape metadata (most SLEAP GUI-saved files do).
- **Tolerance**: Use `.adaptive` for playback/scrubbing paths if decode latency is a concern. Current `.exact` default preserves existing behavior.
- **Prefetch**: No API changes needed — prefetched frames now appear in the shared cache automatically.
- **LRU**: No action needed. The 10k capacity is well above typical annotation sessions. If `FrameIndex.build()` materializes all frames, they stay cached within capacity.
