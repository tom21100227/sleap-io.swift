import Foundation
import CoreGraphics

/// A video source providing frame images.
public final class Video: Hashable, @unchecked Sendable {
    /// Original imported or decoded source path.
    public let originalFilename: String

    /// Optional persisted override path that is written back on save.
    /// Used for permanent relocation without discarding provenance.
    public var persistedFilename: String?

    /// Effective active path used for open/save/export behavior.
    /// Resolves to `persistedFilename ?? originalFilename`.
    public var filename: String {
        persistedFilename ?? originalFilename
    }

    /// Number of frames, or nil if unknown until opened.
    public var frameCount: Int?

    /// Frame dimensions (height, width, channels), or nil if unknown.
    public var frameSize: (height: Int, width: Int, channels: Int)?

    /// The original source video, if this is a derived/embedded copy.
    public var sourceVideo: Video?

    /// Backend type identifier (e.g., "media", "hdf5", "imageSequence").
    public var backendType: String

    /// Backend metadata dictionary for serialization.
    public var backendMetadata: [String: Any]

    public init(filename: String,
                backendType: String = "media",
                backendMetadata: [String: Any] = [:]) {
        self.originalFilename = filename
        self.backendType = backendType
        self.backendMetadata = backendMetadata
    }

    // MARK: - Identity equality

    public static func == (lhs: Video, rhs: Video) -> Bool {
        lhs === rhs
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(ObjectIdentifier(self))
    }
}

// MARK: - Matching primitives (M2)
//
// Path/content/shape comparison helpers used by ``VideoMatcher`` and by
// project-level video de-duplication. These mirror the upstream sleap-io
// `Video.matches_path` / `matches_content` / `matches_shape` /
// `has_overlapping_images` methods and the module-level `is_same_file`
// helper in `sleap_io/model/matching.py`.
//
// Best-effort / adaptation notes:
// - The Swift ``Video`` stores a single ``filename`` string, whereas upstream
//   `ImageVideo` carries a *list* of image paths. Image-sequence file lists are
//   therefore read best-effort from `backendMetadata["filenames"]` (an
//   `[String]`) when ``backendType`` is `"imageSequence"`.
// - There is no live decode backend on this type, so backend identity is
//   approximated by ``backendType`` and shape is taken from
//   ``frameCount``/``frameSize`` (falling back to `backendMetadata["shape"]`).
// - The comparisons are pure (no filesystem access) except for the *strict*
//   path / same-file checks, which consult the filesystem only when both paths
//   exist locally (to resolve symlinks / detect hardlinks), and otherwise fall
//   back to pure string comparison.

extension Video {

    /// The root video in the ``sourceVideo`` provenance chain, or `nil` when
    /// this video is itself an original (it has no ``sourceVideo``).
    ///
    /// Mirrors `Video.original_video`: for a single-level embedding
    /// (`A` embeds from `B`) this returns `B`; for a multi-level chain
    /// (`A <- B <- C`) it returns `C`.
    public var originalVideo: Video? {
        guard var current = sourceVideo else { return nil }
        while let next = current.sourceVideo {
            current = next
        }
        return current
    }

