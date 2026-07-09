import Foundation

/// Codec for converting the Labels object graph to/from untyped dictionaries.
///
/// Holds shared identity tables so that encode/decode preserves object identity
/// (same skeleton instance shared across all instances that use it).
public struct DictionaryCodec {

    // MARK: - Encode Labels

    public static func encode(_ labels: Labels) -> [String: Any] {
        // Auto-materialize if lazy — dictionary codec is for small datasets/interop
        if labels.isLazy {
            labels.materialize()
        }

        var dict: [String: Any] = [:]

        // Build index maps
        var videoIndexMap: [ObjectIdentifier: Int] = [:]
        for (i, v) in labels.videos.enumerated() { videoIndexMap[ObjectIdentifier(v)] = i }
        var skelIndexMap: [ObjectIdentifier: Int] = [:]
        for (i, s) in labels.skeletons.enumerated() { skelIndexMap[ObjectIdentifier(s)] = i }
        var trackIndexMap: [ObjectIdentifier: Int] = [:]
        for (i, t) in labels.tracks.enumerated() { trackIndexMap[ObjectIdentifier(t)] = i }

        // Encode identity tables
        dict["videos"] = labels.videos.map { encodeVideo($0) }
        dict["skeletons"] = labels.skeletons.map { encodeSkeleton($0) }
        dict["tracks"] = labels.tracks.map { encodeTrack($0) }

        // Encode frames
        var frames: [[String: Any]] = []
        for i in 0..<labels.frameStore.count {
            let frame = labels.frameStore.frame(at: i)
            var fd: [String: Any] = [:]
            fd["video"] = videoIndexMap[ObjectIdentifier(frame.video)] ?? 0
            fd["frame_idx"] = frame.frameIndex
            fd["is_negative"] = frame.isNegative

            var instances: [[String: Any]] = []
            for inst in frame.instances {
                var id: [String: Any] = [:]
                id["skeleton"] = skelIndexMap[ObjectIdentifier(inst.skeleton)] ?? 0
                id["track"] = inst.track.flatMap { trackIndexMap[ObjectIdentifier($0)] }
                id["tracking_score"] = inst.trackingScore

                // Encode points
                var points: [[String: Any]] = []
                for j in 0..<inst.points.count {
                    let p = inst.points[j]
                    var pd: [String: Any] = ["x": p.x, "y": p.y,
                                              "visible": p.visible, "complete": p.complete]
                    if let predInst = inst as? PredictedInstance {
                        pd["score"] = predInst.predictedPoints.scores[j]
                    }
                    points.append(pd)
                }
                id["points"] = points

                if let predInst = inst as? PredictedInstance {
                    id["type"] = "predicted"
                    id["score"] = predInst.score
                } else {
                    id["type"] = "user"
                }

                instances.append(id)
            }
            fd["instances"] = instances
            frames.append(fd)
        }
        dict["frames"] = frames

        // Metadata
        dict["suggestions"] = labels.suggestions.map { sug -> [String: Any] in
            var sd: [String: Any] = [:]
            sd["video"] = videoIndexMap[ObjectIdentifier(sug.video)] ?? 0
            sd["frame_idx"] = sug.frameIndex
            sd["group"] = sug.group
            return sd
        }

        // Bridge JSONValue provenance to untyped Foundation objects for interop.
        dict["provenance"] = labels.provenance.mapValues { $0.jsonObject }

        return dict
    }

    // MARK: - Decode Labels

