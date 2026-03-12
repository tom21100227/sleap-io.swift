import Foundation
import ImageIO
import CoreGraphics

/// Codec for reading and writing Ultralytics YOLO Pose datasets.
///
/// Supports single-class pose datasets with `dataset.yaml`, image files,
/// and per-image `.txt` label files containing normalized bounding box
/// and keypoint coordinates.
public struct YOLOCodec {

    /// Configuration for YOLO pose dataset import/export.
    public struct Config {
        /// The skeleton defining node names and order for keypoint indices.
        public let skeleton: Skeleton

        public init(skeleton: Skeleton) {
            self.skeleton = skeleton
        }
    }

    // MARK: - Read

    /// Read a YOLO pose dataset from a directory.
    ///
    /// - Parameters:
    ///   - datasetRoot: Path to the dataset root directory containing `dataset.yaml`.
    ///   - config: Configuration with the target skeleton (required for node order).
    /// - Returns: A fully materialized `Labels` instance.
    /// - Throws: `SleapIOError` on invalid input.
    public static func read(from datasetRoot: String, config: Config) throws -> Labels {
        // Y01: Validate skeleton has nodes
        guard config.skeleton.nodes.count > 0 else {
            throw SleapIOError.invalidSkeleton("YOLO pose import requires a skeleton with at least one node.")
        }

        let fm = FileManager.default
        let rootURL = URL(fileURLWithPath: datasetRoot)

        // Check directory exists
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: datasetRoot, isDirectory: &isDir), isDir.boolValue else {
            throw SleapIOError.fileNotFound("Dataset root directory not found: \(datasetRoot)")
        }

        // Parse dataset.yaml
        let yamlURL = rootURL.appendingPathComponent("dataset.yaml")
        let yaml: DatasetYAML
        do {
            yaml = try parseDatasetYAML(at: yamlURL)
        } catch let error as SleapIOError {
            throw error
        } catch {
            throw SleapIOError.unsupportedFormat("Missing or unreadable dataset.yaml in \(datasetRoot)")
        }

        // Y02: Single-class check
        guard yaml.classNames.count == 1 else {
            throw SleapIOError.unsupportedFormat(
                "Multi-class YOLO pose datasets are not supported in the first pass. Found \(yaml.classNames.count) classes.")
        }

        let kptDim = yaml.kptShape.count >= 2 ? yaml.kptShape[1] : 3

        // Collect image splits
        var imagePaths: [String] = []
        for split in yaml.splits {
            let splitDir: URL
            if split.hasPrefix("/") {
                splitDir = URL(fileURLWithPath: split)
            } else {
                splitDir = rootURL.appendingPathComponent(split)
            }
            guard fm.fileExists(atPath: splitDir.path) else { continue }
            let contents = try fm.contentsOfDirectory(atPath: splitDir.path)
            for file in contents.sorted() {
                let ext = (file as NSString).pathExtension.lowercased()
                if isImageExtension(ext) {
                    imagePaths.append(splitDir.appendingPathComponent(file).path)
                }
            }
        }

        // Build a Set of image base names for O(1) orphan label check
        let imageBaseNames: Set<String> = Set(imagePaths.map { imgPath in
            ((imgPath as NSString).lastPathComponent as NSString).deletingPathExtension
        })

        // Check for orphan label files (labels without corresponding images)
        for split in yaml.splits {
            // Derive labels dir from images dir: images/... -> labels/...
            let labelsSplit = split.replacingOccurrences(of: "images/", with: "labels/")
            let labelsDir: URL
            if labelsSplit.hasPrefix("/") {
                labelsDir = URL(fileURLWithPath: labelsSplit)
            } else {
                labelsDir = rootURL.appendingPathComponent(labelsSplit)
            }
            guard fm.fileExists(atPath: labelsDir.path) else { continue }
            let labelFiles = (try? fm.contentsOfDirectory(atPath: labelsDir.path)) ?? []
            for labelFile in labelFiles {
                let ext = (labelFile as NSString).pathExtension.lowercased()
                guard ext == "txt" else { continue }
                let baseName = (labelFile as NSString).deletingPathExtension
                // O(1) membership check
                if !imageBaseNames.contains(baseName) {
                    throw SleapIOError.fileNotFound(
                        "Label file '\(labelFile)' has no corresponding image file.")
                }
            }
        }

