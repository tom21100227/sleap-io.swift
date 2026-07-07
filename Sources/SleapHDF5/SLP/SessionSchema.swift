import Foundation
import SleapIO

/// Encode/decode helpers for the Python-compatible `sessions_json` schema.
///
/// Mirrors sleap-io's `session_to_dict` / `make_session`: each session is a JSON
/// object with three top-level keys —
///
///   - `calibration`: `{ "cam_0": {…}, "cam_1": {…}, …, "metadata": {…} }`, where
///     each `cam_n` carries a camera's `name`, `size` (`[width, height]`),
///     `matrix` (3×3 nested), `distortions` (`[k1,k2,p1,p2,k3]`), `rotation`
///     (`rvec`) and `translation` (`tvec`). Camera order is fixed by the `n`
///     index and shared by the two maps below.
///   - `camcorder_to_video_idx_map`: `{ "<camIdx>": <videoIdx> }` mapping each
///     camera (by its `calibration` index) to a video index in `Labels.videos`.
///   - `frame_group_dicts`: a list of ``FrameGroup`` dictionaries, each holding
///     `instance_groups` whose `camcorder_to_lf_and_inst_idx_map` links a camera
///     index to a `[labeledFrameIdx, instanceIdx]` pair, plus an optional
///     `frame_idx`. When an ``InstanceGroup`` carries a triangulated
///     ``Instance3D``, that pose is additionally persisted under the additive
///     `points` (per-node `[x,y,z]` rows or `null`) and optional `score` keys;
///     readers that don't model 3D poses simply ignore them.
///
/// For back-compat with the older bespoke schema (and readers that only model
/// it), ``sessionDict(_:orderedCameras:videoIndexMap:labeledFrameToIdx:instanceToLfInst:)``
/// additionally emits the legacy `camera_to_video` array. Python folds this
/// extra key into `RecordingSession.metadata` harmlessly; ``makeSession`` only
/// consults it when the modern `calibration` key is absent.
///
/// This type is pure model↔dictionary translation; it performs no HDF5 I/O so
/// it can be unit-tested in isolation.
enum SessionSchema {

    // MARK: - Session → dictionary (write)

    /// A deterministic, de-duplicated ordering of every ``Camera`` referenced by
    /// `session` (its `cameraToVideo` keys plus any camera appearing in a frame
    /// group). The Swift ``RecordingSession`` has no ordered `CameraGroup`, so a
    /// stable order is synthesized here: primarily by ``Camera/name``, with
    /// first-seen order breaking ties. The returned array is used for both the
    /// `calibration` block and the index maps so they stay mutually consistent.
    static func orderedCameras(for session: RecordingSession) -> [Camera] {
        var seen = Set<ObjectIdentifier>()
        var cameras: [Camera] = []
        func add(_ camera: Camera) {
            if seen.insert(ObjectIdentifier(camera)).inserted { cameras.append(camera) }
        }
        for camera in session.cameraToVideo.keys { add(camera) }
        for group in session.frameGroups {
            for camera in group.frames.keys { add(camera) }
            for instanceGroup in group.instanceGroups {
                for camera in instanceGroup.instances.keys { add(camera) }
            }
        }
        return cameras.enumerated()
            .sorted { lhs, rhs in
                lhs.element.name != rhs.element.name
                    ? lhs.element.name < rhs.element.name
                    : lhs.offset < rhs.offset
            }
            .map { $0.element }
    }

