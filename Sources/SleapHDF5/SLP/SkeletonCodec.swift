import Foundation
import SleapIO

/// Codec for skeleton serialization in the SLEAP/NetworkX graph format.
public struct SkeletonCodec {

    /// Decode a skeleton from the NetworkX graph JSON format used in SLP metadata.
    /// `nodeNames` is the top-level superset node list from the metadata JSON,
    /// used to resolve integer node IDs to names.
    static func decodeFromNetworkX(_ dict: [String: Any], nodeNames: [String] = []) throws -> Skeleton {
        // Handle py/reduce or direct format
        let graphDict: [String: Any]
        if let reduce = dict["py/reduce"] as? [[Any]],
           reduce.count >= 3 {
            // Complex py/reduce format — look for the state dict
            if let stateList = reduce.last,
               let state = stateList.first as? [String: Any] {
                graphDict = state
            } else if let state = dict["py/state"] as? [String: Any] {
                graphDict = state
            } else {
                graphDict = dict
            }
        } else if let state = dict["py/state"] as? [String: Any] {
            graphDict = state
        } else {
            graphDict = dict
        }

        // Extract graph data first (needed for name extraction)
        let graph: [String: Any]
        if let g = graphDict["graph"] as? [String: Any] {
            graph = g
        } else if let g = graphDict["py/state"] as? [String: Any],
                  let gg = g["graph"] as? [String: Any] {
            graph = gg
        } else {
            graph = graphDict
        }

        // Extract skeleton name
        let name: String
        if let graphState = graphDict["py/state"] as? [String: Any] {
            name = graphState["name"] as? String ?? "Skeleton"
        } else if let gname = graph["name"] as? String {
            // Newer format: name is inside the graph dict
            name = gname
        } else {
            name = graphDict["name"] as? String ?? "Skeleton"
        }

        // Parse nodes — in sleap-io 0.5.x, nodes/links are at the top level
        // of the skeleton dict (graphDict), not nested inside graph.
        var nodesByName: [String: Node] = [:]
        var orderedNodes: [Node] = []
        let context = DecodeContext()

        let linksSource = graphDict["links"] ?? graph["links"]
        if let links = linksSource as? [[String: Any]] {
            // Standalone skeleton.json files can list top-level nodes as
            // {"id": {"py/id": N}} while defining Node objects in links.
            // Register those definitions before resolving the nodes array.
            for link in links {
                for key in ["source", "target"] {
                    if let nodeData = link[key] as? [String: Any] {
                        let nodeName = extractNodeName(from: nodeData, nodeNames: nodeNames, context: context)
                        if nodeName != "unknown" {
                            context.registerNodeName(nodeName, from: nodeData)
                        }
                    }
                }
            }
        }

        let nodesSource = graphDict["nodes"] ?? graph["nodes"]
        if let nodesData = nodesSource as? [[String: Any]] {
            for nodeData in nodesData {
                let nodeName = extractNodeName(from: nodeData, nodeNames: nodeNames, context: context)
                let node = Node(name: nodeName)
                nodesByName[nodeName] = node
                orderedNodes.append(node)
                context.registerNodeName(nodeName, from: nodeData)
            }
        } else if let nodesDict = nodesSource as? [String: Any] {
            // Alternative format: nodes as dictionary keyed by index
            let sortedKeys = nodesDict.keys.sorted {
                (Int($0) ?? 0) < (Int($1) ?? 0)
            }
            for key in sortedKeys {
                if let nodeData = nodesDict[key] as? [String: Any] {
                    let nodeName = extractNodeName(from: nodeData, nodeNames: nodeNames, context: context)
                    let node = Node(name: nodeName)
                    nodesByName[nodeName] = node
                    orderedNodes.append(node)
                    context.registerNodeName(nodeName, from: nodeData)
                }
            }
        }

        let skeleton = Skeleton(name: name, nodes: orderedNodes)
        context.registerEdgeTypes(in: graphDict)
        context.registerEdgeTypes(in: graph)

        // Parse body edges and symmetry links — look in graphDict first
        if let links = linksSource as? [[String: Any]] {
            for link in links {
                let srcName: String
                let dstName: String

                if let source = link["source"] as? [String: Any] {
                    srcName = extractNodeName(from: source, nodeNames: nodeNames, context: context)
                } else if let sourceIdx = link["source"] as? Int, sourceIdx < orderedNodes.count {
                    srcName = orderedNodes[sourceIdx].name
                } else {
                    continue
                }

                if let target = link["target"] as? [String: Any] {
                    dstName = extractNodeName(from: target, nodeNames: nodeNames, context: context)
                } else if let targetIdx = link["target"] as? Int, targetIdx < orderedNodes.count {
                    dstName = orderedNodes[targetIdx].name
                } else {
                    continue
                }

                if let src = nodesByName[srcName], let dst = nodesByName[dstName] {
                    if context.resolveEdgeTypeValue(link["type"]) == 2 {
                        skeleton.addSymmetry(src, dst)
                    } else {
                        skeleton.addEdge(from: src, to: dst)
                    }
                }
            }
        }

        // Parse legacy symmetries arrays as well; addSymmetry deduplicates with
        // type-2 symmetry links.
        parseSymmetries(from: graph["symmetries"], nodesByName: nodesByName, into: skeleton)
        if let graphData = graph["graph"] as? [String: Any] {
            parseSymmetries(from: graphData["symmetries"], nodesByName: nodesByName, into: skeleton)
        }

        return skeleton
    }

