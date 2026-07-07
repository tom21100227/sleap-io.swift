import XCTest
@testable import SleapIO

/// E5.3: TrackMatcher / VideoMatcher and Video path/content/shape matching.
final class TrackVideoMatcherTests: XCTestCase {

    // MARK: - Helpers

    private func makeVideo(
        _ filename: String,
        backendType: String = "media",
        metadata: [String: Any] = [:],
        frames: Int? = nil,
        size: (Int, Int, Int)? = nil
    ) -> Video {
        let v = Video(filename: filename, backendType: backendType, backendMetadata: metadata)
        v.frameCount = frames
        v.frameSize = size.map { (height: $0.0, width: $0.1, channels: $0.2) }
        return v
    }

    // MARK: - Track.matches

    func testTrackMatchesByName() {
        let a = Track(name: "mouse")
        let b = Track(name: "mouse")
        let c = Track(name: "rat")

        // Distinct objects with the same name match by NAME, not by IDENTITY.
        XCTAssertTrue(a.matches(b, method: .name))
        XCTAssertFalse(a.matches(b, method: .identity))

        // Different names never match by NAME.
        XCTAssertFalse(a.matches(c, method: .name))

        // Same object matches under both methods.
        XCTAssertTrue(a.matches(a, method: .name))
        XCTAssertTrue(a.matches(a, method: .identity))

        // Default method is NAME.
        XCTAssertTrue(a.matches(b))
    }

    // MARK: - TrackMatcher

    func testTrackMatcherNameVsIdentity() {
        let a = Track(name: "t")
        let b = Track(name: "t")

        let byName = TrackMatcher(method: .name)
        let byIdentity = TrackMatcher(method: .identity)

        XCTAssertTrue(byName.match(a, b))
        XCTAssertFalse(byIdentity.match(a, b))
        XCTAssertTrue(byIdentity.match(a, a))

        // Default matcher uses NAME.
        XCTAssertTrue(TrackMatcher().match(a, b))

        // Presets.
        XCTAssertTrue(TrackMatcher.nameMatcher.match(a, b))
        XCTAssertFalse(TrackMatcher.identityMatcher.match(a, b))
    }

    func testTrackMatcherFirstMatch() {
        let target = Track(name: "b")
        let candidates = [Track(name: "a"), Track(name: "b"), Track(name: "b")]

        let match = TrackMatcher(method: .name).firstMatch(for: target, in: candidates)
        XCTAssertTrue(match === candidates[1])

        // Identity matcher finds nothing among distinct objects.
        XCTAssertNil(TrackMatcher(method: .identity).firstMatch(for: target, in: candidates))
    }

    // MARK: - Video.matchesPath

    func testMatchesPathBasenameVsStrict() {
        let a = makeVideo("/dir1/clip.mp4")
        let b = makeVideo("/dir2/clip.mp4")
        let c = makeVideo("/dir2/other.mp4")

        // Non-strict: same basename matches even in different directories.
        XCTAssertTrue(a.matchesPath(b, strict: false))
        XCTAssertFalse(a.matchesPath(c, strict: false))

        // Strict: different (non-existent) paths do not match.
        XCTAssertFalse(a.matchesPath(b, strict: true))

        // Strict: identical path strings match.
        let d = makeVideo("/dir1/clip.mp4")
        XCTAssertTrue(a.matchesPath(d, strict: true))
    }

    func testMatchesPathFileURLNormalization() {
        let a = makeVideo("file:///dir/clip.mp4")
        let b = makeVideo("/dir/clip.mp4")
        XCTAssertTrue(a.matchesPath(b, strict: true))
    }

