import Foundation
import simd

/// A multi-camera recording session mapping cameras to videos.
///
/// Mirrors Python sleap-io's `RecordingSession`: a set of cameras each paired
/// with the video they recorded, plus the synchronized ``FrameGroup``s that link
/// corresponding frames (and instances) across those views.
public final class RecordingSession: @unchecked Sendable {
    /// Map from camera to its corresponding video in this session.
    public var cameraToVideo: [Camera: Video]

    /// Synchronized frame groups across cameras.
    public var frameGroups: [FrameGroup]

    public init(cameraToVideo: [Camera: Video] = [:], frameGroups: [FrameGroup] = []) {
        self.cameraToVideo = cameraToVideo
        self.frameGroups = frameGroups
    }
}

/// A group of synchronized frames across multiple cameras.
///
/// Aggregates the per-camera ``LabeledFrame``s captured at one synchronized
/// moment plus the ``InstanceGroup``s establishing which instances correspond
/// across those views. Mirrors Python sleap-io's `FrameGroup`.
public final class FrameGroup: @unchecked Sendable {
    /// The labeled frames from each camera view, keyed by camera.
    public var frames: [Camera: LabeledFrame]

    /// Instance correspondences across views.
    public var instanceGroups: [InstanceGroup]

    public init(
        frames: [Camera: LabeledFrame] = [:],
        instanceGroups: [InstanceGroup] = []
    ) {
        self.frames = frames
        self.instanceGroups = instanceGroups
    }

    /// Triangulate every contained ``InstanceGroup`` into a 3D pose.
    ///
    /// Convenience wrapper that calls ``InstanceGroup/triangulate(minimumViews:)``
    /// on each group, populating each group's ``InstanceGroup/instance3D``.
    ///
    /// - Parameter minimumViews: Minimum calibrated views a node must be seen in
    ///   to be triangulated. Defaults to `2`.
    /// - Returns: The triangulated 3D instances, one per group that produced a
    ///   non-empty reconstruction (groups that could not be triangulated are
    ///   omitted).
    @discardableResult
    public func triangulate(minimumViews: Int = 2) -> [Instance3D] {
        instanceGroups.compactMap { $0.triangulate(minimumViews: minimumViews) }
    }
}

/// A group of corresponding instances across camera views.
///
/// Aggregates the 2D ``Instance``s that depict the same physical subject in each
/// camera view and optionally holds the ``Instance3D`` recovered by triangulating
/// them. Mirrors Python sleap-io's `InstanceGroup`.
public final class InstanceGroup: @unchecked Sendable {
    /// Corresponding instances keyed by camera.
    public var instances: [Camera: Instance]

    /// The triangulated 3D pose for this group, if one has been computed.
    public var instance3D: Instance3D?

    public init(
        instances: [Camera: Instance] = [:],
        instance3D: Instance3D? = nil
    ) {
        self.instances = instances
        self.instance3D = instance3D
    }

    /// The group's 2D observations as an `(nCameras, nNodes, 2)` array in the
    /// order of `cameras`, with invisible/absent points as `NaN`.
    ///
    /// A camera not present in the group contributes an all-`NaN` slice sized to
    /// the group's node count. Mirrors `InstanceGroup.numpy`.
    ///
    /// - Parameters:
    ///   - cameras: The camera ordering the output slices follow.
    ///   - invisibleAsNaN: When `true` (default), invisible points are `NaN`.
    public func numpy(cameras: [Camera], invisibleAsNaN: Bool = true) -> [[[Float]]] {
        let nNodes = instances.values.first?.points.count ?? 0
        return cameras.map { camera in
            if let instance = instances[camera] {
                return instance.numpy(invisibleAsNaN: invisibleAsNaN)
            }
            return Array(repeating: [Float.nan, Float.nan], count: nNodes)
        }
    }

    /// Triangulate the group's per-camera 2D instances into a single 3D pose.
    ///
    /// For each skeleton node, gathers the 2D observation from every camera whose
    /// instance marks that node visible (with finite coordinates) and whose
    /// ``Camera`` yields a full projection matrix (intrinsics + extrinsics), then
    /// triangulates via ``Triangulation/triangulate(observations:)``. Nodes seen
    /// by fewer than `minimumViews` calibrated cameras are left missing.
    ///
    /// The node layout is taken from the first instance's skeleton; only
    /// instances whose point count matches contribute. The computed pose is
    /// stored on ``instance3D`` and returned. Returns `nil` (leaving
    /// ``instance3D`` unchanged) when the group has no instances, fewer than
    /// `minimumViews` calibrated views, or no node could be triangulated.
    ///
    /// Mirrors the multi-view reconstruction performed by Python sleap-io's
    /// `InstanceGroup` / `CameraGroup.triangulate`.
    ///
    /// - Parameter minimumViews: Minimum calibrated views a node must be seen in
    ///   to be triangulated. Defaults to `2`.
    /// - Returns: The triangulated 3D pose, or `nil` if none could be produced.
    @discardableResult
    public func triangulate(minimumViews: Int = 2) -> Instance3D? {
        guard let skeleton = instances.values.first?.skeleton else { return nil }
        let nNodes = skeleton.nodes.count

        // Precompute projection matrices for cameras that are fully calibrated
        // and whose instance shares the node layout.
        var views: [(projection: [Double], instance: Instance)] = []
        for (camera, instance) in instances {
            guard instance.points.count == nNodes,
                  let projection = Triangulation.projectionMatrix(for: camera) else { continue }
            views.append((projection, instance))
        }
        guard views.count >= minimumViews else { return nil }

        var points3D = [Point3D](repeating: .missing, count: nNodes)
        var any = false
        for nodeIdx in 0..<nNodes {
            var observations: [(projection: [Double], point: SIMD2<Float>)] = []
            for view in views {
                let points = view.instance.points
                guard points.visibility[nodeIdx] else { continue }
                let x = points.coordinates[nodeIdx * 2]
                let y = points.coordinates[nodeIdx * 2 + 1]
                guard x.isFinite, y.isFinite else { continue }
                observations.append((view.projection, SIMD2(x, y)))
            }
            guard observations.count >= minimumViews,
                  let xyz = Triangulation.triangulate(observations: observations),
                  xyz.x.isFinite, xyz.y.isFinite, xyz.z.isFinite else { continue }
            points3D[nodeIdx] = Point3D(x: xyz.x, y: xyz.y, z: xyz.z, visible: true)
            any = true
        }
        guard any else { return nil }

        let result = Instance3D(skeleton: skeleton, points: points3D)
        instance3D = result
        return result
    }
}
