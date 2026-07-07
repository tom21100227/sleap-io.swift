import CoreGraphics
import XCTest
@testable import SleapIO
@testable import SleapHDF5
import SleapVideo

/// Thread-safe recorder for progress-fraction callbacks.
private final class EmbedProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Double] = []
    func append(_ v: Double) { lock.lock(); storage.append(v); lock.unlock() }
    var values: [Double] { lock.lock(); defer { lock.unlock() }; return storage }
}

/// E9.1: embed-on-save pipeline (`embed=` selection + `VideoReferenceMode`).
///
/// Exercises the real embed path: decode frames from a (synthetic) external video
/// backend, re-encode to PNG/JPEG, write per-video `/videoN` groups with
/// `source_video` lineage, then reload and verify the frames, their content, and
/// the preserved lineage.
final class EmbedPipelineTests: XCTestCase {

    // MARK: - Synthetic external video backend

    /// A stand-in external video backend that renders a distinct solid-gray frame
    /// per index, so re-decoded embedded frames can be matched back to their
    /// source index. Gray value = `20 + index * 30` (clamped), R == G == B.
    private final class SyntheticVideoBackend: VideoBackend, @unchecked Sendable {
        let widthPx: Int
        let heightPx: Int
        let count: Int

        init(width: Int = 16, height: Int = 12, count: Int = 12) {
            self.widthPx = width
            self.heightPx = height
            self.count = count
        }

        var frameCount: Int? { count }
        var frameSize: (height: Int, width: Int, channels: Int)? { (heightPx, widthPx, 3) }
        var fps: Double? { nil }

        static func grayValue(for index: Int) -> UInt8 { UInt8(min(255, 20 + index * 30)) }

        func frame(at index: Int) async throws -> CGImage {
            let value = Self.grayValue(for: index)
            let g = CGFloat(value) / 255.0
            let colorSpace = CGColorSpaceCreateDeviceRGB()
            let ctx = CGContext(
                data: nil,
                width: widthPx,
                height: heightPx,
                bitsPerComponent: 8,
                bytesPerRow: widthPx * 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )!
            ctx.setFillColor(CGColor(red: g, green: g, blue: g, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: widthPx, height: heightPx))
            return ctx.makeImage()!
        }
    }

    // MARK: - Helpers

