import CoreGraphics
import Foundation
import SleapIO

/// Pixel layout of frames stored in a Norpix StreamPix `.seq` file.
///
/// Values are the on-disk `imageFormat` codes from the `.seq` header.
public enum SeqImageFormat: UInt32, Sendable {
    case unknown = 0
    /// 8-bit monochrome (Mono8).
    case monochrome = 100
    /// Raw Bayer-encoded data.
    case rawBayer = 101
    /// 24-bit packed BGR.
    case bgr = 200
    /// Planar color.
    case planar = 300
    /// 24-bit packed RGB.
    case rgb = 400
    /// 32-bit BGRx.
    case bgrx = 500
    /// YUV 4:2:2.
    case yuv422 = 600
    /// UVY 4:2:2.
    case uvy422 = 610
    /// UVY 4:1:1.
    case uvy411 = 620
    /// UVY 4:4:4.
    case uvy444 = 700
    /// JPEG-compressed frames.
    case jpeg = 900

    /// Number of channels a decoded frame carries.
    public var channels: Int {
        switch self {
        case .monochrome, .rawBayer:
            return 1
        case .bgr, .rgb, .planar:
            return 3
        case .bgrx:
            return 4
        default:
            return 3
        }
    }

    /// Whether frames are stored as raw, fixed-stride uncompressed samples that
    /// this backend can decode directly.
    public var isRawUncompressed: Bool {
        switch self {
        case .monochrome, .bgr, .rgb, .bgrx:
            return true
        default:
            return false
        }
    }
}

/// Parsed Norpix StreamPix `.seq` header.
///
/// The header occupies the first `headerSize` bytes (1024 in practice) and is
/// little-endian. Field offsets follow the canonical Norpix layout used by
/// Piotr Dollár's `seqIo` and the `pims` `NorpixSeq` reader.
public struct SeqHeader: Sendable {
    /// Magic number; must equal ``SeqHeader/magicNumber``.
    public let magic: UInt32
    /// Format version.
    public let version: Int32
    /// Header size in bytes (frame data starts at this offset).
    public let headerSize: Int
    /// Frame width in pixels.
    public let width: Int
    /// Frame height in pixels.
    public let height: Int
    /// Nominal bit depth (bits per pixel across all channels).
    public let bitDepth: Int
    /// Real bit depth (bits actually used per sample).
    public let bitDepthReal: Int
    /// Size of a single image's pixel payload in bytes.
    public let imageSizeBytes: Int
    /// Pixel layout of stored frames.
    public let imageFormat: SeqImageFormat
    /// Number of frames the container was allocated for.
    public let allocatedFrames: Int
    /// Origin flag.
    public let origin: Int
    /// Stride between consecutive frame slots in bytes (payload + padding +
    /// per-frame timestamp).
    public let trueImageSize: Int
    /// Suggested playback frame rate.
    public let fps: Double

    /// Expected magic number at offset 0 (`0xFEED`).
    public static let magicNumber: UInt32 = 0xFEED

    /// Number of channels a decoded frame carries.
    public var channels: Int { imageFormat.channels }

    // Little-endian field offsets.
    private static let offWidth = 548
    private static let offHeight = 552
    private static let offBitDepth = 556
    private static let offBitDepthReal = 560
    private static let offImageSizeBytes = 564
    private static let offImageFormat = 568
    private static let offAllocatedFrames = 572
    private static let offOrigin = 576
    private static let offTrueImageSize = 580
    private static let offFPS = 584

    /// Minimum bytes required to parse the fixed header fields.
    static let minHeaderBytes = 592

