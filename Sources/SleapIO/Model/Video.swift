import Foundation
import CoreGraphics

/// A video source providing frame images.
public final class Video: Hashable, @unchecked Sendable {
    /// Original imported or decoded source path.
    public let originalFilename: String

    /// Optional persisted override path that is written back on save.
    /// Used for permanent relocation without discarding provenance.
    public var persistedFilename: String?

    /// Effective active path used for open/save/export behavior.
    /// Resolves to `persistedFilename ?? originalFilename`.
    public var filename: String {
        persistedFilename ?? originalFilename
    }

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
        self.originalFilename = filename
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
