import Foundation

// MARK: - Matching / Merge result vocabulary
//
// Shared value types returned by the M2 matcher and merge APIs. These are
// DATA types only — they carry outcomes and summary information but perform no
// matching or merging behavior themselves.
//
// Upstream reference: `sleap_io/model/matching.py`
// (`MatchResult`, `MergeResult`, `ConflictResolution`, `FrameStrategy`,
// `MergeError` / `SkeletonMismatchError`).
//
// Parity notes:
// - `FrameStrategy` upstream is identical to the existing
//   ``LabeledFrame/MergeStrategy``; it is exposed here as a type alias rather
//   than a competing duplicate enum.
// - Upstream errors (`MergeError` / `SkeletonMismatchError`) are represented
//   with the existing ``RecoverableSleapError`` (`.mergeConflict`,
//   `.skeletonMismatch`) instead of a parallel error type.

/// Per-frame merge strategy.
///
/// Parity alias for the upstream `FrameStrategy` enum. The cases are identical
/// to ``LabeledFrame/MergeStrategy`` (`auto`, `keepOriginal`, `keepNew`,
/// `keepBoth`, `updateTracks`, `replacePredictions`), so this reuses that type
/// rather than defining a competing duplicate.
public typealias FrameStrategy = LabeledFrame.MergeStrategy

// MARK: - MatchResult

/// Correspondence maps produced by matching one `Labels` collection against
/// another, without modifying either.
///
/// Each map is keyed by an item from the *other* collection and maps to the
/// matched item in *self*, or `nil` when no match was found. This mirrors the
/// upstream `MatchResult`, which is useful for evaluation workflows that align
/// predictions with ground truth without merging them.
///
/// This is a plain data container; the maps are populated by the (future)
/// matcher APIs.
public struct MatchResult: Sendable, Equatable {
    /// Videos from the other collection mapped to their match in self
    /// (`nil` when unmatched).
    public var videoMap: [Video: Video?]

    /// Skeletons from the other collection mapped to their match in self
    /// (`nil` when unmatched).
    public var skeletonMap: [Skeleton: Skeleton?]

    /// Tracks from the other collection mapped to their match in self
    /// (`nil` when unmatched).
    public var trackMap: [Track: Track?]

    /// Creates a match result from the given correspondence maps.
    ///
    /// - Parameters:
    ///   - videoMap: Video correspondences (other -> self, `nil` if unmatched).
    ///   - skeletonMap: Skeleton correspondences (other -> self, `nil` if unmatched).
    ///   - trackMap: Track correspondences (other -> self, `nil` if unmatched).
    public init(
        videoMap: [Video: Video?] = [:],
        skeletonMap: [Skeleton: Skeleton?] = [:],
        trackMap: [Track: Track?] = [:]
    ) {
        self.videoMap = videoMap
        self.skeletonMap = skeletonMap
        self.trackMap = trackMap
    }

    // MARK: Unmatched items

    /// Videos from the other collection that had no match in self.
    public var unmatchedVideos: [Video] {
        videoMap.compactMap { key, value in value == nil ? key : nil }
    }

    /// Skeletons from the other collection that had no match in self.
    public var unmatchedSkeletons: [Skeleton] {
        skeletonMap.compactMap { key, value in value == nil ? key : nil }
    }

    /// Tracks from the other collection that had no match in self.
    public var unmatchedTracks: [Track] {
        trackMap.compactMap { key, value in value == nil ? key : nil }
    }

    // MARK: All-matched flags

    /// Whether every video from the other collection was matched.
    public var allVideosMatched: Bool { unmatchedVideos.isEmpty }

    /// Whether every skeleton from the other collection was matched.
    public var allSkeletonsMatched: Bool { unmatchedSkeletons.isEmpty }

    /// Whether every track from the other collection was matched.
    public var allTracksMatched: Bool { unmatchedTracks.isEmpty }

    // MARK: Matched counts

    /// Number of videos that were successfully matched.
    public var nVideosMatched: Int { videoMap.values.filter { $0 != nil }.count }

    /// Number of skeletons that were successfully matched.
    public var nSkeletonsMatched: Int { skeletonMap.values.filter { $0 != nil }.count }

    /// Number of tracks that were successfully matched.
    public var nTracksMatched: Int { trackMap.values.filter { $0 != nil }.count }

    /// A human-readable summary of the match result.
    public func summary() -> String {
        var lines: [String] = []
        lines.append("Videos: \(nVideosMatched)/\(videoMap.count) matched")
        lines.append("Skeletons: \(nSkeletonsMatched)/\(skeletonMap.count) matched")
        lines.append("Tracks: \(nTracksMatched)/\(trackMap.count) matched")
        return lines.joined(separator: "\n")
    }
}

// MARK: - ConflictResolution

/// The kind of conflict encountered while merging.
///
/// Parity with upstream free-form `conflict_type` strings, expressed as a
/// typed enum. Use ``other(_:)`` for kinds not covered by a dedicated case.
public enum ConflictType: Sendable, Equatable {
    /// Two instances occupy the same pose / identity slot.
    case duplicateInstance
    /// Skeletons of the merged instances did not match.
    case skeletonMismatch
    /// Track assignments conflicted.
    case trackConflict
    /// A conflict kind not covered by the dedicated cases.
    case other(String)
}

