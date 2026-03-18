import CoreGraphics
import Foundation
import SleapIO
import SleapVideo

/// Video backend for embedded frames stored inside packaged `.slp` files.
public final class SleapHDF5EmbeddedVideoBackend: VideoBackend, @unchecked Sendable {
    enum Storage {
        case encoded
        case raw(size: (height: Int, width: Int, channels: Int))
    }

    let embeddedFrames: [Int: Data]
    let format: String
    let channelOrder: String
    let sourceVideoJSON: String

    /// The HDF5 file this embedded video was loaded from (for H5Ocopy during save).
    let sourceFilePath: String?
    /// The video group index in the source file (e.g., 0 for /video0).
    let sourceVideoIndex: Int?

    private let storage: Storage
    private let cacheLock = NSLock()
    private var decodedFrames: [Int: CGImage] = [:]

    private let _frameCount: Int?
    private let _frameSize: (height: Int, width: Int, channels: Int)?

    public init(path: String, videoIndex: Int, formatId: Float) throws {
        let file = try HDF5File.openReadOnly(path: path)
        let embedded = try EmbeddedVideo.readFrames(
            from: file,
            videoGroupName: "video\(videoIndex)",
            formatId: formatId
        )

        self.embeddedFrames = embedded.frames
        self.format = embedded.format
        self.channelOrder = embedded.channelOrder
        self.sourceVideoJSON = embedded.sourceVideoJSON
        self.sourceFilePath = path
        self.sourceVideoIndex = videoIndex
        self._frameCount = embedded.frames.keys.max().map { $0 + 1 } ?? 0

        if embedded.format == "hdf5", let size = embedded.frameSize {
            self.storage = .raw(size: size)
            self._frameSize = size
        } else {
            self.storage = .encoded
            if let firstData = embedded.frames.values.first,
               let image = EmbeddedVideo.decodeImage(from: firstData) {
                self._frameSize = (height: image.height, width: image.width, channels: 4)
            } else {
                self._frameSize = nil
            }
        }
    }

    public var frameCount: Int? { _frameCount }
    public var frameSize: (height: Int, width: Int, channels: Int)? { _frameSize }
    public var fps: Double? { nil }

    public func frame(at index: Int) async throws -> CGImage {
        if let cached = cacheLock.withLock({ decodedFrames[index] }) {
            return cached
        }

        guard let data = embeddedFrames[index] else {
            throw SleapIOError.videoError("Embedded frame \(index) not found")
        }

        let image: CGImage
        switch storage {
        case .encoded:
            guard let decoded = EmbeddedVideo.decodeImage(from: data) else {
                throw SleapIOError.videoError("Failed to decode embedded frame \(index)")
            }
            // Python SLEAP stores BGR frames from OpenCV. When JPEG-encoded,
            // the BGR data is written as-is (JPEG assumes RGB), so the decoded
            // image has R and B channels swapped. Fix by swapping channels if
            // the channelOrder metadata says "BGR".
            if channelOrder.uppercased() == "BGR" || channelOrder.uppercased() == "BGRA" {
                guard let swapped = Self.swapRedBlue(decoded) else {
                    throw SleapIOError.videoError("Failed to swap channels for embedded frame \(index)")
                }
                image = swapped
            } else {
                image = decoded
            }
        case .raw(let size):
            guard let decoded = Self.decodeRawFrame(data, size: size, channelOrder: channelOrder) else {
                throw SleapIOError.videoError("Failed to decode embedded frame \(index)")
            }
            image = decoded
        }

        cacheLock.withLock {
            decodedFrames[index] = image
        }
        return image
    }

    /// Swap red and blue channels in a CGImage (BGR → RGB correction).
    private static func swapRedBlue(_ image: CGImage) -> CGImage? {
        let width = image.width
        let height = image.height
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        // Draw the original image to get pixel data
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        guard let data = context.data else { return nil }
        let pixels = data.assumingMemoryBound(to: UInt8.self)
        let pixelCount = width * height

        // Swap R and B channels in place (RGBA layout: [R, G, B, A])
        for i in 0..<pixelCount {
            let offset = i * 4
            let r = pixels[offset]
            pixels[offset] = pixels[offset + 2]     // R ← B
            pixels[offset + 2] = r                   // B ← R
        }

        return context.makeImage()
    }

    private static func decodeRawFrame(
        _ data: Data,
        size: (height: Int, width: Int, channels: Int),
        channelOrder: String
    ) -> CGImage? {
        let pixelCount = size.width * size.height
        guard [1, 3, 4].contains(size.channels) else { return nil }
        guard data.count >= pixelCount * size.channels else { return nil }

        var rgba = [UInt8](repeating: 255, count: pixelCount * 4)
        let normalizedOrder = channelOrder.uppercased()

        data.withUnsafeBytes { rawBuffer in
            guard let src = rawBuffer.bindMemory(to: UInt8.self).baseAddress else { return }
            for pixelIndex in 0..<pixelCount {
                let srcOffset = pixelIndex * size.channels
                let dstOffset = pixelIndex * 4

                switch size.channels {
                case 1:
                    let value = src[srcOffset]
                    rgba[dstOffset] = value
                    rgba[dstOffset + 1] = value
                    rgba[dstOffset + 2] = value
                case 3:
                    let c0 = src[srcOffset]
                    let c1 = src[srcOffset + 1]
                    let c2 = src[srcOffset + 2]
                    if normalizedOrder == "BGR" {
                        rgba[dstOffset] = c2
                        rgba[dstOffset + 1] = c1
                        rgba[dstOffset + 2] = c0
                    } else {
                        rgba[dstOffset] = c0
                        rgba[dstOffset + 1] = c1
                        rgba[dstOffset + 2] = c2
                    }
                case 4:
                    let c0 = src[srcOffset]
                    let c1 = src[srcOffset + 1]
                    let c2 = src[srcOffset + 2]
                    let c3 = src[srcOffset + 3]
                    if normalizedOrder == "BGR" || normalizedOrder == "BGRA" {
                        rgba[dstOffset] = c2
                        rgba[dstOffset + 1] = c1
                        rgba[dstOffset + 2] = c0
                        rgba[dstOffset + 3] = c3
                    } else {
                        rgba[dstOffset] = c0
                        rgba[dstOffset + 1] = c1
                        rgba[dstOffset + 2] = c2
                        rgba[dstOffset + 3] = c3
                    }
                default:
                    break
                }
            }
        }

        let providerData = Data(rgba) as CFData
        guard let provider = CGDataProvider(data: providerData) else { return nil }

        return CGImage(
            width: size.width,
            height: size.height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: size.width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }
}
