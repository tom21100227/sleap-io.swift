import Foundation
import SleapIO

/// Public API entry points for loading and saving Labels.
/// These are extensions on Labels that delegate to the appropriate format-specific codec.
extension Labels {

    /// Load labels from a file. Format is inferred from extension.
    /// For `.slp` files, this uses lazy loading by default.
    /// `errorMode` is reserved for recoverable load paths; SLP lazy loading
    /// currently has no recoverable errors to collect.
    public static func load(from url: URL,
                            format: FileFormat? = nil,
                            errorMode: ErrorMode = .ignore) async throws -> Labels {
        let resolvedFormat = try format ?? inferLoadFormat(from: url)
        _ = errorMode

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
            return try AnalysisHDF5Codec.read(from: url.path)
        case .jabs:
            throw SleapIOError.unsupportedFormat(
                "JABS import requires node names configuration. Use JABSCodec.read(from:config:).")
        case .deepLabCut:
            return try DLCCodec.read(from: url.path)
        }
    }

    /// Load labels eagerly (all frames materialized).
    /// `errorMode` is reserved for recoverable load paths; eager SLP loading
    /// currently has no recoverable errors to collect.
    public static func loadEager(from url: URL,
                                 format: FileFormat? = nil,
                                 errorMode: ErrorMode = .ignore,
                                 progress: ProgressReporter? = nil) async throws -> Labels {
        let resolvedFormat = try format ?? inferLoadFormat(from: url)
        _ = errorMode

        switch resolvedFormat {
        case .slp:
            return try await SLPReader.read(from: url.path, progress: progress)
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
            return try AnalysisHDF5Codec.read(from: url.path)
        case .jabs:
            throw SleapIOError.unsupportedFormat(
                "JABS import requires node names configuration. Use JABSCodec.read(from:config:).")
        case .deepLabCut:
            return try DLCCodec.read(from: url.path)
        }
    }

    /// Save labels to a file. Format is inferred from extension.
    public func save(to url: URL,
                     format: FileFormat? = nil,
                     options: SaveOptions = .defaults,
                     progress: ProgressReporter? = nil) async throws {
        let resolvedFormat = try format ?? Labels.inferSaveFormat(from: url)

        switch resolvedFormat {
        case .slp:
            stampSleapIOVersion()
            try await SLPWriter.write(self, to: url.path, progress: progress)
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
            try AnalysisHDF5Codec.write(self, to: url.path)
        case .jabs:
            throw SleapIOError.unsupportedFormat(
                "JABS export requires node names configuration. Use JABSCodec.write(_:to:config:).")
        case .deepLabCut:
            throw SleapIOError.unsupportedFormat(
                "DeepLabCut format is read-only. Export to DLC HDF5 is not supported.")
        }
    }

    /// Infer input format from a URL.
    public static func inferLoadFormat(from url: URL) throws -> FileFormat {
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
            return try sniffHDF5Format(from: url)
        default:
            throw SleapIOError.unsupportedFormat(
                "Unsupported file extension '\(url.pathExtension)' at \(url.path)")
        }
    }

    /// Infer output format from URL extension.
    public static func inferSaveFormat(from url: URL) throws -> FileFormat {
        switch url.pathExtension.lowercased() {
        case "slp":
            return .slp
        case "csv":
            return .csv
        case "json":
            return .cocoJSON
        case "h5", "hdf5":
            throw SleapIOError.unsupportedFormat(
                "Ambiguous .h5 output format. Use --output-format to specify one of: analysis_h5, jabs, dlc")
        default:
            throw SleapIOError.unsupportedFormat(
                "Unsupported output extension '\(url.pathExtension)' at \(url.path)")
        }
    }

    /// Sniff an HDF5 file to determine its schema format.
    ///
    /// Checks for known markers in priority order:
    /// 1. Analysis HDF5: `node_names` + `locations` datasets
    /// 2. JABS: `poseest` group
    /// 3. DeepLabCut: `df_with_missing` group
    static func sniffHDF5Format(from url: URL) throws -> FileFormat {
        let file: HDF5File
        do {
            file = try HDF5File.openReadOnly(path: url.path)
        } catch {
            if !FileManager.default.fileExists(atPath: url.path) {
                throw SleapIOError.fileNotFound("File not found: \(url.path)")
            }
            throw SleapIOError.corruptData("Cannot open HDF5 file: \(url.path)")
        }

        // Check for Analysis HDF5 markers
        if file.exists(name: "node_names") && file.exists(name: "locations") {
            return .analysisHDF5
        }

        // Check for JABS markers
        if file.exists(name: "poseest") {
            return .jabs
        }

        // Check for DLC markers
        if file.exists(name: "df_with_missing") {
            return .deepLabCut
        }

        throw SleapIOError.unsupportedFormat(
            "Unrecognized HDF5 schema in \(url.path). Expected analysis HDF5 (node_names + locations), JABS (poseest), or DLC (df_with_missing).")
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