    /// Convert `session` to its Python-compatible JSON dictionary.
    ///
    /// - Parameters:
    ///   - orderedCameras: The camera ordering from ``orderedCameras(for:)``.
    ///   - videoIndexMap: `Video` identity → index in `Labels.videos`.
    ///   - labeledFrameToIdx: `LabeledFrame` identity → index in
    ///     `Labels.labeledFrames`. When empty, `frame_group_dicts` is omitted
    ///     (mirroring Python's "skip frame groups when skipping frames").
    ///   - instanceToLfInst: `Instance` identity → `(labeledFrameIdx, instanceIdx)`.
    static func sessionDict(
        _ session: RecordingSession,
        orderedCameras: [Camera],
        videoIndexMap: [ObjectIdentifier: Int],
        labeledFrameToIdx: [ObjectIdentifier: Int],
        instanceToLfInst: [ObjectIdentifier: (Int, Int)]
    ) -> [String: Any] {
        // calibration: one entry per camera plus a (currently empty) metadata block.
        var calibration: [String: Any] = [:]
        for (index, camera) in orderedCameras.enumerated() {
            calibration["cam_\(index)"] = cameraDict(camera)
        }
        calibration["metadata"] = [String: Any]()

        // camcorder_to_video_idx_map + legacy camera_to_video array.
        var cameraToVideoIdx: [String: Any] = [:]
        var legacyCameraToVideo: [[String: Any]] = []
        for (index, camera) in orderedCameras.enumerated() {
            guard let video = session.cameraToVideo[camera],
                  let videoIdx = videoIndexMap[ObjectIdentifier(video)] else { continue }
            cameraToVideoIdx[String(index)] = videoIdx
            legacyCameraToVideo.append(["camera_name": camera.name, "video_idx": videoIdx])
        }

        // frame_group_dicts.
        var frameGroupDicts: [[String: Any]] = []
        if !labeledFrameToIdx.isEmpty {
            for group in session.frameGroups {
                let instanceGroups = instanceGroupDicts(
                    group, orderedCameras: orderedCameras, instanceToLfInst: instanceToLfInst)
                guard !instanceGroups.isEmpty else { continue }
                var groupDict: [String: Any] = ["instance_groups": instanceGroups]
                if let frameIdx = group.frames.values.first?.frameIndex {
                    groupDict["frame_idx"] = frameIdx
                }
                frameGroupDicts.append(groupDict)
            }
        }

        return [
            "calibration": calibration,
            "camcorder_to_video_idx_map": cameraToVideoIdx,
            "frame_group_dicts": frameGroupDicts,
            // Legacy key: recovered by the old-schema reader; ignored by the new one.
            "camera_to_video": legacyCameraToVideo,
        ]
    }

    /// Encode a single ``Camera`` to a `calibration` entry.
    ///
    /// Absent intrinsics/extrinsics are written as JSON `null` (and an absent
    /// ``Camera/size`` as `""`) so the entry keeps Python's fixed key shape.
    static func cameraDict(_ camera: Camera) -> [String: Any] {
        var dict: [String: Any] = ["name": camera.name]
        if let size = camera.size {
            dict["size"] = [size.width, size.height]
        } else {
            dict["size"] = ""
        }
        dict["matrix"] = camera.matrix.map(nestedMatrix) ?? NSNull()
        dict["distortions"] = camera.distortionCoefficients.map { coeffs in coeffs.map { Double($0) } as Any } ?? NSNull()
        dict["rotation"] = camera.rvec.map { rvec in rvec.map { Double($0) } as Any } ?? NSNull()
        dict["translation"] = camera.tvec.map { tvec in tvec.map { Double($0) } as Any } ?? NSNull()
        return dict
    }

    private static func instanceGroupDicts(
        _ group: FrameGroup,
        orderedCameras: [Camera],
        instanceToLfInst: [ObjectIdentifier: (Int, Int)]
    ) -> [[String: Any]] {
        var result: [[String: Any]] = []
        for instanceGroup in group.instanceGroups {
            var map: [String: Any] = [:]
            for (camera, instance) in instanceGroup.instances {
                guard let camIdx = orderedCameras.firstIndex(where: { $0 === camera }),
                      let (lfIdx, instIdx) = instanceToLfInst[ObjectIdentifier(instance)] else { continue }
                map[String(camIdx)] = [lfIdx, instIdx]
            }
            guard !map.isEmpty else { continue }
            var dict: [String: Any] = ["camcorder_to_lf_and_inst_idx_map": map]
            // Additive: persist the triangulated 3D pose when present so an
            // aggregated ``Instance3D`` survives the round-trip. Rows are `[x,y,z]`
            // for visible points and JSON `null` for missing ones (avoids NaN,
            // which `JSONSerialization` rejects). Python readers that don't model
            // this key simply ignore it.
            if let instance3D = instanceGroup.instance3D {
                dict["points"] = points3DArray(instance3D)
                if let score = instance3D.score {
                    dict["score"] = Double(score)
                }
            }
            result.append(dict)
        }
        return result
    }

    /// Encode an ``Instance3D`` as a list of per-node rows: `[x, y, z]` (doubles)
    /// for visible, finite points and `NSNull` for missing ones.
    private static func points3DArray(_ instance3D: Instance3D) -> [Any] {
        instance3D.points.map { point -> Any in
            guard point.visible, point.x.isFinite, point.y.isFinite, point.z.isFinite else {
                return NSNull()
            }
            return [Double(point.x), Double(point.y), Double(point.z)]
        }
    }

