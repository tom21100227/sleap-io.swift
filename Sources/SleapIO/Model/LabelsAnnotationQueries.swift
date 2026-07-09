import Foundation

/// Annotation query families on ``Labels``.
///
/// Mirrors the upstream sleap-io accessors
/// `Labels.get_rois` / `get_masks` / `get_bboxes` / `get_centroids` / `get_label_images`.
///
/// The underlying annotation collections — ``Labels/rois``, ``Labels/masks``,
/// ``Labels/bboxes``, ``Labels/centroids``, and ``Labels/identities`` — are stored
/// directly on ``Labels`` (see Labels.swift). Bounding boxes, centroids, and
/// identities are modeled by ``BoundingBox`` / ``Centroid`` / ``Identity``. Label
/// images (epic E7 #47) are not yet modeled; ``getLabelImages()`` still returns an
/// empty array.
///
/// - Note: The ``getBboxes(video:frameIndex:)`` and ``getCentroids(video:frameIndex:)``
///   accessors intentionally keep their historical flattened `[[Float]]` return
///   shape (`[x0, y0, x1, y1]` and `[x, y]` respectively) so existing callers and
///   tests remain valid. Full-fidelity access to the modeled annotations is via
///   ``Labels/bboxes`` and ``Labels/centroids``.
extension Labels {

    // MARK: - Query families

    /// Labels-level regions of interest, optionally filtered by video and/or frame index.
    ///
    /// - Returns: The contents of ``Labels/rois``.
    public func getRois(video: Video? = nil, frameIndex: Int? = nil) -> [ROI] {
        guard let videoIndex = resolvedVideoIndex(video) else { return [] }
        return rois.filter { roi in
            (videoIndex == nil || roi.videoIndex == videoIndex)
            && (frameIndex == nil || roi.frameIndex == frameIndex)
        }
    }

    /// Labels-level segmentation masks, optionally filtered by video and/or frame index.
    ///
    /// - Returns: The contents of ``Labels/masks``.
    public func getMasks(video: Video? = nil, frameIndex: Int? = nil) -> [SegmentationMask] {
        guard let videoIndex = resolvedVideoIndex(video) else { return [] }
        return masks.filter { mask in
            (videoIndex == nil || mask.videoIndex == videoIndex)
            && (frameIndex == nil || mask.frameIndex == frameIndex)
        }
    }

    /// Bounding boxes for the dataset, optionally filtered by video and/or frame index.
    ///
    /// Returns each box as a flat `[Float]` of its axis-aligned corner
    /// coordinates `[x0, y0, x1, y1]` (using ``BoundingBox/bounds``, so rotated
    /// boxes report their enclosing extent). For full-fidelity access to the
    /// modeled boxes — center/size/angle, predicted flag, score, and metadata —
    /// use ``Labels/bboxes``.
    ///
    /// - Returns: One `[x0, y0, x1, y1]` entry per matching box.
    public func getBboxes(video: Video? = nil, frameIndex: Int? = nil) -> [[Float]] {
        guard let videoIndex = resolvedVideoIndex(video) else { return [] }
        return bboxes.compactMap { box in
            guard (videoIndex == nil || box.videoIndex == videoIndex),
                  (frameIndex == nil || box.frameIndex == frameIndex) else { return nil }
            let b = box.bounds
            return [Float(b.minX), Float(b.minY), Float(b.maxX), Float(b.maxY)]
        }
    }

    /// Centroids for the dataset, optionally filtered by video and/or frame index.
    ///
    /// Returns each centroid as a flat `[Float]` of the form `[x, y]`. For
    /// full-fidelity access — predicted flag, score, and metadata — use
    /// ``Labels/centroids``.
    ///
    /// - Returns: One `[x, y]` entry per matching centroid.
    public func getCentroids(video: Video? = nil, frameIndex: Int? = nil) -> [[Float]] {
        guard let videoIndex = resolvedVideoIndex(video) else { return [] }
        return centroids.compactMap { c in
            guard (videoIndex == nil || c.videoIndex == videoIndex),
                  (frameIndex == nil || c.frameIndex == frameIndex) else { return nil }
            return [Float(c.x), Float(c.y)]
        }
    }

    /// Label images for the dataset.
    ///
    /// Not yet modeled — label images arrive with epic E7 (#47). Until then this
    /// always returns an empty array.
    ///
    /// - Returns: An empty array (placeholder pending E7 #47).
    public func getLabelImages() -> [Int] {
        []
    }

    private func resolvedVideoIndex(_ video: Video?) -> Int?? {
        guard let video else { return .some(nil) }
        guard let resolved = resolveVideo(video),
              let index = videos.firstIndex(where: { $0 === resolved }) else { return nil }
        return .some(index)
    }
}
