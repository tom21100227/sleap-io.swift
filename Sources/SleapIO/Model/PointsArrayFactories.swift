import Foundation

/// Factory helpers for building ``PointsArray`` values from loosely-typed
/// coordinate inputs.
///
/// Mirrors the upstream sleap-io `PointsArray.from_array` / `from_dict`
/// constructors used when ingesting points from external sources.
extension PointsArray {

    /// Builds a points array from an (N, 2) coordinate array.
    ///
    /// Each row is `[x, y]`. A row whose `x` or `y` is `NaN` (or that does not
    /// contain two finite values) produces an invisible point; all other rows
    /// produce a visible point. The resulting count equals `array.count`.
    ///
    /// - Parameter array: One `[x, y]` row per point.
    /// - Returns: A ``PointsArray`` with `count == array.count`.
    public static func from(array: [[Float]]) -> PointsArray {
        let n = array.count
        var coords = ContiguousArray<Float>(repeating: Float.nan, count: n * 2)
        var vis = ContiguousArray<Bool>(repeating: false, count: n)
        let comp = ContiguousArray<Bool>(repeating: false, count: n)

        for i in 0..<n {
            let row = array[i]
            let x = row.count > 0 ? row[0] : Float.nan
            let y = row.count > 1 ? row[1] : Float.nan
            coords[i * 2] = x
            coords[i * 2 + 1] = y
            vis[i] = x.isFinite && y.isFinite
        }

        return PointsArray(coordinates: coords, visibility: vis, completeness: comp)
    }

    /// Builds a points array from a node-name -> `[x, y]` dictionary, ordered by
    /// the skeleton's node order.
    ///
    /// The result has one point per skeleton node (`count == skeleton.nodes.count`).
    /// Nodes present in `dict` with two finite values become visible points;
    /// nodes absent from `dict` (or mapped to a non-finite value) become
    /// invisible `NaN` points. The skeleton is attached so node/name subscripts
    /// work on the result.
    ///
    /// - Parameters:
    ///   - dict: Mapping from node name to `[x, y]`.
    ///   - skeleton: Skeleton defining node order and identity.
    /// - Returns: A ``PointsArray`` with `count == skeleton.nodes.count` and
    ///   `skeleton` set.
    public static func from(dict: [String: [Float]], skeleton: Skeleton) -> PointsArray {
        let nodes = skeleton.nodes
        let n = nodes.count
        var coords = ContiguousArray<Float>(repeating: Float.nan, count: n * 2)
        var vis = ContiguousArray<Bool>(repeating: false, count: n)
        let comp = ContiguousArray<Bool>(repeating: false, count: n)

        for i in 0..<n {
            guard let row = dict[nodes[i].name] else { continue }
            let x = row.count > 0 ? row[0] : Float.nan
            let y = row.count > 1 ? row[1] : Float.nan
            coords[i * 2] = x
            coords[i * 2 + 1] = y
            vis[i] = x.isFinite && y.isFinite
        }

        var result = PointsArray(coordinates: coords, visibility: vis, completeness: comp)
        result.skeleton = skeleton
        return result
    }
}
