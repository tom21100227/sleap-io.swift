import Foundation
import SleapIO

/// Standalone skeleton file load/save helpers.
public struct SkeletonFileCodec {

    /// Load a standalone skeleton JSON file, or extract the first embedded
    /// skeleton from a known training-config JSON structure.
    public static func loadSkeleton(from url: URL) throws -> Skeleton {
        switch url.pathExtension.lowercased() {
        case "json":
            let data = try Data(contentsOf: url)
            guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw SleapIOError.corruptData("Skeleton JSON root must be an object")
            }
            guard let skeletonDict = firstSkeletonDictionary(in: root) else {
                throw SleapIOError.corruptData("No skeleton found in \(url.lastPathComponent)")
            }
            return try SkeletonCodec.decodeFromNetworkX(skeletonDict)
        case "yaml", "yml":
            throw SleapIOError.unsupportedFormat(
                "YAML skeleton files are not supported because the package has no general YAML parser/emitter.")
        default:
            throw SleapIOError.unsupportedFormat(
                "Unsupported skeleton file extension: .\(url.pathExtension)")
        }
    }

    /// Save a standalone skeleton using the same NetworkX/jsonpickle-compatible
    /// dictionary shape used in SLP metadata.
    public static func saveSkeleton(_ skeleton: Skeleton, to url: URL) throws {
        switch url.pathExtension.lowercased() {
        case "json":
            let dict = SkeletonCodec.encodeToNetworkX(skeleton)
            let data = try JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: url)
        case "yaml", "yml":
            throw SleapIOError.unsupportedFormat(
                "YAML skeleton files are not supported because the package has no general YAML parser/emitter.")
        default:
            throw SleapIOError.unsupportedFormat(
                "Unsupported skeleton file extension: .\(url.pathExtension)")
        }
    }

    private static func firstSkeletonDictionary(in root: [String: Any]) -> [String: Any]? {
        if looksLikeSkeleton(root) {
            return root
        }
        if let skeletons = root["skeletons"] as? [[String: Any]], let first = skeletons.first {
            return first
        }
        if let data = root["data"] as? [String: Any],
           let labels = data["labels"] as? [String: Any],
           let skeletons = labels["skeletons"] as? [[String: Any]],
           let first = skeletons.first {
            return first
        }
        if let model = root["model"] as? [String: Any],
           let heads = model["heads"] as? [String: Any],
           let first = firstSkeletonDictionaryRecursively(in: heads) {
            return first
        }
        return nil
    }

    private static func firstSkeletonDictionaryRecursively(in value: Any) -> [String: Any]? {
        if let dict = value as? [String: Any] {
            if looksLikeSkeleton(dict) {
                return dict
            }
            if let skeleton = dict["skeleton"] as? [String: Any], looksLikeSkeleton(skeleton) {
                return skeleton
            }
            if let skeletons = dict["skeletons"] as? [[String: Any]], let first = skeletons.first {
                return first
            }
            for child in dict.values {
                if let found = firstSkeletonDictionaryRecursively(in: child) {
                    return found
                }
            }
        } else if let array = value as? [Any] {
            for child in array {
                if let found = firstSkeletonDictionaryRecursively(in: child) {
                    return found
                }
            }
        }
        return nil
    }

    private static func looksLikeSkeleton(_ dict: [String: Any]) -> Bool {
        if dict["nodes"] != nil || dict["links"] != nil {
            return true
        }
        if let state = dict["py/state"] as? [String: Any],
           let graph = state["graph"] as? [String: Any],
           (graph["nodes"] != nil || graph["links"] != nil) {
            return true
        }
        return false
    }
}
