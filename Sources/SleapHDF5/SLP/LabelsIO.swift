import Foundation
import SleapIO

/// Public API entry points for loading and saving Labels.
/// These are extensions on Labels that delegate to the appropriate format-specific codec.
extension Labels {

    /// Load labels from a file. Format is inferred from extension.
    /// For `.slp` files, this uses lazy loading by default.
    public static func load(from url: URL,
                            format: FileFormat? = nil) async throws -> Labels {
        let resolvedFormat = try format ?? inferLoadFormat(from: url)

        switch resolvedFormat {
        case .slp:
            return try await SLPReader.readLazy(from: url.path)
        case .cocoJSON:
            return try COCOCodec.read(from: url.path)
        case .csv:
            return try CSVCodec.read(from: url.path)
        case .alphaTracker:
            return try AlphaTrackerCodec.read(from: url.path)
        case .labelStudio:
            throw SleapIOError.unsupportedFormat(
                "Label Studio import requires an explicit skeleton mapping. Use LabelStudioCodec.read(from:mapping:).")
        case .yolo:
            throw SleapIOError.unsupportedFormat(
                "YOLO import requires an explicit config. Use YOLOCodec.read(from:config:).")
        case .analysisHDF5:
            throw SleapIOError.unsupportedFormat("Analysis HDF5 is planned for Phase 4")
        }
    }

    /// Load labels eagerly (all frames materialized).
    public static func loadEager(from url: URL,
                                 format: FileFormat? = nil) async throws -> Labels {
        let resolvedFormat = try format ?? inferLoadFormat(from: url)

        switch resolvedFormat {
        case .slp:
            return try await SLPReader.read(from: url.path)
        case .cocoJSON:
            return try COCOCodec.read(from: url.path)
        case .csv:
            return try CSVCodec.read(from: url.path)
        case .alphaTracker:
            return try AlphaTrackerCodec.read(from: url.path)
        case .labelStudio:
            throw SleapIOError.unsupportedFormat(
                "Label Studio import requires an explicit skeleton mapping. Use LabelStudioCodec.read(from:mapping:).")
        case .yolo:
            throw SleapIOError.unsupportedFormat(
                "YOLO import requires an explicit config. Use YOLOCodec.read(from:config:).")
        case .analysisHDF5:
            throw SleapIOError.unsupportedFormat("Analysis HDF5 is planned for Phase 4")
        }
    }

    /// Save labels to a file. Format is inferred from extension.
    public func save(to url: URL,
                     format: FileFormat? = nil,
                     options: SaveOptions = .defaults) async throws {
        let resolvedFormat = try format ?? Labels.inferSaveFormat(from: url)

        switch resolvedFormat {
        case .slp:
            try await SLPWriter.write(self, to: url.path)
        case .cocoJSON:
            try COCOCodec.write(self, to: url.path)
        case .csv:
            try CSVCodec.write(self, to: url.path)
        case .labelStudio:
            throw SleapIOError.unsupportedFormat(
                "Label Studio export requires an explicit skeleton mapping. Use LabelStudioCodec.write(_:to:mapping:).")
        case .yolo:
            throw SleapIOError.unsupportedFormat(
                "YOLO export requires an explicit config. Use YOLOCodec.write(_:to:config:).")
        case .alphaTracker:
            throw SleapIOError.unsupportedFormat("AlphaTracker export is not supported")
        case .analysisHDF5:
            throw SleapIOError.unsupportedFormat("Analysis HDF5 is planned for Phase 4")
        }
    }

    /// Infer input format from a URL.
    private static func inferLoadFormat(from url: URL) throws -> FileFormat {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw SleapIOError.fileNotFound("File not found: \(url.path)")
        }

        if isDirectory.boolValue {
            let datasetYAML = url.appendingPathComponent("dataset.yaml")
            if FileManager.default.fileExists(atPath: datasetYAML.path) {
                return .yolo
            }
            throw SleapIOError.unsupportedFormat(
                "Unsupported directory layout at \(url.path)")
        }

        switch url.pathExtension.lowercased() {
        case "slp":
            return .slp
        case "csv":
            return .csv
        case "json":
            return try sniffJSONFormat(from: url)
        case "h5", "hdf5":
            return .analysisHDF5
        default:
            throw SleapIOError.unsupportedFormat(
                "Unsupported file extension '\(url.pathExtension)' at \(url.path)")
        }
    }

    /// Infer output format from URL extension.
    private static func inferSaveFormat(from url: URL) throws -> FileFormat {
        switch url.pathExtension.lowercased() {
        case "slp":
            return .slp
        case "csv":
            return .csv
        case "json":
            return .cocoJSON
        case "h5", "hdf5":
            return .analysisHDF5
        default:
            throw SleapIOError.unsupportedFormat(
                "Unsupported output extension '\(url.pathExtension)' at \(url.path)")
        }
    }

    /// Detect the supported JSON schema for load dispatch.
    private static func sniffJSONFormat(from url: URL) throws -> FileFormat {
        let jsonObject = try readJSON(from: url)

        if let root = jsonObject as? [String: Any] {
            if root["images"] != nil || root["annotations"] != nil || root["categories"] != nil {
                return .cocoJSON
            }
        } else if let root = jsonObject as? [Any] {
            guard let first = root.first as? [String: Any] else {
                throw SleapIOError.unsupportedFormat(
                    "Unsupported empty or non-object JSON array in \(url.path)")
            }

            if first["image_path"] != nil, first["keypoints"] != nil, first["animal_id"] != nil {
                return .alphaTracker
            }

            let hasTaskData = (first["data"] as? [String: Any])?["image"] is String
            let hasResults = first["annotations"] != nil || first["predictions"] != nil
            if hasTaskData || hasResults {
                return .labelStudio
            }
        }

        throw SleapIOError.unsupportedFormat(
            "Unsupported JSON schema in \(url.path)")
    }

    private static func readJSON(from url: URL) throws -> Any {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw SleapIOError.fileNotFound("File not found: \(url.path)")
        }

        do {
            return try JSONSerialization.jsonObject(with: data)
        } catch {
            throw SleapIOError.corruptData("Malformed JSON in \(url.path): \(error.localizedDescription)")
        }
    }
}
