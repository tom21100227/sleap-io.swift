import CoreGraphics
import SleapIO

extension LabeledFrame {
    /// Decode this labeled frame's image from its video backend.
    public func image() async throws -> CGImage {
        try await video.frame(at: frameIndex)
    }
}