    /// Whether this video has the same path as `other`.
    ///
    /// Mirrors `Video.matches_path`.
    ///
    /// - Parameters:
    ///   - other: The video to compare against.
    ///   - strict: When `true`, require the (resolved) paths to be identical.
    ///     When `false` (default), consider videos with the same basename
    ///     (last path component) as matching.
    /// - Returns: `true` if the paths match under the given strictness.
    ///
    /// For HDF5-embedded videos (`backendType == "hdf5"`) that carry embedding
    /// metadata, matching prioritizes `backendMetadata["source_filename"]`
    /// (and `["dataset"]` for disambiguation), since multiple embedded videos
    /// can share the same container path.
    public func matchesPath(_ other: Video, strict: Bool = false) -> Bool {
        // HDF5-embedded videos: prefer the embedded source filename + dataset.
        if backendType == "hdf5", other.backendType == "hdf5" {
            let selfSource = Video.metadataString(backendMetadata, "source_filename")
            let otherSource = Video.metadataString(other.backendMetadata, "source_filename")
            let selfDataset = Video.metadataString(backendMetadata, "dataset")
            let otherDataset = Video.metadataString(other.backendMetadata, "dataset")

            // Only take the embedded-video path when embedding metadata exists;
            // otherwise fall through to generic single-file comparison.
            if selfSource != nil || otherSource != nil
                || selfDataset != nil || otherDataset != nil {
                // Differing datasets => different embedded videos.
                if let a = selfDataset, let b = otherDataset, a != b { return false }
                if let a = selfSource, let b = otherSource {
                    return strict
                        ? Video.normalizedPath(a) == Video.normalizedPath(b)
                        : (a as NSString).lastPathComponent
                            == (b as NSString).lastPathComponent
                }
                if let a = selfDataset, let b = otherDataset { return a == b }
                return false
            }
        }

        // Image sequences: compare the full file lists (or their basenames).
        if let selfList = imageFilenames, let otherList = other.imageFilenames {
            if strict { return selfList == otherList }
            let selfBase = selfList.map { ($0 as NSString).lastPathComponent }
            let otherBase = otherList.map { ($0 as NSString).lastPathComponent }
            return selfBase == otherBase
        } else if imageFilenames != nil || other.imageFilenames != nil {
            // One is an image sequence, the other a single file: cannot match.
            return false
        }

        // Both are single files.
        let p1 = Video.normalizedPath(filename)
        let p2 = Video.normalizedPath(other.filename)
        if strict {
            if p1 == p2 { return true }
            // Resolve symlinks only when both files exist locally.
            let fm = FileManager.default
            if fm.fileExists(atPath: p1), fm.fileExists(atPath: p2) {
                let r1 = URL(fileURLWithPath: p1).resolvingSymlinksInPath()
                    .standardizedFileURL.path
                let r2 = URL(fileURLWithPath: p2).resolvingSymlinksInPath()
                    .standardizedFileURL.path
                return r1 == r2
            }
            return false
        }
        return (p1 as NSString).lastPathComponent == (p2 as NSString).lastPathComponent
    }

    /// Whether this video has the same *content* as `other`.
    ///
    /// Mirrors `Video.matches_content`: the videos match when they share the
    /// same full shape `(frames, height, width, channels)` **and** the same
    /// ``backendType``. This compares metadata only, never actual pixels.
    public func matchesContent(_ other: Video) -> Bool {
        guard resolvedShapeComponents == other.resolvedShapeComponents else {
            return false
        }
        return backendType == other.backendType
    }

    /// Whether this video has the same spatial shape as `other`.
    ///
    /// Mirrors `Video.matches_shape`: compares only height, width, and channels
    /// (ignoring the frame count), returning `false` when either shape is
    /// unknown.
    public func matchesShape(_ other: Video) -> Bool {
        guard
            let a = resolvedShapeComponents, a.count >= 4,
            let b = other.resolvedShapeComponents, b.count >= 4
        else { return false }
        return Array(a[1..<4]) == Array(b[1..<4])
    }

    /// Whether this image-sequence video shares any image files with `other`.
    ///
    /// Mirrors `Video.has_overlapping_images`. Returns `false` unless both
    /// videos are image sequences (see the file-list note above); overlap is
    /// tested on image basenames.
    public func hasOverlappingImages(_ other: Video) -> Bool {
        guard let selfList = imageFilenames, let otherList = other.imageFilenames else {
            return false
        }
        let selfBase = Set(selfList.map { ($0 as NSString).lastPathComponent })
        let otherBase = Set(otherList.map { ($0 as NSString).lastPathComponent })
        return !selfBase.isDisjoint(with: otherBase)
    }

    /// Whether this video and `other` refer to the same underlying file.
    ///
    /// Mirrors the upstream module-level `is_same_file`: it traverses the
    /// ``sourceVideo`` provenance chain to the root of each video and then
    /// performs a definitive file-identity check. This is stricter than
    /// ``matchesPath(_:strict:)`` with `strict == false` — it only returns
    /// `true` when the files are verifiably the same, not merely same-basename.
    ///
    /// The identity check uses the filesystem when both files exist (to detect
    /// symlinks/hardlinks), and otherwise falls back to resolved-path and
    /// string comparison.
    public func isSameFile(as other: Video) -> Bool {
        let root1 = originalVideo ?? self
        let root2 = other.originalVideo ?? other
        return root1.isSameFileDirect(root2)
    }

    // MARK: - Internal helpers

