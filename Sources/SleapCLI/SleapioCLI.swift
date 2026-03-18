import ArgumentParser
import Foundation
import SleapIO
import SleapHDF5

@main
struct SleapioCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "sleap-io",
        abstract: "SLEAP pose data inspection and conversion tool",
        subcommands: [InfoCommand.self, ShowCommand.self, ConvertCommand.self]
    )

    /// When invoked without a subcommand, print usage info and exit with error.
    mutating func run() async throws {
        throw ValidationError("A subcommand is required. See 'sleap-io --help' for usage.")
    }
}

// MARK: - Format string parsing

/// Map CLI format string to FileFormat enum.
private func parseFormatString(_ str: String) throws -> FileFormat {
    switch str.lowercased() {
    case "slp":
        return .slp
    case "coco", "coco_json":
        return .cocoJSON
    case "csv":
        return .csv
    case "labelstudio", "label_studio":
        return .labelStudio
    case "yolo":
        return .yolo
    case "alphatracker", "alpha_tracker":
        return .alphaTracker
    case "analysis_h5", "analysis_hdf5", "analysishdf5":
        return .analysisHDF5
    case "jabs":
        return .jabs
    case "dlc", "deeplabcut":
        return .deepLabCut
    default:
        throw SleapIOError.unsupportedFormat(
            "Unknown format '\(str)'. Supported: slp, coco, csv, labelstudio, yolo, alphatracker, analysis_h5, jabs, dlc")
    }
}

/// Human-readable format name.
private func formatDisplayName(_ format: FileFormat) -> String {
    switch format {
    case .slp: return "SLP"
    case .cocoJSON: return "COCO JSON"
    case .csv: return "CSV"
    case .labelStudio: return "Label Studio"
    case .yolo: return "YOLO"
    case .alphaTracker: return "AlphaTracker"
    case .analysisHDF5: return "Analysis HDF5"
    case .jabs: return "JABS"
    case .deepLabCut: return "DeepLabCut"
    }
}

/// Machine-readable format key for JSON output.
private func formatKey(_ format: FileFormat) -> String {
    switch format {
    case .slp: return "slp"
    case .cocoJSON: return "coco"
    case .csv: return "csv"
    case .labelStudio: return "labelstudio"
    case .yolo: return "yolo"
    case .alphaTracker: return "alphatracker"
    case .analysisHDF5: return "analysis_h5"
    case .jabs: return "jabs"
    case .deepLabCut: return "dlc"
    }
}

// MARK: - Loading

/// Load labels from a file path. Dispatches to the appropriate codec.
private func loadLabels(from path: String, format: String?) async throws -> (Labels, FileFormat) {
    let url = URL(fileURLWithPath: path)

    let resolvedFormat: FileFormat
    if let fmt = format {
        resolvedFormat = try parseFormatString(fmt)
    } else {
        resolvedFormat = try Labels.inferLoadFormat(from: url)
    }

    let labels: Labels
    switch resolvedFormat {
    case .slp:
        labels = try await SLPReader.read(from: path)
    case .cocoJSON:
        labels = try COCOCodec.read(from: path)
    case .csv:
        labels = try CSVCodec.read(from: path)
    case .alphaTracker:
        labels = try AlphaTrackerCodec.read(from: path)
    case .labelStudio:
        throw SleapIOError.unsupportedFormat(
            "Label Studio import requires an explicit skeleton mapping. Use --labelstudio-mapping with convert.")
    case .yolo:
        throw SleapIOError.unsupportedFormat(
            "YOLO import requires an explicit config. Use --yolo-node-order with convert.")
    case .analysisHDF5:
        labels = try AnalysisHDF5Codec.read(from: path)
    case .jabs:
        throw SleapIOError.unsupportedFormat(
            "JABS import requires node names configuration. Use --jabs-node-names with convert.")
    case .deepLabCut:
        labels = try DLCCodec.read(from: path)
    }

    return (labels, resolvedFormat)
}

/// Save labels to a file path.
///
/// - Parameters:
///   - labels: The labels to save.
///   - path: Output file path.
///   - format: Target format.
///   - jabsNodeNames: Optional JABS node names config path. Required for JABS output.
private func saveLabels(_ labels: Labels, to path: String, format: FileFormat,
                        jabsNodeNames: String? = nil) async throws {
    switch format {
    case .slp:
        try await SLPWriter.write(labels, to: path)
    case .cocoJSON:
        try COCOCodec.write(labels, to: path)
    case .csv:
        try CSVCodec.write(labels, to: path)
    case .labelStudio:
        throw SleapIOError.unsupportedFormat(
            "Label Studio export requires an explicit skeleton mapping.")
    case .yolo:
        throw SleapIOError.unsupportedFormat(
            "YOLO export requires an explicit config.")
    case .alphaTracker:
        throw SleapIOError.unsupportedFormat(
            "AlphaTracker export is not supported.")
    case .analysisHDF5:
        try AnalysisHDF5Codec.write(labels, to: path)
    case .jabs:
        if let nodeNamesPath = jabsNodeNames {
            let nodeNamesData = try Data(contentsOf: URL(fileURLWithPath: nodeNamesPath))
            guard let names = try JSONSerialization.jsonObject(with: nodeNamesData) as? [String] else {
                throw SleapIOError.unsupportedFormat(
                    "JABS node names file must be a JSON array of strings.")
            }
            try JABSCodec.write(labels, to: path, config: JABSCodec.Config(nodeNames: names))
        } else {
            try JABSCodec.write(labels, to: path)
        }
    case .deepLabCut:
        throw SleapIOError.unsupportedFormat(
            "DeepLabCut format is read-only.")
    }
}