    /// Parse a `.seq` header from the leading bytes of a file.
    ///
    /// - Throws: ``SleapIOError/corruptData(_:)`` if the buffer is too small or
    ///   the magic number does not match.
    public static func parse(_ data: Data) throws -> SeqHeader {
        guard data.count >= minHeaderBytes else {
            throw SleapIOError.corruptData(
                ".seq header too small: \(data.count) bytes (need \(minHeaderBytes))")
        }

        let magic = readUInt32(data, at: 0)
        guard magic == magicNumber else {
            throw SleapIOError.corruptData(
                "Bad .seq magic 0x\(String(magic, radix: 16)) (expected 0xFEED)")
        }

        let version = Int32(bitPattern: readUInt32(data, at: 28))
        var headerSize = Int(Int32(bitPattern: readUInt32(data, at: 32)))
        if headerSize <= 0 { headerSize = 1024 }

        let width = Int(readUInt32(data, at: offWidth))
        let height = Int(readUInt32(data, at: offHeight))
        let bitDepth = Int(readUInt32(data, at: offBitDepth))
        let bitDepthReal = Int(readUInt32(data, at: offBitDepthReal))
        let imageSizeBytes = Int(readUInt32(data, at: offImageSizeBytes))
        let formatCode = readUInt32(data, at: offImageFormat)
        let allocatedFrames = Int(readUInt32(data, at: offAllocatedFrames))
        let origin = Int(readUInt32(data, at: offOrigin))
        let trueImageSize = Int(readUInt32(data, at: offTrueImageSize))
        let fps = readDouble(data, at: offFPS)

        return SeqHeader(
            magic: magic,
            version: version,
            headerSize: headerSize,
            width: width,
            height: height,
            bitDepth: bitDepth,
            bitDepthReal: bitDepthReal,
            imageSizeBytes: imageSizeBytes,
            imageFormat: SeqImageFormat(rawValue: formatCode) ?? .unknown,
            allocatedFrames: allocatedFrames,
            origin: origin,
            trueImageSize: trueImageSize,
            fps: fps
        )
    }

    // MARK: - Little-endian readers

    private static func readUInt32(_ data: Data, at offset: Int) -> UInt32 {
        let base = data.startIndex + offset
        var value: UInt32 = 0
        for i in 0..<4 {
            value |= UInt32(data[base + i]) << (8 * i)
        }
        return value
    }

    private static func readDouble(_ data: Data, at offset: Int) -> Double {
        let base = data.startIndex + offset
        var bits: UInt64 = 0
        for i in 0..<8 {
            bits |= UInt64(data[base + i]) << (8 * i)
        }
        return Double(bitPattern: bits)
    }
}

