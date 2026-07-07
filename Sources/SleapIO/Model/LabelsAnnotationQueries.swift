import Foundation

/// Annotation query families on ``Labels``.
///
/// Mirrors the upstream sleap-io accessors
/// `Labels.get_rois` / `get_masks` / `get_bboxes` / `get_centroids` / `get_label_images`.
///
/// `rois` and `masks` are already modeled (``Labels/rois`` / ``Labels/masks``) and are
/// returned directly. Bounding boxes, centroids, and label images are not yet modeled
/// (tracked under epic E7); their accessors return empty arrays today and will be
/// populated when E7 lands. The placeholder return types are kept deliberately simple and
/// honest rather than introducing speculative model types.
extension Labels {

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

    /// Bounding boxes for the dataset.
    ///
    /// Not yet modeled — bounding boxes arrive with epic E7. Until then this always
    /// returns an empty array. Each entry, once populated, is expected to be a flat
    /// `[Float]` of coordinates (e.g. `[x0, y0, x1, y1]`).
    ///
    /// - Returns: An empty array (placeholder pending E7).
    public func getBboxes() -> [[Float]] {
        []
    }

    /// Centroids for the dataset.
    ///
    /// Not yet modeled — centroids arrive with epic E7. Until then this always returns an
    /// empty array. Each entry, once populated, is expected to be a `[Float]` of the form
    /// `[x, y]`.
    ///
    /// - Returns: An empty array (placeholder pending E7).
    public func getCentroids() -> [[Float]] {
        []
    }

    /// Label images for the dataset.
    ///
    /// Not yet modeled — label images arrive with epic E7. Until then this always returns
    /// an empty array.
    ///
    /// - Returns: An empty array (placeholder pending E7).
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
