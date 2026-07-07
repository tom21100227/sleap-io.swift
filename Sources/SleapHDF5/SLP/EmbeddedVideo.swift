import Foundation
import CHDF5
import SleapIO
import CoreGraphics
import ImageIO

/// Support for reading and writing embedded video frames in .pkg.slp files.
public struct EmbeddedVideo {

    /// Strategy for materializing embedded frames out of the HDF5 `video` dataset.
    enum ReadStrategy {
        /// Slice one frame at a time via a single-element / single-row hyperslab
        /// selection. Peak read buffer is bounded to a single frame, so the whole
        /// dataset is never held in memory at once. This is the default.
        case perFrame
        /// Read the entire dataset into memory in one `H5Dread`, then split it into
        /// frames. Faster for tiny datasets but memory scales with the whole dataset.
        /// Retained mainly as a correctness oracle for the per-frame path.
        case wholeDataset
    }

    /// Read embedded video frames from an SLP file.
    ///
    /// Returns a map from source frame index to the raw (raw layout) or encoded
    /// (png/jpg layout) bytes of each frame.
    ///
    /// By default frames are sliced one at a time from the HDF5 dataset via a
    /// hyperslab selection (see ``ReadStrategy/perFrame``), so a large embedded
    /// dataset is never materialized as a single buffer. Pass
    /// ``ReadStrategy/wholeDataset`` to force the legacy single-`H5Dread` path.
    static func readFrames(from file: HDF5File, videoGroupName: String,
                                  formatId: Float,
                                  strategy: ReadStrategy = .perFrame) throws -> (frames: [Int: Data], format: String, channelOrder: String, frameSize: (height: Int, width: Int, channels: Int)?, sourceVideoJSON: String) {
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

        // Read frames using the requested strategy. Per-frame slicing falls back
        // to the whole-dataset path for layouts that aren't row-sliceable (e.g. a
        // degenerate rank-1 fixed-length dataset), so output is always identical.
        let result: [Int: Data]
        switch strategy {
        case .wholeDataset:
            result = try readFramesWholeDataset(dataset: videoDs, format: format,
                                                shape: shape, frameNumbers: frameNumbers)
        case .perFrame:
            if canSlicePerFrame(format: format, dataset: videoDs, shape: shape) {
                result = try readFramesPerFrame(dataset: videoDs, format: format,
                                                shape: shape, frameNumbers: frameNumbers)
            } else {
                result = try readFramesWholeDataset(dataset: videoDs, format: format,
                                                    shape: shape, frameNumbers: frameNumbers)
            }
        }

        return (result, format, channelOrder, frameSize, sourceVideoJSON)
    }

    // MARK: - Frame materialization strategies

    /// Whether the given dataset layout can be sliced one frame at a time with a
    /// hyperslab selection.
    ///
    /// - Raw (`"hdf5"`) layout is sliceable only when it is the expected rank-4
    ///   `(N, H, W, C)` dataset; a wrong rank routes to the whole-dataset path so
    ///   that it raises the same ``SleapIOError/corruptData`` as before.
    /// - Variable-length (vlen) encoded layout is always sliceable per element.
    /// - Fixed-length encoded layout is sliceable when rank >= 2 (`(N, maxBytes)`).
    private static func canSlicePerFrame(format: String, dataset: HDF5Dataset, shape: [Int]) -> Bool {
        if format == "hdf5" { return shape.count == 4 }
        if dataset.datatype.typeClass == shim_H5T_VLEN() { return true }
        return shape.count >= 2
    }

