# Feature Request: Preserve embedded frames during save

## Problem

When `Labels.save(to:)` writes an SLP file that contains embedded video data (`backendType == "hdf5"`), the embedded frame image data is lost. The current write path in `SLPWriter` only writes embedded frames that are currently loaded in the in-memory backend, but:

1. Not all frames may be loaded into memory (lazy loading / cache eviction)
2. Embedded SLP files only store frames for labeled instances, so unlabeled frame indices have no image data at all — this is expected and correct

The result is that a round-trip load → save strips embedded frames from the file, effectively corrupting it.

## Impact

In sleap.swift (the native macOS GUI), macOS `ReferenceFileDocument` triggers auto-save on any mutation. This means simply opening an embedded SLP file and making a small edit (e.g., moving a node) causes auto-save to rewrite the file without the embedded frame data.

**Current workaround in sleap.swift**: We detect `hdf5` backend videos in `snapshot()` and skip the save entirely, returning the existing file unchanged. This means users cannot save *any* edits to embedded SLP files.

## Requested Solution

`SLPWriter` should preserve embedded frame datasets during save. Possible approaches:

1. **Copy HDF5 datasets**: When writing an SLP with `hdf5` backend videos, copy the source file's `/video{N}/video` dataset directly to the output file without decoding/re-encoding. This preserves all embedded frames regardless of what's in memory.

2. **Save-as-copy with patch**: Write only the modified tables (frames, instances, points, etc.) while keeping the video datasets from the source file intact.

3. **Expose a `hasEmbeddedVideo` flag on Labels**: At minimum, provide an API so consumers can detect this case and decide whether to save. Currently we check `video.backendType.lowercased().hasPrefix("hdf5")` manually.

## Context

- Embedded SLP files are common in SLEAP workflows (training packages, shared datasets)
- Python SLEAP handles this by keeping the HDF5 file open and writing in-place
- The sleap.swift GUI currently blocks all saves for embedded files as a safety measure
