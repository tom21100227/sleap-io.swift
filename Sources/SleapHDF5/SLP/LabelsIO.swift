import Foundation
import SleapIO

/// Public API entry points for loading and saving Labels.
/// These are extensions on Labels that delegate to the appropriate format-specific codec.
extension Labels {

    /// Load labels from a file. Format is inferred from extension.
    /// For `.slp` files, this uses lazy loading by default.
    public static func load(from url: URL,
                            format: FileFormat? = nil) async throws -> Labels {
        let resolvedFormat = format ?? inferFormat(from: url)

        switch resolvedFormat {
        case .slp:
            return try await SLPReader.readLazy(from: url.path)
        default:
            throw SleapIOError.unsupportedFormat("Format \(resolvedFormat) is not yet supported")
        }
    }

    /// Load labels eagerly (all frames materialized).
    public static func loadEager(from url: URL,
                                 format: FileFormat? = nil) async throws -> Labels {
        let resolvedFormat = format ?? inferFormat(from: url)

        switch resolvedFormat {
        case .slp:
            return try await SLPReader.read(from: url.path)
        default:
            throw SleapIOError.unsupportedFormat("Format \(resolvedFormat) is not yet supported")
        }
    }

    /// Save labels to a file. Format is inferred from extension.
    public func save(to url: URL,
                     format: FileFormat? = nil,
                     options: SaveOptions = .defaults) async throws {
        let resolvedFormat = format ?? Labels.inferFormat(from: url)

        switch resolvedFormat {
        case .slp:
            try await SLPWriter.write(self, to: url.path)
        default:
            throw SleapIOError.unsupportedFormat("Format \(resolvedFormat) is not yet supported")
        }
    }

    /// Infer file format from URL extension.
    private static func inferFormat(from url: URL) -> FileFormat {
        switch url.pathExtension.lowercased() {
        case "slp":
            return .slp
        case "json":
            return .cocoJSON
        case "csv":
            return .csv
        case "h5", "hdf5":
            return .analysisHDF5
        default:
            return .slp
        }
    }
}
