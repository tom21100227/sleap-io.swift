import Foundation
import CHDF5

/// Thin wrapper around an HDF5 dataset (hid_t).
final class HDF5Dataset {
    let id: hid_t

    init(id: hid_t) {
        self.id = id
    }

    deinit {
        if id >= 0 {
            H5Dclose(id)
        }
    }

    /// Get the dataset's dataspace.
    var dataspace: HDF5Dataspace {
        HDF5Dataspace(id: H5Dget_space(id))
    }

    /// Get the dataset's datatype.
    var datatype: HDF5Datatype {
        HDF5Datatype(id: H5Dget_type(id), owned: true)
    }

    /// Number of elements in the dataset.
    var count: Int {
        dataspace.totalElements
    }

    /// Shape (dimensions) of the dataset.
    var shape: [Int] {
        dataspace.dims
    }

    // MARK: - Read typed arrays

    /// Read the entire dataset as Float32 array.
    func readFloat32() throws -> [Float] {
        let n = count
        var buffer = [Float](repeating: 0, count: n)
        try hdf5Check("H5Dread float32") {
            H5Dread(id, shim_H5T_NATIVE_FLOAT(), shim_H5S_ALL(), shim_H5S_ALL(), shim_H5P_DEFAULT(), &buffer)
        }
        return buffer
    }

    /// Read the entire dataset as Float64 array.
    func readFloat64() throws -> [Double] {
        let n = count
        var buffer = [Double](repeating: 0, count: n)
        try hdf5Check("H5Dread float64") {
            H5Dread(id, shim_H5T_NATIVE_DOUBLE(), shim_H5S_ALL(), shim_H5S_ALL(), shim_H5P_DEFAULT(), &buffer)
        }
        return buffer
    }

    /// Read the entire dataset as UInt8 array.
    func readUInt8() throws -> [UInt8] {
        let n = count
        var buffer = [UInt8](repeating: 0, count: n)
        try hdf5Check("H5Dread uint8") {
            H5Dread(id, shim_H5T_NATIVE_UINT8(), shim_H5S_ALL(), shim_H5S_ALL(), shim_H5P_DEFAULT(), &buffer)
        }
        return buffer
    }

    /// Read the entire dataset as Int32 array.
    func readInt32() throws -> [Int32] {
        let n = count
        var buffer = [Int32](repeating: 0, count: n)
        try hdf5Check("H5Dread int32") {
            H5Dread(id, shim_H5T_NATIVE_INT32(), shim_H5S_ALL(), shim_H5S_ALL(), shim_H5P_DEFAULT(), &buffer)
        }
        return buffer
    }

    /// Read the entire dataset as Int64 array.
    func readInt64() throws -> [Int64] {
        let n = count
        var buffer = [Int64](repeating: 0, count: n)
        try hdf5Check("H5Dread int64") {
            H5Dread(id, shim_H5T_NATIVE_INT64(), shim_H5S_ALL(), shim_H5S_ALL(), shim_H5P_DEFAULT(), &buffer)
        }
        return buffer
    }

    /// Read the entire dataset as UInt32 array.
    func readUInt32() throws -> [UInt32] {
        let n = count
        var buffer = [UInt32](repeating: 0, count: n)
        try hdf5Check("H5Dread uint32") {
            H5Dread(id, shim_H5T_NATIVE_UINT32(), shim_H5S_ALL(), shim_H5S_ALL(), shim_H5P_DEFAULT(), &buffer)
        }
        return buffer
    }

    /// Read the entire dataset as UInt64 array.
    func readUInt64() throws -> [UInt64] {
        let n = count
        var buffer = [UInt64](repeating: 0, count: n)
        try hdf5Check("H5Dread uint64") {
            H5Dread(id, shim_H5T_NATIVE_UINT64(), shim_H5S_ALL(), shim_H5S_ALL(), shim_H5P_DEFAULT(), &buffer)
        }
        return buffer
    }

