import Foundation

// MARK: - Project-level video relocation & de-duplication (E11.3 / #62)
//
// Mirrors the upstream `Labels.add_video` / `replace_videos` /
// `replace_filenames` helpers plus a Swift-native `matchVideo` convenience.
// Implemented as an extension so ``Labels`` itself stays untouched.
//
// Adaptation note: upstream mutates `LabeledFrame.video` in place, but the Swift
// ``LabeledFrame/video`` is a `let`, so ``replaceVideos(oldVideos:newVideos:videoMap:)``
// rebuilds each affected frame (reusing its instances *by reference* — the merge
// contract of preserving instance identity is not required here, only the video
// reference changes). These are structural mutations, so they require an eager
// (materialized) store — see ``Labels/materialize()``.
//
// Index-based annotations (``ROI``/``SegmentationMask``/``BoundingBox``/
// ``Centroid``) reference videos by position (`videoIndex`), and
// ``replaceVideos(oldVideos:newVideos:videoMap:)`` preserves the ordering of the
// video table, so those need no remapping.

extension Labels {

    /// Add a video, de-duplicating against existing videos by file identity.
    ///
    /// Mirrors `Labels.add_video`: if a video with the same underlying file
    /// already exists (per ``Video/isSameFile(as:)``, which also honors embedded
    /// provenance), the existing video is returned and nothing is appended;
    /// otherwise `video` is appended and returned.
    ///
    /// - Throws: ``SleapIOError/mutationWhileLazy(_:)`` if the store is lazy
    ///   (appending changes the identity table). Call ``Labels/materialize()``
    ///   first.
    /// - Returns: The video that should be used (the existing duplicate, or the
    ///   newly added `video`).
    @discardableResult
    public func addVideo(_ video: Video) throws -> Video {
        for existing in videos where existing.isSameFile(as: video) {
            return existing
        }
        try setVideos(videos + [video])
        return video
    }

    /// The first existing video that matches `video` under `matcher`, or `nil`.
    ///
    /// A Swift convenience mirroring the merge-time video de-duplication: it runs
    /// ``VideoMatcher/firstMatch(for:in:)`` against ``Labels/videos``.
    public func matchVideo(
        _ video: Video,
        using matcher: VideoMatcher = .autoMatcher
    ) -> Video? {
        matcher.firstMatch(for: video, in: videos)
    }

    /// Replace videos and remap all references.
    ///
    /// Mirrors `Labels.replace_videos`. References are remapped on labeled frames
    /// (rebuilt, since ``LabeledFrame/video`` is a `let`) and suggestions; the
    /// video table itself is rewritten in place, preserving element order.
    ///
    /// Exactly one of the following input shapes must resolve to a mapping:
    /// - `videoMap`: explicit `(old, new)` pairs.
    /// - `oldVideos` + `newVideos`: parallel lists of equal length.
    /// - `newVideos` alone, when its count equals ``Labels/videos``: replaces the
    ///   full table element-wise (`oldVideos` defaults to the current videos).
    ///
    /// - Throws: ``SleapIOError/mutationWhileLazy(_:)`` if the store is lazy, or
    ///   ``SleapIOError/videoError(_:)`` if the inputs do not form a valid mapping.
    public func replaceVideos(
        oldVideos: [Video]? = nil,
        newVideos: [Video]? = nil,
        videoMap: [(old: Video, new: Video)]? = nil
    ) throws {
        guard !isLazy else {
            throw SleapIOError.mutationWhileLazy(
                "Cannot replace videos while lazy. Call materialize() first.")
        }

        // Build the old -> new identity map.
        var map: [ObjectIdentifier: Video] = [:]
        if let videoMap {
            for pair in videoMap { map[ObjectIdentifier(pair.old)] = pair.new }
        } else {
            var olds = oldVideos
            if olds == nil, let newVideos, newVideos.count == videos.count {
                olds = videos
            }
            guard let olds, let newVideos, olds.count == newVideos.count else {
                throw SleapIOError.videoError(
                    "replaceVideos requires matching old/new video lists or a videoMap.")
            }
            for (o, n) in zip(olds, newVideos) { map[ObjectIdentifier(o)] = n }
        }

        guard !map.isEmpty else { return }

        // Rebuild affected frames (video is `let`), reusing instances by reference.
        // Unaffected frames keep their original object identity.
        let rebuilt = frameStore.allFrames().map { frame -> LabeledFrame in
            guard let mapped = map[ObjectIdentifier(frame.video)] else { return frame }
            return LabeledFrame(
                video: mapped,
                frameIndex: frame.frameIndex,
                instances: frame.instances,
                isNegative: frame.isNegative)
        }
        frameStore = EagerFrameStore(frames: rebuilt)

        // Remap suggestions (SuggestionFrame.video is mutable).
        suggestions = suggestions.map { sf in
            var sf = sf
            if let mapped = map[ObjectIdentifier(sf.video)] { sf.video = mapped }
            return sf
        }

        // Rewrite the video table, preserving order.
        try setVideos(videos.map { map[ObjectIdentifier($0)] ?? $0 })
    }

