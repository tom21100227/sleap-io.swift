import Foundation

/// A named directed graph of body part landmarks.
///
/// Identity type — shared by reference across all instances that use it.
/// Conforms to `RandomAccessCollection` over its nodes for convenience.
public final class Skeleton: Hashable, @unchecked Sendable {
    public var name: String
    public private(set) var nodes: [Node]
    public private(set) var edges: [Edge]
    public private(set) var symmetries: [Symmetry]

    // Cached lookups
    private var _nameToNode: [String: Node] = [:]
    private var _nodeToIndex: [ObjectIdentifier: Int] = [:]

    public init(name: String, nodes: [Node] = [], edges: [Edge] = [], symmetries: [Symmetry] = []) {
        self.name = name
        self.nodes = nodes
        self.edges = edges
        self.symmetries = symmetries
        _rebuildCaches()
    }

    // MARK: - Node management

    public func addNode(_ node: Node) {
        guard _nameToNode[node.name] == nil else { return }
        let idx = nodes.count
        nodes.append(node)
        _nameToNode[node.name] = node
        _nodeToIndex[ObjectIdentifier(node)] = idx
    }

    @discardableResult
    public func addNode(named name: String) -> Node {
        if let existing = _nameToNode[name] { return existing }
        let node = Node(name: name)
        addNode(node)
        return node
    }

    public func removeNode(_ node: Node) {
        guard let idx = _nodeToIndex[ObjectIdentifier(node)] else { return }
        nodes.remove(at: idx)
        edges.removeAll { $0.source === node || $0.destination === node }
        symmetries.removeAll { $0.nodeA === node || $0.nodeB === node }
        _rebuildCaches()
    }

    // MARK: - Node migration

    /// Insert a node at a specific index and migrate all instances.
    ///
    /// This is the ordered-insertion counterpart of `addNode(_:migratingInstances:)`.
    /// It is needed for correct undo of middle-node deletion, where the restored
    /// node must go back to its original position (not appended at the end).
    ///
    /// - Parameters:
    ///   - node: The node to insert. If a node with the same name already exists, this is a no-op.
    ///   - index: The position at which to insert (clamped to `0...nodes.count`).
    ///   - instances: All instances referencing this skeleton that should be migrated.
    public func insertNode(_ node: Node, at index: Int, migratingInstances instances: [Instance]) {
        guard _nameToNode[node.name] == nil else { return }

        let clampedIndex = Swift.max(0, Swift.min(index, nodes.count))
        nodes.insert(node, at: clampedIndex)
        _rebuildCaches()

        for instance in instances {
            guard instance.skeleton === self else { continue }

            let coordIdx = clampedIndex * 2
            if let predicted = instance as? PredictedInstance {
                predicted.predictedPoints.points.coordinates.insert(contentsOf: [Float.nan, Float.nan], at: coordIdx)
                predicted.predictedPoints.points.visibility.insert(false, at: clampedIndex)
                predicted.predictedPoints.points.completeness.insert(false, at: clampedIndex)
                predicted.predictedPoints.scores.insert(0, at: clampedIndex)
            } else {
                instance.points.coordinates.insert(contentsOf: [Float.nan, Float.nan], at: coordIdx)
                instance.points.visibility.insert(false, at: clampedIndex)
                instance.points.completeness.insert(false, at: clampedIndex)
            }
        }
    }

    /// Add a node and migrate all instances that reference this skeleton.
    ///
    /// The new node is appended to the skeleton's node list. For each instance,
    /// a new invisible point with NaN coordinates is appended to its `PointsArray`.
    /// For `PredictedInstance` objects, the corresponding score is set to 0.
    ///
    /// - Parameters:
    ///   - node: The node to add. If a node with the same name already exists, this is a no-op.
    ///   - instances: All instances referencing this skeleton that should be migrated.
    public func addNode(_ node: Node, migratingInstances instances: [Instance]) {
        guard _nameToNode[node.name] == nil else { return }

        let idx = nodes.count
        nodes.append(node)
        _nameToNode[node.name] = node
        _nodeToIndex[ObjectIdentifier(node)] = idx

        for instance in instances {
            guard instance.skeleton === self else { continue }

            if let predicted = instance as? PredictedInstance {
                predicted.predictedPoints.points.coordinates.append(Float.nan)
                predicted.predictedPoints.points.coordinates.append(Float.nan)
                predicted.predictedPoints.points.visibility.append(false)
                predicted.predictedPoints.points.completeness.append(false)
                predicted.predictedPoints.scores.append(0)
            } else {
                instance.points.coordinates.append(Float.nan)
                instance.points.coordinates.append(Float.nan)
                instance.points.visibility.append(false)
                instance.points.completeness.append(false)
            }
        }
    }