    // MARK: - Compound field-by-field reads

    /// Read a single field from a compound dataset as Float64.
    func readCompoundFieldFloat64(fieldName: String, count: Int) throws -> ContiguousArray<Double> {
        let fileType = datatype
        let memberIdx = H5Tget_member_index(fileType.id, fieldName)
        guard memberIdx >= 0 else {
            throw HDF5Error.readFailed("Compound field '\(fieldName)' not found")
        }

        // Create a memory compound type with just this one field
        let memType = try HDF5Datatype.createCompound(size: MemoryLayout<Double>.size)
        try memType.insertField(name: fieldName, offset: 0, type: shim_H5T_NATIVE_DOUBLE())

        var buffer = ContiguousArray<Double>(repeating: 0, count: count)
        try buffer.withUnsafeMutableBufferPointer { ptr in
            try hdf5Check("H5Dread compound field \(fieldName) float64") {
                H5Dread(id, memType.id, shim_H5S_ALL(), shim_H5S_ALL(), shim_H5P_DEFAULT(), ptr.baseAddress!)
            }
        }
        return buffer
    }

    /// Read a single field from a compound dataset as Float32.
    func readCompoundFieldFloat32(fieldName: String, count: Int) throws -> ContiguousArray<Float> {
        let fileType = datatype
        let memberIdx = H5Tget_member_index(fileType.id, fieldName)
        guard memberIdx >= 0 else {
            throw HDF5Error.readFailed("Compound field '\(fieldName)' not found")
        }

        let memType = try HDF5Datatype.createCompound(size: MemoryLayout<Float>.size)
        try memType.insertField(name: fieldName, offset: 0, type: shim_H5T_NATIVE_FLOAT())

        var buffer = ContiguousArray<Float>(repeating: 0, count: count)
        try buffer.withUnsafeMutableBufferPointer { ptr in
            try hdf5Check("H5Dread compound field \(fieldName) float32") {
                H5Dread(id, memType.id, shim_H5S_ALL(), shim_H5S_ALL(), shim_H5P_DEFAULT(), ptr.baseAddress!)
            }
        }
        return buffer
    }

    /// Read a single field from a compound dataset as UInt8.
    func readCompoundFieldUInt8(fieldName: String, count: Int) throws -> ContiguousArray<UInt8> {
        let memType = try HDF5Datatype.createCompound(size: MemoryLayout<UInt8>.size)
        try memType.insertField(name: fieldName, offset: 0, type: shim_H5T_NATIVE_UINT8())

        var buffer = ContiguousArray<UInt8>(repeating: 0, count: count)
        try buffer.withUnsafeMutableBufferPointer { ptr in
            try hdf5Check("H5Dread compound field \(fieldName) uint8") {
                H5Dread(id, memType.id, shim_H5S_ALL(), shim_H5S_ALL(), shim_H5P_DEFAULT(), ptr.baseAddress!)
            }
        }
        return buffer
    }

    /// Read a single field from a compound dataset as UInt32.
    func readCompoundFieldUInt32(fieldName: String, count: Int) throws -> ContiguousArray<UInt32> {
        let memType = try HDF5Datatype.createCompound(size: MemoryLayout<UInt32>.size)
        try memType.insertField(name: fieldName, offset: 0, type: shim_H5T_NATIVE_UINT32())

        var buffer = ContiguousArray<UInt32>(repeating: 0, count: count)
        try buffer.withUnsafeMutableBufferPointer { ptr in
            try hdf5Check("H5Dread compound field \(fieldName) uint32") {
                H5Dread(id, memType.id, shim_H5S_ALL(), shim_H5S_ALL(), shim_H5P_DEFAULT(), ptr.baseAddress!)
            }
        }
        return buffer
    }