    /// Low-level same-file check without provenance-chain traversal.
    /// Mirrors `_is_same_file_direct`.
    func isSameFileDirect(_ other: Video) -> Bool {
        // Image sequences require an identical list (order matters for indices).
        if let selfList = imageFilenames, let otherList = other.imageFilenames {
            guard selfList == otherList else { return false }
            return datasetsMatch(other)
        } else if imageFilenames != nil || other.imageFilenames != nil {
            return false
        }

        let p1 = Video.normalizedPath(filename)
        let p2 = Video.normalizedPath(other.filename)
        var filesMatch = false

        // Prefer a true same-file check when both paths exist (handles symlinks
        // and hardlinks).
        let fm = FileManager.default
        if fm.fileExists(atPath: p1), fm.fileExists(atPath: p2) {
            filesMatch = Video.sameFileOnDisk(p1, p2)
        }
        // Fall back to resolved-path comparison.
        if !filesMatch {
            let r1 = URL(fileURLWithPath: p1).resolvingSymlinksInPath()
                .standardizedFileURL.path
            let r2 = URL(fileURLWithPath: p2).resolvingSymlinksInPath()
                .standardizedFileURL.path
            if r1 == r2 { filesMatch = true }
        }
        // Final fall back to exact normalized string comparison.
        if !filesMatch {
            filesMatch = (p1 == p2)
        }
        guard filesMatch else { return false }

        return datasetsMatch(other)
    }

    /// HDF5 dataset disambiguation: when both videos declare a `dataset` in
    /// their backend metadata, they must be equal to be the same file.
    private func datasetsMatch(_ other: Video) -> Bool {
        if let d1 = Video.metadataString(backendMetadata, "dataset"),
           let d2 = Video.metadataString(other.backendMetadata, "dataset") {
            return d1 == d2
        }
        return true
    }

    /// Full shape as `[frames, height, width, channels]`, preferring the
    /// model's ``shape`` (derived from ``frameCount``/``frameSize``) and
    /// falling back to `backendMetadata["shape"]`; `nil` when unknown.
    var resolvedShapeComponents: [Int]? {
        if let s = shape { return [s.frames, s.height, s.width, s.channels] }
        if let arr = Video.intArray(backendMetadata["shape"]), arr.count == 4 {
            return arr
        }
        return nil
    }

    /// Effective shape used for match rejection, preferring the ``originalVideo``
    /// root's shape (for embedded videos). Mirrors `_get_effective_shape`.
    var effectiveShapeComponents: [Int]? {
        if let root = originalVideo, let s = root.effectiveShapeComponents {
            return s
        }
        return resolvedShapeComponents
    }

    /// Image-sequence file list, read best-effort from
    /// `backendMetadata["filenames"]` (or `["filename"]`) when ``backendType``
    /// is `"imageSequence"`; `nil` otherwise.
    var imageFilenames: [String]? {
        guard backendType == "imageSequence" else { return nil }
        if let list = backendMetadata["filenames"] as? [String] { return list }
        if let list = backendMetadata["filename"] as? [String] { return list }
        return nil
    }

    /// Strip a `file://` scheme (if present) and return a filesystem path.
    static func normalizedPath(_ raw: String) -> String {
        if raw.hasPrefix("file://"), let url = URL(string: raw) {
            return url.path
        }
        return raw
    }

    /// Read a `String` metadata value for `key`, if present.
    static func metadataString(_ metadata: [String: Any], _ key: String) -> String? {
        metadata[key] as? String
    }

    /// Coerce a metadata value into an `[Int]` (handles `[Int]`, `[Double]`,
    /// and `[NSNumber]`); `nil` if it is not an all-numeric array.
    static func intArray(_ value: Any?) -> [Int]? {
        if let ints = value as? [Int] { return ints }
        guard let anyArray = value as? [Any] else { return nil }
        let ints = anyArray.compactMap { element -> Int? in
            switch element {
            case let i as Int: return i
            case let d as Double: return Int(d)
            case let n as NSNumber: return n.intValue
            default: return nil
            }
        }
        return ints.count == anyArray.count ? ints : nil
    }

    /// Whether two existing local paths reference the same file (via the file
    /// system resource identifier, which is stable across symlinks/hardlinks).
    static func sameFileOnDisk(_ path1: String, _ path2: String) -> Bool {
        let u1 = URL(fileURLWithPath: path1)
        let u2 = URL(fileURLWithPath: path2)
        if let id1 = try? u1.resourceValues(forKeys: [.fileResourceIdentifierKey])
            .fileResourceIdentifier,
           let id2 = try? u2.resourceValues(forKeys: [.fileResourceIdentifierKey])
            .fileResourceIdentifier {
            return id1.isEqual(id2)
        }
        return false
    }
}