        // Build Labels
        let skeleton = config.skeleton
        var videos: [Video] = []
        var frames: [LabeledFrame] = []

        for imagePath in imagePaths {
            let video = Video(filename: imagePath)

            // Get image dimensions
            guard let (imgWidth, imgHeight) = readImageDimensions(at: imagePath) else {
                throw SleapIOError.videoError("Cannot determine image dimensions for: \(imagePath)")
            }
            video.frameSize = (height: imgHeight, width: imgWidth, channels: 3)

            // Find corresponding label file
            let labelPath = labelPathForImage(imagePath: imagePath, datasetRoot: datasetRoot)
            var instances: [Instance] = []

            if let labelPath = labelPath, fm.fileExists(atPath: labelPath) {
                let labelContent = try String(contentsOfFile: labelPath, encoding: .utf8)
                let lines = labelContent.components(separatedBy: .newlines).filter { !$0.isEmpty }

                for line in lines {
                    let tokens = line.split(separator: " ").map { String($0) }
                    // Format: class_id cx cy w h [kx ky [v]] ...
                    guard tokens.count >= 5 else { continue }

                    // Skip class_id and bbox (first 5 tokens)
                    let kptTokens = Array(tokens.dropFirst(5))
                    let nodeCount = skeleton.nodes.count

                    var points: [Point] = []
                    for nodeIdx in 0..<nodeCount {
                        if kptDim == 3 {
                            let base = nodeIdx * 3
                            guard base + 2 < kptTokens.count else {
                                points.append(Point(x: .nan, y: .nan, visible: false, complete: false))
                                continue
                            }
                            let nx = Float(kptTokens[base]) ?? 0
                            let ny = Float(kptTokens[base + 1]) ?? 0
                            let v = Float(kptTokens[base + 2]) ?? 0

                            if v <= 0 {
                                // Not labeled
                                points.append(Point(x: .nan, y: .nan, visible: false, complete: false))
                            } else {
                                let absX = nx * Float(imgWidth)
                                let absY = ny * Float(imgHeight)
                                points.append(Point(x: absX, y: absY, visible: true, complete: true))
                            }
                        } else {
                            // kptDim == 2: no visibility, all visible
                            let base = nodeIdx * 2
                            guard base + 1 < kptTokens.count else {
                                points.append(Point(x: .nan, y: .nan, visible: false, complete: false))
                                continue
                            }
                            let nx = Float(kptTokens[base]) ?? 0
                            let ny = Float(kptTokens[base + 1]) ?? 0
                            let absX = nx * Float(imgWidth)
                            let absY = ny * Float(imgHeight)
                            points.append(Point(x: absX, y: absY, visible: true, complete: true))
                        }
                    }

                    let ptsArray = PointsArray(points: points)
                    let inst = Instance(skeleton: skeleton, points: ptsArray)
                    instances.append(inst)
                }
            }

            let frame = LabeledFrame(video: video, frameIndex: 0, instances: instances)
            videos.append(video)
            frames.append(frame)
        }

