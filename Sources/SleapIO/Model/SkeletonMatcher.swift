import Foundation

/// Strategy used by ``SkeletonMatcher`` to decide when two skeletons should be
/// considered equivalent.
///
/// Mirrors Python `sleap_io.model.matching.SkeletonMatchMethod`. The raw string
/// values match the Python enum values (`"exact"`, `"structure"`, `"overlap"`,
/// `"subset"`), so a method can be round-tripped through configuration data.
public enum SkeletonMatchMethod: String, Sendable, CaseIterable, Codable {
    /// Exact match: same node names in the same order, with the same edges and
    /// symmetries.
    case exact

    /// Structural match: same node names, edges, and symmetries, but node order
    /// does not matter (unless ``SkeletonMatcher/requireSameOrder`` is set).
    case structure

    /// Partial match based on how much the node-name sets overlap, measured by
    /// Jaccard similarity and compared against ``SkeletonMatcher/minOverlap``.
    case overlap

    /// Subset match: the first skeleton's node names are a subset of the
    /// second skeleton's node names. Directional — order of arguments matters.
    case subset
}

/// Configurable predicate for comparing two ``Skeleton`` values during merge and
/// proofreading operations.
///
/// Mirrors Python `sleap_io.model.matching.SkeletonMatcher`. The comparison is
/// driven by ``method``; ``requireSameOrder`` and ``minOverlap`` tune the
/// `structure` and `overlap` strategies respectively and are ignored by the
/// others.
///
/// The `exact` and `structure` strategies build on ``Skeleton/matches(_:requireSameOrder:)``
/// for node-name comparison and additionally require the edge sets (directed,
/// by node name) and symmetry sets (unordered node-name pairs) to be equal —
/// matching Python's `Skeleton.matches` semantics.
public struct SkeletonMatcher: Sendable, Equatable {
    /// The matching strategy to apply. Defaults to ``SkeletonMatchMethod/structure``.
    public var method: SkeletonMatchMethod

    /// Whether `structure` matching also requires the nodes to appear in the
    /// same order. Ignored for every method other than
    /// ``SkeletonMatchMethod/structure``. Defaults to `false`.
    public var requireSameOrder: Bool

    /// Minimum Jaccard similarity of the node-name sets required for
    /// ``SkeletonMatchMethod/overlap`` matching. Ignored for every other method.
    /// Defaults to `0.5`.
    public var minOverlap: Double

    /// Create a matcher.
    ///
    /// - Parameters:
    ///   - method: The matching strategy. Defaults to ``SkeletonMatchMethod/structure``.
    ///   - requireSameOrder: Enforce node order for `structure` matching.
    ///     Defaults to `false`.
    ///   - minOverlap: Jaccard threshold for `overlap` matching. Defaults to `0.5`.
    public init(
        method: SkeletonMatchMethod = .structure,
        requireSameOrder: Bool = false,
        minOverlap: Double = 0.5
    ) {
        self.method = method
        self.requireSameOrder = requireSameOrder
        self.minOverlap = minOverlap
    }

    /// Whether the two skeletons match under the configured ``method``.
    ///
    /// - `exact`: same node names in the same order, plus equal edge and
    ///   symmetry sets.
    /// - `structure`: same node names (order controlled by ``requireSameOrder``),
    ///   plus equal edge and symmetry sets.
    /// - `overlap`: node-name Jaccard similarity `>=` ``minOverlap``.
    /// - `subset`: `skeleton1`'s node names are a subset of `skeleton2`'s node
    ///   names (directional).
    ///
    /// - Parameters:
    ///   - skeleton1: The first skeleton. For `subset`, this is the candidate subset.
    ///   - skeleton2: The second skeleton. For `subset`, this is the candidate superset.
    /// - Returns: `true` if the skeletons match under ``method``.
    public func match(_ skeleton1: Skeleton, _ skeleton2: Skeleton) -> Bool {
        switch method {
        case .exact:
            return structurallyMatches(skeleton1, skeleton2, requireSameOrder: true)
        case .structure:
            return structurallyMatches(skeleton1, skeleton2, requireSameOrder: requireSameOrder)
        case .overlap:
            return skeleton1.nodeSimilarity(skeleton2) >= minOverlap
        case .subset:
            let nodes1 = Set(skeleton1.nodeNames)
            let nodes2 = Set(skeleton2.nodeNames)
            return nodes1.isSubset(of: nodes2)
        }
    }

    /// Alias for ``match(_:_:)``. Provided so call sites can read naturally as
    /// `matcher.matches(a, b)`.
    public func matches(_ skeleton1: Skeleton, _ skeleton2: Skeleton) -> Bool {
        match(skeleton1, skeleton2)
    }

    // MARK: - Private

    /// Node-name (optionally ordered), edge, and symmetry equality — the shared
    /// core of `exact` and `structure`. Mirrors Python `Skeleton.matches`.
    private func structurallyMatches(
        _ skeleton1: Skeleton,
        _ skeleton2: Skeleton,
        requireSameOrder: Bool
    ) -> Bool {
        guard skeleton1.matches(skeleton2, requireSameOrder: requireSameOrder) else {
            return false
        }
        guard edgeKeySet(skeleton1) == edgeKeySet(skeleton2) else { return false }
        return symmetryKeySet(skeleton1) == symmetryKeySet(skeleton2)
    }

    /// Directed edges as a set of `[source, destination]` name pairs.
    private func edgeKeySet(_ skeleton: Skeleton) -> Set<[String]> {
        Set(skeleton.edgeNames.map { [$0.0, $0.1] })
    }

    /// Symmetries as a set of unordered `{a, b}` name pairs.
    private func symmetryKeySet(_ skeleton: Skeleton) -> Set<Set<String>> {
        Set(skeleton.symmetryNames.map { Set([$0.0, $0.1]) })
    }
}
