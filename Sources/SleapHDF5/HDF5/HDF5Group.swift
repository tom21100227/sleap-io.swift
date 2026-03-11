import Foundation
import CHDF5

/// Thin wrapper around an HDF5 group (hid_t).
final class HDF5Group {
    let id: hid_t

    init(id: hid_t) {
        self.id = id
    }

    deinit {
        if id >= 0 {
            H5Gclose(id)
        }
    }

    // MARK: - Open child groups/datasets

    /// Open a child group by name.
    func openGroup(name: String) throws -> HDF5Group {
        let gid = try hdf5Call("H5Gopen2 \(name)") {
            H5Gopen2(id, name, shim_H5P_DEFAULT())
        }
        return HDF5Group(id: gid)
    }

    /// Open a child dataset by name.
    func openDataset(name: String) throws -> HDF5Dataset {
        let did = try hdf5Call("H5Dopen2 \(name)") {
            H5Dopen2(id, name, shim_H5P_DEFAULT())
        }
        return HDF5Dataset(id: did)
    }

    /// Check if a child object exists.
    func exists(name: String) -> Bool {
        H5Lexists(id, name, shim_H5P_DEFAULT()) > 0
    }

    // MARK: - Create child groups/datasets

    /// Create a child group.
    func createGroup(name: String) throws -> HDF5Group {
        let gid = try hdf5Call("H5Gcreate2 \(name)") {
            H5Gcreate2(id, name, shim_H5P_DEFAULT(), shim_H5P_DEFAULT(), shim_H5P_DEFAULT())
        }
        return HDF5Group(id: gid)
    }

    /// Create a dataset with given type and space.
    func createDataset(name: String, type: HDF5Datatype, space: HDF5Dataspace,
                       chunkSize: [Int]? = nil) throws -> HDF5Dataset {
        let plist: hid_t
        if let chunk = chunkSize {
            plist = H5Pcreate(shim_H5P_DATASET_CREATE())
            var chunkDims = chunk.map { hsize_t($0) }
            H5Pset_chunk(plist, Int32(chunk.count), &chunkDims)
        } else {
            plist = shim_H5P_DEFAULT()
        }

        let did = try hdf5Call("H5Dcreate2 \(name)") {
            H5Dcreate2(id, name, type.id, space.id, shim_H5P_DEFAULT(), plist, shim_H5P_DEFAULT())
        }

        if chunkSize != nil {
            H5Pclose(plist)
        }

        return HDF5Dataset(id: did)
    }

    /// Create and write a simple 1D dataset of a given native type.
    func writeDataset<T>(name: String, data: [T], type: hid_t) throws {
        let space = try HDF5Dataspace.create(dims: [data.count])
        let dtype = try HDF5Datatype.copy(type)
        let ds = try createDataset(name: name, type: dtype, space: space)
        try ds.write(data, memType: type)
    }

    /// Write a 1D compound dataset.
    func writeCompoundDataset(name: String, count: Int, fileType: HDF5Datatype,
                               data: UnsafeRawPointer, chunkSize: Int? = nil) throws {
        let space = try HDF5Dataspace.create(dims: [count])
        let chunk = chunkSize.map { [$0] }
        let ds = try createDataset(name: name, type: fileType, space: space, chunkSize: chunk)
        try ds.writeRaw(data, memType: fileType.id)
    }

    /// Write variable-length string dataset.
    func writeVLenStringDataset(name: String, strings: [String]) throws {
        let space = try HDF5Dataspace.create(dims: [strings.count])
        let dtype = try HDF5Datatype.createVariableLengthString()
        let ds = try createDataset(name: name, type: dtype, space: space)

        // Build array of C string pointers
        let cStrings = strings.map { strdup($0) }
        defer { cStrings.forEach { free($0) } }

        var ptrs = cStrings.map { UnsafePointer($0) as UnsafePointer<CChar>? }
        try hdf5Check("H5Dwrite vlen strings") {
            H5Dwrite(ds.id, dtype.id, shim_H5S_ALL(), shim_H5S_ALL(), shim_H5P_DEFAULT(), &ptrs)
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