/// How a merge conflict was resolved.
///
/// This is the enum requested by the issue for describing *how* a conflict was
/// resolved. Its cases mirror the outcomes implied by ``FrameStrategy``.
public enum ConflictOutcome: Sendable, Equatable {
    /// The original (base) data was kept; the incoming data was dropped.
    case keptOriginal
    /// The incoming (new) data replaced the original.
    case keptNew
    /// Both original and incoming data were kept.
    case keptBoth
    /// Only track assignments were updated; poses were left unchanged.
    case updatedTracks
    /// Base predictions were removed and incoming predictions added, while base
    /// user instances were kept.
    case replacedPredictions
    /// The conflicting data was combined into a single result.
    case merged
}

/// Information about a single conflict that was resolved during a merge.
///
/// Mirrors the upstream `ConflictResolution` container. The frame identifies
/// where the conflict occurred; ``conflictType`` and ``resolution`` encode what
/// conflicted and how it was resolved. ``details`` carries optional
/// human-readable context (upstream stores free-form `original_data` /
/// `new_data`, which have no Sendable value-type equivalent in Swift).
public struct ConflictResolution: Sendable, Equatable {
    /// The frame where the conflict occurred.
    public var frame: LabeledFrame

    /// The kind of conflict.
    public var conflictType: ConflictType

    /// How the conflict was resolved.
    public var resolution: ConflictOutcome

    /// Optional human-readable context about the conflicting data.
    public var details: String?

    /// Creates a conflict resolution record.
    ///
    /// - Parameters:
    ///   - frame: The frame where the conflict occurred.
    ///   - conflictType: The kind of conflict.
    ///   - resolution: How the conflict was resolved.
    ///   - details: Optional human-readable context.
    public init(
        frame: LabeledFrame,
        conflictType: ConflictType,
        resolution: ConflictOutcome,
        details: String? = nil
    ) {
        self.frame = frame
        self.conflictType = conflictType
        self.resolution = resolution
        self.details = details
    }
}

// MARK: - MergeResult

/// The outcome of a merge operation: summary counts, resolved conflicts, and
/// any collected errors.
///
/// Mirrors the upstream `MergeResult`. Errors are represented with
/// ``RecoverableSleapError`` (e.g. `.mergeConflict`, `.skeletonMismatch`)
/// rather than a parallel error type. This is a plain data container populated
/// by the (future) merge APIs.
public struct MergeResult: Sendable, Equatable {
    /// Whether the merge completed without errors.
    public var successful: Bool

    /// Number of frames that were merged into existing frames.
    public var framesMerged: Int

    /// Number of new instances added.
    public var instancesAdded: Int

    /// Number of existing instances that were updated.
    public var instancesUpdated: Int

    /// Number of instances that were skipped.
    public var instancesSkipped: Int

    /// Conflicts that were resolved during the merge.
    public var conflicts: [ConflictResolution]

    /// Recoverable errors collected during the merge.
    public var errors: [RecoverableSleapError]

    /// Creates a merge result.
    ///
    /// - Parameters:
    ///   - successful: Whether the merge completed without errors.
    ///   - framesMerged: Number of frames merged into existing frames.
    ///   - instancesAdded: Number of new instances added.
    ///   - instancesUpdated: Number of existing instances updated.
    ///   - instancesSkipped: Number of instances skipped.
    ///   - conflicts: Conflicts resolved during the merge.
    ///   - errors: Recoverable errors collected during the merge.
    public init(
        successful: Bool,
        framesMerged: Int = 0,
        instancesAdded: Int = 0,
        instancesUpdated: Int = 0,
        instancesSkipped: Int = 0,
        conflicts: [ConflictResolution] = [],
        errors: [RecoverableSleapError] = []
    ) {
        self.successful = successful
        self.framesMerged = framesMerged
        self.instancesAdded = instancesAdded
        self.instancesUpdated = instancesUpdated
        self.instancesSkipped = instancesSkipped
        self.conflicts = conflicts
        self.errors = errors
    }

    /// A human-readable summary of the merge result.
    public func summary() -> String {
        var lines: [String] = []
        lines.append(successful ? "Merge completed successfully"
                                : "Merge completed with errors")
        lines.append("  Frames merged: \(framesMerged)")
        lines.append("  Instances added: \(instancesAdded)")

        if instancesUpdated != 0 {
            lines.append("  Instances updated: \(instancesUpdated)")
        }
        if instancesSkipped != 0 {
            lines.append("  Instances skipped: \(instancesSkipped)")
        }
        if !conflicts.isEmpty {
            lines.append("  Conflicts resolved: \(conflicts.count)")
        }
        if !errors.isEmpty {
            lines.append("  Errors encountered: \(errors.count)")
            for error in errors.prefix(5) {
                lines.append("    - \(String(describing: error))")
            }
            if errors.count > 5 {
                lines.append("    ... and \(errors.count - 5) more")
            }
        }
        return lines.joined(separator: "\n")
    }
}
