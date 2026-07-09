import CoreGraphics
import Foundation
import ImageIO
import SleapIO

/// Video backend that reads a directory of image files as sequential frames.
///
/// Supports PNG, JPEG, TIFF, and BMP images. Files are sorted lexicographically.
public actor ImageSequenceBackend: VideoBackend {
    private let imageURLs: [URL]
    private let _frameSize: (height: Int, width: Int, channels: Int)?

    /// Create a backend from a directory of image files.
    public init(directory: URL) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: directory.path) else {
            throw SleapIOError.fileNotFound(directory.path)
        }

        let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "tif", "tiff", "bmp"]

        let contents = try fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )

        self.imageURLs = contents
            .filter { imageExtensions.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        // Read first image to determine size and autodetect grayscale by sampling
        // its decoded pixels (channels collapse to 1 when all channels are equal).
        if let firstURL = imageURLs.first,
           let source = CGImageSourceCreateWithURL(firstURL as CFURL, nil),
           let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let width = properties[kCGImagePropertyPixelWidth] as? Int,
           let height = properties[kCGImagePropertyPixelHeight] as? Int {
            let channels: Int
            if let image = CGImageSourceCreateImageAtIndex(source, 0, nil) {
                channels = VideoPixelBuffer.isGrayscale(image) ? 1 : 3
            } else {
                channels = 3
            }
            self._frameSize = (height: height, width: width, channels: channels)
        } else {
            self._frameSize = nil
        }
    }

    nonisolated public var frameCount: Int? { imageURLs.count }
    nonisolated public var frameSize: (height: Int, width: Int, channels: Int)? { _frameSize }
    nonisolated public var fps: Double? { nil }

    public func frame(at index: Int) async throws -> CGImage {
        guard index >= 0 && index < imageURLs.count else {
            throw SleapIOError.videoError(
                "Frame index \(index) out of range [0, \(imageURLs.count))"
            )
        }

        let url = imageURLs[index]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw SleapIOError.videoError("Failed to load image at \(url.lastPathComponent)")
        }
        return image
    }

    nonisolated public func prefetch(indices: IndexSet) {
        // No-op for image sequences
    }
}