    func testMatchesPathStrictResolvesSymlink() throws {
        let tmp = FileManager.default.temporaryDirectory
        let real = tmp.appendingPathComponent("mp_real_\(UUID().uuidString).mp4")
        let link = tmp.appendingPathComponent("mp_link_\(UUID().uuidString).mp4")
        try "x".write(to: real, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        defer {
            try? FileManager.default.removeItem(at: link)
            try? FileManager.default.removeItem(at: real)
        }

        let a = makeVideo(real.path)
        let b = makeVideo(link.path)
        // Different path strings, but both exist and resolve to the same file.
        XCTAssertTrue(a.matchesPath(b, strict: true))
    }

    // MARK: - Video.matchesShape

    func testMatchesShapeIgnoresFrameCount() {
        let a = makeVideo("/a.mp4", frames: 100, size: (480, 640, 3))
        let b = makeVideo("/b.mp4", frames: 50, size: (480, 640, 3))
        let c = makeVideo("/c.mp4", frames: 100, size: (480, 641, 3))

        // Same H/W/C but different frame count still matches by shape.
        XCTAssertTrue(a.matchesShape(b))
        // Different width does not match.
        XCTAssertFalse(a.matchesShape(c))
    }

    func testMatchesShapeUnknownIsFalse() {
        let a = makeVideo("/a.mp4")
        let b = makeVideo("/b.mp4", frames: 10, size: (10, 10, 3))
        XCTAssertFalse(a.matchesShape(b))
        XCTAssertFalse(a.matchesShape(a))
    }

    func testMatchesShapeFromMetadata() {
        // Shape supplied via backendMetadata["shape"] (frames, H, W, C).
        let a = makeVideo("/a.mp4", metadata: ["shape": [100, 480, 640, 3]])
        let b = makeVideo("/b.mp4", frames: 7, size: (480, 640, 3))
        XCTAssertTrue(a.matchesShape(b))
    }

    // MARK: - Video.matchesContent

    func testMatchesContentShapeAndBackend() {
        let a = makeVideo("/a.mp4", frames: 100, size: (480, 640, 3))
        let b = makeVideo("/b.mp4", frames: 100, size: (480, 640, 3))
        XCTAssertTrue(a.matchesContent(b))

        // Different frame count => different content.
        let c = makeVideo("/c.mp4", frames: 50, size: (480, 640, 3))
        XCTAssertFalse(a.matchesContent(c))

        // Same shape but different backend type => different content.
        let d = makeVideo("/d.slp", backendType: "hdf5", frames: 100, size: (480, 640, 3))
        XCTAssertFalse(a.matchesContent(d))
    }

    // MARK: - Video.hasOverlappingImages

    func testHasOverlappingImages() {
        let a = makeVideo(
            "seqA", backendType: "imageSequence",
            metadata: ["filenames": ["/x/img1.png", "/x/img2.png"]]
        )
        let b = makeVideo(
            "seqB", backendType: "imageSequence",
            metadata: ["filenames": ["/y/img2.png", "/y/img3.png"]]
        )
        let c = makeVideo(
            "seqC", backendType: "imageSequence",
            metadata: ["filenames": ["/z/img9.png"]]
        )

        XCTAssertTrue(a.hasOverlappingImages(b))   // img2.png shared
        XCTAssertFalse(a.hasOverlappingImages(c))  // no overlap

        // Non-image-sequence videos never overlap.
        let media = makeVideo("/m.mp4")
        XCTAssertFalse(media.hasOverlappingImages(a))
    }

    // MARK: - Video.isSameFile

    func testIsSameFileIdentityAndString() {
        let v = makeVideo("/data/clip.mp4")
        XCTAssertTrue(v.isSameFile(as: v))

        // Distinct objects, identical (non-existent) path string.
        let w = makeVideo("/data/clip.mp4")
        XCTAssertTrue(v.isSameFile(as: w))

        // Different path string, same basename: NOT the same file.
        let other = makeVideo("/elsewhere/clip.mp4")
        XCTAssertFalse(v.isSameFile(as: other))
    }

    func testIsSameFileNormalizesFileURL() {
        let a = makeVideo("file:///data/clip.mp4")
        let b = makeVideo("/data/clip.mp4")
        XCTAssertTrue(a.isSameFile(as: b))
    }

    func testIsSameFileTraversesProvenanceChain() {
        let original = makeVideo("/root/original.mp4")
        let embedded = makeVideo("/proj.pkg.slp", backendType: "hdf5")
        embedded.sourceVideo = original

        // Embedded video's root is `original`, so it is the same file as a
        // fresh video pointing at the original path.
        let reference = makeVideo("/root/original.mp4")
        XCTAssertTrue(embedded.isSameFile(as: reference))
        XCTAssertTrue(reference.isSameFile(as: embedded))

        // originalVideo exposes the chain root.
        XCTAssertTrue(embedded.originalVideo === original)
        XCTAssertNil(original.originalVideo)
    }

    func testIsSameFileHDF5DatasetDisambiguation() {
        let a = makeVideo(
            "/f.slp", backendType: "hdf5", metadata: ["dataset": "video0"])
        let sameDataset = makeVideo(
            "/f.slp", backendType: "hdf5", metadata: ["dataset": "video0"])
        let otherDataset = makeVideo(
            "/f.slp", backendType: "hdf5", metadata: ["dataset": "video1"])

        XCTAssertTrue(a.isSameFile(as: sameDataset))
        XCTAssertFalse(a.isSameFile(as: otherDataset))
    }

    func testIsSameFileDetectsSymlink() throws {
        let tmp = FileManager.default.temporaryDirectory
        let real = tmp.appendingPathComponent("sf_real_\(UUID().uuidString).mp4")
        let link = tmp.appendingPathComponent("sf_link_\(UUID().uuidString).mp4")
        try "x".write(to: real, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        defer {
            try? FileManager.default.removeItem(at: link)
            try? FileManager.default.removeItem(at: real)
        }

        let a = makeVideo(real.path)
        let b = makeVideo(link.path)
        XCTAssertTrue(a.isSameFile(as: b))

        // Two distinct real files are not the same file.
        let other = tmp.appendingPathComponent("sf_other_\(UUID().uuidString).mp4")
        try "y".write(to: other, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: other) }
        XCTAssertFalse(a.isSameFile(as: makeVideo(other.path)))
    }

    // MARK: - VideoMatcher: PATH / BASENAME / CONTENT / SHAPE

    func testVideoMatcherPath() {
        let a = makeVideo("/dir1/clip.mp4")
        let b = makeVideo("/dir2/clip.mp4")

        // Strict PATH: different directories do not match.
        XCTAssertFalse(VideoMatcher(method: .path, strict: true).match(a, b))
        // Lenient PATH: same basename matches.
        XCTAssertTrue(VideoMatcher(method: .path, strict: false).match(a, b))
        // Preset strict path matcher.
        XCTAssertFalse(VideoMatcher.pathMatcher.match(a, b))
    }

    func testVideoMatcherBasename() {
        let a = makeVideo("/dir1/clip.mp4")
        let b = makeVideo("/dir2/clip.mp4")
        let c = makeVideo("/dir2/nope.mp4")
        XCTAssertTrue(VideoMatcher(method: .basename).match(a, b))
        XCTAssertFalse(VideoMatcher(method: .basename).match(a, c))
    }

    func testVideoMatcherContent() {
        let a = makeVideo("/a.mp4", frames: 10, size: (5, 5, 3))
        let b = makeVideo("/b.mp4", frames: 10, size: (5, 5, 3))
        let c = makeVideo("/c.mp4", frames: 11, size: (5, 5, 3))
        XCTAssertTrue(VideoMatcher(method: .content).match(a, b))
        XCTAssertFalse(VideoMatcher(method: .content).match(a, c))
    }

    func testVideoMatcherShape() {
        let a = makeVideo("/a.mp4", frames: 10, size: (5, 5, 3))
        let b = makeVideo("/b.mp4", frames: 999, size: (5, 5, 3))
        let c = makeVideo("/c.mp4", frames: 10, size: (5, 6, 3))
        XCTAssertTrue(VideoMatcher(method: .shape).match(a, b))
        XCTAssertFalse(VideoMatcher(method: .shape).match(a, c))
    }

    func testVideoMatcherImageDedup() {
        let a = makeVideo(
            "seqA", backendType: "imageSequence",
            metadata: ["filenames": ["/x/1.png", "/x/2.png"]])
        let b = makeVideo(
            "seqB", backendType: "imageSequence",
            metadata: ["filenames": ["/y/2.png"]])
        XCTAssertTrue(VideoMatcher(method: .imageDedup).match(a, b))
    }

    // MARK: - VideoMatcher: AUTO cascade

    func testVideoMatcherAutoExactPath() {
        let a = makeVideo("/data/clip.mp4")
        let b = makeVideo("/data/clip.mp4")
        XCTAssertTrue(VideoMatcher(method: .auto).match(a, b))
    }

    func testVideoMatcherAutoBasenameFallback() {
        // Same basename, different dir, no shape info => not rejected, matches
        // via the basename step of the cascade.
        let a = makeVideo("/dir1/clip.mp4")
        let b = makeVideo("/dir2/clip.mp4")
        XCTAssertTrue(VideoMatcher.autoMatcher.match(a, b))
    }

    func testVideoMatcherAutoRejectsIncompatibleShape() {
        // Same basename, but different frame counts => shape rejection wins.
        let a = makeVideo("/dir1/clip.mp4", frames: 100, size: (10, 10, 3))
        let b = makeVideo("/dir2/clip.mp4", frames: 50, size: (10, 10, 3))
        XCTAssertFalse(VideoMatcher(method: .auto).match(a, b))
    }

    func testVideoMatcherAutoIgnoresChannelDifferenceForRejection() {
        // Channels differ but frames/H/W match => not rejected; basename matches.
        let a = makeVideo("/dir1/clip.mp4", frames: 100, size: (10, 10, 3))
        let b = makeVideo("/dir2/clip.mp4", frames: 100, size: (10, 10, 1))
        XCTAssertTrue(VideoMatcher(method: .auto).match(a, b))
    }

    // MARK: - Rejection helpers

    func testShapesCompatible() {
        let a = makeVideo("/a.mp4", frames: 100, size: (10, 10, 3))
        let b = makeVideo("/b.mp4", frames: 100, size: (10, 10, 1)) // channel differs
        let c = makeVideo("/c.mp4", frames: 50, size: (10, 10, 3))  // frames differ
        let unknown = makeVideo("/u.mp4")

        XCTAssertTrue(VideoMatcher.shapesCompatible(a, b) == true)   // channels ignored
        XCTAssertTrue(VideoMatcher.shapesCompatible(a, c) == false)  // frames differ
        XCTAssertNil(VideoMatcher.shapesCompatible(a, unknown))      // unknown
    }

    func testOriginalVideosConflictNoProvenance() {
        let a = makeVideo("/dir1/clip.mp4")
        let b = makeVideo("/dir2/clip.mp4")
        // Neither has provenance => no conflict.
        XCTAssertFalse(VideoMatcher.originalVideosConflict(a, b))
    }

    func testOriginalVideosConflictUnverifiable() {
        // Both have provenance but roots don't exist => cannot verify => no conflict.
        let a = makeVideo("/emb1.slp", backendType: "hdf5")
        a.sourceVideo = makeVideo("/nope/one.mp4")
        let b = makeVideo("/emb2.slp", backendType: "hdf5")
        b.sourceVideo = makeVideo("/nope/two.mp4")
        XCTAssertFalse(VideoMatcher.originalVideosConflict(a, b))
    }

    func testOriginalVideosConflictVerifiablyDifferent() throws {
        let tmp = FileManager.default.temporaryDirectory
        let fileA = tmp.appendingPathComponent("conf_a_\(UUID().uuidString).mp4")
        let fileB = tmp.appendingPathComponent("conf_b_\(UUID().uuidString).mp4")
        try "a".write(to: fileA, atomically: true, encoding: .utf8)
        try "b".write(to: fileB, atomically: true, encoding: .utf8)
        defer {
            try? FileManager.default.removeItem(at: fileA)
            try? FileManager.default.removeItem(at: fileB)
        }

        // Same basename so path/basename would otherwise match, but provenance
        // points to two verifiably different existing files.
        let a = makeVideo("/proj/clip.mp4", frames: 10, size: (5, 5, 3))
        a.sourceVideo = makeVideo(fileA.path)
        let b = makeVideo("/proj/clip.mp4", frames: 10, size: (5, 5, 3))
        b.sourceVideo = makeVideo(fileB.path)

        XCTAssertTrue(VideoMatcher.originalVideosConflict(a, b))
        // AUTO must reject despite the matching basename/shape.
        XCTAssertFalse(VideoMatcher(method: .auto).match(a, b))
    }
}