    /// Remove a node and migrate all instances that reference this skeleton.
    ///
    /// The node is removed from the skeleton's node list, and any edges or symmetries
    /// referencing it are also removed. For each instance, the point at the node's
    /// index is dropped from its `PointsArray`.
    ///
    /// - Parameters:
    ///   - node: The node to remove.
    ///   - instances: All instances referencing this skeleton that should be migrated.
    /// - Throws: ``SleapIOError/invalidSkeleton(_:)`` if the node is not part of this skeleton.
    public func removeNode(_ node: Node, migratingInstances instances: [Instance]) throws {
        guard let idx = _nodeToIndex[ObjectIdentifier(node)] else {
            throw SleapIOError.invalidSkeleton("Node '\(node.name)' not found in skeleton '\(name)'")
        }

        nodes.remove(at: idx)
        edges.removeAll { $0.source === node || $0.destination === node }
        symmetries.removeAll { $0.nodeA === node || $0.nodeB === node }
        _rebuildCaches()

        for instance in instances {
            guard instance.skeleton === self else { continue }

            if let predicted = instance as? PredictedInstance {
                predicted.predictedPoints.points.coordinates.removeSubrange((idx * 2)..<(idx * 2 + 2))
                predicted.predictedPoints.points.visibility.remove(at: idx)
                predicted.predictedPoints.points.completeness.remove(at: idx)
                predicted.predictedPoints.scores.remove(at: idx)
            } else {
                instance.points.coordinates.removeSubrange((idx * 2)..<(idx * 2 + 2))
                instance.points.visibility.remove(at: idx)
                instance.points.completeness.remove(at: idx)
            }
        }
    }

    // MARK: - Node rename / reorder (E3.3)

    /// Rename a single node. Instances are unaffected (points are stored by index;
    /// nodes are shared by reference). Mirrors `Skeleton.rename_node`.
    /// - Throws: ``SleapIOError/invalidSkeleton(_:)`` if `oldName` is absent or
    ///   `newName` already names a different node.
    public func renameNode(_ oldName: String, to newName: String) throws {
        guard let node = _nameToNode[oldName] else {
            throw SleapIOError.invalidSkeleton("Node '\(oldName)' not found in skeleton '\(name)'")
        }
        if newName != oldName, _nameToNode[newName] != nil {
            throw SleapIOError.invalidSkeleton("Node '\(newName)' already exists in skeleton '\(name)'")
        }
        node.name = newName
        _nameToNode[oldName] = nil
        _nameToNode[newName] = node
    }

    /// Rename all nodes in order. The new names must be unique. Allows permutations
    /// and swaps (names are applied, then caches rebuilt). Mirrors the list form of
    /// `Skeleton.rename_nodes`.
    public func renameNodes(_ newNames: [String]) throws {
        guard newNames.count == nodes.count else {
            throw SleapIOError.invalidSkeleton("Expected \(nodes.count) names, got \(newNames.count)")
        }
        guard Set(newNames).count == newNames.count else {
            throw SleapIOError.invalidSkeleton("New node names must be unique")
        }
        for (node, newName) in zip(nodes, newNames) { node.name = newName }
        _rebuildCaches()
    }

    /// Rename nodes via an old-name → new-name map. Applied atomically (set then
    /// rebuild), so swaps are allowed. Mirrors the dict form of `Skeleton.rename_nodes`.
    public func renameNodes(_ nameMap: [String: String]) throws {
        for oldName in nameMap.keys where _nameToNode[oldName] == nil {
            throw SleapIOError.invalidSkeleton("Node '\(oldName)' not found in skeleton '\(name)'")
        }
        let resulting = nodes.map { nameMap[$0.name] ?? $0.name }
        guard Set(resulting).count == resulting.count else {
            throw SleapIOError.invalidSkeleton("Rename would produce duplicate node names")
        }
        for node in nodes { if let newName = nameMap[node.name] { node.name = newName } }
        _rebuildCaches()
    }

    /// Reorder nodes to `newOrder` (a permutation of the current node names) and
    /// permute each migrating instance's points to stay aligned.
    ///
    /// Unlike Python (where points are name-keyed), our points are index-aligned to
    /// node order, so instances must be migrated to preserve alignment — pass every
    /// instance that uses this skeleton.
    public func reorderNodes(_ newOrder: [String], migratingInstances instances: [Instance]) throws {
        guard newOrder.count == nodes.count, Set(newOrder) == Set(nodeNames) else {
            throw SleapIOError.invalidSkeleton("newOrder must be a permutation of the current node names")
        }
        var perm = [Int]()
        perm.reserveCapacity(newOrder.count)
        var newNodes = [Node]()
        for nodeName in newOrder {
            guard let node = _nameToNode[nodeName], let oldIdx = index(of: node) else {
                throw SleapIOError.invalidSkeleton("Node '\(nodeName)' not found in skeleton '\(name)'")
            }
            newNodes.append(node)
            perm.append(oldIdx)
        }
        nodes = newNodes
        _rebuildCaches()

        for instance in instances where instance.skeleton === self {
            if let predicted = instance as? PredictedInstance {
                predicted.predictedPoints = Self.permuted(predicted.predictedPoints, by: perm, skeleton: self)
            } else {
                instance.points = Self.permuted(instance.points, by: perm, skeleton: self)
            }
        }
    }

