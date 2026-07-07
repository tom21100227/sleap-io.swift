import CoreGraphics
import Foundation
import ImageIO
import SleapIO

/// Layout of a TIFF video stack.
///
/// Mirrors the `format` attribute of the upstream sleap-io `TiffVideo` backend.
/// A multi-page TIFF stores one frame per page; the rank-3/4 stack formats store
/// the whole stack in a single page whose sample axis carries the extra
/// dimension(s).
///
/// - `multiPage`: one image per TIFF page (the common, ImageIO-native case).
/// - `THW`: rank-3 grayscale stack, frames along the first axis.
/// - `HWT`: rank-3 grayscale stack, frames along the last axis.
/// - `THWC`: rank-4 color stack, frames along the first axis.
/// - `CHWT`: rank-4 color stack, channels first and frames last.
///
/// `THW`/`THWC` are written to disk by tools such as `tifffile` as multi-page
/// TIFFs (one page per frame), so they are read through the same page-index path
/// as ``multiPage``. `HWT`/`CHWT` place the frame axis inside a single page and
/// are extracted by slicing the decoded pixel buffer.
public enum TiffStackFormat: String, Sendable {
    case auto
    case multiPage = "multi_page"
    case THW
    case HWT
    case THWC
    case CHWT
}

/// Video backend for reading multi-page TIFF stacks.
///
/// Each page in a multi-page TIFF is treated as a frame, read lazily by page
/// index via ImageIO's `CGImageSource`. Rank-3/4 single-page stacks (`HWT` /
/// `CHWT`) are supported by decoding the single page once and slicing frames out
/// of the pixel buffer.
///
/// Mirrors the upstream sleap-io `TiffVideo` backend. See ``TiffStackFormat`` for
/// the supported stack layouts.
public actor TiffVideo: VideoBackend {
    private let url: URL
    private let source: CGImageSource
    private let _format: TiffStackFormat
    private let _frameCount: Int
    private let _frameSize: (height: Int, width: Int, channels: Int)

    /// Cached fully-decoded single page for `HWT`/`CHWT` slicing.
    private var stackImage: CGImage?

    /// The resolved stack layout for this file.
    public nonisolated var format: TiffStackFormat { _format }

    /// Create a backend for a TIFF file.
    ///
    /// - Parameters:
    ///   - url: Path to the TIFF file.
    ///   - format: Stack layout. Defaults to ``TiffStackFormat/auto``, which
    ///     resolves to ``TiffStackFormat/multiPage`` (pages are frames).
    public init(url: URL, format: TiffStackFormat = .auto) throws {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw SleapIOError.fileNotFound(url.path)
        }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw SleapIOError.videoError("Failed to open TIFF at \(url.lastPathComponent)")
        }

        let pageCount = CGImageSourceGetCount(source)
        guard pageCount > 0 else {
            throw SleapIOError.videoError("TIFF \(url.lastPathComponent) contains no images")
        }

        // Read page-0 properties to learn the pixel dimensions and color model.
        guard let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let pw = props[kCGImagePropertyPixelWidth] as? Int,
              let ph = props[kCGImagePropertyPixelHeight] as? Int
        else {
            throw SleapIOError.videoError(
                "Failed to read TIFF properties for \(url.lastPathComponent)")
        }
        let colorModel = props[kCGImagePropertyColorModel] as? String
        let pageChannels = (colorModel == (kCGImagePropertyColorModelGray as String)) ? 1 : 3

        // Resolve the format.
        let resolved = TiffVideo.resolveFormat(format, pageCount: pageCount)

        // Compute frame count + frame size for the resolved layout.
        let layout = TiffVideo.resolveShape(
            format: resolved,
            pageWidth: pw,
            pageHeight: ph,
            pageChannels: pageChannels,
            pageCount: pageCount
        )

        self.url = url
        self.source = source
        self._format = resolved
        self._frameCount = layout.frameCount
        self._frameSize = (height: layout.height, width: layout.width, channels: layout.channels)
    }

    nonisolated public var frameCount: Int? { _frameCount }
    nonisolated public var frameSize: (height: Int, width: Int, channels: Int)? { _frameSize }
    nonisolated public var fps: Double? { nil }

    public func frame(at index: Int) async throws -> CGImage {
        guard index >= 0 && index < _frameCount else {
            throw SleapIOError.videoError(
                "Frame index \(index) out of range [0, \(_frameCount))")
        }

        switch _format {
        case .auto, .multiPage, .THW, .THWC, .CHWT:
            // Page index == frame index. `THW`/`THWC` are stored multi-page by
            // tools such as tifffile; `CHWT` cannot be represented as a rank-4
            // single page in ImageIO, so it falls back to treating pages as
            // frames.
            guard let image = CGImageSourceCreateImageAtIndex(source, index, nil) else {
                throw SleapIOError.videoError(
                    "Failed to decode TIFF page \(index) in \(url.lastPathComponent)")
            }
            return image
        case .HWT:
            return try sliceStackFrame(at: index)
        }
    }

    // MARK: - Format resolution (pure, unit-tested)

    /// Resolve `auto`/explicit formats against the number of TIFF pages.
    ///
    /// `auto` becomes ``TiffStackFormat/multiPage`` (each page is a frame). All
    /// other formats are passed through unchanged.
    static func resolveFormat(_ requested: TiffStackFormat, pageCount: Int) -> TiffStackFormat {
        switch requested {
        case .auto:
            return .multiPage
        default:
            return requested
        }
    }

    /// Frame count + per-frame dimensions for a resolved layout.
    ///
    /// Mirrors upstream `TiffVideo._detect_*_format` / `num_frames` semantics.
    /// For page-indexed layouts (`multiPage`/`THW`/`THWC`) the frame count is the
    /// page count and the frame size is the page size. For the single-page
    /// slice layouts (`HWT`/`CHWT`) the page's sample axis carries the frame
    /// index, so the frame count is derived from the reported channel count.
    static func resolveShape(
        format: TiffStackFormat,
        pageWidth: Int,
        pageHeight: Int,
        pageChannels: Int,
        pageCount: Int
    ) -> (frameCount: Int, height: Int, width: Int, channels: Int) {
        switch format {
        case .auto, .multiPage, .THW, .THWC, .CHWT:
            // Page-indexed layouts: each page is a (grayscale or color) frame.
            // `THW`/`THWC` are written multi-page by tifffile; `CHWT` cannot be
            // a rank-4 single page in ImageIO and falls back to pages-as-frames.
            return (pageCount, pageHeight, pageWidth, max(pageChannels, 1))
        case .HWT:
            // Single page of shape (H, W, T): the T frames live on the sample
            // axis, each grayscale.
            return (max(pageChannels, 1), pageHeight, pageWidth, 1)
        }
    }

    // MARK: - Single-page stack slicing

    /// Extract frame `index` from a single-page `HWT`/`CHWT` stack by slicing the
    /// decoded pixel buffer along the sample axis.
    private func sliceStackFrame(at index: Int) throws -> CGImage {
        let image = try decodedStackImage()

        let width = image.width
        let height = image.height
        let channels = _frameSize.channels
        let sampleCount = _frameCount

        guard index < sampleCount else {
            throw SleapIOError.videoError(
                "Frame index \(index) out of range for stack of \(sampleCount)")
        }

        // Render into a known 8-bit layout so the sample stride is predictable.
        guard let (buffer, bytesPerRow, samplesPerPixel) = TiffVideo.rawSamples(from: image) else {
            throw SleapIOError.videoError(
                "Failed to read raw samples from TIFF \(url.lastPathComponent)")
        }

        // Extract sample `index` for every pixel into a tight (H, W, channels) buffer.
        var out = [UInt8](repeating: 0, count: width * height * channels)
        for row in 0..<height {
            for col in 0..<width {
                let src = row * bytesPerRow + col * samplesPerPixel
                let dst = (row * width + col) * channels
                for c in 0..<channels {
                    // For HWT (grayscale) `index` selects the sample; for CHWT
                    // (color) we keep the leading `channels` samples.
                    let sampleIndex = (channels == 1) ? index : c
                    if sampleIndex < samplesPerPixel {
                        out[dst + c] = buffer[src + sampleIndex]
                    }
                }
            }
        }

        return try TiffVideo.makeImage(
            from: out, width: width, height: height, channels: channels)
    }

    private func decodedStackImage() throws -> CGImage {
        if let cached = stackImage { return cached }
        guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw SleapIOError.videoError(
                "Failed to decode TIFF stack page in \(url.lastPathComponent)")
        }
        stackImage = image
        return image
    }

    /// Read an image's raw 8-bit samples via a same-size bitmap context.
    ///
    /// Returns the pixel buffer, its `bytesPerRow`, and the samples-per-pixel of
    /// the render (4 for RGBA). Used only for single-page stack slicing.
    static func rawSamples(from image: CGImage) -> (buffer: [UInt8], bytesPerRow: Int, samplesPerPixel: Int)? {
        let width = image.width
        let height = image.height
        let samplesPerPixel = 4
        let bytesPerRow = width * samplesPerPixel
        var buffer = [UInt8](repeating: 0, count: bytesPerRow * height)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let ok = buffer.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(
                data: raw.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return ok ? (buffer, bytesPerRow, samplesPerPixel) : nil
    }

    /// Build a `CGImage` from a tightly-packed 8-bit buffer.
    static func makeImage(from bytes: [UInt8], width: Int, height: Int, channels: Int) throws -> CGImage {
        let colorSpace: CGColorSpace
        let bitmapInfo: CGBitmapInfo
        let bytesPerPixel: Int
        switch channels {
        case 1:
            colorSpace = CGColorSpaceCreateDeviceGray()
            bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue)
            bytesPerPixel = 1
        default:
            colorSpace = CGColorSpaceCreateDeviceRGB()
            // 3 source channels expanded to RGBA below when needed.
            bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
            bytesPerPixel = 4
        }

        var pixels = bytes
        if channels == 3 {
            // Expand RGB -> RGBA (opaque) for a CG-friendly layout.
            var rgba = [UInt8](repeating: 255, count: width * height * 4)
            for i in 0..<(width * height) {
                rgba[i * 4 + 0] = bytes[i * 3 + 0]
                rgba[i * 4 + 1] = bytes[i * 3 + 1]
                rgba[i * 4 + 2] = bytes[i * 3 + 2]
                rgba[i * 4 + 3] = 255
            }
            pixels = rgba
        }

        let bytesPerRow = width * bytesPerPixel
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else {
            throw SleapIOError.videoError("Failed to build image data provider")
        }
        guard let image = CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: bytesPerPixel * 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ) else {
            throw SleapIOError.videoError("Failed to construct CGImage from raw samples")
        }
        return image
    }
}
