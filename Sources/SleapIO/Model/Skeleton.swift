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