    /// Encode a skeleton to the NetworkX graph JSON format for SLP metadata.
    static func encodeToNetworkX(_ skeleton: Skeleton) -> [String: Any] {
        // TODO(#24): full jsonpickle-canonical encoder.
        var nodes: [[String: Any]] = []
        for node in skeleton.nodes {
            nodes.append([
                "py/state": ["name": node.name, "weight": 1.0]
            ])
        }

        var links: [[String: Any]] = []
        for edge in skeleton.edges {
            guard let srcIdx = skeleton.index(of: edge.source),
                  skeleton.index(of: edge.destination) != nil else { continue }
            links.append([
                "source": ["py/state": ["name": edge.source.name, "weight": 1.0]],
                "target": ["py/state": ["name": edge.destination.name, "weight": 1.0]],
                "edge_insert_idx": srcIdx,
                "key": 0,
                "type": "BODY"
            ])
        }

        var symmetries: [[String: Any]] = []
        for sym in skeleton.symmetries {
            symmetries.append(["nodes": [sym.nodeA.name, sym.nodeB.name]])
        }

        let graph: [String: Any] = [
            "directed": true,
            "graph": [
                "name": skeleton.name,
                "num_edges_inserted": skeleton.edges.count,
                "symmetries": symmetries
            ],
            "links": links,
            "multigraph": true,
            "nodes": nodes
        ]

        return [
            "py/state": [
                "graph": graph,
                "name": skeleton.name
            ]
        ]
    }

    // MARK: - Private helpers

    private static func parseSymmetries(
        from value: Any?,
        nodesByName: [String: Node],
        into skeleton: Skeleton
    ) {
        guard let symmetries = value as? [[String: Any]] else { return }
        for sym in symmetries {
            if let names = sym["nodes"] as? [String], names.count == 2,
               let a = nodesByName[names[0]], let b = nodesByName[names[1]] {
                skeleton.addSymmetry(a, b)
            }
        }
    }

    private final class DecodeContext {
        private var nextImplicitID = 0
        private var explicitNodeNamesByPyID: [Int: String] = [:]
        private var positionalNodeNamesByPyID: [Int: String] = [:]
        private var edgeTypeValuesByPyID: [Int: Int] = [:]

        func registerNodeName(_ name: String, from dict: [String: Any]) {
            if let id = explicitPyID(in: dict) {
                explicitNodeNamesByPyID[id] = name
            }
            positionalNodeNamesByPyID[nextImplicitID] = name
            nextImplicitID += 1
        }

        func nodeName(forPyID id: Int) -> String? {
            explicitNodeNamesByPyID[id] ?? positionalNodeNamesByPyID[id]
        }

        func registerEdgeTypes(in value: Any) {
            walk(value)
        }

