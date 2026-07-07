import Foundation
import SleapIO

// E9.2: source_video / original_video lineage — in-memory restore.
//
// Complements the read-side lineage decode (SLPVideoTable) and the save-side
// reference modes in Python sleap-io. `restoreOriginalVideos` performs the model
// equivalent of the `restore_original_videos` save mode: an embedded / proxy
// video is swapped back to the original external source it was derived from.

extension Labels {

    /// Swap every video that carries a ``Video/sourceVideo`` provenance chain back
    /// to its root original video, updating every reference (labeled frames and
    /// suggestions) so they point at the restored videos.
    ///
    /// This mirrors the `restore_original_videos` save mode in Python sleap-io:
    /// when saving without embedding, an embedded/proxy video is written out as the
    /// original external source it was derived from. Here the swap is performed
    /// in-memory on the model, following the ``Video/sourceVideo`` chain to its
    /// root (``Video/originalVideo``).
    ///
    /// Videos without a ``Video/sourceVideo`` are left untouched, and each video's
    /// position in ``videos`` is preserved. Because index-based annotations
    /// (``rois``, ``masks``, ``bboxes``, ``centroids``) reference videos positionally,
    /// they remain valid without modification.
    ///
    /// Lazy ``Labels`` are materialized first so that frame references can be
    /// rebuilt (``LabeledFrame/video`` is immutable, so swapped frames are recreated
    /// while unaffected frames are reused as-is).
    ///
    /// - Returns: The number of videos that were swapped to their originals.
    @discardableResult
    public func restoreOriginalVideos() -> Int {
        // Rebuilding frame references requires eager frames.
        materialize()

        // Build an old -> restored map (keyed by object identity), preserving the
        // order and length of the video table.
        var replacements: [ObjectIdentifier: Video] = [:]
        var restoredVideos: [Video] = []
        restoredVideos.reserveCapacity(videos.count)
        for video in videos {
            if let original = video.originalVideo {
                replacements[ObjectIdentifier(video)] = original
                restoredVideos.append(original)
            } else {
                restoredVideos.append(video)
            }
        }

        guard !replacements.isEmpty else { return 0 }

        // Repoint labeled frames. `LabeledFrame.video` is immutable, so swapped
        // frames are rebuilt; frames on unaffected videos are reused unchanged.
        let oldFrames = frameStore.allFrames()
        var newFrames: [LabeledFrame] = []
        newFrames.reserveCapacity(oldFrames.count)
        for frame in oldFrames {
            if let restored = replacements[ObjectIdentifier(frame.video)] {
                newFrames.append(LabeledFrame(
                    video: restored,
                    frameIndex: frame.frameIndex,
                    instances: frame.instances,
                    isNegative: frame.isNegative
                ))
            } else {
                newFrames.append(frame)
            }
        }
        frameStore = EagerFrameStore(frames: newFrames)

        // Repoint suggestions (their `video` reference is mutable).
        for index in suggestions.indices {
            if let restored = replacements[ObjectIdentifier(suggestions[index].video)] {
                suggestions[index].video = restored
            }
        }

        // Publish the restored video table. This also invalidates the cached
        // frame-lookup index. `setVideos` only throws while lazy, and we
        // materialized above, so the swap has already been applied to the store.
        try? setVideos(restoredVideos)

        return replacements.count
    }
}
