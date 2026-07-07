import Foundation
import SleapIO

/// Parsed metadata from the /metadata group's json attribute.
struct SLPMetadata {
    var formatId: Float
    var skeletons: [Skeleton]
    var provenance: [String: JSONValue]
    var allNodeNames: [String]

    /// Parse the /metadata JSON attribute.
    static func parse(json: String, formatId: Float) throws -> SLPMetadata {
        guard let data = json.data(using: .utf8),
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SleapIOError.corruptData("Cannot parse metadata JSON")
        }

        // Preserve arbitrary JSON provenance (mirrors Python dict[str, Any]) rather
        // than string-coercing every value.
        var provenance: [String: JSONValue] = [:]
        if let prov = root["provenance"] as? [String: Any] {
            for (k, v) in prov {
                provenance[k] = JSONValue(jsonObject: v)
            }
        }

        // All node names from the superset node list (must parse before skeletons)
        var allNodeNames: [String] = []
        if let nodes = root["nodes"] as? [[String: Any]] {
            for nodeDict in nodes {
                if let nameDict = nodeDict["py/state"] as? [String: Any],
                   let name = nameDict["name"] as? String {
                    allNodeNames.append(name)
                } else if let name = nodeDict["name"] as? String {
                    allNodeNames.append(name)
                }
            }
        }

        // Parse skeletons from NetworkX graph format
        var skeletons: [Skeleton] = []
        if let skelList = root["skeletons"] as? [[String: Any]] {
            for skelDict in skelList {
                let skeleton = try SkeletonCodec.decodeFromNetworkX(skelDict, nodeNames: allNodeNames)
                skeletons.append(skeleton)
            }
        }

        return SLPMetadata(
            formatId: formatId,
            skeletons: skeletons,
            provenance: provenance,
            allNodeNames: allNodeNames
        )
    }
}