        func resolveEdgeTypeValue(_ value: Any?) -> Int? {
            guard let value else { return nil }

            if let intValue = value as? Int {
                return intValue
            }
            if let stringValue = value as? String {
                switch stringValue.uppercased() {
                case "BODY": return 1
                case "SYMMETRY": return 2
                default: return Int(stringValue)
                }
            }
            if let dict = value as? [String: Any] {
                if dict.count == 1, let id = explicitPyID(in: dict) {
                    return edgeTypeValuesByPyID[id] ?? id
                }
                if let raw = dict["value"] ?? dict["_value_"] ?? dict["val"],
                   let resolved = resolveEdgeTypeValue(raw) {
                    registerEdgeTypeValue(resolved, from: dict)
                    return resolved
                }
                if let reduce = dict["py/reduce"],
                   let resolved = firstEdgeTypeValue(in: reduce) {
                    registerEdgeTypeValue(resolved, from: dict)
                    return resolved
                }
                if let state = dict["py/state"],
                   let resolved = firstEdgeTypeValue(in: state) {
                    registerEdgeTypeValue(resolved, from: dict)
                    return resolved
                }
            }
            if let array = value as? [Any] {
                return firstEdgeTypeValue(in: array)
            }
            return nil
        }

        private func walk(_ value: Any) {
            if let dict = value as? [String: Any] {
                if let resolved = resolveEdgeTypeValue(dict) {
                    registerEdgeTypeValue(resolved, from: dict)
                }
                for child in dict.values {
                    walk(child)
                }
            } else if let array = value as? [Any] {
                for child in array {
                    walk(child)
                }
            }
        }

        private func registerEdgeTypeValue(_ value: Int, from dict: [String: Any]) {
            if let id = explicitPyID(in: dict) {
                edgeTypeValuesByPyID[id] = value
            }
        }

        private func firstEdgeTypeValue(in value: Any) -> Int? {
            if let intValue = value as? Int, intValue == 1 || intValue == 2 {
                return intValue
            }
            if let stringValue = value as? String {
                switch stringValue.uppercased() {
                case "BODY": return 1
                case "SYMMETRY": return 2
                default: return nil
                }
            }
            if let dict = value as? [String: Any] {
                if dict.count == 1, let id = explicitPyID(in: dict) {
                    return edgeTypeValuesByPyID[id] ?? id
                }
                for key in ["value", "_value_", "val", "py/reduce", "py/state"] {
                    if let child = dict[key], let resolved = firstEdgeTypeValue(in: child) {
                        return resolved
                    }
                }
                for child in dict.values {
                    if let resolved = firstEdgeTypeValue(in: child) {
                        return resolved
                    }
                }
            }
            if let array = value as? [Any] {
                for child in array {
                    if let resolved = firstEdgeTypeValue(in: child) {
                        return resolved
                    }
                }
            }
            return nil
        }

        private func explicitPyID(in dict: [String: Any]) -> Int? {
            if let id = dict["py/id"] as? Int {
                return id
            }
            if let id = dict["py/id"] as? String {
                return Int(id)
            }
            return nil
        }
    }

    private static func extractNodeName(
        from dict: [String: Any],
        nodeNames: [String] = [],
        context: DecodeContext? = nil
    ) -> String {
        if dict.count == 1,
           let pyID = dict["py/id"] as? Int,
           let name = context?.nodeName(forPyID: pyID) {
            return name
        }
        if dict.count == 1,
           let pyIDString = dict["py/id"] as? String,
           let pyID = Int(pyIDString),
           let name = context?.nodeName(forPyID: pyID) {
            return name
        }
        if let state = dict["py/state"] as? [String: Any],
           let tuple = state["py/tuple"] as? [Any],
           let name = tuple.first as? String {
            return name
        }
        if let state = dict["py/state"] as? [String: Any],
           let name = state["name"] as? String {
            return name
        }
        if let name = dict["name"] as? String {
            return name
        }
        // Newer sleap-io format: nodes are {"id": <int>} referencing the
        // top-level superset node list by index.
        if let id = dict["id"] as? Int, id >= 0, id < nodeNames.count {
            return nodeNames[id]
        }
        if let idDict = dict["id"] as? [String: Any],
           let pyID = idDict["py/id"] as? Int,
           let name = context?.nodeName(forPyID: pyID) {
            return name
        }
        if let idDict = dict["id"] as? [String: Any],
           let pyIDString = idDict["py/id"] as? String,
           let pyID = Int(pyIDString),
           let name = context?.nodeName(forPyID: pyID) {
            return name
        }
        if let id = dict["id"] as? String {
            return id
        }
        return "unknown"
    }
}
