import Foundation

extension Labels {

    /// Produce a deep, identity-preserving clone of this `Labels`.
    ///
    /// Every identity object (``Video``, ``Skeleton``, ``Node``, ``Track``,
    /// ``LabeledFrame``, ``Instance`` / ``PredictedInstance``) is reconstructed as a
    /// new object, and value types (``PointsArray``, ``PredictedPointsArray``,
    /// ``ROI``, ``SegmentationMask``, ``SuggestionFrame``, provenance) are copied.
    ///
    /// The clone is internally consistent via object-identity dedup: a cloned
    /// frame's `video` is the same object as the corresponding entry in the
    /// clone's `videos` table, and a cloned instance's `skeleton` / `track`
    /// are the same objects as the corresponding entries in the clone's
    /// `skeletons` / `tracks` tables.
    ///
    /// Mirrors `Labels.copy(open_videos)` in upstream sleap-io.
    ///
    /// If this `Labels` is lazy, it is materialized first (mutating `self`) so
    /// that all frames are available for cloning.
    ///
    /// - Note: `Instance.fromPredicted` links are remapped when the target
    ///   predicted instance lives in the same frame as the user instance. Links
    ///   pointing to a predicted instance that cannot be located among the cloned
    ///   instances are left `nil`.
    ///
    /// - Returns: A new, fully independent `Labels`.
    public func copy() -> Labels {
        // Materialize lazy storage so every frame can be cloned.
        materialize()

        // MARK: Clone identity tables.

        // Videos: clone each, then wire up sourceVideo references via the map.
        var videoMap: [ObjectIdentifier: Video] = [:]
        videoMap.reserveCapacity(videos.count)
        var clonedVideos: [Video] = []
        clonedVideos.reserveCapacity(videos.count)
        for video in videos {
            let cloned = Self.cloneVideoShell(video)
            videoMap[ObjectIdentifier(video)] = cloned
            clonedVideos.append(cloned)
        }
        // Remap sourceVideo to the cloned source where it exists in the table;
        // otherwise clone the orphaned source standalone so the link is preserved.
        for video in videos {
            guard let source = video.sourceVideo else { continue }
            let clonedSelf = videoMap[ObjectIdentifier(video)]!
            if let mappedSource = videoMap[ObjectIdentifier(source)] {
                clonedSelf.sourceVideo = mappedSource
            } else {
                clonedSelf.sourceVideo = Self.cloneVideoShell(source)
            }
        }

        // Skeletons: clone with new nodes and remapped edges/symmetries.
        var skeletonMap: [ObjectIdentifier: Skeleton] = [:]
        skeletonMap.reserveCapacity(skeletons.count)
        var clonedSkeletons: [Skeleton] = []
        clonedSkeletons.reserveCapacity(skeletons.count)
        for skeleton in skeletons {
            let cloned = Self.cloneSkeleton(skeleton)
            skeletonMap[ObjectIdentifier(skeleton)] = cloned
            clonedSkeletons.append(cloned)
        }

        // Tracks: clone by name.
        var trackMap: [ObjectIdentifier: Track] = [:]
        trackMap.reserveCapacity(tracks.count)
        var clonedTracks: [Track] = []
        clonedTracks.reserveCapacity(tracks.count)
        for track in tracks {
            let cloned = Track(name: track.name)
            trackMap[ObjectIdentifier(track)] = cloned
            clonedTracks.append(cloned)
        }

        // Helper closures that fall back to cloning an off-table object if an
        // instance/frame references an identity object missing from the tables.
        func mappedVideo(_ video: Video) -> Video {
            if let v = videoMap[ObjectIdentifier(video)] { return v }
            let v = Self.cloneVideoShell(video)
            videoMap[ObjectIdentifier(video)] = v
            return v
        }
        func mappedSkeleton(_ skeleton: Skeleton) -> Skeleton {
            if let s = skeletonMap[ObjectIdentifier(skeleton)] { return s }
            let s = Self.cloneSkeleton(skeleton)
            skeletonMap[ObjectIdentifier(skeleton)] = s
            return s
        }
        func mappedTrack(_ track: Track) -> Track {
            if let t = trackMap[ObjectIdentifier(track)] { return t }
            let t = Track(name: track.name)
            trackMap[ObjectIdentifier(track)] = t
            return t
        }

        // MARK: Clone frames and instances.

        // Track original-instance -> cloned-instance to remap fromPredicted links.
        var instanceMap: [ObjectIdentifier: Instance] = [:]

        var clonedFrames: [LabeledFrame] = []
        clonedFrames.reserveCapacity(frameStore.count)

        for i in 0..<frameStore.count {
            let frame = frameStore.frame(at: i)
            let clonedFrameVideo = mappedVideo(frame.video)

            var clonedInstances: [Instance] = []
            clonedInstances.reserveCapacity(frame.instances.count)
            for inst in frame.instances {
                let clonedSkeleton = mappedSkeleton(inst.skeleton)
                let clonedTrack = inst.track.map { mappedTrack($0) }
                let clonedInst = inst.clone(skeleton: clonedSkeleton,
                                            track: clonedTrack)
                instanceMap[ObjectIdentifier(inst)] = clonedInst
                clonedInstances.append(clonedInst)
            }

            let clonedFrame = LabeledFrame(video: clonedFrameVideo,
                                           frameIndex: frame.frameIndex,
                                           instances: clonedInstances,
                                           isNegative: frame.isNegative)
            clonedFrames.append(clonedFrame)
        }

        // Second pass: remap fromPredicted links where the target was cloned.
        for i in 0..<frameStore.count {
            let frame = frameStore.frame(at: i)
            for inst in frame.instances {
                guard let target = inst.fromPredicted,
                      let clonedInst = instanceMap[ObjectIdentifier(inst)],
                      let clonedTarget = instanceMap[ObjectIdentifier(target)]
                        as? PredictedInstance else { continue }
                clonedInst.fromPredicted = clonedTarget
            }
        }

        // MARK: Copy metadata (value types remapped to cloned identity objects).

        let clonedSuggestions: [SuggestionFrame] = suggestions.map { s in
            SuggestionFrame(video: mappedVideo(s.video),
                            frameIndex: s.frameIndex,
                            group: s.group)
        }

        // Sessions reference cameras/videos; remap their video mappings to the
        // cloned videos while preserving camera identity (cameras are not part of
        // the top-level identity tables, so they are shared by reference).
        let clonedSessions: [RecordingSession] = sessions.map { session in
            var remapped: [Camera: Video] = [:]
            for (camera, video) in session.cameraToVideo {
                remapped[camera] = mappedVideo(video)
            }
            return RecordingSession(cameraToVideo: remapped)
        }

        // ROIs and masks are value structs; copy by value.
        let clonedROIs = rois
        let clonedMasks = masks
        let clonedProvenance = provenance

        let store = EagerFrameStore(frames: clonedFrames)

        // Re-collect the deduped identity tables (in case off-table objects were
        // discovered while cloning frames). Preserve original table ordering and
        // append any newly discovered objects.
        let finalVideos = Self.collectTable(original: videos, map: videoMap)
        let finalSkeletons = Self.collectTable(original: skeletons, map: skeletonMap)
        let finalTracks = Self.collectTable(original: tracks, map: trackMap)

        return Labels(
            frameStore: store,
            videos: finalVideos,
            skeletons: finalSkeletons,
            tracks: finalTracks,
            suggestions: clonedSuggestions,
            sessions: clonedSessions,
            provenance: clonedProvenance,
            rois: clonedROIs,
            masks: clonedMasks
        )
    }