    /// Legacy path: read the entire dataset in one `H5Dread`, then split it into
    /// per-frame byte blobs. Memory scales with the whole dataset.
    ///
    /// Retained as the reference/oracle implementation that ``readFramesPerFrame``
    /// is validated against, and as the fallback for non-sliceable layouts.
    private static func readFramesWholeDataset(dataset: HDF5Dataset, format: String,
                                               shape: [Int], frameNumbers: [Int]) throws -> [Int: Data] {
        var result: [Int: Data] = [:]

        if format == "hdf5" {
            // Raw array format: rank-4 uint8 (N, H, W, C)
            // Read entire dataset as uint8
            let raw = try dataset.readUInt8()
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
            let tc = dataset.datatype.typeClass
            if tc == shim_H5T_VLEN() {
                // Variable-length: each row is a different-sized byte array
                let frameData = try dataset.readVLenBytes()
                for (rowIdx, sourceIdx) in frameNumbers.enumerated() {
                    if rowIdx < frameData.count {
                        result[sourceIdx] = frameData[rowIdx]
                    }
                }
            } else {
                // Fixed-length rank-2: (N, maxBytes) int8, padded with zeros
                let raw = try dataset.readUInt8()
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

        return result
    }

    /// Slice each frame out of the dataset one at a time via a hyperslab
    /// selection, so only a single frame's bytes are read into memory at once.
    ///
    /// Produces byte-for-byte the same result as ``readFramesWholeDataset`` for
    /// every supported layout (verified by `EmbeddedHyperslabTests`).
    private static func readFramesPerFrame(dataset: HDF5Dataset, format: String,
                                           shape: [Int], frameNumbers: [Int]) throws -> [Int: Data] {
        var result: [Int: Data] = [:]
        let numRows = shape.first ?? 0

        if format == "hdf5" {
            // Raw array format: rank-4 uint8 (N, H, W, C). Slice one frame, no trim.
            for (rowIdx, sourceIdx) in frameNumbers.enumerated() {
                guard rowIdx < numRows else { break }
                let bytes = try readRowBytes(dataset: dataset, rowIndex: rowIdx, shape: shape)
                result[sourceIdx] = Data(bytes)
            }
        } else {
            let tc = dataset.datatype.typeClass
            if tc == shim_H5T_VLEN() {
                // Variable-length: read a single element per frame.
                for (rowIdx, sourceIdx) in frameNumbers.enumerated() {
                    guard rowIdx < numRows else { break }
                    result[sourceIdx] = try readVLenElementBytes(dataset: dataset, rowIndex: rowIdx)
                }
            } else {
                // Fixed-length rank-2: (N, maxBytes) int8, padded with zeros.
                for (rowIdx, sourceIdx) in frameNumbers.enumerated() {
                    guard rowIdx < numRows else { break }
                    let bytes = try readRowBytes(dataset: dataset, rowIndex: rowIdx, shape: shape)
                    // Trim zero padding using format-specific markers, matching the
                    // whole-dataset path (indices are frame-local here: start == 0).
                    let trimEnd = EmbeddedVideo.findImageEnd(in: bytes, start: 0, end: bytes.count)
                    if trimEnd > 0 {
                        result[sourceIdx] = Data(bytes[0..<trimEnd])
                    }
                }
            }
        }

        return result
    }

    // MARK: - Single-frame hyperslab reads

    /// Read a single frame's raw bytes from a fixed-shape integer dataset by row,
    /// selecting only that row via a hyperslab so the rest of the dataset is
    /// never read from disk or held in memory.
    ///
    /// Handles both signed (h5py `int8`, the common encoded layout) and unsigned
    /// 1-byte storage exactly as ``HDF5Dataset/readUInt8()`` does, preserving the
    /// bit pattern of every byte — reading signed data through `H5T_NATIVE_UINT8`
    /// would clamp negative values to zero and corrupt PNG/JPEG payloads.
    ///
    /// - Parameters:
    ///   - dataset: The embedded `video` dataset (rank >= 2, first axis = frame).
    ///   - rowIndex: Zero-based row (frame) index to read.
    ///   - shape: The dataset's dimensions; `shape[0]` is the frame count and the
    ///     trailing axes describe one frame's element layout.
    /// - Returns: Exactly `shape[1] * shape[2] * ...` bytes for the requested row.
    static func readRowBytes(dataset: HDF5Dataset, rowIndex: Int, shape: [Int]) throws -> [UInt8] {
        precondition(shape.count >= 2, "readRowBytes requires a rank >= 2 dataset")
        let perFrame = shape[1...].reduce(1, *)

        // Select a single-row hyperslab on the file dataspace: offset the first
        // axis to the requested frame, count == 1 there and full extent elsewhere.
        let fileSpace = dataset.dataspace
        var offset = [Int](repeating: 0, count: shape.count)
        offset[0] = rowIndex
        var count = shape
        count[0] = 1
        try fileSpace.selectHyperslab(offset: offset, count: count)

        // Memory dataspace holds exactly one frame's worth of elements.
        let memSpace = try HDF5Dataspace.create(dims: [perFrame])

        let dtype = dataset.datatype  // hold reference to prevent premature dealloc
        let fileTypeClass = dtype.typeClass
        let fileTypeSize = H5Tget_size(dtype.id)

        // Signed 1-byte storage: read as Int8 then reinterpret the bits as UInt8.
        if fileTypeClass == shim_H5T_INTEGER() && fileTypeSize == 1
            && H5Tget_sign(dtype.id) == H5T_SGN_2 {
            var buffer = [Int8](repeating: 0, count: perFrame)
            try hdf5Check("H5Dread embedded frame row int8") {
                H5Dread(dataset.id, shim_H5T_NATIVE_INT8(), memSpace.id, fileSpace.id,
                        shim_H5P_DEFAULT(), &buffer)
            }
            return buffer.map { UInt8(bitPattern: $0) }
        }

        var buffer = [UInt8](repeating: 0, count: perFrame)
        try hdf5Check("H5Dread embedded frame row uint8") {
            H5Dread(dataset.id, shim_H5T_NATIVE_UINT8(), memSpace.id, fileSpace.id,
                    shim_H5P_DEFAULT(), &buffer)
        }
        return buffer
    }

    /// Read a single variable-length element (one encoded frame) from a vlen
    /// dataset, selecting only that element via a hyperslab so the other frames'
    /// bytes are never read. Mirrors the vlen branch of
    /// ``HDF5Dataset/readVLenBytes()`` for a single element.
    ///
    /// - Parameters:
    ///   - dataset: The embedded `video` dataset (vlen type).
    ///   - rowIndex: Zero-based element (frame) index to read.
    /// - Returns: The frame's encoded bytes (empty `Data` if the element is null).
    static func readVLenElementBytes(dataset: HDF5Dataset, rowIndex: Int) throws -> Data {
        let fileType = dataset.datatype
        let memType = try HDF5Datatype.copy(fileType.id)

        // Select the single element for this frame.
        let fileSpace = dataset.dataspace
        try fileSpace.selectHyperslab(offset: [rowIndex], count: [1])
        let memSpace = try HDF5Dataspace.create(dims: [1])

        var hvl = hvl_t()
        try hdf5Check("H5Dread embedded vlen element") {
            H5Dread(dataset.id, memType.id, memSpace.id, fileSpace.id,
                    shim_H5P_DEFAULT(), &hvl)
        }

        let data: Data
        if hvl.len > 0, let p = hvl.p {
            data = Data(bytes: p, count: hvl.len)
        } else {
            data = Data()
        }

        // Reclaim the buffer HDF5 allocated for the vlen element.
        H5Treclaim(memType.id, memSpace.id, shim_H5P_DEFAULT(), &hvl)
        return data
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