    /// Replace video filenames across the project (relocation).
    ///
    /// Mirrors `Labels.replace_filenames`. Exactly one input form must be
    /// provided:
    /// - `newFilenames`: one path per video, in table order (counts must match).
    /// - `filenameMap`: maps old paths to new paths (compared by standardized
    ///   path, per ``Video/pathsEqual(_:_:)``-style semantics).
    /// - `prefixMap`: maps old path prefixes to new prefixes, preserving the
    ///   trailing remainder and separators.
    ///
    /// Each affected video is updated via ``Video/replaceFilename(_:keepOpen:)``,
    /// threading `openVideos` through as the backend-reopen intent.
    ///
    /// - Throws: ``SleapIOError/videoError(_:)`` if not exactly one input form is
    ///   provided, or if `newFilenames` has the wrong length.
    public func replaceFilenames(
        newFilenames: [String]? = nil,
        filenameMap: [String: String]? = nil,
        prefixMap: [(old: String, new: String)]? = nil,
        openVideos: Bool = true
    ) throws {
        let provided = [newFilenames != nil, filenameMap != nil, prefixMap != nil]
            .filter { $0 }.count
        guard provided == 1 else {
            throw SleapIOError.videoError(
                "Exactly one input method must be provided to replaceFilenames.")
        }

        if let newFilenames {
            guard newFilenames.count == videos.count else {
                throw SleapIOError.videoError(
                    "Number of new filenames (\(newFilenames.count)) does not match "
                        + "the number of videos (\(videos.count)).")
            }
            for (video, newFilename) in zip(videos, newFilenames) {
                video.replaceFilename(newFilename, keepOpen: openVideos)
            }
        } else if let filenameMap {
            for video in videos {
                for (oldFn, newFn) in filenameMap where Video.pathsEqual(video.filename, oldFn) {
                    video.replaceFilename(newFn, keepOpen: openVideos)
                }
            }
        } else if let prefixMap {
            for video in videos {
                for (oldPrefix, newPrefix) in prefixMap {
                    if let relocated = Labels.applyPrefix(
                        to: video.filename, oldPrefix: oldPrefix, newPrefix: newPrefix) {
                        video.replaceFilename(relocated, keepOpen: openVideos)
                    }
                }
            }
        }
    }

    /// Rewrite `filename` by swapping a leading `oldPrefix` for `newPrefix`,
    /// preserving the trailing remainder and its separator. Returns `nil` when
    /// `filename` does not start with `oldPrefix`.
    ///
    /// Mirrors the single-file branch of `Labels.replace_filenames(prefix_map=...)`,
    /// including its separator normalization (backslashes are treated as `/`).
    private static func applyPrefix(
        to filename: String, oldPrefix: String, newPrefix: String
    ) -> String? {
        func sanitize(_ s: String) -> String { s.replacingOccurrences(of: "\\", with: "/") }

        let fn = sanitize(filename)
        let old = sanitize(oldPrefix)
        guard fn.hasPrefix(old) else { return nil }

        var remainder = String(fn.dropFirst(old.count))
        let newEndsWithSep = newPrefix.hasSuffix("/") || newPrefix.hasSuffix("\\")

        if remainder.hasPrefix("/") {
            // Remainder carries its own separator; avoid doubling it.
            remainder.removeFirst()
            return (newPrefix.isEmpty || newEndsWithSep)
                ? newPrefix + remainder
                : newPrefix + "/" + remainder
        } else if old.hasSuffix("/") {
            // Old prefix ended with a separator; reintroduce one for the new prefix.
            return (newPrefix.isEmpty || newEndsWithSep)
                ? newPrefix + remainder
                : newPrefix + "/" + remainder
        } else {
            // No separator boundary; concatenate directly.
            return newPrefix + remainder
        }
    }
}
