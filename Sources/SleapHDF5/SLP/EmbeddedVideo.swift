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
                                  formatId: Float) throws -> (frames: [Int: Data], format: String, channelOrder: String) {
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
            let shape = videoDs.shape
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
            // Encoded images (png/jpg): variable-length int8 dataset
            let frameData = try videoDs.readVLenBytes()
            for (rowIdx, sourceIdx) in frameNumbers.enumerated() {
                if rowIdx < frameData.count {
                    result[sourceIdx] = frameData[rowIdx]
                }
            }
        }

        return (result, format, channelOrder)
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
