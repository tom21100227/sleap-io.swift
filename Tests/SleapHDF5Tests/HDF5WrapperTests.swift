import XCTest
import CHDF5
@testable import SleapHDF5

/// Basic HDF5 wrapper read/write tests.
///
/// These test the low-level HDF5 Swift wrapper (HDF5File, HDF5Group, HDF5Dataset)
/// without going through the SLP codec layer.
final class HDF5WrapperTests: XCTestCase {

    private func tempPath(extension ext: String = "h5") -> String {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("hdf5_test_\(UUID().uuidString).\(ext)")
            .path
    }

    private func cleanup(_ path: String) {
        try? FileManager.default.removeItem(atPath: path)
    }

    // MARK: - File operations

    func testCreateAndOpenFile() throws {
        let path = tempPath()
        defer { cleanup(path) }

        // Create a new HDF5 file
        let file = try HDF5File.create(path: path)
        // File is open; close by letting it deinit or via scope

        XCTAssertTrue(FileManager.default.fileExists(atPath: path))

        // Reopen for reading
        let file2 = try HDF5File.openReadOnly(path: path)
        _ = file2  // Use it so it stays alive
    }

    func testOpenNonexistentFileThrows() {
        let path = tempPath()
        XCTAssertThrowsError(try HDF5File.openReadOnly(path: path))
    }

    // MARK: - Groups

    func testCreateAndOpenGroup() throws {
        let path = tempPath()
        defer { cleanup(path) }

        let file = try HDF5File.create(path: path)
        let group = try file.createGroup(name: "metadata")
        _ = group

        // Reopen and verify group exists
        let file2 = try HDF5File.openReadOnly(path: path)
        XCTAssertTrue(file2.exists(name: "metadata"))
        let group2 = try file2.openGroup(name: "metadata")
        _ = group2
    }

    func testNestedGroups() throws {
        let path = tempPath()
        defer { cleanup(path) }

        let file = try HDF5File.create(path: path)
        let g1 = try file.createGroup(name: "level1")
        let g2 = try g1.createGroup(name: "level2")
        try g2.writeStringAttribute(name: "test", value: "nested")

        let file2 = try HDF5File.openReadOnly(path: path)
        let g1r = try file2.openGroup(name: "level1")
        let g2r = try g1r.openGroup(name: "level2")
        let val = try g2r.readStringAttribute(name: "test")
        XCTAssertEqual(val, "nested")
    }

    // MARK: - Attributes

    func testWriteAndReadStringAttribute() throws {
        let path = tempPath()
        defer { cleanup(path) }

        let file = try HDF5File.create(path: path)
        let group = try file.createGroup(name: "metadata")
        try group.writeStringAttribute(name: "format_id", value: "1.5")

        let file2 = try HDF5File.openReadOnly(path: path)
        let group2 = try file2.openGroup(name: "metadata")
        let value = try group2.readStringAttribute(name: "format_id")
        XCTAssertEqual(value, "1.5")
    }

    func testWriteAndReadFloatAttribute() throws {
        let path = tempPath()
        defer { cleanup(path) }

        let file = try HDF5File.create(path: path)
        let group = try file.createGroup(name: "metadata")
        try group.writeFloatAttribute(name: "version", value: 1.5)

        let file2 = try HDF5File.openReadOnly(path: path)
        let group2 = try file2.openGroup(name: "metadata")
        let value = try group2.readFloatAttribute(name: "version")
        XCTAssertEqual(value, 1.5, accuracy: 1e-6)
    }

    func testHasAttribute() throws {
        let path = tempPath()
        defer { cleanup(path) }

        let file = try HDF5File.create(path: path)
        let group = try file.createGroup(name: "test")
        try group.writeStringAttribute(name: "exists", value: "yes")

        let file2 = try HDF5File.openReadOnly(path: path)
        let group2 = try file2.openGroup(name: "test")
        XCTAssertTrue(group2.hasAttribute(name: "exists"))
        XCTAssertFalse(group2.hasAttribute(name: "doesNotExist"))
    }

    // MARK: - Simple typed datasets

