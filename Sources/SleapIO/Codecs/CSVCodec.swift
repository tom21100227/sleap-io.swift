import Foundation

/// Codec for reading and writing SLEAP pose data in canonical CSV format.
///
/// The CSV format uses a long-table layout with one row per node per instance.
/// Required columns: video, frame_idx, skeleton, instance, node, x, y, visible.
/// Optional columns: complete, track, instance_type, instance_score, point_score, tracking_score.
///
/// This format is lossy: skeleton edges, symmetries, and some metadata are not preserved.
public struct CSVCodec {

    // MARK: - Public API

    /// Read a Labels object from a CSV file.
    ///
    /// - Parameter path: Path to the CSV file.
    /// - Returns: A fully materialized Labels instance.
    /// - Throws: `SleapIOError.fileNotFound` if the file does not exist,
    ///           `SleapIOError.corruptData` if the file is empty or missing required columns.
    public static func read(from path: String) throws -> Labels {
        // Read file content (handles fileNotFound via do-catch)
        let content: String
        do {
            content = try String(contentsOfFile: path, encoding: .utf8)
        } catch {
            throw SleapIOError.fileNotFound("File not found: \(path)")
        }

        // Parse all lines
        let lines = parseLines(content)

        // Must have at least a header + one data row
        guard lines.count >= 2 else {
            throw SleapIOError.corruptData("CSV file is empty or has no data rows")
        }

        let headerFields = parseCSVRow(lines[0])

        // Build column index map
        var colIndex: [String: Int] = [:]
        for (i, field) in headerFields.enumerated() {
            colIndex[field.trimmingCharacters(in: .whitespaces)] = i
        }

        // Validate required columns
        let requiredColumns = ["video", "frame_idx", "skeleton", "instance", "node", "x", "y", "visible"]
        for col in requiredColumns {
            guard colIndex[col] != nil else {
                throw SleapIOError.corruptData("Missing required column: \(col)")
            }
        }

        // Optional column indices
        let completeCol = colIndex["complete"]
        let trackCol = colIndex["track"]
        let instanceTypeCol = colIndex["instance_type"]
        let instanceScoreCol = colIndex["instance_score"]
        let pointScoreCol = colIndex["point_score"]
        let trackingScoreCol = colIndex["tracking_score"]

        let videoCol = colIndex["video"]!
        let frameIdxCol = colIndex["frame_idx"]!
        let skeletonCol = colIndex["skeleton"]!
        let instanceCol = colIndex["instance"]!
        let nodeCol = colIndex["node"]!
        let xCol = colIndex["x"]!
        let yCol = colIndex["y"]!
        let visibleCol = colIndex["visible"]!

        // Parse data rows into structured records
        struct RowData {
            let video: String
            let frameIdx: Int
            let skeleton: String
            let instance: String
            let node: String
            let x: Float
            let y: Float
            let visible: Bool
            let complete: Bool
            let track: String
            let instanceType: String
            let instanceScore: Float?
            let pointScore: Float?
            let trackingScore: Float?
        }

        var rows: [RowData] = []
        for lineIdx in 1..<lines.count {
            let fields = parseCSVRow(lines[lineIdx])
            let maxCol = max(videoCol, max(frameIdxCol, max(skeletonCol, max(instanceCol, max(nodeCol, max(xCol, max(yCol, visibleCol)))))))
            guard fields.count > maxCol else { continue }

            let video = fields[videoCol].trimmingCharacters(in: .whitespaces)
            let frameIdx = Int(fields[frameIdxCol].trimmingCharacters(in: .whitespaces)) ?? 0
            let skeleton = fields[skeletonCol].trimmingCharacters(in: .whitespaces)
            let instance = fields[instanceCol].trimmingCharacters(in: .whitespaces)
            let node = fields[nodeCol].trimmingCharacters(in: .whitespaces)
            let x = Float(fields[xCol].trimmingCharacters(in: .whitespaces)) ?? .nan
            let y = Float(fields[yCol].trimmingCharacters(in: .whitespaces)) ?? .nan
            let visStr = fields[visibleCol].trimmingCharacters(in: .whitespaces).lowercased()
            let visible = visStr == "true" || visStr == "1"

            var complete = false
            if let col = completeCol, fields.count > col {
                let s = fields[col].trimmingCharacters(in: .whitespaces).lowercased()
                complete = s == "true" || s == "1"
            }

            var trackStr = ""
            if let col = trackCol, fields.count > col {
                trackStr = fields[col].trimmingCharacters(in: .whitespaces)
            }

            var instanceType = ""
            if let col = instanceTypeCol, fields.count > col {
                instanceType = fields[col].trimmingCharacters(in: .whitespaces).lowercased()
            }

            var instanceScore: Float? = nil
            if let col = instanceScoreCol, fields.count > col {
                let s = fields[col].trimmingCharacters(in: .whitespaces)
                if !s.isEmpty { instanceScore = Float(s) }
            }

            var pointScore: Float? = nil
            if let col = pointScoreCol, fields.count > col {
                let s = fields[col].trimmingCharacters(in: .whitespaces)
                if !s.isEmpty { pointScore = Float(s) }
            }

            var trackingScore: Float? = nil
            if let col = trackingScoreCol, fields.count > col {
                let s = fields[col].trimmingCharacters(in: .whitespaces)
                if !s.isEmpty { trackingScore = Float(s) }
            }

            rows.append(RowData(
                video: video, frameIdx: frameIdx, skeleton: skeleton,
                instance: instance, node: node, x: x, y: y,
                visible: visible, complete: complete, track: trackStr,
                instanceType: instanceType, instanceScore: instanceScore,
                pointScore: pointScore, trackingScore: trackingScore
            ))
        }

        guard !rows.isEmpty else {
            throw SleapIOError.corruptData("CSV file has no data rows")
        }

        // Identity tables: keyed by string
        var videoMap: [String: Video] = [:]      // video string -> Video
        var videoOrder: [String] = []             // preserve first-seen order
        var skeletonMap: [String: Skeleton] = [:] // skeleton string -> Skeleton
        var skeletonOrder: [String] = []          // preserve first-seen order
        var trackMap: [String: Track] = [:]       // track string -> Track

        // Skeleton node order: first-seen order per skeleton name
        // Use parallel Set for O(1) membership check
        var skeletonNodes: [String: [String]] = [:] // skeleton name -> ordered node names
        var skeletonNodeSets: [String: Set<String>] = [:]

        // First pass: collect skeleton node orders and identity objects
        for row in rows {
            // Video identity
            if videoMap[row.video] == nil {
                videoMap[row.video] = Video(filename: row.video)
                videoOrder.append(row.video)
            }

            // Skeleton node order — O(1) membership check via Set
            if skeletonNodes[row.skeleton] == nil {
                skeletonNodes[row.skeleton] = []
                skeletonNodeSets[row.skeleton] = []
                skeletonOrder.append(row.skeleton)
            }
            if skeletonNodeSets[row.skeleton, default: []].insert(row.node).inserted {
                skeletonNodes[row.skeleton]!.append(row.node)
            }

            // Track identity
            if !row.track.isEmpty && trackMap[row.track] == nil {
                trackMap[row.track] = Track(name: row.track)
            }
        }

        // Build skeletons from collected node orders
        for skelName in skeletonOrder {
            let nodeNames = skeletonNodes[skelName]!
            let nodes = nodeNames.map { Node(name: $0) }
            skeletonMap[skelName] = Skeleton(name: skelName, nodes: nodes)
        }

        // Group rows by (video, frameIdx) preserving order, then by (skeleton, instance)
        struct FrameKey: Hashable {
            let video: String
            let frameIdx: Int
        }
        struct InstanceKey: Hashable {
            let skeleton: String
            let instance: String
        }

        // Collect frame keys in order
        var frameKeyOrder: [FrameKey] = []
        var frameKeySet: Set<FrameKey> = []
        // Nested dictionary for O(1) instance lookup: FrameKey -> InstanceKey -> [RowData]
        var frameInstanceRows: [FrameKey: [InstanceKey: [RowData]]] = [:]
        // Preserve instance order per frame
        var frameInstanceOrder: [FrameKey: [InstanceKey]] = [:]

        for row in rows {
            let fk = FrameKey(video: row.video, frameIdx: row.frameIdx)
            let ik = InstanceKey(skeleton: row.skeleton, instance: row.instance)

            if !frameKeySet.contains(fk) {
                frameKeySet.insert(fk)
                frameKeyOrder.append(fk)
                frameInstanceRows[fk] = [:]
                frameInstanceOrder[fk] = []
            }

            if frameInstanceRows[fk]![ik] == nil {
                frameInstanceOrder[fk]!.append(ik)
                frameInstanceRows[fk]![ik] = [row]
            } else {
                frameInstanceRows[fk]![ik]!.append(row)
            }
        }

        // Build LabeledFrames
        var frames: [LabeledFrame] = []
        for fk in frameKeyOrder {
            let video = videoMap[fk.video]!
            let instanceKeys = frameInstanceOrder[fk]!
            let instanceRowMap = frameInstanceRows[fk]!

            var instances: [Instance] = []
            for ik in instanceKeys {
                let groupRows = instanceRowMap[ik]!
                let skeleton = skeletonMap[ik.skeleton]!
                let nodeNames = skeletonNodes[ik.skeleton]!

                // Determine if predicted
                var isPredicted = false
                var instScore: Float = 0
                var trkScore: Float? = nil
                var trackStr = ""

                for r in groupRows {
                    if r.instanceType == "predicted" { isPredicted = true }
                    if r.instanceScore != nil {
                        isPredicted = true
                        instScore = r.instanceScore!
                    }
                    if r.pointScore != nil {
                        isPredicted = true
                    }
                    if r.trackingScore != nil { trkScore = r.trackingScore }
                    if !r.track.isEmpty { trackStr = r.track }
                }

                let track: Track? = trackStr.isEmpty ? nil : trackMap[trackStr]

                // Build node -> row mapping
                var nodeRowMap: [String: RowData] = [:]
                for r in groupRows {
                    nodeRowMap[r.node] = r
                }

                if isPredicted {
                    var predPoints: [PredictedPoint] = []
                    for nodeName in nodeNames {
                        if let r = nodeRowMap[nodeName] {
                            predPoints.append(PredictedPoint(
                                x: r.x, y: r.y,
                                visible: r.visible, complete: r.complete,
                                score: r.pointScore ?? 0
                            ))
                        } else {
                            // Missing node
                            predPoints.append(PredictedPoint(
                                x: .nan, y: .nan,
                                visible: false, complete: false,
                                score: 0
                            ))
                        }
                    }
                    let ppa = PredictedPointsArray(points: predPoints)
                    let inst = PredictedInstance(
                        skeleton: skeleton, points: ppa,
                        score: instScore, track: track,
                        trackingScore: trkScore
                    )
                    instances.append(inst)
                } else {
                    var points: [Point] = []
                    for nodeName in nodeNames {
                        if let r = nodeRowMap[nodeName] {
                            points.append(Point(x: r.x, y: r.y, visible: r.visible, complete: r.complete))
                        } else {
                            // Missing node
                            points.append(Point(x: .nan, y: .nan, visible: false, complete: false))
                        }
                    }
                    let pa = PointsArray(points: points)
                    let inst = Instance(skeleton: skeleton, points: pa, track: track, trackingScore: trkScore)
                    instances.append(inst)
                }
            }

            let frame = LabeledFrame(video: video, frameIndex: fk.frameIdx, instances: instances)
            frames.append(frame)
        }

        let videos = videoOrder.map { videoMap[$0]! }
        let skeletons = skeletonOrder.map { skeletonMap[$0]! }
        let tracks = Array(trackMap.values)

        let store = EagerFrameStore(frames: frames)
        return Labels(
            frameStore: store,
            videos: videos,
            skeletons: skeletons,
            tracks: tracks
        )
    }