    public static func decode(_ dict: [String: Any]) throws -> Labels {
        // Decode identity tables first
        var videos: [Video] = []
        if let videoList = dict["videos"] as? [[String: Any]] {
            videos = videoList.map { decodeVideo($0) }
        }

        var skeletons: [Skeleton] = []
        if let skelList = dict["skeletons"] as? [[String: Any]] {
            skeletons = try skelList.map { try decodeSkeleton($0) }
        }

        var tracks: [Track] = []
        if let trackList = dict["tracks"] as? [[String: Any]] {
            tracks = trackList.map { decodeTrack($0) }
        }

        // Decode frames
        var frames: [LabeledFrame] = []
        if let frameList = dict["frames"] as? [[String: Any]] {
            for fd in frameList {
                let videoIdx = fd["video"] as? Int ?? 0
                let frameIdx = fd["frame_idx"] as? Int ?? 0
                let isNegative = fd["is_negative"] as? Bool ?? false

                guard videoIdx < videos.count else { continue }
                let video = videos[videoIdx]

                var instances: [Instance] = []
                if let instList = fd["instances"] as? [[String: Any]] {
                    for id in instList {
                        let skelIdx = id["skeleton"] as? Int ?? 0
                        guard skelIdx < skeletons.count else { continue }
                        let skeleton = skeletons[skelIdx]

                        let trackIdx = id["track"] as? Int
                        let track = trackIdx.flatMap { $0 < tracks.count ? tracks[$0] : nil }
                        let trackingScore = id["tracking_score"] as? Float

                        let type = id["type"] as? String ?? "user"

                        if let pointsList = id["points"] as? [[String: Any]] {
                            if type == "predicted" {
                                let predPts = pointsList.map { pd -> PredictedPoint in
                                    PredictedPoint(
                                        x: (pd["x"] as? NSNumber)?.floatValue ?? 0,
                                        y: (pd["y"] as? NSNumber)?.floatValue ?? 0,
                                        visible: pd["visible"] as? Bool ?? true,
                                        complete: pd["complete"] as? Bool ?? false,
                                        score: (pd["score"] as? NSNumber)?.floatValue ?? 0
                                    )
                                }
                                let predArray = PredictedPointsArray(points: predPts)
                                let score = (id["score"] as? NSNumber)?.floatValue ?? 0
                                let inst = PredictedInstance(
                                    skeleton: skeleton, points: predArray,
                                    score: score, track: track, trackingScore: trackingScore)
                                instances.append(inst)
                            } else {
                                let pts = pointsList.map { pd -> Point in
                                    Point(
                                        x: (pd["x"] as? NSNumber)?.floatValue ?? 0,
                                        y: (pd["y"] as? NSNumber)?.floatValue ?? 0,
                                        visible: pd["visible"] as? Bool ?? true,
                                        complete: pd["complete"] as? Bool ?? false
                                    )
                                }
                                let ptsArray = PointsArray(points: pts)
                                let inst = Instance(skeleton: skeleton, points: ptsArray,
                                                   track: track, trackingScore: trackingScore)
                                instances.append(inst)
                            }
                        }
                    }
                }

                let frame = LabeledFrame(video: video, frameIndex: frameIdx,
                                         instances: instances, isNegative: isNegative)
                frames.append(frame)
            }
        }

        // Decode suggestions
        var suggestions: [SuggestionFrame] = []
        if let sugList = dict["suggestions"] as? [[String: Any]] {
            for sd in sugList {
                let videoIdx = sd["video"] as? Int ?? 0
                let frameIdx = sd["frame_idx"] as? Int ?? 0
                let group = sd["group"] as? String
                guard videoIdx < videos.count else { continue }
                suggestions.append(SuggestionFrame(
                    video: videos[videoIdx], frameIndex: frameIdx, group: group))
            }
        }

        var provenance: [String: JSONValue] = [:]
        if let prov = dict["provenance"] as? [String: Any] {
            for (k, v) in prov {
                provenance[k] = JSONValue(jsonObject: v)
            }
        }

        let store = EagerFrameStore(frames: frames)
        return Labels(
            frameStore: store,
            videos: videos,
            skeletons: skeletons,
            tracks: tracks,
            suggestions: suggestions,
            provenance: provenance
        )
    }

    // MARK: - Skeleton encode/decode

    public static func encodeSkeleton(_ skeleton: Skeleton) -> [String: Any] {
        var dict: [String: Any] = [:]
        dict["name"] = skeleton.name
        dict["nodes"] = skeleton.nodes.map { ["name": $0.name] }
        dict["edges"] = skeleton.edges.map { edge -> [String: Any] in
            [
                "source": edge.source.name,
                "destination": edge.destination.name
            ]
        }
        dict["symmetries"] = skeleton.symmetries.map { sym -> [String: Any] in
            ["nodes": [sym.nodeA.name, sym.nodeB.name]]
        }
        return dict
    }

    public static func decodeSkeleton(_ dict: [String: Any]) throws -> Skeleton {
        let name = dict["name"] as? String ?? "Skeleton"

        var nodes: [Node] = []
        var nodesByName: [String: Node] = [:]
        if let nodeList = dict["nodes"] as? [[String: Any]] {
            for nd in nodeList {
                let nodeName = nd["name"] as? String ?? "unknown"
                let node = Node(name: nodeName)
                nodes.append(node)
                nodesByName[nodeName] = node
            }
        }

        var edges: [Edge] = []
        if let edgeList = dict["edges"] as? [[String: Any]] {
            for ed in edgeList {
                let srcName = ed["source"] as? String ?? ""
                let dstName = ed["destination"] as? String ?? ""
                if let src = nodesByName[srcName], let dst = nodesByName[dstName] {
                    edges.append(Edge(source: src, destination: dst))
                }
            }
        }

        var symmetries: [Symmetry] = []
        if let symList = dict["symmetries"] as? [[String: Any]] {
            for sd in symList {
                if let names = sd["nodes"] as? [String], names.count == 2,
                   let a = nodesByName[names[0]], let b = nodesByName[names[1]] {
                    symmetries.append(Symmetry(a, b))
                }
            }
        }

        return Skeleton(name: name, nodes: nodes, edges: edges, symmetries: symmetries)
    }

    // MARK: - Video encode/decode

    public static func encodeVideo(_ video: Video) -> [String: Any] {
        var dict: [String: Any] = [
            "filename": video.filename,
            "backend_type": video.backendType
        ]
        if video.persistedFilename != nil {
            dict["original_filename"] = video.originalFilename
        }
        return dict
    }

    public static func decodeVideo(_ dict: [String: Any]) -> Video {
        let filename = dict["filename"] as? String ?? ""
        let backendType = dict["backend_type"] as? String ?? "media"
        if let originalFilename = dict["original_filename"] as? String {
            let video = Video(filename: originalFilename, backendType: backendType)
            video.persistedFilename = filename
            return video
        }
        return Video(filename: filename, backendType: backendType)
    }

    // MARK: - Track encode/decode

    public static func encodeTrack(_ track: Track) -> [String: Any] {
        ["name": track.name]
    }

    public static func decodeTrack(_ dict: [String: Any]) -> Track {
        Track(name: dict["name"] as? String ?? "")
    }
}
