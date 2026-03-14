import Foundation
import SleapIO
import SleapVideo

enum SLPVideoTable {
    static func readVideosAndIdMap(from file: HDF5File) throws -> (videos: [Video], videoIdMap: [Int: Int]) {
        guard file.exists(name: "videos_json") else {
            return ([], [:])
        }

        let ds = try file.openDataset(name: "videos_json")
        let strings = try ds.readVLenStrings()

        var videos: [Video] = []
        var videoIdMap: [Int: Int] = [:]
        videos.reserveCapacity(strings.count)

        for (index, str) in strings.enumerated() {
            guard let data = str.data(using: .utf8),
                  let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw SleapIOError.corruptData("Invalid video JSON: \(str)")
            }

            let persistedID = dict["id"] as? Int ?? index
            videos.append(decodeVideo(from: dict))
            videoIdMap[persistedID] = index
        }

        return (videos, videoIdMap)
    }

    static func decodeVideo(from dict: [String: Any]) -> Video {
        let backend = dict["backend"] as? [String: Any] ?? [:]
        let filename = backend["filename"] as? String ?? dict["filename"] as? String ?? ""

        var backendType = "media"
        if let type = backend["type"] as? String {
            backendType = type
        } else if filename == "." {
            backendType = "hdf5"
        }

        let video = Video(filename: filename, backendType: backendType, backendMetadata: backend)

        // Extract frame count and size from backend shape if available.
        // Python sleap-io stores shape as [num_frames, height, width, channels].
        if let shape = backend["shape"] as? [Int], shape.count >= 4 {
            video.frameCount = shape[0]
            video.frameSize = (height: shape[1], width: shape[2], channels: shape[3])
        }

        return video
    }

    static func configureBackends(
        for videos: [Video],
        filePath: String,
        formatId: Float
    ) throws {
        for (index, video) in videos.enumerated()
            where video.backendType.lowercased().hasPrefix("hdf5") {
            video.backendOpener = {
                try SleapHDF5EmbeddedVideoBackend(
                    path: filePath,
                    videoIndex: index,
                    formatId: formatId
                )
            }

            guard let backend = try? SleapHDF5EmbeddedVideoBackend(
                path: filePath,
                videoIndex: index,
                formatId: formatId
            ) else {
                continue
            }
            video.backend = backend

            if let count = backend.frameCount {
                video.frameCount = count
            }
            if let size = backend.frameSize {
                video.frameSize = size
            }
        }
    }

    static func resolvedIndex(for rawID: Int, videoIdMap: [Int: Int], videoCount: Int) -> Int? {
        let resolved = videoIdMap[rawID] ?? rawID
        guard resolved >= 0 && resolved < videoCount else {
            return nil
        }
        return resolved
    }

    static func validateReferencedVideoIDs(
        _ rawIDs: [Int],
        videoIdMap: [Int: Int],
        videoCount: Int
    ) throws {
        for rawID in rawIDs {
            guard resolvedIndex(for: rawID, videoIdMap: videoIdMap, videoCount: videoCount) != nil else {
                throw SleapIOError.corruptData("Frame references unknown video id \(rawID)")
            }
        }
    }

    static func validateReferencedVideoIDs(
        _ rawIDs: ContiguousArray<UInt32>,
        videoIdMap: [Int: Int],
        videoCount: Int
    ) throws {
        try validateReferencedVideoIDs(rawIDs.map(Int.init), videoIdMap: videoIdMap, videoCount: videoCount)
    }
}