    /// Write a Labels object to a CSV file.
    ///
    /// - Parameters:
    ///   - labels: The Labels to export.
    ///   - path: Path to write the CSV file.
    /// - Throws: File system errors on write failure.
    public static func write(_ labels: Labels, to path: String) throws {
        // Materialize if lazy (no-ops when eager)
        labels.materialize()

        let header = "video,frame_idx,skeleton,instance,node,x,y,visible,complete,track,instance_type,instance_score,point_score,tracking_score"

        var outputRows: [String] = [header]

        // Deterministic order: videos in labels.videos order, frames by frameIndex, instances in frame order
        for video in labels.videos {
            let videoFrames = labels.frames(for: video)
            // frames(for:) already sorts by frameIndex

            for frame in videoFrames {
                for (instIdx, inst) in frame.instances.enumerated() {
                    let skeleton = inst.skeleton
                    let isPredicted = inst is PredictedInstance
                    let predInst = inst as? PredictedInstance
                    let instanceType = isPredicted ? "predicted" : "user"
                    let trackName = inst.track?.name ?? ""

                    for (nodeIdx, node) in skeleton.nodes.enumerated() {
                        let point = inst.points[nodeIdx]
                        let x = formatFloat(point.x)
                        let y = formatFloat(point.y)
                        let visible = point.visible ? "true" : "false"
                        let complete = point.complete ? "true" : "false"

                        let instanceScore: String
                        let pointScore: String
                        if let pred = predInst {
                            instanceScore = formatFloat(pred.score)
                            pointScore = formatFloat(pred.predictedPoints.scores[nodeIdx])
                        } else {
                            instanceScore = ""
                            pointScore = ""
                        }

                        let trackingScore: String
                        if let ts = inst.trackingScore {
                            trackingScore = formatFloat(ts)
                        } else {
                            trackingScore = ""
                        }

                        let videoField = escapeCSVField(video.filename)
                        let skelField = escapeCSVField(skeleton.name)
                        let nodeField = escapeCSVField(node.name)
                        let trackField = escapeCSVField(trackName)

                        let row = "\(videoField),\(frame.frameIndex),\(skelField),\(instIdx),\(nodeField),\(x),\(y),\(visible),\(complete),\(trackField),\(instanceType),\(instanceScore),\(pointScore),\(trackingScore)"
                        outputRows.append(row)
                    }
                }
            }
        }

        let output = outputRows.joined(separator: "\n") + "\n"
        try output.write(toFile: path, atomically: true, encoding: .utf8)
    }

