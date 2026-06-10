import XCTest
@testable import SleapIO

/// E11.1: Video metadata accessors.
final class VideoAccessorsTests: XCTestCase {

    func testShape() {
        let v = Video(filename: "v.mp4")
        XCTAssertNil(v.shape)
        v.frameCount = 100
        v.frameSize = (height: 480, width: 640, channels: 3)
        let s = v.shape
        XCTAssertEqual(s?.frames, 100)
        XCTAssertEqual(s?.height, 480)
        XCTAssertEqual(s?.width, 640)
        XCTAssertEqual(s?.channels, 3)
    }

    func testGrayscaleGetSet() {
        let v = Video(filename: "v.mp4")
        XCTAssertNil(v.grayscale) // unknown frame size
        v.frameSize = (height: 10, width: 10, channels: 3)
        XCTAssertEqual(v.grayscale, false)
        v.grayscale = true
        XCTAssertEqual(v.frameSize?.channels, 1)
        XCTAssertEqual(v.grayscale, true)
        v.grayscale = false
        XCTAssertEqual(v.frameSize?.channels, 3)
    }

    func testExists() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("sleapio_exists_\(UUID().uuidString).txt")
        try "x".write(to: tmp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let present = Video(filename: tmp.path)
        XCTAssertTrue(present.exists)

        let absent = Video(filename: "/definitely/not/here_\(UUID().uuidString).mp4")
        XCTAssertFalse(absent.exists)
    }

    func testFpsAndTimeMapping() {
        let v = Video(filename: "v.mp4", backendMetadata: ["fps": 30.0])
        XCTAssertEqual(v.fps, 30.0)
        XCTAssertEqual(v.frameToSeconds(60), 2.0)
        XCTAssertEqual(v.secondsToFrame(2.0), 60)
    }

    func testFpsMissing() {
        let v = Video(filename: "v.mp4")
        XCTAssertNil(v.fps)
        XCTAssertNil(v.frameToSeconds(10))
        XCTAssertNil(v.secondsToFrame(1.0))
    }

    func testFromFilenameInfersBackend() {
        XCTAssertEqual(Video.from(filename: "/a/b/clip.mp4").backendType, "media")
        XCTAssertEqual(Video.from(filename: "/a/b/proj.slp").backendType, "hdf5")
        XCTAssertEqual(Video.from(filename: "/a/b/frame.png").backendType, "imageSequence")
        XCTAssertEqual(Video.from(filename: "/a/b/unknown.xyz").backendType, "media")
    }
}
