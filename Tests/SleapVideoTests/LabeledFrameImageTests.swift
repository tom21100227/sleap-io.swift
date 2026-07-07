import CoreGraphics
import XCTest
import SleapIO
@testable import SleapVideo

private final class LabeledFrameImageBackend: VideoBackend, @unchecked Sendable {
    var requestedIndices: [Int] = []

    var frameCount: Int? { 4 }
    var frameSize: (height: Int, width: Int, channels: Int)? { (7, 11, 4) }
    var fps: Double? { nil }

    func frame(at index: Int) async throws -> CGImage {
        requestedIndices.append(index)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
        let context = CGContext(
            data: nil,
            width: 11,
            height: 7,
            bitsPerComponent: 8,
            bytesPerRow: 11 * 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        )!
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 11, height: 7))
        return context.makeImage()!
    }
}

final class LabeledFrameImageTests: XCTestCase {
    func testImageDelegatesToVideoFrameAtFrameIndex() async throws {
        let backend = LabeledFrameImageBackend()
        let video = Video(filename: "unused", backendType: "custom")
        video.backend = backend
        let frame = LabeledFrame(video: video, frameIndex: 2)

        let image = try await frame.image()

        XCTAssertEqual(image.width, 11)
        XCTAssertEqual(image.height, 7)
        XCTAssertEqual(backend.requestedIndices, [2])
    }

    func testImageThrowsWhenVideoBackendIsMissing() async {
        let video = Video(filename: "missing.mp4", backendType: "media")
        let frame = LabeledFrame(video: video, frameIndex: 0)

        do {
            _ = try await frame.image()
            XCTFail("Expected image() to throw without an opened backend")
        } catch {}
    }
}
