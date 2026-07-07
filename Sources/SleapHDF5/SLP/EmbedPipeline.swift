import Foundation
import CoreGraphics
import SleapIO
import SleapVideo

// MARK: - Public embed configuration

/// How a video is referenced in a saved SLP file, mirroring Python sleap-io's
/// `VideoReferenceMode` (`EMBED` / `RESTORE_ORIGINAL` / `PRESERVE_SOURCE`).
///
/// This enum names the three high-level strategies the embed pipeline supports.
/// Callers select a strategy indirectly through ``EmbedSelection`` (the `embed=`
/// argument), which the pipeline maps onto a per-video mode:
///   - ``EmbedSelection/all`` / `.user` / `.suggestions` / `.userAndSuggestions`
///     / `.list` → ``embed`` for the selected videos.
///   - ``EmbedSelection/source`` → ``restoreOriginal`` for embedded videos that
///     carry a source-video lineage.
///   - ``EmbedSelection/none`` → ``preserveSource`` (the default; already-embedded
///     groups are byte-copied and external videos are referenced unchanged).
public enum VideoReferenceMode: Sendable, Equatable {
    /// Decode selected frames and store them as embedded PNG/JPEG image data.
    case embed
    /// Drop any embedding and reference the original/source external video.
    case restoreOriginal
    /// Preserve an already-embedded video's frames verbatim (byte copy).
    case preserveSource
}

/// Which frames to embed when saving an SLP file, mirroring Python sleap-io's
/// `embed=` argument to `Labels.save`.
///
/// The selection is resolved against a ``SleapIO/Labels`` into a set of
/// `(video, frameIndex)` pairs that are then decoded via the video backends and
/// re-encoded into per-video `/videoN` HDF5 groups. The default ``none`` leaves
/// the writer's behavior unchanged (external videos stay external; already
/// embedded videos are preserved by byte-copy).
public enum EmbedSelection: Sendable {
    /// Do not embed. External videos stay referenced by path; already-embedded
    /// videos are preserved verbatim. This is the writer's historical behavior.
    case none
    /// All user-labeled frames plus suggestion frames. Mirrors Python
    /// `embed="all"` / `embed=True`, both of which alias `"user+suggestions"`.
    case all
    /// Frames that contain at least one user (non-predicted) instance. Mirrors
    /// Python `embed="user"`.
    case user
    /// Suggestion frames. Mirrors Python `embed="suggestions"`.
    case suggestions
    /// User-labeled frames plus suggestion frames. Mirrors Python
    /// `embed="user+suggestions"`.
    case userAndSuggestions
    /// Embed no images and restore the original/source video for any video that
    /// carries a source-video lineage. Mirrors Python `embed="source"`.
    case source
    /// An explicit list of `(video, frameIndex)` pairs. Mirrors Python
    /// `embed=[(video, frame_idx), ...]`.
    case list([(video: Video, frameIndex: Int)])
}

extension EmbedSelection {
    /// The primary ``VideoReferenceMode`` this selection maps onto, mirroring how
    /// Python sleap-io translates the `embed=` argument into a per-video reference
    /// mode: ``EmbedSelection/none`` preserves existing sources, ``source``
    /// restores originals, and every frame-selecting case embeds image data.
    public var referenceMode: VideoReferenceMode {
        switch self {
        case .none: return .preserveSource
        case .source: return .restoreOriginal
        case .all, .user, .suggestions, .userAndSuggestions, .list: return .embed
        }
    }
}

// MARK: - Embed plan (internal)

/// Decoded and re-encoded frames for one video, ready to be written as an
/// embedded `/videoN` HDF5 group.
struct EmbeddedVideoPlan: Sendable {
    /// Source frame index → encoded image bytes, in ascending frame-index order.
    var frames: [(sourceFrameIdx: Int, data: Data)]
    /// Encoded image format identifier stored on the dataset (`"png"` or `"jpg"`).
    var format: String
    /// Channel order stored on the dataset. Frames are encoded from `CGImage`s in
    /// RGB order, so this is `"RGB"` and the reader performs no BGR swap.
    var channelOrder: String
    /// JSON lineage of the source (external) video for the `source_video` group.
    var sourceVideoJSON: String
    /// First embedded frame's pixel height (for the `shape` metadata).
    var height: Int
    /// First embedded frame's pixel width (for the `shape` metadata).
    var width: Int
    /// Channel count recorded in the `shape` metadata.
    var channels: Int
}

