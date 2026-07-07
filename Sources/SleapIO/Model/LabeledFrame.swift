import Foundation

/// A single video frame with associated pose instances.
public final class LabeledFrame: Hashable, @unchecked Sendable {
    /// The video this frame belongs to.
    public let video: Video

    /// The frame index within the video.
    public let frameIndex: Int

    /// The instances in this frame.
    public var instances: [Instance]

    /// Whether this frame is explicitly marked as having no instances.
    public var isNegative: Bool

    public init(video: Video, frameIndex: Int, instances: [Instance] = [], isNegative: Bool = false) {
        self.video = video
        self.frameIndex = frameIndex
        self.instances = instances
        self.isNegative = isNegative
    }

    /// Add a new instance to this frame and return it.
    @discardableResult
    public func addInstance(skeleton: Skeleton, track: Track? = nil) -> Instance {
        let instance = Instance(skeleton: skeleton, track: track)
        instances.append(instance)
        return instance
    }

    /// All user-labeled (non-predicted) instances.
    public var userInstances: [Instance] {
        instances.filter { !($0 is PredictedInstance) }
    }

    /// All predicted instances.
    public var predictedInstances: [PredictedInstance] {
        instances.compactMap { $0 as? PredictedInstance }
    }

    /// Check if this frame has any user-labeled instances.
    public var hasUserInstances: Bool {
        instances.contains { !($0 is PredictedInstance) }
    }

    // MARK: - Merge

    /// Strategy for resolving conflicts when merging instances into this frame.
    ///
    /// Parity with the upstream `FrameStrategy` enum.
    public enum MergeStrategy: Sendable {
        /// Preserve user labels, dedup duplicate instances spatially, and prefer
        /// user instances over predictions when they overlap.
        case auto
        /// Keep every instance from this (original) frame; ignore the incoming one.
        case keepOriginal
        /// Replace this frame's instances with the incoming frame's instances.
        case keepNew
        /// Keep every instance from both frames without deduplication.
        case keepBoth
        /// Update track assignments and tracking scores of matched instances
        /// only, without adding or removing any instances.
        case updateTracks
        /// Keep user instances from this frame, drop this frame's predictions, and
        /// add only the incoming frame's predictions. No spatial matching.
        case replacePredictions
    }

    /// Merge instances from another frame into this one, resolving duplicate
    /// instances with `instanceMatcher` and reporting how each conflict was
    /// resolved.
    ///
    /// The frame is modified in place. Mirrors the upstream `LabeledFrame.merge`,
    /// which detects duplicate instances via spatial / IoU / identity matching and
    /// resolves them according to `strategy`. Non-duplicate incoming instances are
    /// added, and the `isNegative` marking is resolved against the merged result.
    ///
    /// - Parameters:
    ///   - other: The frame whose instances are merged into this one.
    ///   - strategy: How to resolve conflicts between duplicate instances.
    ///   - instanceMatcher: Matcher used to detect duplicate instances. Defaults
    ///     to the spatial duplicate matcher (5px tolerance).
    /// - Returns: The conflicts that were resolved during the merge (empty when a
    ///   strategy performs no deduplication).
    @discardableResult
    public func merge(
        from other: LabeledFrame,
        strategy: MergeStrategy = .auto,
        instanceMatcher: InstanceMatcher = .duplicate
    ) throws -> [ConflictResolution] {
        var conflicts: [ConflictResolution] = []

        switch strategy {
        case .keepOriginal:
            // Keep every instance from this frame; ignore the incoming frame
            // (including its negative marking).
            return conflicts

        case .keepNew:
            // Wholesale replacement with the incoming frame's contents.
            instances = other.instances
            isNegative = other.isNegative
            return conflicts

        case .keepBoth:
            // Keep all instances from both frames without deduplication.
            instances = instances + other.instances
            resolveNegative(mergingFrom: other, into: &conflicts)
            return conflicts

        case .updateTracks:
            // Update track and tracking score of matched instances only; do not
            // add or remove any instances.
            let matches = instanceMatcher.findMatches(instances, other.instances)
            for match in matches {
                instances[match.index1].track = other.instances[match.index2].track
                instances[match.index1].trackingScore =
                    other.instances[match.index2].trackingScore
            }
            resolveNegative(mergingFrom: other, into: &conflicts)
            return conflicts

        case .replacePredictions:
            // Keep this frame's user instances, drop its predictions, and add only
            // the incoming frame's predictions. No spatial matching is performed.
            var merged = instances.filter { !($0 is PredictedInstance) }
            merged.append(
                contentsOf: other.instances.compactMap { $0 as? PredictedInstance })
            instances = merged
            resolveNegative(mergingFrom: other, into: &conflicts)
            return conflicts

        case .auto:
            instances = autoMerge(
                from: other, matcher: instanceMatcher, conflicts: &conflicts)
            resolveNegative(mergingFrom: other, into: &conflicts)
            return conflicts
        }
    }