    private static func nestedMatrix(_ flat: [Float]) -> Any {
        guard flat.count == 9 else { return flat.map { Double($0) } }
        return [
            [Double(flat[0]), Double(flat[1]), Double(flat[2])],
            [Double(flat[3]), Double(flat[4]), Double(flat[5])],
            [Double(flat[6]), Double(flat[7]), Double(flat[8])],
        ]
    }

    // MARK: - Dictionary → session (read)

    /// Reconstruct a ``RecordingSession`` from one `sessions_json` entry.
    ///
    /// Prefers the modern `calibration` + `camcorder_to_video_idx_map`
    /// (+ `frame_group_dicts`) schema. When `calibration` is absent it falls
    /// back to the legacy `camera_to_video` array so old-schema files keep
    /// loading. Always returns a session (possibly empty), matching the prior
    /// reader's one-session-per-entry behavior.
    static func makeSession(
        from dict: [String: Any],
        videos: [Video],
        videoIdMap: [Int: Int],
        frames: FrameStore
    ) -> RecordingSession {
        let session = RecordingSession()

        if let calibration = dict["calibration"] as? [String: Any] {
            let orderedCameras = decodeCameras(from: calibration)

            if let map = dict["camcorder_to_video_idx_map"] as? [String: Any] {
                for (camIdxStr, videoIdxAny) in map {
                    guard let camIdx = Int(camIdxStr),
                          camIdx >= 0, camIdx < orderedCameras.count,
                          let videoIdxValue = doubleValue(videoIdxAny) else { continue }
                    guard let resolved = SLPVideoTable.resolvedIndex(
                        for: Int(videoIdxValue), videoIdMap: videoIdMap, videoCount: videos.count
                    ) else { continue }
                    session.cameraToVideo[orderedCameras[camIdx]] = videos[resolved]
                }
            }

            if let frameGroupDicts = dict["frame_group_dicts"] as? [[String: Any]] {
                for groupDict in frameGroupDicts {
                    if let group = decodeFrameGroup(
                        groupDict, orderedCameras: orderedCameras, frames: frames) {
                        session.frameGroups.append(group)
                    }
                }
            }
            return session
        }

        // Legacy schema: camera_to_video array of {camera_name, video_idx}.
        if let cameraVideos = dict["camera_to_video"] as? [[String: Any]] {
            for entry in cameraVideos {
                let camName = entry["camera_name"] as? String ?? "camera"
                let videoIdx = doubleValue(entry["video_idx"]).map { Int($0) } ?? 0
                guard let resolved = SLPVideoTable.resolvedIndex(
                    for: videoIdx, videoIdMap: videoIdMap, videoCount: videos.count
                ) else { continue }
                session.cameraToVideo[Camera(name: camName)] = videos[resolved]
            }
        }
        return session
    }

    /// Back-compat overload for callers holding a plain `[LabeledFrame]` array
    /// (the eager reader and unit tests). Wraps the array in an
    /// ``EagerFrameStore`` and delegates to the ``FrameStore`` implementation so
    /// both the eager and lazy paths share one decoder.
    static func makeSession(
        from dict: [String: Any],
        videos: [Video],
        videoIdMap: [Int: Int],
        frames: [LabeledFrame]
    ) -> RecordingSession {
        makeSession(
            from: dict, videos: videos, videoIdMap: videoIdMap,
            frames: EagerFrameStore(frames: frames))
    }

    /// Decode the ordered camera list from a `calibration` dictionary. Cameras
    /// are keyed `cam_0`, `cam_1`, … and returned sorted by that index; the
    /// `metadata` key (and any non-`cam_` key) is ignored.
    static func decodeCameras(from calibration: [String: Any]) -> [Camera] {
        var indexed: [(Int, Camera)] = []
        for (key, value) in calibration {
            guard key.hasPrefix("cam_"),
                  let idx = Int(key.dropFirst("cam_".count)),
                  let cameraDict = value as? [String: Any] else { continue }
            indexed.append((idx, makeCamera(from: cameraDict)))
        }
        return indexed.sorted { $0.0 < $1.0 }.map { $0.1 }
    }

    /// Decode a single ``Camera`` from a `calibration` entry, populating only the
    /// fields present (via ``Camera``'s existing public API).
    static func makeCamera(from dict: [String: Any]) -> Camera {
        let camera = Camera(name: dict["name"] as? String ?? "")
        camera.size = intPair(dict["size"])
        camera.matrix = flatMatrix(dict["matrix"])
        camera.distortionCoefficients = floatArray(dict["distortions"])
        camera.rvec = floatArray(dict["rotation"])
        camera.tvec = floatArray(dict["translation"])
        return camera
    }

