import Foundation

/// `clean()` and `removePredictions()` mirror sleap-io's `Labels.clean` /
/// `Labels.remove_predictions` (labels.py).
///
/// Both operations mutate the frame list and identity tables, so they require an
/// eager (materialized) store. If the store is lazy, it is materialized first via
/// ``Labels/materialize()``.
extension Labels {

    /// Whether an instance has no visible points and is therefore considered "empty".
    ///
    /// Mirrors the upstream notion used by `Labels.clean` of an instance with no
    /// visible landmarks. (Standalone helper so this file remains new-file-only; once
    /// `Instance.isEmpty` lands from E2.2 it carries identical semantics.)
    private static func isEmptyInstance(_ instance: Instance) -> Bool {
        !instance.points.visibility.contains(true)
    }

    /// Remove empty frames/instances and prune unreferenced identity-table entries.
    ///
    /// - Parameters:
    ///   - frames: When `true`, remove frames that end up with no instances —
    ///     **except** frames explicitly marked ``LabeledFrame/isNegative``, which are
    ///     always preserved. Note this prunes on *instance presence*, not on
    ///     ``LabeledFrame/kind``: a prediction-only frame (classified
    ///     ``LabeledFrame/Kind/empty``) still has instances and is retained; only
    ///     frames with zero instances that are not negative are dropped.
    ///   - instances: When `true`, remove instances that have no visible points.
    ///   - skeletons: When `true`, remove skeletons no longer referenced by any
    ///     remaining instance.
    ///   - tracks: When `true`, remove tracks no longer referenced by any remaining
    ///     instance.
    ///   - videos: When `true`, remove videos no longer referenced by any remaining
    ///     frame.
    ///
    /// Lazy stores are materialized before mutation.
    public func clean(frames: Bool = true,
                      instances: Bool = false,
                      skeletons: Bool = true,
                      tracks: Bool = true,
                      videos: Bool = false) throws {
        // This operation mutates the frame list, so it needs an eager store.
        materialize()

        var remainingFrames = frameStore.allFrames()

        // 1. Remove instances with no visible points.
        if instances {
            for frame in remainingFrames {
                frame.instances.removeAll { Labels.isEmptyInstance($0) }
            }
        }

        // 2. Remove frames that ended up empty, preserving negative frames.
        if frames {
            remainingFrames = remainingFrames.filter { frame in
                !frame.instances.isEmpty || frame.isNegative
            }
        }

        // Rebuild the eager frame store from what remains.
        try setFrames(remainingFrames)

        // 3. Prune unreferenced identity tables from what remains.
        if videos {
            var referenced = Set<ObjectIdentifier>()
            for frame in remainingFrames {
                referenced.insert(ObjectIdentifier(frame.video))
            }
            let oldVideos = self.videos
            let newVideos = oldVideos.filter { referenced.contains(ObjectIdentifier($0)) }
            let indexMap = Self.identityIndexMap(from: oldVideos, to: newVideos)

            rois = rois.compactMap { roi in
                var remapped = roi
                guard Self.remapRequiredIndex(&remapped.videoIndex, using: indexMap) else {
                    return nil
                }
                return remapped
            }
            masks = masks.compactMap { mask in
                var remapped = mask
                guard Self.remapRequiredIndex(&remapped.videoIndex, using: indexMap) else {
                    return nil
                }
                return remapped
            }

            try setVideos(newVideos)
        }

        if skeletons {
            var referenced = Set<ObjectIdentifier>()
            for frame in remainingFrames {
                for inst in frame.instances {
                    referenced.insert(ObjectIdentifier(inst.skeleton))
                }
            }
            try setSkeletons(self.skeletons.filter { referenced.contains(ObjectIdentifier($0)) })
        }

        if tracks {
            var referenced = Set<ObjectIdentifier>()
            for frame in remainingFrames {
                for inst in frame.instances {
                    if let track = inst.track {
                        referenced.insert(ObjectIdentifier(track))
                    }
                }
            }
            let oldTracks = self.tracks
            let newTracks = oldTracks.filter { referenced.contains(ObjectIdentifier($0)) }
            let indexMap = Self.identityIndexMap(from: oldTracks, to: newTracks)

            rois = rois.map { roi in
                var remapped = roi
                Self.remapOptionalIndex(&remapped.trackIndex, using: indexMap)
                return remapped
            }
            masks = masks.map { mask in
                var remapped = mask
                Self.remapOptionalIndex(&remapped.trackIndex, using: indexMap)
                return remapped
            }

            try setTracks(newTracks)
        }
    }

    /// Remove all predicted instances from every frame.
    ///
    /// - Parameter clean: When `true`, run ``clean()`` afterward to drop frames and
    ///   identity-table entries that became empty/unreferenced once predictions were
    ///   stripped.
    ///
    /// Lazy stores are materialized before mutation.
    public func removePredictions(clean: Bool = true) throws {
        materialize()

        for frame in frameStore.allFrames() {
            frame.instances.removeAll { $0 is PredictedInstance }
        }

        if clean {
            try self.clean()
        }
    }

    /// Replace the eager frame store with the given frames.
    ///
    /// Assumes the store is already eager (callers materialize first).
    private func setFrames(_ frames: [LabeledFrame]) throws {
        guard let eager = frameStore as? EagerFrameStore else {
            throw SleapIOError.mutationWhileLazy(
                "Cannot replace frames while lazy. Call materialize() first."
            )
        }
        eager.frames = frames
    }

    private static func identityIndexMap<T: AnyObject>(from oldItems: [T], to newItems: [T]) -> [Int: Int?] {
        var newIndexByID: [ObjectIdentifier: Int] = [:]
        for (newIndex, item) in newItems.enumerated() {
            newIndexByID[ObjectIdentifier(item)] = newIndex
        }
        var map: [Int: Int?] = [:]
        for (oldIndex, item) in oldItems.enumerated() {
            map[oldIndex] = newIndexByID[ObjectIdentifier(item)]
        }
        return map
    }

    private static func remapRequiredIndex(_ index: inout Int?, using map: [Int: Int?]) -> Bool {
        guard let oldIndex = index else { return true }
        guard let mapped = map[oldIndex], let newIndex = mapped else { return false }
        index = newIndex
        return true
    }

    private static func remapOptionalIndex(_ index: inout Int?, using map: [Int: Int?]) {
        guard let oldIndex = index else { return }
        index = map[oldIndex] ?? nil
    }
}
