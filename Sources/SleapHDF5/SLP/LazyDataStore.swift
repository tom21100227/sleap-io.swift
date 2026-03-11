import Foundation
import CHDF5
import SleapIO

/// Column arrays for /frames dataset.
struct FrameColumns {
    var video: ContiguousArray<UInt32>
    var frameIdx: ContiguousArray<UInt64>
    var instanceIdStart: ContiguousArray<UInt64>
    var instanceIdEnd: ContiguousArray<UInt64>

    var count: Int { video.count }
}

/// Column arrays for /instances dataset.
struct InstanceColumns {
    var instanceType: ContiguousArray<UInt8>
    var skeleton: ContiguousArray<UInt32>
    var track: ContiguousArray<Int32>
    var fromPredicted: ContiguousArray<Int64>
    var score: ContiguousArray<Float>
    var pointIdStart: ContiguousArray<UInt64>
    var pointIdEnd: ContiguousArray<UInt64>
    var trackingScore: ContiguousArray<Float>

    var count: Int { instanceType.count }
}

/// Column arrays for /points dataset (user points).
struct PointColumns {
    var x: ContiguousArray<Double>
    var y: ContiguousArray<Double>
    var visible: ContiguousArray<Bool>
    var complete: ContiguousArray<Bool>

    var count: Int { x.count }

    func copySlice(start: Int, end: Int, skeleton: Skeleton) -> PointsArray {
        let n = end - start
        var coords = ContiguousArray<Float>(repeating: 0, count: n * 2)
        var vis = ContiguousArray<Bool>(repeating: false, count: n)
        var comp = ContiguousArray<Bool>(repeating: false, count: n)
        for i in 0..<n {
            let srcIdx = start + i
            coords[i * 2] = Float(x[srcIdx])
            coords[i * 2 + 1] = Float(y[srcIdx])
            vis[i] = visible[srcIdx]
            comp[i] = complete[srcIdx]
        }
        var pts = PointsArray(coordinates: coords, visibility: vis, completeness: comp)
        pts.skeleton = skeleton
        return pts
    }
}

/// Column arrays for /pred_points dataset.
struct PredPointColumns {
    var x: ContiguousArray<Double>
    var y: ContiguousArray<Double>
    var visible: ContiguousArray<Bool>
    var complete: ContiguousArray<Bool>
    var scores: ContiguousArray<Double>

    var count: Int { x.count }

    func copySlice(start: Int, end: Int, skeleton: Skeleton) -> (PointsArray, ContiguousArray<Float>) {
        let n = end - start
        var coords = ContiguousArray<Float>(repeating: 0, count: n * 2)
        var vis = ContiguousArray<Bool>(repeating: false, count: n)
        var comp = ContiguousArray<Bool>(repeating: false, count: n)
        var sc = ContiguousArray<Float>(repeating: 0, count: n)
        for i in 0..<n {
            let srcIdx = start + i
            coords[i * 2] = Float(x[srcIdx])
            coords[i * 2 + 1] = Float(y[srcIdx])
            vis[i] = visible[srcIdx]
            comp[i] = complete[srcIdx]
            sc[i] = Float(scores[srcIdx])
        }
        var pts = PointsArray(coordinates: coords, visibility: vis, completeness: comp)
        pts.skeleton = skeleton
        return (pts, sc)
    }
}

/// Holds raw column arrays read from HDF5 — the lazy backing store.
final class LazyDataStore {
    let framesData: FrameColumns
    let instancesData: InstanceColumns
    let pointsData: PointColumns
    let predPointsData: PredPointColumns

    let videos: [Video]
    let skeletons: [Skeleton]
    let tracks: [Track]
    let formatId: Float

    /// Video ID remap table.
    let videoIdMap: [Int: Int]

    init(framesData: FrameColumns, instancesData: InstanceColumns,
         pointsData: PointColumns, predPointsData: PredPointColumns,
         videos: [Video], skeletons: [Skeleton], tracks: [Track],
         formatId: Float, videoIdMap: [Int: Int]) {
        self.framesData = framesData
        self.instancesData = instancesData
        self.pointsData = pointsData
        self.predPointsData = predPointsData
        self.videos = videos
        self.skeletons = skeletons
        self.tracks = tracks
        self.formatId = formatId
        self.videoIdMap = videoIdMap
    }

    /// Materialize a single frame from column data.
    func materializeFrame(at index: Int) -> LabeledFrame {
        let videoRaw = Int(framesData.video[index])
        let videoIdx = videoIdMap[videoRaw] ?? videoRaw
        let video = videos[min(videoIdx, videos.count - 1)]
        let frameIdx = Int(framesData.frameIdx[index])

        let instStart = Int(framesData.instanceIdStart[index])
        let instEnd = Int(framesData.instanceIdEnd[index])

        var instances: [Instance] = []
        instances.reserveCapacity(instEnd - instStart)

        for iIdx in instStart..<instEnd {
            instances.append(materializeInstance(at: iIdx))
        }

        // Resolve from_predicted within this frame's instances
        for iIdx in instStart..<instEnd {
            let localIdx = iIdx - instStart
            let fromPredIdx = Int(instancesData.fromPredicted[iIdx])
            if fromPredIdx >= 0 && fromPredIdx < instEnd {
                // The from_predicted index is global across all instances
                let fromPredLocalIdx = fromPredIdx - instStart
                if fromPredLocalIdx >= 0 && fromPredLocalIdx < instances.count,
                   let predicted = instances[fromPredLocalIdx] as? PredictedInstance {
                    instances[localIdx].fromPredicted = predicted
                }
            }
        }

        return LabeledFrame(video: video, frameIndex: frameIdx, instances: instances)
    }

    /// Materialize a single instance from column data.
    func materializeInstance(at index: Int) -> Instance {
        let skelIdx = Int(instancesData.skeleton[index])
        let skeleton = skeletons[min(skelIdx, skeletons.count - 1)]

        let trackRaw = instancesData.track[index]
        let track: Track? = trackRaw >= 0 && Int(trackRaw) < tracks.count
            ? tracks[Int(trackRaw)] : nil

        let trackingScore: Float? = instancesData.trackingScore[index] != 0
            ? instancesData.trackingScore[index] : nil

        let isUser = instancesData.instanceType[index] == 0
        let start = Int(instancesData.pointIdStart[index])
        let end = Int(instancesData.pointIdEnd[index])

        if isUser {
            let pts = pointsData.copySlice(start: start, end: end, skeleton: skeleton)

            // Apply coordinate adjustment for pre-1.1 format
            var adjustedPts = pts
            if formatId < 1.1 {
                for i in 0..<adjustedPts.count {
                    adjustedPts.coordinates[i * 2] -= 0.5
                    adjustedPts.coordinates[i * 2 + 1] -= 0.5
                }
            }

            return Instance(skeleton: skeleton, points: adjustedPts,
                          track: track, trackingScore: trackingScore)
        } else {
            let (pts, scores) = predPointsData.copySlice(start: start, end: end, skeleton: skeleton)

            var adjustedPts = pts
            if formatId < 1.1 {
                for i in 0..<adjustedPts.count {
                    adjustedPts.coordinates[i * 2] -= 0.5
                    adjustedPts.coordinates[i * 2 + 1] -= 0.5
                }
            }

            let predPts = PredictedPointsArray(pointsArray: adjustedPts, scores: scores)
            let score = instancesData.score[index]
            return PredictedInstance(skeleton: skeleton, points: predPts,
                                   score: score, track: track,
                                   trackingScore: trackingScore)
        }
    }
}
