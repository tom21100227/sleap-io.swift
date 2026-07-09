import Foundation

// E1.5: Count accessors used by sidebars / QC, mirroring Python `Labels`.
// Instance counts are O(1) on the lazy store; the per-track count and
// `userLabeledFrames` iterate frames (materializing lazy frames).

extension Labels {

    /// Total number of user-labeled (non-predicted) instances across all frames.
    /// O(1) when lazy (derived from column-store row counts).
    /// Mirrors `Labels.n_user_instances`.
    public var nUserInstances: Int {
        instanceCount - predictedInstanceCount
    }

    /// Total number of predicted instances across all frames.
    /// O(1) when lazy. Mirrors `Labels.n_pred_instances`.
    public var nPredInstances: Int {
        predictedInstanceCount
    }

    /// Number of labeled frames for each video.
    ///
    /// Uses ``frameMetadata()`` so it does not materialize frames when lazy.
    /// Mirrors `Labels.n_frames_per_video`.
    public func nFramesPerVideo() -> [Video: Int] {
        var perIndex = [Int: Int]()
        for m in frameMetadata() {
            perIndex[m.videoIndex, default: 0] += 1
        }
        var counts = [Video: Int]()
        for (i, v) in videos.enumerated() {
            counts[v] = perIndex[i] ?? 0
        }
        return counts
    }

    /// Number of instances for each track. Untracked instances are not counted.
    ///
    /// Iterates instances, so this materializes lazy frames. Mirrors
    /// `Labels.n_instances_per_track`.
    public func nInstancesPerTrack() -> [Track: Int] {
        var counts = [Track: Int]()
        for t in tracks { counts[t] = 0 }
        for i in 0..<frameCount {
            for inst in self[i].instances {
                if let t = inst.track {
                    counts[t, default: 0] += 1
                }
            }
        }
        return counts
    }

    /// Frames containing at least one user-labeled instance.
    ///
    /// Iterates frames, so this materializes lazy frames. Mirrors
    /// `Labels.user_labeled_frames`.
    public var userLabeledFrames: [LabeledFrame] {
        (0..<frameCount).map { self[$0] }.filter { $0.hasUserInstances }
    }
}