    func testWriteAndReadInt32Dataset() throws {
        let path = tempPath()
        defer { cleanup(path) }

        let data: [Int32] = [1, 2, 3, 4, 5]

        let file = try HDF5File.create(path: path)
        try file.writeDataset(name: "integers", data: data, type: shim_H5T_NATIVE_INT32())

        let file2 = try HDF5File.openReadOnly(path: path)
        let ds = try file2.openDataset(name: "integers")
        let read = try ds.readInt32()
        XCTAssertEqual(read, data)
    }

    func testWriteAndReadFloat64Dataset() throws {
        let path = tempPath()
        defer { cleanup(path) }

        let data: [Double] = [1.5, 2.7, 3.14159, -0.001]

        let file = try HDF5File.create(path: path)
        try file.writeDataset(name: "doubles", data: data, type: shim_H5T_NATIVE_DOUBLE())

        let file2 = try HDF5File.openReadOnly(path: path)
        let ds = try file2.openDataset(name: "doubles")
        let read = try ds.readFloat64()
        XCTAssertEqual(read.count, data.count)
        for i in 0..<data.count {
            XCTAssertEqual(read[i], data[i], accuracy: 1e-10)
        }
    }

    func testWriteAndReadFloat32Dataset() throws {
        let path = tempPath()
        defer { cleanup(path) }

        let data: [Float] = [1.0, 2.0, 3.0]

        let file = try HDF5File.create(path: path)
        try file.writeDataset(name: "floats", data: data, type: shim_H5T_NATIVE_FLOAT())

        let file2 = try HDF5File.openReadOnly(path: path)
        let ds = try file2.openDataset(name: "floats")
        let read = try ds.readFloat32()
        XCTAssertEqual(read.count, data.count)
        for i in 0..<data.count {
            XCTAssertEqual(read[i], data[i], accuracy: 1e-6)
        }
    }

    func testWriteAndReadUInt8Dataset() throws {
        let path = tempPath()
        defer { cleanup(path) }

        let data: [UInt8] = [0, 127, 255, 42]

        let file = try HDF5File.create(path: path)
        try file.writeDataset(name: "bytes", data: data, type: shim_H5T_NATIVE_UINT8())

        let file2 = try HDF5File.openReadOnly(path: path)
        let ds = try file2.openDataset(name: "bytes")
        let read = try ds.readUInt8()
        XCTAssertEqual(read, data)
    }

    func testWriteAndReadUInt64Dataset() throws {
        let path = tempPath()
        defer { cleanup(path) }

        let data: [UInt64] = [0, 1, UInt64.max, 42]

        let file = try HDF5File.create(path: path)
        try file.writeDataset(name: "uint64s", data: data, type: shim_H5T_NATIVE_UINT64())

        let file2 = try HDF5File.openReadOnly(path: path)
        let ds = try file2.openDataset(name: "uint64s")
        let read = try ds.readUInt64()
        XCTAssertEqual(read, data)
    }

    // MARK: - Variable-length string datasets

    func testWriteAndReadVLenStringDataset() throws {
        let path = tempPath()
        defer { cleanup(path) }

        let strings = [
            "{\"name\": \"video0\"}",
            "{\"name\": \"video1\"}",
        ]

        let file = try HDF5File.create(path: path)
        try file.writeVLenStringDataset(name: "videos_json", strings: strings)

        let file2 = try HDF5File.openReadOnly(path: path)
        let ds = try file2.openDataset(name: "videos_json")
        let read = try ds.readVLenStrings()
        XCTAssertEqual(read, strings)
    }

    // MARK: - Dataset shape and count

    func testDatasetShapeAndCount() throws {
        let path = tempPath()
        defer { cleanup(path) }

        let data: [Float] = Array(repeating: 0.0, count: 100)

        let file = try HDF5File.create(path: path)
        try file.writeDataset(name: "data", data: data, type: shim_H5T_NATIVE_FLOAT())

        let file2 = try HDF5File.openReadOnly(path: path)
        let ds = try file2.openDataset(name: "data")
        XCTAssertEqual(ds.count, 100)
        XCTAssertEqual(ds.shape, [100])
    }

    // MARK: - Compound dataset (field-by-field)

