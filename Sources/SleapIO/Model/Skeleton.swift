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
