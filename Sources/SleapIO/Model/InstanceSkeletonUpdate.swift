import Foundation

// E2.4: Instance.replaceSkeleton / updateSkeleton, mirroring Python sleap_io.
//
// Our points are index-aligned to the skeleton node order (no per-point name
// array), so `replaceSkeleton` remaps points by matching the OLD skeleton's node
// names to the NEW skeleton's, leaving unmatched new nodes invisible. Predicted
// instances are handled in the same method (extension methods can't be overridden).

extension Instance {

    /// Re-point ``points.skeleton`` to this instance's current ``skeleton``.
    ///
    /// In our index-based model the node-name array is derived from the skeleton, so
    /// `namesOnly` simply refreshes the points' skeleton reference. When `namesOnly`
    /// is `false` and the point count no longer matches the skeleton, the points are
    /// resized (extra nodes become invisible; surplus points are dropped) — prefer
    /// the migrating `Skeleton` mutators for structural edits.
    public func updateSkeleton(namesOnly: Bool = false) {
        points.skeleton = skeleton
        guard !namesOnly else { return }
        let target = skeleton.nodes.count
        if let pred = self as? PredictedInstance {
            if pred.predictedPoints.count != target {
                var resized = PredictedPointsArray(count: target)
                for i in 0..<Swift.min(pred.predictedPoints.count, target) { resized[i] = pred.predictedPoints[i] }
                resized.skeleton = skeleton
                pred.predictedPoints = resized
            }
        } else if points.count != target {
            var resized = PointsArray(count: target)
            for i in 0..<Swift.min(points.count, target) { resized[i] = points[i] }
            resized.skeleton = skeleton
            points = resized
        }
    }

    /// Replace this instance's skeleton with `newSkeleton`, remapping points (and, for
    /// predicted instances, per-point scores) by node name. New nodes with no
    /// corresponding old node become invisible. Mirrors `Instance.replace_skeleton`.
    ///
    /// - Parameters:
    ///   - newSkeleton: The skeleton to adopt.
    ///   - nodeNamesMap: Optional old-name → new-name mapping. When omitted, nodes are
    ///     matched by identical name.
    public func replaceSkeleton(_ newSkeleton: Skeleton, nodeNamesMap: [String: String]? = nil) {
        let oldSkeleton = skeleton
        let mappedName: (String) -> String = { nodeNamesMap?[$0] ?? $0 }
        var newNameToIndex = [String: Int]()
        for (i, node) in newSkeleton.nodes.enumerated() { newNameToIndex[node.name] = i }

        if let pred = self as? PredictedInstance {
            var newPred = PredictedPointsArray(count: newSkeleton.nodes.count)
            for (oldIdx, oldNode) in oldSkeleton.nodes.enumerated() where oldIdx < pred.predictedPoints.count {
                if let newIdx = newNameToIndex[mappedName(oldNode.name)] {
                    newPred[newIdx] = pred.predictedPoints[oldIdx]
                }
            }
            newPred.skeleton = newSkeleton
            skeleton = newSkeleton
            pred.predictedPoints = newPred
        } else {
            var newPoints = PointsArray(count: newSkeleton.nodes.count)
            for (oldIdx, oldNode) in oldSkeleton.nodes.enumerated() where oldIdx < points.count {
                if let newIdx = newNameToIndex[mappedName(oldNode.name)] {
                    newPoints[newIdx] = points[oldIdx]
                }
            }
            newPoints.skeleton = newSkeleton
            skeleton = newSkeleton
            points = newPoints
        }
    }
}
