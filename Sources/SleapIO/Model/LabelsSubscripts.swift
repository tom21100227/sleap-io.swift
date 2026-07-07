import Foundation

/// Foreign-video resolution and `find()` query helpers.
///
/// These mirror the upstream sleap-io `Labels.__getitem__` / `find` / `match_video`
/// semantics: a `Video` originating from a different object graph (same filename,
/// different identity) is resolved against the local identity table before the
/// frame store is queried. None of these methods mutate the store.
extension Labels {
    /// All labeled frames for `video`, resolving foreign video objects by filename.
    public subscript(video: Video) -> [LabeledFrame] {
        frames(forVideoMatching: video)
    }

    /// The labeled frame at `frameIndex` for `video`, resolving foreign video objects by filename.
    public subscript(video: Video, frameIndex: Int) -> LabeledFrame? {
        find(video: video, frameIdx: frameIndex).first
    }

    /// Labeled frames at the given collection positions.
    public subscript(indices: [Int]) -> [LabeledFrame] {
        indices.map { self[$0] }
    }

    /// Labeled frames in the given collection-position range.
    public subscript<R: RangeExpression>(range: R) -> [LabeledFrame] where R.Bound == Int {
        range.relative(to: startIndex..<endIndex).map { self[$0] }
    }

    /// Resolves a possibly-foreign `Video` to the equivalent video in this
    /// `Labels`' identity table.
    ///
    /// Resolution order:
    /// 1. The video that is `===` to `video` (same object identity).
    /// 2. Otherwise, the first video whose ``Video/filename`` matches.
    /// 3. Otherwise, `nil`.
    ///
    /// - Parameter video: A video object, which may belong to a different graph.
    /// - Returns: The matching video from ``Labels/videos``, or `nil` if none matches.
    public func resolveVideo(_ video: Video) -> Video? {
        // Fast path: exact identity match.
        if videos.contains(where: { $0 === video }) {
            return video
        }
        // Fallback: match by effective filename.
        return videos.first { $0.filename == video.filename }
    }

    /// All labeled frames for a video, resolving a foreign `Video` by filename
    /// when it is not the same object as one held by this `Labels`.
    ///
    /// Frames are returned sorted by ``LabeledFrame/frameIndex``.
    ///
    /// - Parameter video: The video to match (may be a foreign object).
    /// - Returns: The matching frames, or an empty array if the video cannot be resolved.
    public func frames(forVideoMatching video: Video) -> [LabeledFrame] {
        guard let resolved = resolveVideo(video) else { return [] }
        return frames(for: resolved)
    }

    /// Finds labeled frames for a video, with optional frame-index filtering and
    /// on-demand creation of an empty frame.
    ///
    /// The supplied `video` is resolved against the local identity table first
    /// (see ``resolveVideo(_:)``), so foreign objects with matching filenames are
    /// handled transparently.
    ///
    /// - Parameters:
    ///   - video: The video to match (may be a foreign object).
    ///   - frameIdx: When `nil`, returns every frame for the resolved video,
    ///     sorted by frame index. When non-`nil`, returns only the frame(s) at
    ///     that index.
    ///   - returnNew: When `true` and `frameIdx` is non-`nil` and no matching
    ///     frame exists, a fresh empty ``LabeledFrame`` is created on the
    ///     resolved video and returned. The frame is **not** added to the store.
    /// - Returns: The matching (or newly created) frames. Empty if the video
    ///   cannot be resolved.
    public func find(video: Video,
                     frameIdx: Int? = nil,
                     returnNew: Bool = false) -> [LabeledFrame] {
        guard let resolved = resolveVideo(video) else { return [] }

        guard let frameIdx = frameIdx else {
            // All frames for the resolved video, sorted by frame index.
            return frames(for: resolved)
        }

        if let existing = frame(for: resolved, at: frameIdx) {
            return [existing]
        }

        if returnNew {
            // Create a detached empty frame; do NOT mutate the store.
            return [LabeledFrame(video: resolved, frameIndex: frameIdx)]
        }

        return []
    }
}
