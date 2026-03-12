import Foundation
import SleapIO

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

        return Video(filename: filename, backendType: backendType, backendMetadata: backend)
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
