import Foundation

/// A multi-camera recording session mapping cameras to videos.
public final class RecordingSession: @unchecked Sendable {
    /// Map from camera to its corresponding video in this session.
    public var cameraToVideo: [Camera: Video]

    /// Synchronized frame groups across cameras.
    public var frameGroups: [FrameGroup]

    public init(cameraToVideo: [Camera: Video] = [:]) {
        self.cameraToVideo = cameraToVideo
        self.frameGroups = []
    }
}

/// A group of synchronized frames across multiple cameras.
public final class FrameGroup: @unchecked Sendable {
    /// The labeled frames from each camera view, keyed by camera.
    public var frames: [Camera: LabeledFrame]

    /// Instance correspondences across views.
    public var instanceGroups: [InstanceGroup]

    public init() {
        self.frames = [:]
        self.instanceGroups = []
    }
}

/// A group of corresponding instances across camera views.
public final class InstanceGroup: @unchecked Sendable {
    /// Corresponding instances keyed by camera.
    public var instances: [Camera: Instance]

    public init() {
        self.instances = [:]
    }
}