// MARK: - InfoCommand

struct InfoCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "info",
        abstract: "Print dataset summary"
    )

    @Argument(help: "Input file path")
    var input: String

    @Option(name: .long, help: "Input format override")
    var inputFormat: String?

    @Flag(name: .long, help: "Output as JSON")
    var json: Bool = false

    func run() async throws {
        let (labels, detectedFormat) = try await withErrorHandling {
            try await loadLabels(from: input, format: inputFormat)
        }

        let frameCount = labels.frameCount
        let videoCount = labels.videos.count
        let skeletonCount = labels.skeletons.count
        let trackCount = labels.tracks.count
        let instanceCount = labels.instanceCount
        let predictedCount = labels.predictedInstanceCount
        let userCount = instanceCount - predictedCount

        if json {
            let obj: [String: Any] = [
                "format": formatKey(detectedFormat),
                "path": input,
                "frames": frameCount,
                "videos": videoCount,
                "skeletons": skeletonCount,
                "tracks": trackCount,
                "instances": instanceCount,
                "user_instances": userCount,
                "predicted_instances": predictedCount,
            ]
            let data = try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys])
            if let str = String(data: data, encoding: .utf8) {
                print(str)
            }
        } else {
            print("Format:               \(formatDisplayName(detectedFormat))")
            print("Path:                 \(input)")
            print("Frames:               \(frameCount)")
            print("Videos:               \(videoCount)")
            print("Skeletons:            \(skeletonCount)")
            print("Tracks:               \(trackCount)")
            print("Instances:            \(instanceCount)")
            print("  User:               \(userCount)")
            print("  Predicted:          \(predictedCount)")
        }
    }
}

// MARK: - ShowCommand

struct ShowCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "show",
        abstract: "Show frame-level detail"
    )

    @Argument(help: "Input file path")
    var input: String

    @Option(name: .long, help: "Input format override")
    var inputFormat: String?

    @Option(name: .long, help: "Show specific frame index")
    var frame: Int?

    @Option(name: .long, help: "Limit number of frames shown (default: 5)")
    var limit: Int?

    @Flag(name: .long, help: "Output as JSON")
    var json: Bool = false

    func run() async throws {
        let (labels, _) = try await withErrorHandling {
            try await loadLabels(from: input, format: inputFormat)
        }

        let totalFrames = labels.frameCount

        // Determine which frames to show
        let framesToShow: [LabeledFrame]
        if let specificFrame = frame {
            // Find a frame with this frame index
            var found: [LabeledFrame] = []
            for i in 0..<totalFrames {
                let f = labels[i]
                if f.frameIndex == specificFrame {
                    found.append(f)
                }
            }
            if found.isEmpty {
                FileHandle.standardError.write(
                    Data("Error: No frame with index \(specificFrame) found.\n".utf8))
                throw ExitCode(1)
            }
            framesToShow = found
        } else {
            let maxFrames = limit ?? 5
            let count = min(maxFrames, totalFrames)
            var frames: [LabeledFrame] = []
            for i in 0..<count {
                frames.append(labels[i])
            }
            framesToShow = frames
        }

        if json {
            var jsonFrames: [[String: Any]] = []
            for f in framesToShow {
                var frameObj: [String: Any] = [
                    "frame_index": f.frameIndex,
                    "video": f.video.filename,
                    "instance_count": f.instances.count,
                    "user_instance_count": f.userInstances.count,
                    "predicted_instance_count": f.predictedInstances.count,
                ]

                var instancesArr: [[String: Any]] = []
                for inst in f.instances {
                    var instObj: [String: Any] = [
                        "type": (inst is PredictedInstance) ? "predicted" : "user",
                        "node_count": inst.points.count,
                        "visible_count": inst.points.visibility.filter { $0 }.count,
                    ]
                    if let track = inst.track {
                        instObj["track"] = track.name
                    }
                    if let pred = inst as? PredictedInstance {
                        instObj["score"] = pred.score
                    }
                    instancesArr.append(instObj)
                }
                frameObj["instances"] = instancesArr
                jsonFrames.append(frameObj)
            }

            let data = try JSONSerialization.data(withJSONObject: jsonFrames, options: [.prettyPrinted, .sortedKeys])
            if let str = String(data: data, encoding: .utf8) {
                print(str)
            }
        } else {
            let showing = frame != nil ? "Frame \(frame!)" : "Showing \(framesToShow.count) of \(totalFrames) frames"
            print(showing)
            print("")
            for f in framesToShow {
                let userCount = f.userInstances.count
                let predCount = f.predictedInstances.count
                print("Frame \(f.frameIndex)  video=\(f.video.filename)  instances=\(f.instances.count) (user=\(userCount), pred=\(predCount))")
                for (idx, inst) in f.instances.enumerated() {
                    let typeStr = (inst is PredictedInstance) ? "predicted" : "user"
                    let visCount = inst.points.visibility.filter { $0 }.count
                    let trackStr = inst.track.map { " track=\"\($0.name)\"" } ?? ""
                    let scoreStr: String
                    if let pred = inst as? PredictedInstance {
                        scoreStr = String(format: " score=%.3f", pred.score)
                    } else {
                        scoreStr = ""
                    }
                    print("  [\(idx)] \(typeStr)  nodes=\(inst.points.count) visible=\(visCount)\(trackStr)\(scoreStr)")
                }
            }
        }
    }
}