    private static func permuted(_ points: PointsArray, by perm: [Int], skeleton: Skeleton) -> PointsArray {
        var coords = ContiguousArray<Float>(repeating: .nan, count: perm.count * 2)
        var vis = ContiguousArray<Bool>(repeating: false, count: perm.count)
        var comp = ContiguousArray<Bool>(repeating: false, count: perm.count)
        for newIdx in 0..<perm.count {
            let oldIdx = perm[newIdx]
            coords[newIdx * 2] = points.coordinates[oldIdx * 2]
            coords[newIdx * 2 + 1] = points.coordinates[oldIdx * 2 + 1]
            vis[newIdx] = points.visibility[oldIdx]
            comp[newIdx] = points.completeness[oldIdx]
        }
        var result = PointsArray(coordinates: coords, visibility: vis, completeness: comp)
        result.skeleton = skeleton
        return result
    }

    private static func permuted(_ predicted: PredictedPointsArray, by perm: [Int], skeleton: Skeleton) -> PredictedPointsArray {
        let permutedPoints = permuted(predicted.points, by: perm, skeleton: skeleton)
        var scores = ContiguousArray<Float>(repeating: 0, count: perm.count)
        for newIdx in 0..<perm.count { scores[newIdx] = predicted.scores[perm[newIdx]] }
        return PredictedPointsArray(pointsArray: permutedPoints, scores: scores)
    }

    // MARK: - Edge management

    public func addEdge(from source: Node, to destination: Node) {
        let edge = Edge(source: source, destination: destination)
        guard !edges.contains(edge) else { return }
        edges.append(edge)
    }

    public func removeEdge(_ edge: Edge) {
        edges.removeAll { $0 == edge }
    }

    // MARK: - Symmetry management

    public func addSymmetry(_ a: Node, _ b: Node) {
        let sym = Symmetry(a, b)
        guard !symmetries.contains(sym) else { return }
        symmetries.append(sym)
    }

    public func removeSymmetry(_ symmetry: Symmetry) {
        symmetries.removeAll { $0 == symmetry }
    }

    // MARK: - Lookup

    /// O(1) lookup by name.
    public func node(named name: String) -> Node? {
        _nameToNode[name]
    }

    /// O(1) index of a node.
    public func index(of node: Node) -> Int? {
        _nodeToIndex[ObjectIdentifier(node)]
    }

    /// Whether a node with the given name exists. Mirrors Python `name in skeleton`.
    public func contains(nodeNamed name: String) -> Bool {
        _nameToNode[name] != nil
    }

    // MARK: - Derived accessors
    //
    // These mirror the read-only views Python `Skeleton` exposes and are used
    // throughout rendering, matching, and tensor export. Edges/symmetries whose
    // endpoints are not part of this skeleton are skipped rather than crashing.

    /// Node names in order. Mirrors `Skeleton.node_names`.
    public var nodeNames: [String] {
        nodes.map(\.name)
    }

    /// Edges as `(sourceIndex, destinationIndex)` pairs. Mirrors `Skeleton.edge_inds`.
    public var edgeInds: [(Int, Int)] {
        edges.compactMap { edge in
            guard let s = index(of: edge.source),
                  let d = index(of: edge.destination) else { return nil }
            return (s, d)
        }
    }

    /// Edges as `(sourceName, destinationName)` pairs. Mirrors `Skeleton.edge_names`.
    public var edgeNames: [(String, String)] {
        edges.map { ($0.source.name, $0.destination.name) }
    }

    /// Symmetries as sorted `(indexA, indexB)` pairs. Mirrors `Skeleton.symmetry_inds`.
    public var symmetryInds: [(Int, Int)] {
        symmetries.compactMap { sym in
            guard let a = index(of: sym.nodeA),
                  let b = index(of: sym.nodeB) else { return nil }
            return a <= b ? (a, b) : (b, a)
        }
    }

    /// Symmetries as `(nameA, nameB)` pairs, ordered to match ``symmetryInds``.
    /// Mirrors `Skeleton.symmetry_names`.
    public var symmetryNames: [(String, String)] {
        symmetryInds.map { (nodes[$0.0].name, nodes[$0.1].name) }
    }

    // MARK: - Identity equality

    public static func == (lhs: Skeleton, rhs: Skeleton) -> Bool {
        lhs === rhs
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(ObjectIdentifier(self))
    }

    // MARK: - Private

    private func _rebuildCaches() {
        _nameToNode.removeAll(keepingCapacity: true)
        _nodeToIndex.removeAll(keepingCapacity: true)
        for (i, node) in nodes.enumerated() {
            _nameToNode[node.name] = node
            _nodeToIndex[ObjectIdentifier(node)] = i
        }
    }
}

// MARK: - RandomAccessCollection

extension Skeleton: RandomAccessCollection {
    public typealias Element = Node
    public typealias Index = Int

    public var startIndex: Int { 0 }
    public var endIndex: Int { nodes.count }

    public subscript(position: Int) -> Node {
        nodes[position]
    }
}