    private static func decodeFrameGroup(
        _ dict: [String: Any],
        orderedCameras: [Camera],
        frames: FrameStore
    ) -> FrameGroup? {
        guard let instanceGroupDicts = dict["instance_groups"] as? [[String: Any]] else { return nil }
        let group = FrameGroup()
        for instanceGroupDict in instanceGroupDicts {
            guard let map = instanceGroupDict["camcorder_to_lf_and_inst_idx_map"] as? [String: Any]
            else { continue }
            let instanceGroup = InstanceGroup()
            for (camIdxStr, pairAny) in map {
                guard let camIdx = Int(camIdxStr),
                      camIdx >= 0, camIdx < orderedCameras.count,
                      let pair = pairAny as? [Any], pair.count == 2,
                      let lfValue = doubleValue(pair[0]),
                      let instValue = doubleValue(pair[1]) else { continue }
                let lfIdx = Int(lfValue), instIdx = Int(instValue)
                guard lfIdx >= 0, lfIdx < frames.count else { continue }
                // On a lazy store this materializes (and caches) just this frame,
                // so it stays identity-stable with later `labels[lfIdx]` access.
                let labeledFrame = frames.frame(at: lfIdx)
                guard instIdx >= 0, instIdx < labeledFrame.instances.count else { continue }
                let camera = orderedCameras[camIdx]
                instanceGroup.instances[camera] = labeledFrame.instances[instIdx]
                group.frames[camera] = labeledFrame
            }
            if !instanceGroup.instances.isEmpty {
                decodeInstance3D(from: instanceGroupDict, into: instanceGroup)
                group.instanceGroups.append(instanceGroup)
            }
        }
        return group
    }

    /// Reconstruct an ``Instance3D`` from the additive `points` (and optional
    /// `score`) keys written by ``points3DArray(_:)``.
    ///
    /// The skeleton and node order are taken from the group's already-decoded 2D
    /// instances. A `null` (or malformed) row decodes to a missing point. Does
    /// nothing when `points` is absent, empty, or does not match the node count.
    private static func decodeInstance3D(
        from dict: [String: Any],
        into instanceGroup: InstanceGroup
    ) {
        guard let rows = dict["points"] as? [Any],
              let skeleton = instanceGroup.instances.values.first?.skeleton,
              rows.count == skeleton.nodes.count else { return }
        var points: [Point3D] = []
        points.reserveCapacity(rows.count)
        for row in rows {
            if let coords = row as? [Any], coords.count == 3,
               let x = doubleValue(coords[0]),
               let y = doubleValue(coords[1]),
               let z = doubleValue(coords[2]) {
                points.append(Point3D(x: Float(x), y: Float(y), z: Float(z), visible: true))
            } else {
                points.append(.missing)
            }
        }
        let instance3D = Instance3D(skeleton: skeleton, points: points)
        if let score = doubleValue(dict["score"]) { instance3D.score = Float(score) }
        instanceGroup.instance3D = instance3D
    }

    // MARK: - JSON coercion helpers

    /// Read a matrix stored either as a nested `[[Double]]` (Python 3×3) or a
    /// flat numeric array, returning a flat row-major `[Float]`.
    static func flatMatrix(_ any: Any?) -> [Float]? {
        if let nested = any as? [[Any]] {
            var flat: [Float] = []
            for row in nested {
                for value in row {
                    guard let d = doubleValue(value) else { return nil }
                    flat.append(Float(d))
                }
            }
            return flat.isEmpty ? nil : flat
        }
        return floatArray(any)
    }

    /// Read a flat numeric array as `[Float]`, or `nil` for `null`/absent/non-array.
    static func floatArray(_ any: Any?) -> [Float]? {
        guard let array = any as? [Any] else { return nil }
        var out: [Float] = []
        out.reserveCapacity(array.count)
        for value in array {
            guard let d = doubleValue(value) else { return nil }
            out.append(Float(d))
        }
        return out.isEmpty ? nil : out
    }

    private static func intPair(_ any: Any?) -> (width: Int, height: Int)? {
        guard let array = any as? [Any], array.count == 2,
              let w = doubleValue(array[0]), let h = doubleValue(array[1]) else { return nil }
        return (Int(w), Int(h))
    }

    private static func doubleValue(_ any: Any?) -> Double? {
        switch any {
        case let d as Double: return d
        case let i as Int: return Double(i)
        case let n as NSNumber: return n.doubleValue
        default: return nil
        }
    }
}