/// The resolved embed plan produced by ``EmbedPipeline/buildPlan(labels:embed:imageFormat:progress:)``.
///
/// `videos` maps a video's index within `labels.videos` to its decoded frame
/// data; `restoreOriginal` names video indices whose reference should be replaced
/// by their source/original external video (embed = ``EmbedSelection/source``).
struct EmbedPlan: Sendable {
    var videos: [Int: EmbeddedVideoPlan]
    var restoreOriginal: Set<Int>

    static let empty = EmbedPlan(videos: [:], restoreOriginal: [])

    /// Whether the plan neither embeds frames nor restores any source video, in
    /// which case the writer behaves exactly as it does without an embed request.
    var isEmpty: Bool { videos.isEmpty && restoreOriginal.isEmpty }
}

// MARK: - Embed pipeline

/// Builds the embed-on-save plan: selects frames per ``EmbedSelection``, decodes
/// them through the video backends, and re-encodes each to PNG/JPEG so they can
/// be written into per-video HDF5 groups with `source_video` lineage.
///
/// Mirrors Python sleap-io's `embed_videos` / `embed_frames`: the frame decoding
/// is async (backends are async), so the plan is built up front — before the
/// destination HDF5 file is opened for the synchronous write — and then handed to
/// ``SLPWriter``.
enum EmbedPipeline {

    /// Resolve an ``EmbedSelection`` into per-video sorted, de-duplicated frame
    /// indices, keyed by the video's index within `labels.videos`.
    ///
    /// Videos referenced by a selection but absent from `labels.videos` (e.g. an
    /// explicit ``EmbedSelection/list`` naming a foreign video) are skipped, since
    /// the writer addresses embedded groups by video index.
    static func frameSelection(labels: Labels, embed: EmbedSelection) -> [Int: [Int]] {
        var pairs: [(video: Video, frameIndex: Int)] = []
        switch embed {
        case .none, .source:
            return [:]
        case .user:
            pairs = labels.userLabeledFrames.map { (video: $0.video, frameIndex: $0.frameIndex) }
        case .suggestions:
            pairs = labels.suggestions.map { (video: $0.video, frameIndex: $0.frameIndex) }
        case .all, .userAndSuggestions:
            // Python aliases `"all"`/`True` to `"user+suggestions"`.
            pairs = labels.userLabeledFrames.map { (video: $0.video, frameIndex: $0.frameIndex) }
            pairs += labels.suggestions.map { (video: $0.video, frameIndex: $0.frameIndex) }
        case .list(let list):
            pairs = list
        }

        var videoIndexMap: [ObjectIdentifier: Int] = [:]
        for (i, v) in labels.videos.enumerated() { videoIndexMap[ObjectIdentifier(v)] = i }

        var byIndex: [Int: Set<Int>] = [:]
        for pair in pairs {
            guard let idx = videoIndexMap[ObjectIdentifier(pair.video)] else { continue }
            byIndex[idx, default: []].insert(pair.frameIndex)
        }
        return byIndex.mapValues { $0.sorted() }
    }

