import Foundation

/// Errors from I/O and mutation operations.
public enum SleapIOError: Error, Sendable {
    case fileNotFound(String)
    case unsupportedFormat(String)
    case corruptData(String)
    case hdf5Error(String)
    case videoError(String)
    case invalidSkeleton(String)
    case formatVersionTooNew(Float)
    case mutationWhileLazy(String)
}

/// Supported file formats.
public enum FileFormat: Sendable {
    case slp
    case cocoJSON
    case csv
    case labelStudio
    case yolo
    case alphaTracker
    case analysisHDF5
    case jabs
    case deepLabCut
}

/// Options controlling save behavior.
public struct SaveOptions: Sendable {
    /// Convenience cross-module embed switch.
    ///
    /// `SaveOptions` lives in `SleapIO`, which cannot reference `SleapHDF5`'s
    /// richer `EmbedSelection` (that would be a circular module dependency). So the
    /// full embed selection is expressed via the `embed:` parameter on
    /// `Labels.save(to:format:options:embed:progress:)`; this bool is the layer-safe
    /// shorthand it maps to: when the caller leaves `embed` at `.none`,
    /// `embedFrames == true` is treated as `EmbedSelection.all` (Python's
    /// `embed=True`). An explicit `embed:` argument always takes precedence.
    public var embedFrames: Bool
    public var compressionLevel: Float
    /// Image format used to re-encode embedded frames (forwarded to the SLP
    /// writer's `imageFormat`). Only consulted when frames are actually embedded.
    public var embeddedImageFormat: EmbeddedImageFormat

    public static let defaults = SaveOptions(
        embedFrames: false,
        compressionLevel: 0.8,
        embeddedImageFormat: .jpeg(quality: 0.95)
    )

    public enum EmbeddedImageFormat: Sendable {
        case png
        case jpeg(quality: Float)
    }

    public init(embedFrames: Bool = false,
                compressionLevel: Float = 0.8,
                embeddedImageFormat: EmbeddedImageFormat = .jpeg(quality: 0.95)) {
        self.embedFrames = embedFrames
        self.compressionLevel = compressionLevel
        self.embeddedImageFormat = embeddedImageFormat
    }
}