        let store = EagerFrameStore(frames: frames)
        return Labels(
            frameStore: store,
            videos: videos,
            skeletons: [skeleton],
            tracks: []
        )
    }

    // MARK: - Write

    /// Write a `Labels` object as a YOLO pose dataset.
    ///
    /// - Parameters:
    ///   - labels: The labels to export.
    ///   - datasetRoot: Path to the output dataset root directory.
    ///   - config: Configuration with the target skeleton.
    /// - Throws: `SleapIOError` on invalid input or I/O failure.
    public static func write(_ labels: Labels, to datasetRoot: String, config: Config) throws {
        guard config.skeleton.nodes.count > 0 else {
            throw SleapIOError.invalidSkeleton("YOLO pose export requires a skeleton with at least one node.")
        }

        let fm = FileManager.default
        let rootURL = URL(fileURLWithPath: datasetRoot)
        let imagesDir = rootURL.appendingPathComponent("images/train")
        let labelsDir = rootURL.appendingPathComponent("labels/train")

        try fm.createDirectory(at: imagesDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: labelsDir, withIntermediateDirectories: true)

        let skeleton = config.skeleton
        let nodeCount = skeleton.nodes.count

        // Write dataset.yaml
        let yamlContent = """
        path: \(datasetRoot)
        train: images/train
        names:
          0: \(skeleton.name)
        kpt_shape: [\(nodeCount), 3]
        """
        try yamlContent.write(
            to: rootURL.appendingPathComponent("dataset.yaml"),
            atomically: true, encoding: .utf8
        )

        // Write label files for each frame
        var usedImageNames = Set<String>()

        for i in 0..<labels.frameStore.count {
            let frame = labels.frameStore.frame(at: i)
            let video = frame.video

            // Determine image dimensions
            guard let frameSize = video.frameSize else {
                throw SleapIOError.videoError(
                    "Cannot export frame without known image dimensions for video: \(video.filename)")
            }
            let imgWidth = Float(frameSize.width)
            let imgHeight = Float(frameSize.height)

            // Derive a unique image name per frame.
            // Multiple frames from the same video (e.g. movie-backed) need distinct names.
            let videoBaseName = (video.filename as NSString).lastPathComponent
            let videoExt = (videoBaseName as NSString).pathExtension
            let videoStem = (videoBaseName as NSString).deletingPathExtension

            let baseName: String
            let imageFileName: String
            let candidateName = videoBaseName
            if usedImageNames.contains(candidateName) {
                // Disambiguate by appending frame index
                baseName = "\(videoStem)_frame\(frame.frameIndex)"
                let ext = isImageExtension(videoExt.lowercased()) ? videoExt : "ppm"
                imageFileName = "\(baseName).\(ext)"
            } else {
                baseName = videoStem
                imageFileName = videoBaseName
            }
            usedImageNames.insert(imageFileName)

            // Copy/link image file to images/train if it exists and isn't already there
            let destImagePath = imagesDir.appendingPathComponent(imageFileName)
            if !fm.fileExists(atPath: destImagePath.path) {
                let srcPath = video.filename
                if fm.fileExists(atPath: srcPath), isImageExtension(videoExt.lowercased()) {
                    try fm.copyItem(atPath: srcPath, toPath: destImagePath.path)
                } else {
                    // Create a placeholder PPM so the round-trip read can get dimensions
                    let w = frameSize.width
                    let h = frameSize.height
                    let header = "P6\n\(w) \(h)\n255\n"
                    var data = Data(header.utf8)
                    data.append(Data(repeating: 128, count: w * h * 3))
                    try data.write(to: destImagePath)
                }
            }

            // Build label lines
            var lines: [String] = []
            for inst in frame.instances {
                // Y02: Reject instances with a different skeleton than config
                guard inst.skeleton === skeleton else {
                    throw SleapIOError.unsupportedFormat(
                        "Mixed-skeleton YOLO export is not supported. Instance uses skeleton '\(inst.skeleton.name)' but config specifies '\(skeleton.name)'.")
                }
                var tokens: [String] = []
                // Class ID
                tokens.append("0")

                // Bounding box (cx, cy, w, h) normalized — includes all finite points
                // (both visible and occluded) for correct bbox coverage
                var minX = Float.greatestFiniteMagnitude
                var minY = Float.greatestFiniteMagnitude
                var maxX = -Float.greatestFiniteMagnitude
                var maxY = -Float.greatestFiniteMagnitude
                var hasFinite = false

                for j in 0..<inst.points.count {
                    let pt = inst.points[j]
                    if !pt.x.isNaN && !pt.y.isNaN {
                        hasFinite = true
                        minX = min(minX, pt.x)
                        minY = min(minY, pt.y)
                        maxX = max(maxX, pt.x)
                        maxY = max(maxY, pt.y)
                    }
                }

                if hasFinite {
                    let cx = ((minX + maxX) / 2.0) / imgWidth
                    let cy = ((minY + maxY) / 2.0) / imgHeight
                    let bw = (maxX - minX) / imgWidth
                    let bh = (maxY - minY) / imgHeight
                    tokens.append(formatFloat(cx))
                    tokens.append(formatFloat(cy))
                    tokens.append(formatFloat(bw))
                    tokens.append(formatFloat(bh))
                } else {
                    tokens.append(contentsOf: ["0.000000", "0.000000", "0.000000", "0.000000"])
                }

                // Keypoints (kpt_shape [N, 3])
                // Visibility: v=2 for visible+finite, v=1 for occluded+finite, v=0 for missing/NaN
                for j in 0..<nodeCount {
                    if j < inst.points.count {
                        let pt = inst.points[j]
                        if !pt.x.isNaN && !pt.y.isNaN {
                            let nx = pt.x / imgWidth
                            let ny = pt.y / imgHeight
                            tokens.append(formatFloat(nx))
                            tokens.append(formatFloat(ny))
                            tokens.append(pt.visible ? "2" : "1")
                        } else {
                            tokens.append("0.000000")
                            tokens.append("0.000000")
                            tokens.append("0")
                        }
                    } else {
                        tokens.append("0.000000")
                        tokens.append("0.000000")
                        tokens.append("0")
                    }
                }

                lines.append(tokens.joined(separator: " "))
            }

            let labelFile = labelsDir.appendingPathComponent("\(baseName).txt")
            let labelContent = lines.joined(separator: "\n")
            try labelContent.write(to: labelFile, atomically: true, encoding: .utf8)
        }
    }

    // MARK: - Private Helpers

    /// Parsed content of a dataset.yaml file.
    private struct DatasetYAML {
        var path: String
        var splits: [String]  // train, val paths
        var classNames: [String]
        var kptShape: [Int]
    }

    /// Minimal YAML parser for dataset.yaml (key: value pairs and simple lists).
    private static func parseDatasetYAML(at url: URL) throws -> DatasetYAML {
        let content = try String(contentsOf: url, encoding: .utf8)
        let lines = content.components(separatedBy: .newlines)

        var path = ""
        var train = ""
        var val = ""
        var classNames: [String] = []
        var kptShape: [Int] = []
        var inNames = false

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }

            // Check if we're in a names: block (indented lines)
            if inNames {
                // Indented lines belong to the names block
                let isIndented = line.hasPrefix(" ") || line.hasPrefix("\t")
                if isIndented && trimmed.contains(":") {
                    // Split carefully to handle "0: animal" — use range of first ":"
                    if let colonIdx = trimmed.firstIndex(of: ":") {
                        let key = trimmed[trimmed.startIndex..<colonIdx]
                            .trimmingCharacters(in: .whitespaces)
                        if Int(key) != nil {
                            let afterColon = trimmed[trimmed.index(after: colonIdx)...]
                                .trimmingCharacters(in: .whitespaces)
                            classNames.append(afterColon)
                            continue
                        }
                    }
                    // Non-numeric key means we left the names block
                    inNames = false
                } else if isIndented {
                    // Indented but no colon — skip (e.g. list item)
                    continue
                } else {
                    inNames = false
                }
            }

            guard trimmed.contains(":") else { continue }

            // Split on first colon to get key and value
            guard let colonIdx = trimmed.firstIndex(of: ":") else { continue }
            let key = trimmed[trimmed.startIndex..<colonIdx]
                .trimmingCharacters(in: .whitespaces)
            let value = trimmed[trimmed.index(after: colonIdx)...]
                .trimmingCharacters(in: .whitespaces)

            switch key {
            case "path":
                path = value
            case "train":
                train = value
            case "val":
                val = value
            case "names":
                inNames = true
            case "kpt_shape":
                // Parse [N, D] format
                let stripped = value
                    .replacingOccurrences(of: "[", with: "")
                    .replacingOccurrences(of: "]", with: "")
                kptShape = stripped.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            default:
                break
            }
        }

        var splits: [String] = []
        if !train.isEmpty { splits.append(train) }
        if !val.isEmpty && val != train { splits.append(val) }

        return DatasetYAML(path: path, splits: splits, classNames: classNames, kptShape: kptShape)
    }

    /// Determine the label file path for a given image path.
    ///
    /// Follows YOLO convention: images/... -> labels/... with .txt extension.
    private static func labelPathForImage(imagePath: String, datasetRoot: String) -> String? {
        // Replace "images" directory component with "labels" and change extension to .txt
        guard let imagesRange = imagePath.range(of: "/images/") else { return nil }
        let prefix = String(imagePath[imagePath.startIndex..<imagesRange.lowerBound])
        let suffix = String(imagePath[imagesRange.upperBound...])
        let baseName = (suffix as NSString).deletingPathExtension
        return prefix + "/labels/" + baseName + ".txt"
    }

    /// Read image dimensions from a file without loading the full image.
    ///
    /// Supports standard image formats via CoreGraphics ImageIO, plus PPM (P6) format
    /// used in test fixtures.
    private static func readImageDimensions(at path: String) -> (width: Int, height: Int)? {
        // Only try PPM parsing for PPM files
        let ext = (path as NSString).pathExtension.lowercased()
        if ext == "ppm" || ext == "pgm" || ext == "pbm" {
            if let dims = readPPMDimensions(at: path) {
                return dims
            }
        }

        // Try CoreGraphics ImageIO
        let url = URL(fileURLWithPath: path) as CFURL
        guard let source = CGImageSourceCreateWithURL(url, nil) else {
            // Fallback: try PPM for extensionless files
            if ext.isEmpty, let dims = readPPMDimensions(at: path) {
                return dims
            }
            return nil
        }
        guard let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] else {
            return nil
        }
        guard let width = props[kCGImagePropertyPixelWidth as String] as? Int,
              let height = props[kCGImagePropertyPixelHeight as String] as? Int else {
            return nil
        }
        return (width: width, height: height)
    }

    /// Parse PPM P6 header to get dimensions.
    private static func readPPMDimensions(at path: String) -> (width: Int, height: Int)? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { handle.closeFile() }

        // Read enough for the header (typically < 100 bytes)
        guard let data = try? handle.read(upToCount: 256) else { return nil }
        guard let header = String(data: data, encoding: .ascii) else { return nil }

        // PPM P6 format: "P6\n<width> <height>\n<maxval>\n"
        let lines = header.components(separatedBy: .newlines)
        guard lines.count >= 3, lines[0] == "P6" else { return nil }

        // Skip comment lines
        var dimLine = ""
        for i in 1..<lines.count {
            let line = lines[i].trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#") { continue }
            dimLine = line
            break
        }

        let parts = dimLine.split(separator: " ")
        guard parts.count >= 2,
              let width = Int(parts[0]),
              let height = Int(parts[1]) else { return nil }
        return (width: width, height: height)
    }

    /// Check if a file extension is an image format.
    private static func isImageExtension(_ ext: String) -> Bool {
        let imageExtensions: Set<String> = [
            "png", "jpg", "jpeg", "bmp", "tiff", "tif", "ppm", "pgm", "pbm"
        ]
        return imageExtensions.contains(ext)
    }

    /// Format a float with 6 decimal places for YOLO label output.
    private static func formatFloat(_ value: Float) -> String {
        String(format: "%.6f", value)
    }
}
