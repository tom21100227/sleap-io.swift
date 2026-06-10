import Foundation

/// Flip / require / match helpers for ``Skeleton``.
///
/// These mirror the Python sleap-io API:
/// `Skeleton.get_flipped_node_inds`, `require_node`, `match_nodes`,
/// `matches`, and `node_similarities`. They are used for left/right
/// augmentation flips and for migrating points between differently
/// ordered skeletons.
extension Skeleton {

    /// Node indices after applying all symmetry flips.
    ///
    /// Starts from the identity permutation `[0, 1, ..., count-1]` and, for
    /// each symmetry pair `(a, b)`, swaps the entries at `a`'s and `b`'s
    /// indices. Non-symmetric nodes keep their original index.
    ///
    /// Example: nodes `A, B_left, B_right, C` with symmetry
    /// `(B_left, B_right)` yields `[0, 2, 1, 3]`.
    public func getFlippedNodeInds() -> [Int] {
        var flipped = Array(0..<nodes.count)
        for symmetry in symmetries {
            guard
                let ia = index(of: symmetry.nodeA),
                let ib = index(of: symmetry.nodeB)
            else { continue }
            flipped.swapAt(ia, ib)
        }
        return flipped
    }

    /// Return the node with the given name, optionally adding it if absent.
    ///
    /// - Parameters:
    ///   - name: The node name to look up.
    ///   - addMissing: When `true` (default) and no node with `name` exists,
    ///     a new node is appended via ``addNode(named:)`` and returned. When
    ///     `false`, a missing node yields `nil`.
    /// - Returns: The existing or newly added node, or `nil` if the node is
    ///   absent and `addMissing` is `false`.
    @discardableResult
    public func requireNode(_ name: String, addMissing: Bool = true) -> Node? {
        if let existing = node(named: name) {
            return existing
        }
        guard addMissing else { return nil }
        return addNode(named: name)
    }

    /// Map names that exist in this skeleton to index pairs.
    ///
    /// For each entry in `names` whose name exists in this skeleton:
    /// - `newInds` receives this skeleton's index of that name.
    /// - `oldInds` receives the position of that name within `names`.
    ///
    /// Names not present in this skeleton are skipped. This is used to
    /// migrate per-node point data when reordering or merging skeletons.
    ///
    /// - Parameter names: The source ordering of node names.
    /// - Returns: Parallel arrays of `(newInds, oldInds)`.
    public func matchNodes(_ names: [String]) -> (newInds: [Int], oldInds: [Int]) {
        var newInds: [Int] = []
        var oldInds: [Int] = []
        for (oldIndex, name) in names.enumerated() {
            guard let node = node(named: name), let newIndex = index(of: node) else { continue }
            newInds.append(newIndex)
            oldInds.append(oldIndex)
        }
        return (newInds, oldInds)
    }

    /// Whether two skeletons share the same set of node names.
    ///
    /// - Parameters:
    ///   - other: The skeleton to compare against.
    ///   - requireSameOrder: When `true`, the node names must also appear in
    ///     the same order. Defaults to `false` (set equality only).
    /// - Returns: `true` if the skeletons match under the given constraint.
    public func matches(_ other: Skeleton, requireSameOrder: Bool = false) -> Bool {
        let selfNames = nodes.map { $0.name }
        let otherNames = other.nodes.map { $0.name }
        if requireSameOrder {
            return selfNames == otherNames
        }
        return Set(selfNames) == Set(otherNames)
    }

    /// Jaccard similarity of the two skeletons' node-name sets.
    ///
    /// Computed as `|intersection| / |union|`: `1.0` for identical name
    /// sets, `0.0` for disjoint sets. An empty union (both skeletons have no
    /// nodes) is defined as `0.0` to avoid division by zero.
    ///
    /// - Parameter other: The skeleton to compare against.
    /// - Returns: A similarity score in `[0, 1]`.
    public func nodeSimilarity(_ other: Skeleton) -> Double {
        let selfNames = Set(nodes.map { $0.name })
        let otherNames = Set(other.nodes.map { $0.name })
        let unionCount = selfNames.union(otherNames).count
        guard unionCount > 0 else { return 0.0 }
        let intersectionCount = selfNames.intersection(otherNames).count
        return Double(intersectionCount) / Double(unionCount)
    }
}