    private func tempURL(extension ext: String = "pkg.slp") -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("sleap_embed_\(UUID().uuidString).\(ext)")
    }

    private func fixtureURL(_ name: String) -> URL? {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // SleapHDF5Tests/
            .deletingLastPathComponent()  // Tests/
            .deletingLastPathComponent()  // package root
        let url = packageRoot.appendingPathComponent("Tests/Fixtures/\(name)")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Read the red channel of the center pixel of a decoded image.
    private func centerRed(_ image: CGImage) -> Int {
        let w = image.width, h = image.height
        var buffer = [UInt8](repeating: 0, count: w * h * 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        buffer.withUnsafeMutableBytes { raw in
            let ctx = CGContext(
                data: raw.baseAddress,
                width: w, height: h,
                bitsPerComponent: 8, bytesPerRow: w * 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )!
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        let offset = ((h / 2) * w + (w / 2)) * 4
        return Int(buffer[offset])
    }

    /// Build a Labels over a single external (synthetic-backed) video with user
    /// instances at `userFrames` and suggestions at `suggestionFrames`.
    private func makeLabels(
        filename: String = "external.mp4",
        userFrames: [Int],
        suggestionFrames: [Int],
        backend: SyntheticVideoBackend
    ) -> (Labels, Video) {
        let skeleton = Skeleton(name: "fly", nodes: [Node(name: "head"), Node(name: "tail")])
        let video = Video(filename: filename, backendType: "media")
        video.backend = backend
        video.frameCount = backend.count
        video.frameSize = backend.frameSize

        let frames = userFrames.map { idx in
            LabeledFrame(
                video: video,
                frameIndex: idx,
                instances: [Instance(
                    skeleton: skeleton,
                    points: PointsArray(points: [
                        Point(x: 1, y: 2, visible: true, complete: true),
                        Point(x: 3, y: 4, visible: true, complete: true),
                    ])
                )]
            )
        }
        let suggestions = suggestionFrames.map { SuggestionFrame(video: video, frameIndex: $0) }

        let labels = Labels(
            frameStore: EagerFrameStore(frames: frames),
            videos: [video],
            skeletons: [skeleton],
            tracks: [],
            suggestions: suggestions
        )
        return (labels, video)
    }

    // MARK: - Round-trip: embed = .all

    func testEmbedAllRoundTripEmbedsFramesAndPreservesLineage() async throws {
        let backend = SyntheticVideoBackend()
        let (labels, _) = makeLabels(userFrames: [1, 4], suggestionFrames: [7], backend: backend)

        // Baseline: nothing is embedded yet.
        XCTAssertFalse(labels.hasEmbeddedVideo)

        let outputURL = tempURL()
        defer { try? FileManager.default.removeItem(at: outputURL) }
        try await SLPWriter.write(labels, to: outputURL.path, embed: .all, imageFormat: .png)

        let reloaded = try await Labels.load(from: outputURL)
        reloaded.materialize()

        // The external video is now an embedded HDF5 video.
        XCTAssertTrue(reloaded.hasEmbeddedVideo)
        guard let embedded = reloaded.videos[0].backend as? SleapHDF5EmbeddedVideoBackend else {
            return XCTFail("Expected an embedded video backend after embed=all")
        }

        // Exactly the user + suggestion frames were embedded (sorted-unique union).
        XCTAssertEqual(Set(embedded.embeddedFrames.keys), Set([1, 4, 7]))

        // Each embedded frame decodes to the source dimensions and preserves the
        // per-frame content (proving frame_numbers maps back to the right frame).
        for idx in [1, 4, 7] {
            let image = try await reloaded.videos[0].frame(at: idx)
            XCTAssertEqual(image.width, backend.widthPx, "frame \(idx) width")
            XCTAssertEqual(image.height, backend.heightPx, "frame \(idx) height")
            let expected = Int(SyntheticVideoBackend.grayValue(for: idx))
            XCTAssertLessThanOrEqual(abs(centerRed(image) - expected), 24,
                                     "frame \(idx) content should survive PNG embedding")
        }

        // Source-video lineage: the embedded video points back to the external video.
        let source = reloaded.videos[0].sourceVideo
        XCTAssertNotNil(source, "embedded video should carry source_video lineage")
        XCTAssertEqual(source?.filename, "external.mp4")
    }

    func testEmbedAllDistinctFramesDecodeDistinctly() async throws {
        let backend = SyntheticVideoBackend()
        let (labels, _) = makeLabels(userFrames: [0, 5], suggestionFrames: [], backend: backend)

        let outputURL = tempURL()
        defer { try? FileManager.default.removeItem(at: outputURL) }
        try await SLPWriter.write(labels, to: outputURL.path, embed: .all, imageFormat: .png)

        let reloaded = try await Labels.load(from: outputURL)
        reloaded.materialize()

        let img0 = try await reloaded.videos[0].frame(at: 0)
        let img5 = try await reloaded.videos[0].frame(at: 5)
        XCTAssertNotEqual(centerRed(img0), centerRed(img5),
                          "frames at different source indices must decode to different content")
    }

    // MARK: - Selection: user vs. all vs. suggestions vs. list

    func testEmbedUserSelectsOnlyUserFrames() async throws {
        let backend = SyntheticVideoBackend()
        let (labels, _) = makeLabels(userFrames: [1, 4], suggestionFrames: [7], backend: backend)

        let outputURL = tempURL()
        defer { try? FileManager.default.removeItem(at: outputURL) }
        try await SLPWriter.write(labels, to: outputURL.path, embed: .user, imageFormat: .png)

        let reloaded = try await Labels.load(from: outputURL)
        reloaded.materialize()
        let embedded = try XCTUnwrap(reloaded.videos[0].backend as? SleapHDF5EmbeddedVideoBackend)
        XCTAssertEqual(Set(embedded.embeddedFrames.keys), Set([1, 4]),
                       "embed=user must exclude the suggestion-only frame 7")
    }

    func testEmbedSuggestionsSelectsOnlySuggestionFrames() async throws {
        let backend = SyntheticVideoBackend()
        let (labels, _) = makeLabels(userFrames: [1, 4], suggestionFrames: [7], backend: backend)

        let outputURL = tempURL()
        defer { try? FileManager.default.removeItem(at: outputURL) }
        try await SLPWriter.write(labels, to: outputURL.path, embed: .suggestions, imageFormat: .png)

        let reloaded = try await Labels.load(from: outputURL)
        reloaded.materialize()
        let embedded = try XCTUnwrap(reloaded.videos[0].backend as? SleapHDF5EmbeddedVideoBackend)
        XCTAssertEqual(Set(embedded.embeddedFrames.keys), Set([7]))
    }

    func testEmbedExplicitListSelection() async throws {
        let backend = SyntheticVideoBackend()
        let (labels, video) = makeLabels(userFrames: [1, 4], suggestionFrames: [7], backend: backend)

        let outputURL = tempURL()
        defer { try? FileManager.default.removeItem(at: outputURL) }
        try await SLPWriter.write(
            labels, to: outputURL.path,
            embed: .list([(video: video, frameIndex: 2), (video: video, frameIndex: 9)]),
            imageFormat: .png)

        let reloaded = try await Labels.load(from: outputURL)
        reloaded.materialize()
        let embedded = try XCTUnwrap(reloaded.videos[0].backend as? SleapHDF5EmbeddedVideoBackend)
        XCTAssertEqual(Set(embedded.embeddedFrames.keys), Set([2, 9]))
    }

    // MARK: - Frame selection (unit)

    func testFrameSelectionModes() {
        let backend = SyntheticVideoBackend()
        let (labels, video) = makeLabels(userFrames: [4, 1, 4], suggestionFrames: [7], backend: backend)

        let user = EmbedPipeline.frameSelection(labels: labels, embed: .user)
        XCTAssertEqual(user[0] ?? [], [1, 4], "sorted + de-duplicated user frames")

        let suggestions = EmbedPipeline.frameSelection(labels: labels, embed: .suggestions)
        XCTAssertEqual(suggestions[0] ?? [], [7])

        let all = EmbedPipeline.frameSelection(labels: labels, embed: .all)
        XCTAssertEqual(all[0] ?? [], [1, 4, 7], "all == user + suggestions, sorted/unique")

        let userAndSuggestions = EmbedPipeline.frameSelection(labels: labels, embed: .userAndSuggestions)
        XCTAssertEqual(userAndSuggestions[0] ?? [], [1, 4, 7])

        let none = EmbedPipeline.frameSelection(labels: labels, embed: .none)
        XCTAssertTrue(none.isEmpty)

        let source = EmbedPipeline.frameSelection(labels: labels, embed: .source)
        XCTAssertTrue(source.isEmpty)

        let list = EmbedPipeline.frameSelection(
            labels: labels, embed: .list([(video: video, frameIndex: 3), (video: video, frameIndex: 3)]))
        XCTAssertEqual(list[0] ?? [], [3])
    }

    func testEmbedSelectionMapsToVideoReferenceMode() {
        XCTAssertEqual(EmbedSelection.none.referenceMode, .preserveSource)
        XCTAssertEqual(EmbedSelection.source.referenceMode, .restoreOriginal)
        XCTAssertEqual(EmbedSelection.all.referenceMode, .embed)
        XCTAssertEqual(EmbedSelection.user.referenceMode, .embed)
        XCTAssertEqual(EmbedSelection.suggestions.referenceMode, .embed)
        XCTAssertEqual(EmbedSelection.userAndSuggestions.referenceMode, .embed)
        XCTAssertEqual(EmbedSelection.list([]).referenceMode, .embed)
    }

    func testFrameSelectionSkipsForeignVideo() {
        let backend = SyntheticVideoBackend()
        let (labels, _) = makeLabels(userFrames: [1], suggestionFrames: [], backend: backend)
        let foreign = Video(filename: "other.mp4", backendType: "media")

        let list = EmbedPipeline.frameSelection(
            labels: labels, embed: .list([(video: foreign, frameIndex: 0)]))
        XCTAssertTrue(list.isEmpty, "frames of a video not in labels.videos are skipped")
    }

    // MARK: - No-embed default leaves the external video unchanged

    func testEmbedNoneKeepsExternalVideo() async throws {
        let backend = SyntheticVideoBackend()
        let (labels, _) = makeLabels(userFrames: [1, 4], suggestionFrames: [7], backend: backend)

        let outputURL = tempURL(extension: "slp")
        defer { try? FileManager.default.removeItem(at: outputURL) }
        // Default embed == .none.
        try await SLPWriter.write(labels, to: outputURL.path)

        let reloaded = try await Labels.load(from: outputURL)
        reloaded.materialize()
        XCTAssertFalse(reloaded.hasEmbeddedVideo, "embed=.none must not embed frames")
        XCTAssertEqual(reloaded.videos[0].filename, "external.mp4")
        XCTAssertNil(reloaded.videos[0].sourceVideo)
    }

    // MARK: - Restore original (embed = .source)

    func testEmbedSourceRestoresOriginalVideo() async throws {
        guard let url = fixtureURL("packaged_frames_v1_5.pkg.slp") else {
            throw XCTSkip("Fixture 'packaged_frames_v1_5.pkg.slp' not found")
        }
        let labels = try await Labels.load(from: url)
        labels.materialize()
        XCTAssertTrue(labels.hasEmbeddedVideo)

        guard let source = labels.videos[0].sourceVideo else {
            throw XCTSkip("Fixture's embedded video carries no source_video lineage to restore")
        }
        let sourceFilename = source.filename

        let outputURL = tempURL(extension: "slp")
        defer { try? FileManager.default.removeItem(at: outputURL) }
        try await SLPWriter.write(labels, to: outputURL.path, embed: .source)

        let reloaded = try await Labels.load(from: outputURL)
        reloaded.materialize()

        // The embedded dataset is gone; the video references its original source.
        XCTAssertFalse(reloaded.hasEmbeddedVideo, "embed=.source must not embed frames")
        XCTAssertEqual(reloaded.videos[0].filename, sourceFilename,
                       "embed=.source must restore the original external video path")
    }

    // MARK: - JPEG format path

    func testEmbedAllWithJPEGFormat() async throws {
        let backend = SyntheticVideoBackend()
        let (labels, _) = makeLabels(userFrames: [2], suggestionFrames: [], backend: backend)

        let outputURL = tempURL()
        defer { try? FileManager.default.removeItem(at: outputURL) }
        try await SLPWriter.write(labels, to: outputURL.path, embed: .all, imageFormat: .jpeg(quality: 0.9))

        let reloaded = try await Labels.load(from: outputURL)
        reloaded.materialize()
        XCTAssertTrue(reloaded.hasEmbeddedVideo)
        let image = try await reloaded.videos[0].frame(at: 2)
        XCTAssertEqual(image.width, backend.widthPx)
        XCTAssertEqual(image.height, backend.heightPx)
    }

    // MARK: - Progress + cancellation

    func testEmbedProgressIsMonotonicAndEndsAtOne() async throws {
        let backend = SyntheticVideoBackend()
        let (labels, _) = makeLabels(userFrames: [0, 1, 2], suggestionFrames: [3, 4], backend: backend)

        let outputURL = tempURL()
        defer { try? FileManager.default.removeItem(at: outputURL) }

        let recorder = EmbedProgressRecorder()
        try await SLPWriter.write(labels, to: outputURL.path, embed: .all, imageFormat: .png,
                                  progress: { recorder.append($0) })

        let values = recorder.values
        XCTAssertFalse(values.isEmpty)
        XCTAssertEqual(values.last, 1.0)
        XCTAssertTrue(values.allSatisfy { $0 >= 0 && $0 <= 1 })
        XCTAssertTrue(zip(values, values.dropFirst()).allSatisfy { $0 <= $1 },
                      "embed progress must be monotonically non-decreasing")
    }

    func testEmbedCancellationIsTolerant() async throws {
        let backend = SyntheticVideoBackend(count: 64)
        let (labels, _) = makeLabels(
            userFrames: Array(0..<32), suggestionFrames: Array(32..<64), backend: backend)

        let outputURL = tempURL()
        defer { try? FileManager.default.removeItem(at: outputURL) }

        let task = Task {
            try await SLPWriter.write(labels, to: outputURL.path, embed: .all, imageFormat: .png)
        }
        task.cancel()

        do {
            try await task.value
        } catch is CancellationError {
            return
        } catch {
            // A non-cancellation completion is also acceptable if the write raced
            // ahead of the cancel; the contract is only that cancel is tolerated.
        }
    }
}