    // MARK: - Private helpers

    /// Parse a CSV file content into non-empty lines.
    private static func parseLines(_ content: String) -> [String] {
        content.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    /// Parse a single CSV row, handling quoted fields that may contain commas and escaped quotes.
    private static func parseCSVRow(_ line: String) -> [String] {
        var fields: [String] = []
        var current = ""
        var inQuotes = false
        var iterator = line.makeIterator()

        while let ch = iterator.next() {
            if inQuotes {
                if ch == "\"" {
                    // Peek at next character for escaped quote (double-quote)
                    if let next = iterator.next() {
                        if next == "\"" {
                            // Escaped quote — append literal quote and stay in quoted mode
                            current.append("\"")
                        } else {
                            // End of quoted field; process the next char normally
                            inQuotes = false
                            if next == "," {
                                fields.append(current)
                                current = ""
                            } else {
                                current.append(next)
                            }
                        }
                    } else {
                        // End of string after closing quote
                        inQuotes = false
                    }
                } else {
                    current.append(ch)
                }
            } else {
                if ch == "\"" {
                    inQuotes = true
                } else if ch == "," {
                    fields.append(current)
                    current = ""
                } else {
                    current.append(ch)
                }
            }
        }
        fields.append(current)
        return fields
    }

    /// Format a Float value for CSV output with enough precision for round-trip.
    private static func formatFloat(_ value: Float) -> String {
        if value.isNaN { return "nan" }
        if value.isInfinite { return value > 0 ? "inf" : "-inf" }
        // Use enough decimal places for Float32 round-trip (typically 9 significant digits suffice)
        return String(value)
    }

    /// Escape a CSV field if it contains commas, quotes, or newlines.
    private static func escapeCSVField(_ field: String) -> String {
        if field.contains(",") || field.contains("\"") || field.contains("\n") {
            let escaped = field.replacingOccurrences(of: "\"", with: "\"\"")
            return "\"\(escaped)\""
        }
        return field
    }
}
