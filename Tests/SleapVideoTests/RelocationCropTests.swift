import XCTest
import CoreGraphics
import Foundation
@testable import SleapVideo
import SleapIO

// MARK: - Test helpers

/// A minimal in-memory ``VideoBackend`` returning a fixed raw frame, used to
/// exercise ``CropVideoBackend`` deterministically.
private struct FixedBackend: VideoBackend {
    let raw: RawFrame
    let count: Int
    let framesPerSecond: Double?

    init(raw: RawFrame, count: Int = 10, fps: Double? = 30) {
        self.raw = raw
        self.count = count
        self.framesPerSecond = fps
    }

    var frameCount: Int? { count }
    var frameSize: (height: Int, width: Int, channels: Int)? {
        (height: raw.height, width: raw.width, channels: raw.channels)
    }
    var fps: Double? { framesPerSecond }

    func frame(at index: Int) async throws -> CGImage {
        try CropVideoBackend.makeImage(from: raw)
    }

    // Override so cropping operates on known bytes (the default path would
    // re-decode through a CGImage and lose exact sample values).
    func rawFrame(at index: Int) async throws -> RawFrame { raw }
}

private func tempFile(ext: String = "mp4") -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("sleap_reloc_\(UUID().uuidString).\(ext)")
}

// MARK: - #61: Video.replaceFilename + matchers

final class VideoRelocationTests: XCTestCase {

    func testReplaceFilenameUpdatesPersistedPath() {
        let video = Video(filename: "/orig/movie.mp4")
        XCTAssertNil(video.persistedFilename)

        video.replaceFilename("/relocated/movie.mp4")

        XCTAssertEqual(video.filename, "/relocated/movie.mp4")
        XCTAssertEqual(video.persistedFilename, "/relocated/movie.mp4")
        // Provenance (original path) is preserved.
        XCTAssertEqual(video.originalFilename, "/orig/movie.mp4")
        // Mirrored into backend metadata for round-tripping.
        XCTAssertEqual(video.backendMetadata["filename"] as? String, "/relocated/movie.mp4")
    }

    func testReplaceFilenameEnablesReopenAfterMissingPath() {
        let missing = "/definitely/not/here_\(UUID().uuidString).mp4"
        let video = Video(filename: missing)
        XCTAssertFalse(video.exists, "video with a missing path should not exist")

        // Relocate onto a real file (deferred open + relocate).
        let real = tempFile()
        FileManager.default.createFile(atPath: real.path, contents: Data([0, 1, 2]))
        defer { try? FileManager.default.removeItem(at: real) }

        video.replaceFilename(real.path)
        XCTAssertTrue(video.exists, "relocated video should resolve to the real file")
    }

    func testMatchesPathBasenameVsStrict() {
        let a = Video(filename: "/dir1/clip.mp4")
        let b = Video(filename: "/dir2/clip.mp4")
        XCTAssertTrue(a.matchesPath(b), "same basename matches leniently")
        XCTAssertFalse(a.matchesPath(b, strict: true), "different dirs do not match strictly")

        let c = Video(filename: "/dir1/clip.mp4")
        XCTAssertTrue(a.matchesPath(c, strict: true), "identical paths match strictly")
    }

    func testMatchesShapeAndContent() {
        let a = Video(filename: "/a.mp4")
        a.frameCount = 100
        a.frameSize = (height: 480, width: 640, channels: 3)
        let b = Video(filename: "/b.mp4")
        b.frameCount = 50  // differs in frame count only
        b.frameSize = (height: 480, width: 640, channels: 3)

        XCTAssertTrue(a.matchesShape(b), "same H/W/C matches shape regardless of frame count")
        XCTAssertFalse(a.matchesContent(b), "different frame count is different content")

        b.frameCount = 100
        XCTAssertTrue(a.matchesContent(b), "same full shape + backend type is same content")
    }
}

// MARK: - #62: Labels.addVideo / replaceVideos / replaceFilenames / matchVideo

final class LabelsVideoManagementTests: XCTestCase {

    private func makeLabels(video: Video) throws -> (Labels, Skeleton, Instance) {
        let skel = Skeleton(name: "s", nodes: [Node(name: "a")])
        let labels = Labels()
        let frame = LabeledFrame(video: video, frameIndex: 0)
        let inst = Instance(skeleton: skel)
        frame.instances.append(inst)
        try labels.addFrame(frame)
        return (labels, skel, inst)
    }