/// Video backend for reading Norpix StreamPix `.seq` files.
///
/// Parses the fixed 1024-byte header and reads frames at fixed offsets
/// (`headerSize + index * trueImageSize`). Raw uncompressed layouts
/// (monochrome, RGB, BGR, BGRx) are decoded directly; compressed layouts
/// (JPEG, YUV, Bayer) are reported as unsupported.
///
/// Mirrors the upstream sleap-io `SeqVideo` backend.
public actor SeqVideo: VideoBackend {
    private let url: URL
    private let header: SeqHeader
    private let _frameCount: Int

    /// The parsed file header.
    public nonisolated var seqHeader: SeqHeader { header }

    /// Create a backend for a `.seq` file.
    public init(url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw SleapIOError.fileNotFound(url.path)
        }

        // Read just the header region; frames are read lazily on demand.
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let headerData = handle.readData(ofLength: SeqHeader.minHeaderBytes)
        let header = try SeqHeader.parse(headerData)

        // Prefer the allocated frame count, but clamp to what actually fits in
        // the file so a partially-written container reports a usable range.
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let fileSize = attrs?[.size] as? Int
        var frameCount = header.allocatedFrames
        if let fileSize, header.trueImageSize > 0 {
            let derived = (fileSize - header.headerSize) / header.trueImageSize
            if derived > 0 {
                frameCount = frameCount > 0 ? min(frameCount, derived) : derived
            }
        }

        self.url = url
        self.header = header
        self._frameCount = max(frameCount, 0)
    }

    nonisolated public var frameCount: Int? { _frameCount }
    nonisolated public var frameSize: (height: Int, width: Int, channels: Int)? {
        (height: header.height, width: header.width, channels: header.channels)
    }
    nonisolated public var fps: Double? { header.fps > 0 ? header.fps : nil }

    public func frame(at index: Int) async throws -> CGImage {
        guard index >= 0 && index < _frameCount else {
            throw SleapIOError.videoError(
                "Frame index \(index) out of range [0, \(_frameCount))")
        }
        guard header.imageFormat.isRawUncompressed else {
            throw SleapIOError.videoError(
                ".seq image format \(header.imageFormat) is not a supported raw layout")
        }

        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        let offset = header.headerSize + index * header.trueImageSize
        try handle.seek(toOffset: UInt64(offset))
        let payloadLength = header.imageSizeBytes > 0
            ? header.imageSizeBytes
            : header.width * header.height * header.channels
        let raw = handle.readData(ofLength: payloadLength)
        guard raw.count >= header.width * header.height * header.channels else {
            throw SleapIOError.corruptData(
                "Truncated .seq frame \(index): got \(raw.count) bytes")
        }

        return try SeqVideo.makeImage(
            from: raw,
            width: header.width,
            height: header.height,
            format: header.imageFormat
        )
    }

    // MARK: - Raw frame decoding

    /// Build a `CGImage` from a raw uncompressed `.seq` frame payload.
    static func makeImage(
        from raw: Data,
        width: Int,
        height: Int,
        format: SeqImageFormat
    ) throws -> CGImage {
        let pixelCount = width * height
        var rgbaOrGray: [UInt8]
        let channels: Int
        let colorSpace: CGColorSpace
        let bitmapInfo: CGBitmapInfo

        let bytes = [UInt8](raw)

        switch format {
        case .monochrome:
            channels = 1
            colorSpace = CGColorSpaceCreateDeviceGray()
            bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue)
            rgbaOrGray = Array(bytes.prefix(pixelCount))
        case .rgb:
            channels = 4
            colorSpace = CGColorSpaceCreateDeviceRGB()
            bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
            rgbaOrGray = [UInt8](repeating: 255, count: pixelCount * 4)
            for i in 0..<pixelCount {
                rgbaOrGray[i * 4 + 0] = bytes[i * 3 + 0]
                rgbaOrGray[i * 4 + 1] = bytes[i * 3 + 1]
                rgbaOrGray[i * 4 + 2] = bytes[i * 3 + 2]
            }
        case .bgr:
            channels = 4
            colorSpace = CGColorSpaceCreateDeviceRGB()
            bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
            rgbaOrGray = [UInt8](repeating: 255, count: pixelCount * 4)
            for i in 0..<pixelCount {
                rgbaOrGray[i * 4 + 0] = bytes[i * 3 + 2]  // R <- B
                rgbaOrGray[i * 4 + 1] = bytes[i * 3 + 1]  // G
                rgbaOrGray[i * 4 + 2] = bytes[i * 3 + 0]  // B <- R
            }
        case .bgrx:
            channels = 4
            colorSpace = CGColorSpaceCreateDeviceRGB()
            bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
            rgbaOrGray = [UInt8](repeating: 255, count: pixelCount * 4)
            for i in 0..<pixelCount {
                rgbaOrGray[i * 4 + 0] = bytes[i * 4 + 2]  // R <- B
                rgbaOrGray[i * 4 + 1] = bytes[i * 4 + 1]  // G
                rgbaOrGray[i * 4 + 2] = bytes[i * 4 + 0]  // B <- R
            }
        default:
            throw SleapIOError.videoError(
                ".seq image format \(format) is not a supported raw layout")
        }

        let bytesPerRow = width * channels
        guard let provider = CGDataProvider(data: Data(rgbaOrGray) as CFData) else {
            throw SleapIOError.videoError("Failed to build .seq image data provider")
        }
        guard let image = CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: channels * 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ) else {
            throw SleapIOError.videoError("Failed to construct CGImage from .seq frame")
        }
        return image
    }
}
