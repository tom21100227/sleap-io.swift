import Foundation

// MARK: - Video matching (M2)
//
// Mirrors `VideoMatchMethod` / `VideoMatcher` and the module-level rejection
// helpers (`shapes_compatible`, `original_videos_conflict`) from
// `sleap_io/model/matching.py`. Resolves which incoming video corresponds to
// an existing one during a project merge.
//
// Scope note: upstream's AUTO `find_match` additionally performs leaf-path
// uniqueness, pose-based, and image-similarity matching. Those require a
// `Labels` context and frame decoding (out of scope for this pure-model layer),
// so ``VideoMatcher/match(_:_:)`` implements the self-contained *pairwise* AUTO
// cascade (shape/provenance rejection, then file-identity and path matching),
// matching upstream's pairwise `match()` behavior.

/// Methods for matching ``Video`` objects.
///
/// Mirrors the upstream `VideoMatchMethod` enum.
public enum VideoMatchMethod: String, Sendable, CaseIterable {
    /// Match by file path (strict or lenient per ``VideoMatcher/strict``).
    case path
    /// Match by basename only, ignoring directory paths.
    case basename
    /// Match by full shape `(frames, height, width, channels)` and backend type.
    case content
    /// Automatic pairwise cascade: reject on incompatible shape or conflicting
    /// provenance, then match by file identity or path.
    case auto
    /// Match image-sequence videos with overlapping image files.
    case imageDedup = "image_dedup"
    /// Match by spatial shape only (height, width, channels).
    case shape
}

/// Configurable matcher for comparing and matching videos.
///
/// Mirrors the upstream `VideoMatcher`.
public struct VideoMatcher: Sendable {
    /// The matching method to use. Defaults to ``VideoMatchMethod/auto``.
    public var method: VideoMatchMethod

    /// Whether to use strict path matching for the ``VideoMatchMethod/path``
    /// method. When `true`, paths must resolve to the same file; when `false`
    /// (default), same-basename videos match. Only used when ``method`` is
    /// ``VideoMatchMethod/path``.
    public var strict: Bool

    /// Creates a video matcher.
    ///
    /// - Parameters:
    ///   - method: The matching method (defaults to ``VideoMatchMethod/auto``).
    ///   - strict: Strict path matching for the `path` method (defaults to
    ///     `false`).
    public init(method: VideoMatchMethod = .auto, strict: Bool = false) {
        self.method = method
        self.strict = strict
    }

    /// Whether two videos match according to ``method``.
    ///
    /// For ``VideoMatchMethod/auto`` this performs the pairwise cascade:
    /// reject on incompatible shape, reject on conflicting provenance, then
    /// accept on file identity, strict path, or basename match.
    public func match(_ video1: Video, _ video2: Video) -> Bool {
        switch method {
        case .auto:
            // Rejection: definitely-incompatible shapes.
            if VideoMatcher.shapesCompatible(video1, video2) == false { return false }
            // Rejection: provenance points to verifiably different files.
            if VideoMatcher.originalVideosConflict(video1, video2) { return false }
            // Definitive: same underlying file.
            if video1.isSameFile(as: video2) { return true }
            // String: strict path match.
            if video1.matchesPath(video2, strict: true) { return true }
            // String: basename match (pairwise fallback).
            if video1.matchesPath(video2, strict: false) { return true }
            return false
        case .path:
            return video1.matchesPath(video2, strict: strict)
        case .basename:
            return video1.matchesPath(video2, strict: false)
        case .content:
            return video1.matchesContent(video2)
        case .imageDedup:
            return video1.hasOverlappingImages(video2)
        case .shape:
            return video1.matchesShape(video2)
        }
    }

    /// The first video in `candidates` that matches `video`, or `nil`.
    ///
    /// - Note: For ``VideoMatchMethod/auto`` this uses the pairwise ``match``
    ///   check for each candidate; it does not implement upstream's full
    ///   leaf-path-uniqueness / pose / image algorithm.
    public func firstMatch(for video: Video, in candidates: [Video]) -> Video? {
        candidates.first { match(video, $0) }
    }

    // MARK: - Rejection helpers

    /// Whether two videos have compatible shapes.
    ///
    /// Mirrors `shapes_compatible`, used for *rejection only*: compares frames,
    /// height, and width (but **not** channels, which are noisy/configurable).
    ///
    /// - Returns: `false` if the shapes are definitely incompatible, `true` if
    ///   compatible, and `nil` if either shape is unknown.
    public static func shapesCompatible(_ video1: Video, _ video2: Video) -> Bool? {
        guard
            let s1 = video1.effectiveShapeComponents,
            let s2 = video2.effectiveShapeComponents
        else { return nil }
        return s1[0] == s2[0] && s1[1] == s2[1] && s1[2] == s2[2]
    }

    /// Whether two videos have conflicting provenance (verifiably different
    /// source files).
    ///
    /// Mirrors `original_videos_conflict`, used for *rejection*: returns `true`
    /// only when **both** videos carry provenance (a ``Video/sourceVideo``
    /// chain) whose roots point to verifiably different, existing files.
    public static func originalVideosConflict(_ video1: Video, _ video2: Video) -> Bool {
        // Both must have provenance for a conflict to be possible.
        guard video1.sourceVideo != nil, video2.sourceVideo != nil else { return false }

        let root1 = video1.originalVideo ?? video1
        let root2 = video2.originalVideo ?? video2

        // Roots are the same file: no conflict.
        if root1.isSameFile(as: root2) { return false }
        // Cannot verify (neither root file exists locally): allow fall-through.
        if !root1.exists, !root2.exists { return false }
        // At least one file exists and roots differ: conflict.
        return true
    }
}

extension VideoMatcher {
    /// Automatic pairwise matcher. Mirrors `AUTO_VIDEO_MATCHER`.
    public static let autoMatcher = VideoMatcher(method: .auto)

    /// Strict path matcher. Mirrors `PATH_VIDEO_MATCHER`.
    public static let pathMatcher = VideoMatcher(method: .path, strict: true)

    /// Basename matcher. Mirrors `BASENAME_VIDEO_MATCHER`.
    public static let basenameMatcher = VideoMatcher(method: .basename)

    /// Content (shape + backend) matcher.
    public static let contentMatcher = VideoMatcher(method: .content)

    /// Image-sequence overlap matcher. Mirrors `IMAGE_DEDUP_VIDEO_MATCHER`.
    public static let imageDedupMatcher = VideoMatcher(method: .imageDedup)

    /// Spatial-shape matcher. Mirrors `SHAPE_VIDEO_MATCHER`.
    public static let shapeMatcher = VideoMatcher(method: .shape)
}
