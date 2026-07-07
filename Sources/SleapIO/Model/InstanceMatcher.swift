import Foundation

// MARK: - Instance matching
//
// Configurable matcher for deciding when two ``Instance`` objects should be
// considered equivalent during evaluation / merge workflows.
//
// Upstream reference: `sleap_io/model/matching.py`
// (`InstanceMatchMethod`, `InstanceMatcher`).

/// Methods for matching instances.
///
/// Mirrors Python `InstanceMatchMethod`.
public enum InstanceMatchMethod: String, Sendable, CaseIterable, Codable {
    /// Match instances by spatial proximity (Euclidean distance of poses).
    case spatial
    /// Match instances by track identity (same ``Track`` object).
    case identity
    /// Match instances by bounding-box Intersection-over-Union.
    case iou
}

/// Matcher for comparing and matching instances.
///
/// Chooses a comparison strategy via ``method`` and interprets ``threshold``
/// accordingly. This is a lightweight value type; it holds no mutable matching
/// state. Mirrors Python `InstanceMatcher`.
public struct InstanceMatcher: Sendable, Equatable {
    /// The matching strategy to use.
    public var method: InstanceMatchMethod

    /// The threshold used for matching.
    ///
    /// - For ``InstanceMatchMethod/spatial``, the maximum per-point pixel
    ///   distance (passed as the pose tolerance).
    /// - For ``InstanceMatchMethod/iou``, the minimum IoU value.
    /// - Ignored for ``InstanceMatchMethod/identity``.
    ///
    /// Defaults to `5.0`, matching the upstream default.
    public var threshold: Float

    /// Creates an instance matcher.
    ///
    /// - Parameters:
    ///   - method: The matching strategy. Defaults to ``InstanceMatchMethod/spatial``.
    ///   - threshold: The distance / IoU threshold. Defaults to `5.0`.
    public init(method: InstanceMatchMethod = .spatial, threshold: Float = 5.0) {
        self.method = method
        self.threshold = threshold
    }

    /// Whether two instances match under the configured method.
    ///
    /// - Parameters:
    ///   - instance1: The first instance.
    ///   - instance2: The second instance.
    /// - Returns: `true` if the instances match according to ``method``.
    public func match(_ instance1: Instance, _ instance2: Instance) -> Bool {
        switch method {
        case .spatial:
            return instance1.samePoseAs(instance2, tolerance: threshold)
        case .identity:
            return instance1.sameIdentityAs(instance2)
        case .iou:
            return instance1.overlapsWith(instance2, iouThreshold: threshold)
        }
    }

    /// Find all matching pairs between two lists of instances.
    ///
    /// Every instance in `instances1` is compared against every instance in
    /// `instances2`; matches are returned with a per-method score:
    /// - ``InstanceMatchMethod/spatial``: `1 / (1 + meanDistance)` over the
    ///   mutually-visible points (higher is closer).
    /// - ``InstanceMatchMethod/iou``: the actual bounding-box IoU.
    /// - ``InstanceMatchMethod/identity``: always `1.0` (binary match).
    ///
    /// Mirrors Python `InstanceMatcher.find_matches`.
    ///
    /// - Parameters:
    ///   - instances1: Instances indexed by the first tuple element.
    ///   - instances2: Instances indexed by the second tuple element.
    /// - Returns: `(index1, index2, score)` tuples for each matching pair.
    public func findMatches(
        _ instances1: [Instance],
        _ instances2: [Instance]
    ) -> [(index1: Int, index2: Int, score: Float)] {
        var matches: [(index1: Int, index2: Int, score: Float)] = []
        for (i, inst1) in instances1.enumerated() {
            for (j, inst2) in instances2.enumerated() {
                guard match(inst1, inst2) else { continue }
                let score: Float
                switch method {
                case .spatial:
                    score = InstanceMatcher.spatialScore(inst1, inst2)
                case .iou:
                    score = inst1.boundingBoxIoU(with: inst2)
                case .identity:
                    score = 1.0
                }
                matches.append((index1: i, index2: j, score: score))
            }
        }
        return matches
    }

    /// Inverse-distance score over mutually-visible points, matching the upstream
    /// SPATIAL scoring: `1 / (1 + meanDistance)`, or `0` when no points are
    /// visible in both instances.
    private static func spatialScore(_ a: Instance, _ b: Instance) -> Float {
        let pa = a.numpy(invisibleAsNaN: true)
        let pb = b.numpy(invisibleAsNaN: true)
        let n = Swift.min(pa.count, pb.count)
        var total: Float = 0
        var count = 0
        for i in 0..<n {
            // A point is valid only when visible (finite) in both instances.
            if pa[i][0].isNaN || pb[i][0].isNaN { continue }
            let dx = pa[i][0] - pb[i][0]
            let dy = pa[i][1] - pb[i][1]
            total += (dx * dx + dy * dy).squareRoot()
            count += 1
        }
        guard count > 0 else { return 0 }
        return 1.0 / (1.0 + total / Float(count))
    }

    // MARK: - Pre-configured matchers

    /// Spatial duplicate matcher (max 5px per-point distance). Mirrors
    /// upstream `DUPLICATE_MATCHER`.
    public static let duplicate = InstanceMatcher(method: .spatial, threshold: 5.0)

    /// Bounding-box IoU matcher (min IoU 0.5). Mirrors upstream `IOU_MATCHER`.
    public static let iou = InstanceMatcher(method: .iou, threshold: 0.5)

    /// Track-identity matcher. Mirrors upstream `IDENTITY_INSTANCE_MATCHER`.
    public static let identity = InstanceMatcher(method: .identity)
}
