import Foundation

/// Frame classification helpers mirroring sleap-io's user / negative / empty
/// distinction, driven by ``LabeledFrame/isNegative`` and user-instance presence.
extension LabeledFrame {

    /// The labeling classification of a ``LabeledFrame``.
    ///
    /// This partitions frames by their *user-labeling* state — the distinction
    /// SLEAP draws when deciding what a frame contributes to training and review.
    /// It is intentionally user-centric: predictions alone never make a frame
    /// user-labeled.
    ///
    /// The three cases are mutually exclusive and exhaustive. When a frame is in
    /// an inconsistent state (for example, marked ``LabeledFrame/isNegative`` yet
    /// carrying user instances), the presence of user instances wins. That
    /// matches the invariant enforced by
    /// ``LabeledFrame/merge(from:strategy:instanceMatcher:)`` and ``Labels/clean``:
    /// a populated frame is never negative.
    public enum Kind: Sendable, Hashable, CaseIterable {
        /// The frame has at least one user-labeled (non-predicted) instance. A
        /// positive training example.
        case user

        /// The frame has no user instances and is explicitly marked
        /// ``LabeledFrame/isNegative`` — a negative anchor asserting "no objects
        /// here". A negative training example.
        case negative

        /// The frame has no user instances and is not marked negative. Either
        /// truly empty or carrying predictions only; predictions do not count as
        /// user labeling.
        case empty
    }

    /// The labeling ``Kind`` of this frame.
    ///
    /// Resolved in priority order — user instances, then a negative marking, then
    /// empty:
    /// - ``Kind/user`` when ``hasUserInstances`` is `true`.
    /// - ``Kind/negative`` when there are no user instances and
    ///   ``isNegative`` is `true`.
    /// - ``Kind/empty`` otherwise (no user instances and not negative, including
    ///   prediction-only frames).
    public var kind: Kind {
        if hasUserInstances {
            return .user
        }
        if isNegative {
            return .negative
        }
        return .empty
    }

    /// Returns the labeling ``Kind`` of this frame.
    ///
    /// Method form of ``kind`` for call sites that prefer `frame.classify()`.
    public func classify() -> Kind {
        kind
    }
}
