import Foundation

/// A named landmark in a skeleton. Identity type.
///
/// `name` is mutable to support skeleton node renaming (`Skeleton.renameNode`).
/// Equality/hashing remain identity-based, so a `Node` stays a stable dictionary
/// key across renames. Rename only through `Skeleton` so its name cache stays in sync.
public final class Node: Hashable, @unchecked Sendable {
    public var name: String

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
