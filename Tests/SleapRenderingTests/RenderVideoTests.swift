#if canImport(AVFoundation)
import AVFoundation
import CoreGraphics
import XCTest
@testable import SleapRendering

final class RenderVideoTests: XCTestCase {
    func testLowLevelRenderWritesShortClipAndReportsProgress() async throws {
        let url = renderVideoTestURL("sleap_render_video_tests_short_clip.mp4")
        try? FileManager.default.removeItem(at: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let progressExpectation = expectation(description: "progress")
        progressExpectation.expectedFulfillmentCount = 8
        let recorder = RenderVideoProgressRecorder()

        try await RenderVideo().render(
            frames: 0..<8,
            width: 64,
            height: 48,
            to: url,
            fps: 15.0,
            progress: { value in
                recorder.record(value)
                progressExpectation.fulfill()
            }
        ) { index in
            renderVideoTestImage(width: 64, height: 48, index: index)
        }

        await fulfillment(of: [progressExpectation], timeout: 5.0)

        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let fileSize = try XCTUnwrap(attributes[.size] as? NSNumber)
        XCTAssertGreaterThan(fileSize.intValue, 0)
        XCTAssertEqual(recorder.values.count, 8)
        XCTAssertEqual(try XCTUnwrap(recorder.values.last), 1.0, accuracy: 1e-6)

        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        XCTAssertGreaterThanOrEqual(tracks.count, 1)
    }

    func testLowLevelRenderEmptyRangeWritesFileWithoutProgress() async throws {
        let url = renderVideoTestURL("sleap_render_video_tests_empty_range.mp4")
        try? FileManager.default.removeItem(at: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let recorder = RenderVideoProgressRecorder()

        try await RenderVideo().render(
            frames: 0..<0,
            width: 64,
            height: 48,
            to: url,
            fps: 15.0,
            progress: { value in
                recorder.record(value)
            }
        ) { _ in
            XCTFail("Empty render should not request frames")
            return renderVideoTestImage(width: 64, height: 48, index: 0)
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertTrue(recorder.values.isEmpty)
    }
}

private final class RenderVideoProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValues: [Double] = []

    var values: [Double] {
        lock.withLock { storedValues }
    }

    func record(_ value: Double) {
        lock.withLock {
            storedValues.append(value)
        }
    }
}

private func renderVideoTestURL(_ filename: String) -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent(filename)
}

private func renderVideoTestImage(width: Int, height: Int, index: Int) -> CGImage {
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let context = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: width * 4,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    let red = CGFloat(index % 8) / 7.0
    let green = CGFloat((index * 3) % 8) / 7.0
    let blue = CGFloat((index * 5) % 8) / 7.0
    context.setFillColor(CGColor(red: red, green: green, blue: blue, alpha: 1.0))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    return context.makeImage()!
}
#endif
