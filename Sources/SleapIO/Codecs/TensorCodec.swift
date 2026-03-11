import Foundation

/// Labels.numpy() equivalent — converts Labels to a 4D tensor [frames, tracks, nodes, 2+].
///
/// The output shape matches Python's `labels.numpy()`:
/// - Axis 0: frames (ordered by frame index)
/// - Axis 1: tracks (ordered by track list)
/// - Axis 2: nodes (ordered by skeleton)
/// - Axis 3: channels (x, y, [score])
///
/// Missing data (no instance for a track in a frame) is filled with NaN.
public struct TensorCodec {

    /// Result of tensor conversion.
    public struct Tensor4D: Sendable {
        /// Flat row-major array of shape [frames * tracks * nodes * channels].
        public let data: ContiguousArray<Float>
        public let frameCount: Int
        public let trackCount: Int
        public let nodeCount: Int
        public let channels: Int

        /// Access element at [frame, track, node, channel].
        public subscript(frame: Int, track: Int, node: Int, channel: Int) -> Float {
            data[((frame * trackCount + track) * nodeCount + node) * channels + channel]
        }

        /// Shape as an array: [frameCount, trackCount, nodeCount, channels].
        public var shape: [Int] { [frameCount, trackCount, nodeCount, channels] }
    }

    /// Convert Labels to a 4D tensor.
    /// - Parameters:
    ///   - labels: The Labels to convert.
    ///   - includeScores: If true, output has 3 channels (x, y, score). Otherwise 2 (x, y).
    /// - Returns: A Tensor4D with the converted data.
    public static func toTensor(_ labels: Labels, includeScores: Bool = false) -> Tensor4D {
        let skeleton = labels.skeleton
        let nodeCount = skeleton?.nodes.count ?? 0
        let trackCount = max(labels.tracks.count, 1) // At least 1 for untracked instances
        let frameCount = labels.frameStore.count
        let channels = includeScores ? 3 : 2

        let totalSize = frameCount * trackCount * nodeCount * channels
        var data = ContiguousArray<Float>(repeating: Float.nan, count: totalSize)

        // Build track index map
        var trackIndexMap: [ObjectIdentifier: Int] = [:]
        for (i, t) in labels.tracks.enumerated() { trackIndexMap[ObjectIdentifier(t)] = i }

        for frameIdx in 0..<frameCount {
            let frame = labels.frameStore.frame(at: frameIdx)

            for instance in frame.instances {
                let trackIdx: Int
                if let track = instance.track, let idx = trackIndexMap[ObjectIdentifier(track)] {
                    trackIdx = idx
                } else {
                    trackIdx = 0 // untracked goes to slot 0
                }

                for nodeIdx in 0..<min(instance.points.count, nodeCount) {
                    let baseIdx = ((frameIdx * trackCount + trackIdx) * nodeCount + nodeIdx) * channels
                    data[baseIdx] = instance.points.coordinates[nodeIdx * 2]
                    data[baseIdx + 1] = instance.points.coordinates[nodeIdx * 2 + 1]
                    if includeScores && channels > 2 {
                        if let pred = instance as? PredictedInstance {
                            data[baseIdx + 2] = pred.predictedPoints.scores[nodeIdx]
                        } else {
                            data[baseIdx + 2] = 1.0
                        }
                    }
                }
            }
        }

        return Tensor4D(data: data, frameCount: frameCount,
                        trackCount: trackCount, nodeCount: nodeCount, channels: channels)
    }
}
