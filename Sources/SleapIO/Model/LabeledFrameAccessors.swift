import Foundation

// Note: `Instance.isEmpty` is provided by E2.2 (ModelNumpyAccessors.swift).

// MARK: - LabeledFrame cleanup + classification helpers

extension LabeledFrame {
    /// Remove instances that have no visible points.
    ///
    /// Upstream reference: `LabeledFrame.remove_empty_instances`.
    public func removeEmptyInstances() {
        instances.removeAll { $0.isEmpty }
    }

    /// Remove all predicted instances, keeping user-labeled instances.
    ///
    /// Upstream reference: `LabeledFrame.remove_predictions`.
    public func removePredictions() {
        instances.removeAll { $0 is PredictedInstance }
    }

    /// Predicted instances that are not referenced by any user instance's
    /// `fromPredicted` link.
    ///
    /// Upstream reference: `LabeledFrame.unused_predictions`.
    public var unusedPredictions: [PredictedInstance] {
        let usedIdentities = Set(
            userInstances.compactMap { $0.fromPredicted.map(ObjectIdentifier.init) }
        )
        return predictedInstances.filter {
            !usedIdentities.contains(ObjectIdentifier($0))
        }
    }

    /// Whether this frame has at least one user-labeled (non-predicted) instance.
    ///
    /// Upstream reference: `LabeledFrame.is_user_labeled`. Exposed under the
    /// Python name; equivalent to ``hasUserInstances``.
    public var isUserLabeled: Bool {
        hasUserInstances
    }
}