    /// Automatic merge cascade: keep user labels, spatially deduplicate against
    /// incoming instances, prefer user instances over predictions, and record a
    /// ``ConflictResolution`` for every duplicate that is resolved.
    ///
    /// Mirrors the upstream auto strategy in `LabeledFrame.merge`.
    private func autoMerge(
        from other: LabeledFrame,
        matcher: InstanceMatcher,
        conflicts: inout [ConflictResolution]
    ) -> [Instance] {
        var merged: [Instance] = []
        var usedSelfIndices = Set<Int>()

        // 1. Keep all user (non-predicted) instances from this frame.
        for inst in instances where !(inst is PredictedInstance) {
            merged.append(inst)
        }

        // 2. Match this frame's instances against the incoming frame's.
        let matches = matcher.findMatches(instances, other.instances)

        // 3. For each incoming instance, keep only its best (highest score) match.
        var otherToSelf: [Int: (selfIdx: Int, score: Float)] = [:]
        for match in matches {
            if let existing = otherToSelf[match.index2] {
                if match.score > existing.score {
                    otherToSelf[match.index2] = (match.index1, match.score)
                }
            } else {
                otherToSelf[match.index2] = (match.index1, match.score)
            }
        }

        // 4. Process each incoming instance.
        for (otherIdx, otherInst) in other.instances.enumerated() {
            guard let (selfIdx, _) = otherToSelf[otherIdx] else {
                // No duplicate in this frame: add the incoming instance.
                merged.append(otherInst)
                continue
            }

            let selfInst = instances[selfIdx]
            let selfIsUser = !(selfInst is PredictedInstance)
            let otherIsUser = !(otherInst is PredictedInstance)

            switch (selfIsUser, otherIsUser) {
            case (true, true):
                // Two user instances collide: keep the original.
                conflicts.append(ConflictResolution(
                    frame: self,
                    conflictType: .duplicateInstance,
                    resolution: .keptOriginal,
                    details: "Duplicate user instances; kept original."))
                usedSelfIndices.insert(selfIdx)

            case (false, true):
                // A prediction is superseded by a matching user instance.
                if !usedSelfIndices.contains(selfIdx) {
                    merged.append(otherInst)
                    usedSelfIndices.insert(selfIdx)
                }
                conflicts.append(ConflictResolution(
                    frame: self,
                    conflictType: .duplicateInstance,
                    resolution: .keptNew,
                    details: "Replaced prediction with matching user instance."))

            case (true, false):
                // A user instance wins over a matching incoming prediction.
                conflicts.append(ConflictResolution(
                    frame: self,
                    conflictType: .duplicateInstance,
                    resolution: .keptOriginal,
                    details: "Kept user instance over incoming prediction."))
                usedSelfIndices.insert(selfIdx)

            case (false, false):
                // Two predictions collide: keep the incoming one.
                if !usedSelfIndices.contains(selfIdx) {
                    merged.append(otherInst)
                    usedSelfIndices.insert(selfIdx)
                }
                conflicts.append(ConflictResolution(
                    frame: self,
                    conflictType: .duplicateInstance,
                    resolution: .keptNew,
                    details: "Duplicate predictions; kept incoming."))
            }
        }

        // 5. Keep this frame's unmatched predictions (safety net for edge cases).
        for (selfIdx, selfInst) in instances.enumerated()
        where selfInst is PredictedInstance && !usedSelfIndices.contains(selfIdx) {
            let matchedElsewhere = otherToSelf.values.contains { $0.selfIdx == selfIdx }
            if !matchedElsewhere {
                merged.append(selfInst)
            }
        }

        return merged
    }

    /// Resolve the `isNegative` marking after merging in another frame's data.
    ///
    /// A frame that ends up with instances cannot be negative; if a negative
    /// marking is cleared as a result, that is reported as a conflict. When the
    /// merged frame is still empty, negativity carries over from either frame.
    private func resolveNegative(
        mergingFrom other: LabeledFrame,
        into conflicts: inout [ConflictResolution]
    ) {
        if instances.isEmpty {
            isNegative = isNegative || other.isNegative
        } else {
            if isNegative || other.isNegative {
                conflicts.append(ConflictResolution(
                    frame: self,
                    conflictType: .other("negativeFrame"),
                    resolution: .merged,
                    details:
                        "Cleared negative marking because merged frame contains instances."))
            }
            isNegative = false
        }
    }

    // MARK: - Identity equality

    public static func == (lhs: LabeledFrame, rhs: LabeledFrame) -> Bool {
        lhs === rhs
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(ObjectIdentifier(self))
    }
}
