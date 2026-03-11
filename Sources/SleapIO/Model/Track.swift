import Foundation

/// An identity label for linking instances across frames.
public final class Track: Hashable, @unchecked Sendable {
    public var name: String

    public init(name: String) {
        self.name = name
    }

    public static func == (lhs: Track, rhs: Track) -> Bool {
        lhs === rhs
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(ObjectIdentifier(self))
    }
}
