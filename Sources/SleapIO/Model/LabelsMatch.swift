import Foundation

// MARK: - Labels.match
//
// Pure correspondence matching between two `Labels` collections, mirroring the
// upstream `Labels.match`. Unlike ``Labels/merge(from:strategy:videoMatcher:skeletonMatcher:trackMatcher:instanceMatcher:errorMode:progress:)``,
// this builds correspondence maps without mutating either collection, which is
// useful for evaluation workflows that align predictions with ground truth.

extension Labels {
    /// Match the videos, skeletons, and tracks of `other` against this collection
    /// without modifying either.
    ///
    /// Mirrors the upstream `Labels.match`. Each returned map is keyed by an item
    /// from `other` and maps to the matched item in `self` (or `nil` when no match
    /// is found). Typically `self` is the ground-truth collection and `other` the
    /// predictions being aligned to it.
    ///
    /// - Parameters:
    ///   - other: The collection whose items are matched against this one.
    ///   - videoMatcher: Matcher used to correspond videos. Defaults to
    ///     `VideoMatcher()`.
    ///   - skeletonMatcher: Matcher used to correspond skeletons. Defaults to
    ///     `SkeletonMatcher()`.
    ///   - trackMatcher: Matcher used to correspond tracks. Defaults to
    ///     `TrackMatcher()`.
    /// - Returns: A ``MatchResult`` with the video, skeleton, and track
    ///   correspondence maps (`other` -> `self`, `nil` when unmatched).
    public func match(
        _ other: Labels,
        videoMatcher: VideoMatcher = VideoMatcher(),
        skeletonMatcher: SkeletonMatcher = SkeletonMatcher(),
        trackMatcher: TrackMatcher = TrackMatcher()
    ) -> MatchResult {
        var videoMap: [Video: Video?] = [:]
        var skeletonMap: [Skeleton: Skeleton?] = [:]
        var trackMap: [Track: Track?] = [:]

        // Skeletons: first local skeleton matching each incoming one.
        for otherSkeleton in other.skeletons {
            let matched = skeletons.first { skeletonMatcher.match($0, otherSkeleton) }
            skeletonMap.updateValue(matched, forKey: otherSkeleton)
        }

        // Videos: first local video matching each incoming one.
        for otherVideo in other.videos {
            let matched = videoMatcher.firstMatch(for: otherVideo, in: videos)
            videoMap.updateValue(matched, forKey: otherVideo)
        }

        // Tracks: first local track matching each incoming one.
        for otherTrack in other.tracks {
            let matched = trackMatcher.firstMatch(for: otherTrack, in: tracks)
            trackMap.updateValue(matched, forKey: otherTrack)
        }

        return MatchResult(
            videoMap: videoMap, skeletonMap: skeletonMap, trackMap: trackMap)
    }
}