    /// Read a single field from a compound dataset as UInt64.
    func readCompoundFieldUInt64(fieldName: String, count: Int) throws -> ContiguousArray<UInt64> {
        let memType = try HDF5Datatype.createCompound(size: MemoryLayout<UInt64>.size)
        try memType.insertField(name: fieldName, offset: 0, type: shim_H5T_NATIVE_UINT64())

        var buffer = ContiguousArray<UInt64>(repeating: 0, count: count)
        try buffer.withUnsafeMutableBufferPointer { ptr in
            try hdf5Check("H5Dread compound field \(fieldName) uint64") {
                H5Dread(id, memType.id, shim_H5S_ALL(), shim_H5S_ALL(), shim_H5P_DEFAULT(), ptr.baseAddress!)
            }
        }
        return buffer
    }

    /// Read a single field from a compound dataset as Int32.
    func readCompoundFieldInt32(fieldName: String, count: Int) throws -> ContiguousArray<Int32> {
        let memType = try HDF5Datatype.createCompound(size: MemoryLayout<Int32>.size)
        try memType.insertField(name: fieldName, offset: 0, type: shim_H5T_NATIVE_INT32())

        var buffer = ContiguousArray<Int32>(repeating: 0, count: count)
        try buffer.withUnsafeMutableBufferPointer { ptr in
            try hdf5Check("H5Dread compound field \(fieldName) int32") {
                H5Dread(id, memType.id, shim_H5S_ALL(), shim_H5S_ALL(), shim_H5P_DEFAULT(), ptr.baseAddress!)
            }
        }
        return buffer
    }

    /// Read a single field from a compound dataset as Int64.
    func readCompoundFieldInt64(fieldName: String, count: Int) throws -> ContiguousArray<Int64> {
        let memType = try HDF5Datatype.createCompound(size: MemoryLayout<Int64>.size)
        try memType.insertField(name: fieldName, offset: 0, type: shim_H5T_NATIVE_INT64())

        var buffer = ContiguousArray<Int64>(repeating: 0, count: count)
        try buffer.withUnsafeMutableBufferPointer { ptr in
            try hdf5Check("H5Dread compound field \(fieldName) int64") {
                H5Dread(id, memType.id, shim_H5S_ALL(), shim_H5S_ALL(), shim_H5P_DEFAULT(), ptr.baseAddress!)
            }
        }
        return buffer
    }

    /// Read a boolean field from a compound dataset (stored as hbool_t / uint8).
    func readCompoundFieldBool(fieldName: String, count: Int) throws -> ContiguousArray<Bool> {
        let raw = try readCompoundFieldUInt8(fieldName: fieldName, count: count)
        return ContiguousArray(raw.map { $0 != 0 })
    }

    // MARK: - Variable-length reads