    // MARK: - Private clone helpers

    /// Clone a video's own scalar state (not its `sourceVideo`, wired separately).
    private static func cloneVideoShell(_ video: Video) -> Video {
        let cloned = Video(filename: video.originalFilename,
                           backendType: video.backendType,
                           backendMetadata: video.backendMetadata)
        cloned.persistedFilename = video.persistedFilename
        cloned.frameCount = video.frameCount
        cloned.frameSize = video.frameSize
        return cloned
    }

    /// Clone a skeleton with brand-new `Node` objects and edges/symmetries
    /// remapped onto those new nodes.
    private static func cloneSkeleton(_ skeleton: Skeleton) -> Skeleton {
        var nodeMap: [ObjectIdentifier: Node] = [:]
        nodeMap.reserveCapacity(skeleton.nodes.count)
        let clonedNodes: [Node] = skeleton.nodes.map { node in
            let cloned = Node(name: node.name)
            nodeMap[ObjectIdentifier(node)] = cloned
            return cloned
        }

        let clonedEdges: [Edge] = skeleton.edges.compactMap { edge in
            guard let src = nodeMap[ObjectIdentifier(edge.source)],
                  let dst = nodeMap[ObjectIdentifier(edge.destination)] else { return nil }
            return Edge(source: src, destination: dst)
        }

        let clonedSymmetries: [Symmetry] = skeleton.symmetries.compactMap { sym in
            guard let a = nodeMap[ObjectIdentifier(sym.nodeA)],
                  let b = nodeMap[ObjectIdentifier(sym.nodeB)] else { return nil }
            return Symmetry(a, b)
        }

        return Skeleton(name: skeleton.name,
                        nodes: clonedNodes,
                        edges: clonedEdges,
                        symmetries: clonedSymmetries)
    }

    /// Reassemble a cloned identity table preserving original order and appending
    /// any objects discovered during frame cloning that were not in the original
    /// table.
    private static func collectTable<T: AnyObject>(original: [T],
                                                   map: [ObjectIdentifier: T]) -> [T] {
        var result: [T] = []
        result.reserveCapacity(map.count)
        var seen = Set<ObjectIdentifier>()
        for obj in original {
            if let cloned = map[ObjectIdentifier(obj)] {
                result.append(cloned)
                seen.insert(ObjectIdentifier(cloned))
            }
        }
        for (_, cloned) in map where !seen.contains(ObjectIdentifier(cloned)) {
            result.append(cloned)
            seen.insert(ObjectIdentifier(cloned))
        }
        return result
    }
}
