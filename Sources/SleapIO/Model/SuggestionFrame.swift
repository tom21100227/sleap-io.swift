import Foundation

/// A suggested frame for labeling.
public struct SuggestionFrame: Hashable, Sendable {
    public var video: Video
    public var frameIndex: Int
    public var group: String?

    public init(video: Video, frameIndex: Int, group: String? = nil) {
        self.video = video
        self.frameIndex = frameIndex
        self.group = group
    }

    public static func == (lhs: SuggestionFrame, rhs: SuggestionFrame) -> Bool {
        lhs.video === rhs.video && lhs.frameIndex == rhs.frameIndex && lhs.group == rhs.group
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(ObjectIdentifier(video))
        hasher.combine(frameIndex)
        hasher.combine(group)
    }
}
