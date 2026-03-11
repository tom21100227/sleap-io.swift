import Foundation

/// A symmetry relationship between two nodes (e.g., left_eye <-> right_eye).
public struct Symmetry: Hashable, Sendable {
    public var nodeA: Node
    public var nodeB: Node

    public init(_ a: Node, _ b: Node) {
        self.nodeA = a
        self.nodeB = b
    }

    public static func == (lhs: Symmetry, rhs: Symmetry) -> Bool {
        (lhs.nodeA === rhs.nodeA && lhs.nodeB === rhs.nodeB) ||
        (lhs.nodeA === rhs.nodeB && lhs.nodeB === rhs.nodeA)
    }

    public func hash(into hasher: inout Hasher) {
        // Order-independent hash: sort by ObjectIdentifier
        let idA = ObjectIdentifier(nodeA)
        let idB = ObjectIdentifier(nodeB)
        if idA < idB {
            hasher.combine(idA)
            hasher.combine(idB)
        } else {
            hasher.combine(idB)
            hasher.combine(idA)
        }
    }
}