    /// Read string dataset (variable-length or fixed-length). Each element is a Data blob.
    func readVLenBytes() throws -> [Data] {
        let n = count
        guard n > 0 else { return [] }
        let fileType = datatype
        let tc = fileType.typeClass

        guard tc == shim_H5T_VLEN() || tc == shim_H5T_STRING() else {
            throw HDF5Error.typeMismatch("Dataset is not a string or vlen type")
        }

        // Generic H5T_VLEN (e.g. vlen<int8>) — read via hvl_t structs
        if tc == shim_H5T_VLEN() {
            let memType = try HDF5Datatype.copy(fileType.id)
            var hvls = [hvl_t](repeating: hvl_t(), count: n)
            try hdf5Check("H5Dread vlen") {
                H5Dread(id, memType.id, shim_H5S_ALL(), shim_H5S_ALL(), shim_H5P_DEFAULT(), &hvls)
            }

            var result = [Data]()
            result.reserveCapacity(n)
            for hvl in hvls {
                if hvl.len > 0, let p = hvl.p {
                    result.append(Data(bytes: p, count: hvl.len))
                } else {
                    result.append(Data())
                }
            }

            let space = dataspace
            H5Treclaim(memType.id, space.id, shim_H5P_DEFAULT(), &hvls)
            return result
        }

        let isVarLen = H5Tis_variable_str(fileType.id) > 0

        if isVarLen {
            // Variable-length string path — use the file's own type to avoid
            // ASCII/UTF-8 charset mismatch during type conversion.
            let memType = try HDF5Datatype.copy(fileType.id)
            var ptrs = [UnsafeMutablePointer<CChar>?](repeating: nil, count: n)
            try hdf5Check("H5Dread vlen") {
                H5Dread(id, memType.id, shim_H5S_ALL(), shim_H5S_ALL(), shim_H5P_DEFAULT(), &ptrs)
            }

            var result = [Data]()
            result.reserveCapacity(n)
            for ptr in ptrs {
                if let p = ptr {
                    let str = String(cString: p)
                    result.append(str.data(using: .utf8) ?? Data())
                } else {
                    result.append(Data())
                }
            }

            let space = dataspace
            H5Treclaim(memType.id, space.id, shim_H5P_DEFAULT(), &ptrs)
            return result
        } else {
            // Fixed-length string path
            let strSize = H5Tget_size(fileType.id)
            var buffer = [UInt8](repeating: 0, count: n * strSize)
            try hdf5Check("H5Dread fixed strings") {
                H5Dread(id, fileType.id, shim_H5S_ALL(), shim_H5S_ALL(), shim_H5P_DEFAULT(), &buffer)
            }

            var result = [Data]()
            result.reserveCapacity(n)
            for i in 0..<n {
                let start = i * strSize
                var end = start + strSize
                // Strip trailing nulls
                while end > start && buffer[end - 1] == 0 { end -= 1 }
                let bytes = buffer[start..<end]
                result.append(Data(bytes))
            }
            return result
        }
    }

    /// Read string dataset. Each element is a String.
    func readVLenStrings() throws -> [String] {
        let data = try readVLenBytes()
        return data.map { String(data: $0, encoding: .utf8) ?? "" }
    }

    // MARK: - Write

    /// Write a typed array to this dataset.
    func write<T>(_ buffer: [T], memType: hid_t) throws {
        try buffer.withUnsafeBufferPointer { ptr in
            try hdf5Check("H5Dwrite") {
                H5Dwrite(id, memType, shim_H5S_ALL(), shim_H5S_ALL(), shim_H5P_DEFAULT(), ptr.baseAddress!)
            }
        }
    }

    /// Write a ContiguousArray to this dataset.
    func write<T>(_ buffer: ContiguousArray<T>, memType: hid_t) throws {
        try buffer.withUnsafeBufferPointer { ptr in
            try hdf5Check("H5Dwrite") {
                H5Dwrite(id, memType, shim_H5S_ALL(), shim_H5S_ALL(), shim_H5P_DEFAULT(), ptr.baseAddress!)
            }
        }
    }

    /// Write raw bytes to this dataset.
    func writeRaw(_ data: UnsafeRawPointer, memType: hid_t) throws {
        try hdf5Check("H5Dwrite raw") {
            H5Dwrite(id, memType, shim_H5S_ALL(), shim_H5S_ALL(), shim_H5P_DEFAULT(), data)
        }
    }

    // MARK: - Attribute access

    func readStringAttribute(name: String) throws -> String {
        try HDF5Attribute.readString(from: id, name: name)
    }

    func readFloatAttribute(name: String) throws -> Float {
        try HDF5Attribute.readFloat(from: id, name: name)
    }

    func writeStringAttribute(name: String, value: String) throws {
        try HDF5Attribute.writeString(to: id, name: name, value: value)
    }

    func writeFloatAttribute(name: String, value: Float) throws {
        try HDF5Attribute.writeFloat(to: id, name: name, value: value)
    }

    func hasAttribute(name: String) -> Bool {
        HDF5Attribute.exists(on: id, name: name)
    }
}
