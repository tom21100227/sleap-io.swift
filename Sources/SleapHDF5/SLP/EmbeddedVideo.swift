import Foundation
import CHDF5
import SleapIO
import CoreGraphics
import ImageIO

/// Support for reading and writing embedded video frames in .pkg.slp files.
public struct EmbeddedVideo {

    /// Read embedded video frames from an SLP file.
    /// Returns a map from source frame index to decoded CGImage.
    static func readFrames(from file: HDF5File, videoGroupName: String,
                                  formatId: Float) throws -> (frames: [Int: Data], format: String, channelOrder: String, frameSize: (height: Int, width: Int, channels: Int)?, sourceVideoJSON: String) {
        let group = try file.openGroup(name: videoGroupName)

        // Read the video dataset
        let videoDs = try group.openDataset(name: "video")

        // Determine format
        let format: String
        if videoDs.hasAttribute(name: "format") {
            format = try videoDs.readStringAttribute(name: "format")
        } else {
            format = "hdf5"
        }

        // Channel order (format >= 1.4)
        let channelOrder: String
        if formatId >= 1.4 && videoDs.hasAttribute(name: "channel_order") {
            channelOrder = try videoDs.readStringAttribute(name: "channel_order")
        } else {
            channelOrder = "BGR" // default for pre-1.4
        }

        let shape = videoDs.shape
        let frameSize: (height: Int, width: Int, channels: Int)?
        if shape.count == 4 {
            frameSize = (height: shape[1], width: shape[2], channels: shape[3])
        } else {
            frameSize = nil
        }

        let sourceVideoJSON: String
        if group.exists(name: "source_video") {
            let sourceVideoGroup = try group.openGroup(name: "source_video")
            sourceVideoJSON = try sourceVideoGroup.readStringAttribute(name: "json")
        } else {
            sourceVideoJSON = "{}"
        }

        // Read frame numbers mapping (dataset row index -> source frame index)
        let frameNumbers: [Int]
        if group.exists(name: "frame_numbers") {
            let fnDs = try group.openDataset(name: "frame_numbers")
            let raw = try fnDs.readUInt64()
            frameNumbers = raw.map { Int($0) }
        } else {
            frameNumbers = Array(0..<videoDs.shape.first!)
        }

        // Read frames
        var result: [Int: Data] = [:]

        if format == "hdf5" {
            // Raw array format: rank-4 uint8 (N, H, W, C)
            // Read entire dataset as uint8
            let raw = try videoDs.readUInt8()
            guard shape.count == 4 else {
                throw SleapIOError.corruptData("Expected rank-4 dataset for raw video, got rank \(shape.count)")
            }
            let frameSize = shape[1] * shape[2] * shape[3]
            for (rowIdx, sourceIdx) in frameNumbers.enumerated() {
                let start = rowIdx * frameSize
                let end = start + frameSize
                guard end <= raw.count else { break }
                result[sourceIdx] = Data(raw[start..<end])
            }
        } else {
            // Encoded images (png/jpg): either vlen int8 or fixed-length rank-2 int8
            let tc = videoDs.datatype.typeClass
            if tc == shim_H5T_VLEN() {
                // Variable-length: each row is a different-sized byte array
                let frameData = try videoDs.readVLenBytes()
                for (rowIdx, sourceIdx) in frameNumbers.enumerated() {
                    if rowIdx < frameData.count {
                        result[sourceIdx] = frameData[rowIdx]
                    }
                }
            } else {
                // Fixed-length rank-2: (N, maxBytes) int8, padded with zeros
                let raw = try videoDs.readUInt8()
                let numRows = shape[0]
                let rowLen = shape.count >= 2 ? shape[1] : raw.count / max(numRows, 1)
                for (rowIdx, sourceIdx) in frameNumbers.enumerated() {
                    guard rowIdx < numRows else { break }
                    let start = rowIdx * rowLen
                    let end = start + rowLen
                    guard end <= raw.count else { break }
                    // Find actual image end using format-specific markers.
                    // Can't use trailing-zero stripping because PNG/JPEG contain legitimate zero bytes.
                    let trimEnd = EmbeddedVideo.findImageEnd(in: raw, start: start, end: end)
                    if trimEnd > start {
                        result[sourceIdx] = Data(raw[start..<trimEnd])
                    }
                }
            }
        }

        return (result, format, channelOrder, frameSize, sourceVideoJSON)
    }

