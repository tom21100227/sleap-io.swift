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
    ///     always preserved.
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
                      instances: Bool = true,
                      skeletons: Bool = true,
                      tracks: Bool = true,
                      videos: Bool = true) throws {
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
            try setVideos(self.videos.filter { referenced.contains(ObjectIdentifier($0)) })
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
            try setTracks(self.tracks.filter { referenced.contains(ObjectIdentifier($0)) })
        }
    }

    /// Remove all predicted instances from every frame.
    ///
    /// - Parameter clean: When `true`, run ``clean()`` afterward to drop frames and
    ///   identity-table entries that became empty/unreferenced once predictions were
    ///   stripped.
    ///
    /// Lazy stores are materialized before mutation.
    public func removePredictions(clean: Bool = false) throws {
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
}
