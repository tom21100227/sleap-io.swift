import Foundation

/// A named landmark in a skeleton. Identity type.
public final class Node: Hashable, Sendable {
    public let name: String

    public init(name: String) {
        self.name = name
    }

    public static func == (lhs: Node, rhs: Node) -> Bool {
        lhs === rhs
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(ObjectIdentifier(self))
    }
}