// MARK: - ConvertCommand

struct ConvertCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "convert",
        abstract: "Convert between formats"
    )

    @Argument(help: "Input file path")
    var input: String

    @Argument(help: "Output file path")
    var output: String

    @Option(name: .long, help: "Input format override")
    var inputFormat: String?

    @Option(name: .long, help: "Output format override")
    var outputFormat: String?

    @Flag(name: .long, help: "Overwrite existing output")
    var force: Bool = false

    // Config file options
    @Option(name: .long, help: "Label Studio mapping file")
    var labelstudioMapping: String?

    @Option(name: .long, help: "YOLO node order file")
    var yoloNodeOrder: String?

    @Option(name: .long, help: "AlphaTracker node names file")
    var alphatrackerNodeNames: String?

    @Option(name: .long, help: "JABS node names file")
    var jabsNodeNames: String?

    func run() async throws {
        // Check output doesn't already exist (unless --force)
        if !force && FileManager.default.fileExists(atPath: output) {
            FileHandle.standardError.write(
                Data("Error: Output file already exists: \(output). Use --force to overwrite.\n".utf8))
            throw ExitCode(1)
        }

        // Load input
        let (labels, _) = try await withErrorHandling {
            try await loadLabels(from: input, format: inputFormat)
        }

        // Determine output format
        let outFormat = try withErrorHandling { () -> FileFormat in
            if let fmt = outputFormat {
                return try parseFormatString(fmt)
            } else {
                return try Labels.inferSaveFormat(from: URL(fileURLWithPath: output))
            }
        }

        // Save
        try await withErrorHandling {
            try await saveLabels(labels, to: output, format: outFormat, jabsNodeNames: jabsNodeNames)
        }

        print("Converted \(input) -> \(output) (\(formatDisplayName(outFormat)))")
    }
}

// MARK: - Error handling

/// Execute a throwing closure, converting SleapIOError to stderr output + ExitCode(1).
private func withErrorHandling<T>(_ block: () throws -> T) throws -> T {
    do {
        return try block()
    } catch let error as SleapIOError {
        printError(error)
        throw ExitCode(1)
    } catch {
        FileHandle.standardError.write(Data("Error: \(error.localizedDescription)\n".utf8))
        throw ExitCode(1)
    }
}

/// Execute an async throwing closure, converting SleapIOError to stderr output + ExitCode(1).
private func withErrorHandling<T>(_ block: () async throws -> T) async throws -> T {
    do {
        return try await block()
    } catch let error as SleapIOError {
        printError(error)
        throw ExitCode(1)
    } catch {
        FileHandle.standardError.write(Data("Error: \(error.localizedDescription)\n".utf8))
        throw ExitCode(1)
    }
}

private func printError(_ error: SleapIOError) {
    let message: String
    switch error {
    case .fileNotFound(let detail):
        message = "File not found: \(detail)"
    case .unsupportedFormat(let detail):
        message = "Unsupported format: \(detail)"
    case .corruptData(let detail):
        message = "Corrupt data: \(detail)"
    case .hdf5Error(let detail):
        message = "HDF5 error: \(detail)"
    case .videoError(let detail):
        message = "Video error: \(detail)"
    case .invalidSkeleton(let detail):
        message = "Invalid skeleton: \(detail)"
    case .formatVersionTooNew(let version):
        message = "Format version \(version) is not supported"
    case .mutationWhileLazy(let detail):
        message = "Mutation while lazy: \(detail)"
    }
    FileHandle.standardError.write(Data("Error: \(message)\n".utf8))
}
