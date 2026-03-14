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
    public enum MergeStrategy: Sendable {
        case auto
        case keepOriginal
        case keepNew
        case keepBoth
        case updateTracks
        case replacePredictions
    }

    /// Merge instances from another frame into this one.
    public func merge(from other: LabeledFrame, strategy: MergeStrategy = .auto) {
        switch strategy {
        case .keepBoth:
            instances.append(contentsOf: other.instances)
        case .keepOriginal:
            break
        case .keepNew:
            instances = other.instances
        case .replacePredictions:
            instances.removeAll { $0 is PredictedInstance }
            instances.append(contentsOf: other.instances)
        case .auto, .updateTracks:
            // Default: add new predictions, keep existing user instances
            let existingPredicted = Set(predictedInstances.map { ObjectIdentifier($0) })
            for predicted in other.predictedInstances
                where !existingPredicted.contains(ObjectIdentifier(predicted)) {
                instances.append(predicted)
            }
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
