import Foundation
import CoreGraphics

/// A video source providing frame images.
public final class Video: Hashable, @unchecked Sendable {
    /// Path or URL to the video file (or image directory).
    public let filename: String

    /// Number of frames, or nil if unknown until opened.
    public var frameCount: Int?

    /// Frame dimensions (height, width, channels), or nil if unknown.
    public var frameSize: (height: Int, width: Int, channels: Int)?

    /// The original source video, if this is a derived/embedded copy.
    public var sourceVideo: Video?

    /// Backend type identifier (e.g., "media", "hdf5", "imageSequence").
    public var backendType: String

    /// Backend metadata dictionary for serialization.
    public var backendMetadata: [String: Any]

    public init(filename: String,
                backendType: String = "media",
                backendMetadata: [String: Any] = [:]) {
        self.filename = filename
        self.backendType = backendType
        self.backendMetadata = backendMetadata
    }

    // MARK: - Identity equality

    public static func == (lhs: Video, rhs: Video) -> Bool {
        lhs === rhs
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(ObjectIdentifier(self))
    }
}