    func testAddVideoDeduplicatesByIdentity() throws {
        let labels = Labels()
        let v1 = Video(filename: "/data/a.mp4")
        let v2 = Video(filename: "/data/a.mp4")  // same path, different object
        let v3 = Video(filename: "/data/b.mp4")

        let added1 = try labels.addVideo(v1)
        XCTAssertTrue(added1 === v1)
        XCTAssertEqual(labels.videos.count, 1)

        let added2 = try labels.addVideo(v2)
        XCTAssertTrue(added2 === v1, "duplicate path returns the existing video")
        XCTAssertEqual(labels.videos.count, 1)

        let added3 = try labels.addVideo(v3)
        XCTAssertTrue(added3 === v3)
        XCTAssertEqual(labels.videos.count, 2)
    }

    func testMatchVideoFindsExisting() throws {
        let labels = Labels()
        let v1 = Video(filename: "/data/a.mp4")
        _ = try labels.addVideo(v1)

        let query = Video(filename: "/elsewhere/a.mp4")  // same basename
        XCTAssertTrue(labels.matchVideo(query) === v1)

        let noMatch = Video(filename: "/data/other.mp4")
        XCTAssertNil(labels.matchVideo(noMatch))
    }

    func testReplaceVideosRemapsFramesAndSuggestions() throws {
        let v1 = Video(filename: "/data/a.mp4")
        let (labels, _, inst) = try makeLabels(video: v1)
        labels.suggestions.append(SuggestionFrame(video: v1, frameIndex: 5))

        let v2 = Video(filename: "/data/relocated.mp4")
        try labels.replaceVideos(oldVideos: [v1], newVideos: [v2])

        XCTAssertEqual(labels.videos.count, 1)
        XCTAssertTrue(labels.videos[0] === v2, "video table points at the replacement")

        let framesForV2 = labels.frames(for: v2)
        XCTAssertEqual(framesForV2.count, 1)
        XCTAssertTrue(framesForV2[0].video === v2, "frame references the new video")
        XCTAssertTrue(framesForV2[0].instances[0] === inst, "instances preserved by reference")
        XCTAssertTrue(labels.frames(for: v1).isEmpty, "no frame references the old video")

        XCTAssertTrue(labels.suggestions[0].video === v2, "suggestion remapped to new video")
    }

    func testReplaceVideosViaMapAndNewListOnly() throws {
        let v1 = Video(filename: "/data/a.mp4")
        let (labels, _, _) = try makeLabels(video: v1)

        // Map form.
        let v2 = Video(filename: "/data/b.mp4")
        try labels.replaceVideos(videoMap: [(old: v1, new: v2)])
        XCTAssertTrue(labels.videos[0] === v2)

        // new-list-only form (counts match the table).
        let v3 = Video(filename: "/data/c.mp4")
        try labels.replaceVideos(newVideos: [v3])
        XCTAssertTrue(labels.videos[0] === v3)
    }

    func testReplaceFilenamesListForm() throws {
        let labels = Labels()
        let v1 = Video(filename: "/old/a.mp4")
        let v2 = Video(filename: "/old/b.mp4")
        _ = try labels.addVideo(v1)
        _ = try labels.addVideo(v2)

        try labels.replaceFilenames(newFilenames: ["/new/a.mp4", "/new/b.mp4"])
        XCTAssertEqual(v1.filename, "/new/a.mp4")
        XCTAssertEqual(v2.filename, "/new/b.mp4")
        XCTAssertEqual(v1.originalFilename, "/old/a.mp4", "provenance preserved")
    }

    func testReplaceFilenamesCountMismatchThrows() throws {
        let labels = Labels()
        _ = try labels.addVideo(Video(filename: "/old/a.mp4"))
        XCTAssertThrowsError(try labels.replaceFilenames(newFilenames: ["/x.mp4", "/y.mp4"]))
    }

    func testReplaceFilenamesRequiresExactlyOneForm() throws {
        let labels = Labels()
        _ = try labels.addVideo(Video(filename: "/old/a.mp4"))
        // Zero forms.
        XCTAssertThrowsError(try labels.replaceFilenames())
        // Two forms.
        XCTAssertThrowsError(try labels.replaceFilenames(
            newFilenames: ["/x.mp4"], filenameMap: ["/old/a.mp4": "/y.mp4"]))
    }

