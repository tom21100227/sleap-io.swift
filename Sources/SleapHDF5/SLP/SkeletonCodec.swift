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

        let nodesSource = graphDict["nodes"] ?? graph["nodes"]
        if let nodesData = nodesSource as? [[String: Any]] {
            for nodeData in nodesData {
                let nodeName = extractNodeName(from: nodeData, nodeNames: nodeNames)
                let node = Node(name: nodeName)
                nodesByName[nodeName] = node
                orderedNodes.append(node)
            }
        } else if let nodesDict = nodesSource as? [String: Any] {
            // Alternative format: nodes as dictionary keyed by index
            let sortedKeys = nodesDict.keys.sorted {
                (Int($0) ?? 0) < (Int($1) ?? 0)
            }
            for key in sortedKeys {
                if let nodeData = nodesDict[key] as? [String: Any] {
                    let nodeName = extractNodeName(from: nodeData, nodeNames: nodeNames)
                    let node = Node(name: nodeName)
                    nodesByName[nodeName] = node
                    orderedNodes.append(node)
                }
            }
        }

        let skeleton = Skeleton(name: name, nodes: orderedNodes)

        // Parse edges (links) — look in graphDict first
        let linksSource = graphDict["links"] ?? graph["links"]
        if let links = linksSource as? [[String: Any]] {
            for link in links {
                let srcName: String
                let dstName: String

                if let source = link["source"] as? [String: Any] {
                    srcName = extractNodeName(from: source)
                } else if let sourceIdx = link["source"] as? Int, sourceIdx < orderedNodes.count {
                    srcName = orderedNodes[sourceIdx].name
                } else {
                    continue
                }

                if let target = link["target"] as? [String: Any] {
                    dstName = extractNodeName(from: target)
                } else if let targetIdx = link["target"] as? Int, targetIdx < orderedNodes.count {
                    dstName = orderedNodes[targetIdx].name
                } else {
                    continue
                }

                if let src = nodesByName[srcName], let dst = nodesByName[dstName] {
                    skeleton.addEdge(from: src, to: dst)
                }
            }
        }

        // Parse symmetries
        if let graphData = graph["graph"] as? [String: Any],
           let symmetries = graphData["symmetries"] as? [[String: Any]] {
            for sym in symmetries {
                if let names = sym["nodes"] as? [String], names.count == 2,
                   let a = nodesByName[names[0]], let b = nodesByName[names[1]] {
                    skeleton.addSymmetry(a, b)
                }
            }
        }

        return skeleton
    }

    /// Encode a skeleton to the NetworkX graph JSON format for SLP metadata.
    static func encodeToNetworkX(_ skeleton: Skeleton) -> [String: Any] {
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

    private static func extractNodeName(from dict: [String: Any], nodeNames: [String] = []) -> String {
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
        if let id = dict["id"] as? String {
            return id
        }
        return "unknown"
    }
}