    /// Write embedded frames to an SLP file.
    /// Creates /video{N}/video, /video{N}/frame_numbers, /video{N}/source_video groups.
    static func writeFrames(
        frameData: [(sourceFrameIdx: Int, data: Data)],
        videoIndex: Int,
        sourceVideoJSON: String,
        format: String,
        channelOrder: String,
        to file: HDF5File
    ) throws {
        let groupName = "video\(videoIndex)"
        let group = try file.createGroup(name: groupName)

        // Write frame_numbers
        let frameNumbers = frameData.map { UInt64($0.sourceFrameIdx) }
        try group.writeDataset(name: "frame_numbers", data: frameNumbers, type: shim_H5T_NATIVE_UINT64())

        // Write video dataset as variable-length strings (encoded images)
        let vlenType = try HDF5Datatype.createVLen(of: shim_H5T_NATIVE_INT8())
        let space = try HDF5Dataspace.create(dims: [frameData.count])
        let ds = try group.createDataset(name: "video", type: vlenType, space: space)

        // Write as vlen byte arrays
        var hvls = frameData.map { fd -> hvl_t in
            let ptr = UnsafeMutablePointer<UInt8>.allocate(capacity: fd.data.count)
            fd.data.copyBytes(to: ptr, count: fd.data.count)
            return hvl_t(len: fd.data.count, p: ptr)
        }
        defer {
            for hvl in hvls {
                hvl.p?.assumingMemoryBound(to: UInt8.self).deallocate()
            }
        }

        try hvls.withUnsafeMutableBufferPointer { ptr in
            try hdf5Check("H5Dwrite embedded frames") {
                H5Dwrite(ds.id, vlenType.id, shim_H5S_ALL(), shim_H5S_ALL(), shim_H5P_DEFAULT(), ptr.baseAddress!)
            }
        }

        // Write attributes
        try ds.writeStringAttribute(name: "format", value: format)
        try ds.writeStringAttribute(name: "channel_order", value: channelOrder)

        // Write source_video group
        let srcGroup = try group.createGroup(name: "source_video")
        try srcGroup.writeStringAttribute(name: "json", value: sourceVideoJSON)
    }

    /// Find the actual end of an encoded image within a zero-padded buffer.
    ///
    /// Fixed-length HDF5 datasets pad rows with zeros, but PNG/JPEG data contains
    /// legitimate zero bytes internally, so naive trailing-zero stripping corrupts data.
    /// Instead, detect the image format and find its end marker:
    /// - PNG: IEND chunk (4-byte length + "IEND" + 4-byte CRC = `...IEND\xAE\x42\x60\x82`)
    /// - JPEG: EOI marker (`0xFF 0xD9`)
    /// - Unknown: fall back to trailing-zero stripping
    static func findImageEnd(in buffer: [UInt8], start: Int, end: Int) -> Int {
        let length = end - start
        guard length >= 8 else { return end }

        // Check PNG magic: 0x89 P N G \r \n 0x1A \n
        let isPNG = buffer[start] == 0x89
            && buffer[start + 1] == 0x50  // P
            && buffer[start + 2] == 0x4E  // N
            && buffer[start + 3] == 0x47  // G

        if isPNG {
            // Scan for IEND chunk. The IEND chunk is:
            //   4 bytes chunk length (0x00000000)
            //   4 bytes chunk type ("IEND" = 0x49 0x45 0x4E 0x44)
            //   4 bytes CRC (0xAE 0x42 0x60 0x82)
            // Total 12 bytes. Search for the "IEND" signature.
            let iend: [UInt8] = [0x49, 0x45, 0x4E, 0x44]  // "IEND"
            // Search backwards from end for efficiency (IEND is always last chunk)
            var pos = end - 8  // minimum: 4 bytes for "IEND" + 4 bytes CRC after it
            while pos >= start + 4 {
                if buffer[pos] == iend[0] && buffer[pos + 1] == iend[1]
                    && buffer[pos + 2] == iend[2] && buffer[pos + 3] == iend[3] {
                    // Found IEND. End of PNG is 4 bytes CRC after chunk type.
                    return min(pos + 8, end)  // +4 for "IEND" + 4 for CRC
                }
                pos -= 1
            }
            // IEND not found — return full buffer
            return end
        }

        // Check JPEG magic: 0xFF 0xD8
        let isJPEG = buffer[start] == 0xFF && buffer[start + 1] == 0xD8

        if isJPEG {
            // Scan backwards for EOI marker: 0xFF 0xD9
            var pos = end - 2
            while pos >= start {
                if buffer[pos] == 0xFF && buffer[pos + 1] == 0xD9 {
                    return pos + 2
                }
                pos -= 1
            }
            return end
        }

        // Unknown format: fall back to trailing-zero stripping
        var trimEnd = end
        while trimEnd > start && buffer[trimEnd - 1] == 0 {
            trimEnd -= 1
        }
        return trimEnd
    }

    /// Decode image data to a CGImage.
    public static func decodeImage(from data: Data) -> CGImage? {
        guard let provider = CGDataProvider(data: data as CFData),
              let source = CGImageSourceCreateWithDataProvider(provider, nil),
              CGImageSourceGetCount(source) > 0 else {
            return nil
        }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    /// Encode a CGImage to JPEG data.
    public static func encodeJPEG(image: CGImage, quality: Float = 0.95) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data as CFMutableData, "public.jpeg" as CFString, 1, nil) else {
            return nil
        }
        let options: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: quality
        ]
        CGImageDestinationAddImage(dest, image, options as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }

    /// Encode a CGImage to PNG data.
    public static func encodePNG(image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data as CFMutableData, "public.png" as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }
}