    func testReplaceFilenamesMapForm() throws {
        let labels = Labels()
        let v1 = Video(filename: "/old/a.mp4")
        let v2 = Video(filename: "/old/b.mp4")
        _ = try labels.addVideo(v1)
        _ = try labels.addVideo(v2)

        try labels.replaceFilenames(filenameMap: ["/old/a.mp4": "/new/a.mp4"])
        XCTAssertEqual(v1.filename, "/new/a.mp4")
        XCTAssertEqual(v2.filename, "/old/b.mp4", "unmatched video untouched")
    }

    func testReplaceFilenamesPrefixForm() throws {
        let labels = Labels()
        let v1 = Video(filename: "/old/dir/a.mp4")
        let v2 = Video(filename: "/other/b.mp4")
        _ = try labels.addVideo(v1)
        _ = try labels.addVideo(v2)

        try labels.replaceFilenames(prefixMap: [(old: "/old", new: "/new")])
        XCTAssertEqual(v1.filename, "/new/dir/a.mp4", "prefix swapped, remainder preserved")
        XCTAssertEqual(v2.filename, "/other/b.mp4", "non-matching prefix untouched")
    }
}

// MARK: - #63: Security-scoped bookmark relocation

final class SecurityScopedBookmarkTests: XCTestCase {

    func testBookmarkBase64RoundTrip() {
        let data = Data([1, 2, 3, 4, 5, 250, 128, 0])
        let bookmark = SecurityScopedBookmark(data: data)
        let restored = SecurityScopedBookmark(base64: bookmark.base64)
        XCTAssertEqual(restored, bookmark)
        XCTAssertEqual(restored?.data, data)
    }

    func testVideoBookmarkPersistsInMetadata() {
        let video = Video(filename: "/data/a.mp4")
        XCTAssertNil(video.securityScopedBookmark)

        let data = Data([9, 8, 7, 6])
        video.securityScopedBookmark = SecurityScopedBookmark(data: data)

        // Stored as a base64 string (JSON-serializable) so it survives save/load.
        XCTAssertNotNil(video.backendMetadata[Video.bookmarkMetadataKey] as? String)

        // Survives a metadata copy (simulating a save/reopen round-trip).
        let reopened = Video(filename: "/data/a.mp4", backendMetadata: video.backendMetadata)
        XCTAssertEqual(reopened.securityScopedBookmark?.data, data)

        // Clearing removes the key.
        video.securityScopedBookmark = nil
        XCTAssertNil(video.backendMetadata[Video.bookmarkMetadataKey])
    }

    func testWithSecurityScopedAccessFallsBackToFilenameWhenNoBookmark() throws {
        let video = Video(filename: "/tmp/plain.mp4")
        let path = try video.withSecurityScopedAccess { $0.path }
        XCTAssertEqual(path, "/tmp/plain.mp4")
    }

    func testBookmarkResolvesToSameFile() throws {
        let url = tempFile()
        FileManager.default.createFile(atPath: url.path, contents: Data([1, 2, 3]))
        defer { try? FileManager.default.removeItem(at: url) }

        do {
            let bookmark = try SecurityScopedBookmark.create(for: url)
            let resolved = try bookmark.resolve()
            XCTAssertEqual(
                resolved.url.standardizedFileURL.path,
                url.standardizedFileURL.path,
                "resolved bookmark points back at the original file")
        } catch {
            throw XCTSkip("Security-scoped bookmarks unavailable in this environment: \(error)")
        }
    }

    func testPersistAndResolveRelocatedURL() throws {
        let url = tempFile()
        FileManager.default.createFile(atPath: url.path, contents: Data([4, 5, 6]))
        defer { try? FileManager.default.removeItem(at: url) }

        let video = Video(filename: url.path)
        do {
            try video.persistSecurityScopedBookmark()
        } catch {
            throw XCTSkip("Security-scoped bookmarks unavailable in this environment: \(error)")
        }
        XCTAssertNotNil(video.securityScopedBookmark)

        let resolved = video.resolveRelocatedURL()
        XCTAssertEqual(resolved?.standardizedFileURL.path, url.standardizedFileURL.path)
    }
}