    func testCompoundDatasetFieldByFieldRead() throws {
        let path = tempPath()
        defer { cleanup(path) }

        // Create a compound dataset simulating /points: {x: f64, y: f64, visible: u8}
        let n = 3
        let file = try HDF5File.create(path: path)
        let group = try file.createGroup(name: "test")

        // Build the compound type manually
        let xOffset = 0
        let yOffset = MemoryLayout<Double>.size
        let visOffset = yOffset + MemoryLayout<Double>.size
        let totalSize = visOffset + MemoryLayout<UInt8>.size

        let compType = try HDF5Datatype.createCompound(size: totalSize)
        try compType.insertField(name: "x", offset: xOffset, type: shim_H5T_NATIVE_DOUBLE())
        try compType.insertField(name: "y", offset: yOffset, type: shim_H5T_NATIVE_DOUBLE())
        try compType.insertField(name: "visible", offset: visOffset, type: shim_H5T_NATIVE_UINT8())

        // Pack data into a contiguous buffer
        var buffer = [UInt8](repeating: 0, count: totalSize * n)
        let xs: [Double] = [10.0, 20.0, 30.0]
        let ys: [Double] = [15.0, 25.0, 35.0]
        let visible: [UInt8] = [1, 0, 1]

        buffer.withUnsafeMutableBufferPointer { ptr in
            let base = ptr.baseAddress!
            for i in 0..<n {
                let rowBase = base + totalSize * i
                rowBase.withMemoryRebound(to: UInt8.self, capacity: totalSize) { _ in
                    let xPtr = UnsafeMutableRawPointer(rowBase + xOffset).assumingMemoryBound(to: Double.self)
                    let yPtr = UnsafeMutableRawPointer(rowBase + yOffset).assumingMemoryBound(to: Double.self)
                    let vPtr = UnsafeMutableRawPointer(rowBase + visOffset).assumingMemoryBound(to: UInt8.self)
                    xPtr.pointee = xs[i]
                    yPtr.pointee = ys[i]
                    vPtr.pointee = visible[i]
                }
            }
        }

        try group.writeCompoundDataset(
            name: "points",
            count: n,
            fileType: compType,
            data: buffer
        )

        // Read back field-by-field
        let file2 = try HDF5File.openReadOnly(path: path)
        let group2 = try file2.openGroup(name: "test")
        let ds = try group2.openDataset(name: "points")

        let readXs = try ds.readCompoundFieldFloat64(fieldName: "x", count: n)
        let readYs = try ds.readCompoundFieldFloat64(fieldName: "y", count: n)
        let readVis = try ds.readCompoundFieldUInt8(fieldName: "visible", count: n)

        XCTAssertEqual(Array(readXs), xs)
        XCTAssertEqual(Array(readYs), ys)
        XCTAssertEqual(Array(readVis), visible)
    }

    // MARK: - Exists check

    func testExistsCheck() throws {
        let path = tempPath()
        defer { cleanup(path) }

        let file = try HDF5File.create(path: path)
        _ = try file.createGroup(name: "present")

        XCTAssertTrue(file.exists(name: "present"))
        XCTAssertFalse(file.exists(name: "absent"))
    }

    // MARK: - Multiple datasets in same file

    func testMultipleDatasetsCoexist() throws {
        let path = tempPath()
        defer { cleanup(path) }

        let file = try HDF5File.create(path: path)
        try file.writeDataset(name: "ds_a", data: [Int32(1), 2, 3], type: shim_H5T_NATIVE_INT32())
        try file.writeDataset(name: "ds_b", data: [Float(4.0), 5.0], type: shim_H5T_NATIVE_FLOAT())

        let file2 = try HDF5File.openReadOnly(path: path)
        let dsA = try file2.openDataset(name: "ds_a")
        let dsB = try file2.openDataset(name: "ds_b")

        let readA = try dsA.readInt32()
        let readB = try dsB.readFloat32()

        XCTAssertEqual(readA, [1, 2, 3])
        XCTAssertEqual(readB.count, 2)
        XCTAssertEqual(readB[0], 4.0, accuracy: 1e-6)
        XCTAssertEqual(readB[1], 5.0, accuracy: 1e-6)
    }
}