    /// Decode + re-encode the selected frames into an ``EmbedPlan``.
    ///
    /// - For ``EmbedSelection/none`` this returns ``EmbedPlan/empty`` without
    ///   touching any backend or the progress reporter, so the non-embedding save
    ///   path is unchanged.
    /// - For ``EmbedSelection/source`` this embeds nothing and records the video
    ///   indices whose reference should be restored to their source video.
    /// - Otherwise, each selected video's backend is opened (if needed) and the
    ///   chosen frames are decoded and re-encoded with `imageFormat`.
    ///
    /// Progress is reported as a fraction over the total number of frames decoded,
    /// and ``Swift/Task/checkCancellation()`` is polled per frame so a cancelled
    /// save aborts promptly while frames are still staged in memory.
    static func buildPlan(
        labels: Labels,
        embed: EmbedSelection,
        imageFormat: SaveOptions.EmbeddedImageFormat,
        progress: ProgressReporter?
    ) async throws -> EmbedPlan {
        if case .none = embed { return .empty }

        if case .source = embed {
            var restore: Set<Int> = []
            for (i, video) in labels.videos.enumerated()
                where video.backendType.lowercased().hasPrefix("hdf5") && video.sourceVideo != nil {
                restore.insert(i)
            }
            return EmbedPlan(videos: [:], restoreOriginal: restore)
        }

        let selection = frameSelection(labels: labels, embed: embed)
        guard !selection.isEmpty else { return .empty }

        let totalFrames = selection.values.reduce(0) { $0 + $1.count }
        var processed = 0

        let format = formatString(imageFormat)
        var planned: [Int: EmbeddedVideoPlan] = [:]

        for videoIndex in selection.keys.sorted() {
            try Task.checkCancellation()
            let frameIndices = selection[videoIndex]!
            guard !frameIndices.isEmpty else { continue }
            let video = labels.videos[videoIndex]

            // Ensure a decode backend is available (external media/image videos
            // open lazily). Embedded videos already carry a backend from load.
            if video.backend == nil {
                try await video.open()
            }

            var frames: [(sourceFrameIdx: Int, data: Data)] = []
            frames.reserveCapacity(frameIndices.count)
            var firstHeight = 0
            var firstWidth = 0

            for frameIdx in frameIndices {
                try Task.checkCancellation()
                let image = try await video.frame(at: frameIdx)
                let data = try encode(image, format: imageFormat, videoIndex: videoIndex, frameIndex: frameIdx)
                if frames.isEmpty {
                    firstHeight = image.height
                    firstWidth = image.width
                }
                frames.append((sourceFrameIdx: frameIdx, data: data))
                processed += 1
                if totalFrames > 0 {
                    progress?(Double(processed) / Double(totalFrames))
                }
            }

            let sourceVideoJSON = encodeSourceVideoJSON(for: video)
            planned[videoIndex] = EmbeddedVideoPlan(
                frames: frames,
                format: format,
                channelOrder: "RGB",
                sourceVideoJSON: sourceVideoJSON,
                height: firstHeight,
                width: firstWidth,
                channels: video.frameSize?.channels ?? 3
            )
        }

        return EmbedPlan(videos: planned, restoreOriginal: [])
    }

    // MARK: - Encoding helpers

    /// The dataset `format` string for an image format (`"png"` or `"jpg"`),
    /// matching Python sleap-io's embedded-image format labels.
    static func formatString(_ f: SaveOptions.EmbeddedImageFormat) -> String {
        switch f {
        case .png: return "png"
        case .jpeg: return "jpg"
        }
    }

    private static func encode(
        _ image: CGImage,
        format: SaveOptions.EmbeddedImageFormat,
        videoIndex: Int,
        frameIndex: Int
    ) throws -> Data {
        let encoded: Data?
        switch format {
        case .png:
            encoded = EmbeddedVideo.encodePNG(image: image)
        case .jpeg(let quality):
            encoded = EmbeddedVideo.encodeJPEG(image: image, quality: quality)
        }
        guard let data = encoded else {
            throw SleapIOError.videoError(
                "Failed to encode embedded frame \(frameIndex) of video \(videoIndex)")
        }
        return data
    }

    /// Serialize the source-video lineage for a video being embedded. The video
    /// as it stands (an external media/image source) becomes the `source_video`
    /// of the new embedded video, so the JSON is exactly ``SLPWriter/encodeVideo``
    /// of the current video — which recursively includes its own source chain.
    static func encodeSourceVideoJSON(for video: Video) -> String {
        let dict = SLPWriter.encodeVideo(video)
        guard let data = try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return json
    }
}