// MARK: - #70: CropVideoBackend + coordinate mapping

final class CropVideoBackendTests: XCTestCase {

    func testCropRegionCoordinateMappingIsInverse() {
        let region = CropRegion(x1: 3, y1: 4, x2: 20, y2: 30)
        let source = CGPoint(x: 10, y: 20)
        let cropped = region.toCrop(source)
        XCTAssertEqual(cropped.x, 7)
        XCTAssertEqual(cropped.y, 16)

        let roundTrip = region.toSource(cropped)
        XCTAssertEqual(roundTrip.x, source.x)
        XCTAssertEqual(roundTrip.y, source.y)
    }

    func testCropRegionPreservesNaN() {
        let region = CropRegion(x1: 5, y1: 5, x2: 10, y2: 10)
        let missing = CGPoint(x: CGFloat.nan, y: CGFloat.nan)
        let mapped = region.toCrop(missing)
        XCTAssertTrue(mapped.x.isNaN)
        XCTAssertTrue(mapped.y.isNaN)
    }

    func testCropApplyExtractsRegion() {
        // 4x4 single-channel frame with bytes 0..15 (row-major).
        let bytes = (0..<16).map { UInt8($0) }
        let frame = RawFrame(height: 4, width: 4, channels: 1, bytes: bytes)

        let region = CropRegion(x1: 1, y1: 1, x2: 3, y2: 3)
        let cropped = region.apply(to: frame)

        XCTAssertEqual(cropped.width, 2)
        XCTAssertEqual(cropped.height, 2)
        XCTAssertEqual(cropped.channels, 1)
        // Rows y=1,2 and cols x=1,2 => source indices 5,6 / 9,10.
        XCTAssertEqual(cropped.bytes, [5, 6, 9, 10])
    }

    func testCropApplyFillsOutOfBounds() {
        let bytes = (0..<16).map { UInt8($0) }
        let frame = RawFrame(height: 4, width: 4, channels: 1, bytes: bytes)

        // Crop extends past the bottom-right edge; OOB filled with 99.
        let region = CropRegion(x1: 2, y1: 2, x2: 5, y2: 5)
        let cropped = region.apply(to: frame, fill: 99)

        XCTAssertEqual(cropped.width, 3)
        XCTAssertEqual(cropped.height, 3)
        XCTAssertEqual(cropped.bytes, [
            10, 11, 99,
            14, 15, 99,
            99, 99, 99,
        ])
    }

    func testCropVideoBackendWrapsSource() async throws {
        let bytes = (0..<16).map { UInt8($0) }
        let source = FixedBackend(
            raw: RawFrame(height: 4, width: 4, channels: 1, bytes: bytes),
            count: 7,
            fps: 24)
        let region = CropRegion(x1: 1, y1: 1, x2: 3, y2: 3)
        let backend = CropVideoBackend(source: source, crop: region)

        XCTAssertEqual(backend.frameCount, 7, "frame count passes through from source")
        XCTAssertEqual(backend.fps, 24, "fps passes through from source")
        XCTAssertEqual(backend.frameSize?.width, 2)
        XCTAssertEqual(backend.frameSize?.height, 2)
        XCTAssertEqual(backend.frameSize?.channels, 1)

        let cropped = try await backend.rawFrame(at: 0)
        XCTAssertEqual(cropped.bytes, [5, 6, 9, 10])

        let image = try await backend.frame(at: 0)
        XCTAssertEqual(image.width, 2)
        XCTAssertEqual(image.height, 2)
    }

    func testMakeCropBackendFromMetadata() {
        let video = Video(filename: "crop", backendType: Video.cropBackendType)
        video.backendMetadata["crop"] = [1, 1, 3, 3]
        XCTAssertTrue(video.isCropVideo)

        let region = video.cropRegion
        XCTAssertEqual(region?.x1, 1)
        XCTAssertEqual(region?.x2, 3)

        let source = FixedBackend(
            raw: RawFrame(height: 4, width: 4, channels: 1, bytes: (0..<16).map { UInt8($0) }))
        let backend = video.makeCropBackend(source: source)
        XCTAssertNotNil(backend)
        XCTAssertEqual(backend?.crop.width, 2)
    }
}
