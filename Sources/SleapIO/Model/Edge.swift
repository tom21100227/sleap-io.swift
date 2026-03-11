import Foundation

/// A directed connection between two nodes.
public struct Edge: Hashable, Sendable {
    public var source: Node
    public var destination: Node

    public init(source: Node, destination: Node) {
        self.source = source
        self.destination = destination
    }
}
