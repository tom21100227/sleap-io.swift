import Foundation
import CHDF5

/// Thin wrapper around an HDF5 file (hid_t).
/// All access must go through `HDF5FileActor` for thread safety.
final class HDF5File {
    let id: hid_t
    let path: String

    /// Suppress HDF5's default stderr error stack output once on first use.
    static let suppressErrorStack: Void = {
        shim_H5E_suppress()
    }()

    private init(id: hid_t, path: String) {
        self.id = id
        self.path = path
    }

    deinit {
        if id >= 0 {
            H5Fclose(id)
        }
    }

    /// Open an existing HDF5 file for reading.
    static func openReadOnly(path: String) throws -> HDF5File {
        _ = suppressErrorStack
        let fid = H5Fopen(path, shim_H5F_ACC_RDONLY(), shim_H5P_DEFAULT())
        guard fid >= 0 else {
            throw HDF5Error.openFailed("Cannot open file: \(path)")
        }
        return HDF5File(id: fid, path: path)
    }

    /// Open an existing HDF5 file for reading and writing.
    static func openReadWrite(path: String) throws -> HDF5File {
        _ = suppressErrorStack
        let fid = H5Fopen(path, shim_H5F_ACC_RDWR(), shim_H5P_DEFAULT())
        guard fid >= 0 else {
            throw HDF5Error.openFailed("Cannot open file for writing: \(path)")
        }
        return HDF5File(id: fid, path: path)
    }

    /// Create a new HDF5 file, truncating if it exists.
    static func create(path: String) throws -> HDF5File {
        _ = suppressErrorStack
        let fid = H5Fcreate(path, shim_H5F_ACC_TRUNC(), shim_H5P_DEFAULT(), shim_H5P_DEFAULT())
        guard fid >= 0 else {
            throw HDF5Error.createFailed("Cannot create file: \(path)")
        }
        return HDF5File(id: fid, path: path)
    }

    // MARK: - Root-level operations

    /// Open a top-level group.
    func openGroup(name: String) throws -> HDF5Group {
        let gid = try hdf5Call("H5Gopen2 \(name)") {
            H5Gopen2(id, name, shim_H5P_DEFAULT())
        }
        return HDF5Group(id: gid)
    }

    /// Open a top-level dataset.
    func openDataset(name: String) throws -> HDF5Dataset {
        let did = try hdf5Call("H5Dopen2 \(name)") {
            H5Dopen2(id, name, shim_H5P_DEFAULT())
        }
        return HDF5Dataset(id: did)
    }

    /// Check if a top-level object exists.
    func exists(name: String) -> Bool {
        H5Lexists(id, name, shim_H5P_DEFAULT()) > 0
    }

    /// Create a top-level group.
    func createGroup(name: String) throws -> HDF5Group {
        let gid = try hdf5Call("H5Gcreate2 \(name)") {
            H5Gcreate2(id, name, shim_H5P_DEFAULT(), shim_H5P_DEFAULT(), shim_H5P_DEFAULT())
        }
        return HDF5Group(id: gid)
    }

    /// Create a top-level dataset.
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

    /// Write a variable-length string dataset at the root level.
    func writeVLenStringDataset(name: String, strings: [String]) throws {
        let space = try HDF5Dataspace.create(dims: [strings.count])
        let dtype = try HDF5Datatype.createVariableLengthString()
        let ds = try createDataset(name: name, type: dtype, space: space)

        let cStrings = strings.map { strdup($0) }
        defer { cStrings.forEach { free($0) } }

        var ptrs = cStrings.map { UnsafePointer($0) as UnsafePointer<CChar>? }
        try hdf5Check("H5Dwrite vlen strings") {
            H5Dwrite(ds.id, dtype.id, shim_H5S_ALL(), shim_H5S_ALL(), shim_H5P_DEFAULT(), &ptrs)
        }
    }

    /// Write a 1D dataset at the root level.
    func writeDataset<T>(name: String, data: [T], type: hid_t) throws {
        let space = try HDF5Dataspace.create(dims: [data.count])
        let dtype = try HDF5Datatype.copy(type)
        let ds = try createDataset(name: name, type: dtype, space: space)
        try ds.write(data, memType: type)
    }

    // MARK: - Attribute access on root

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
}

// MARK: - HDF5FileActor

/// Actor that serializes all HDF5 file access.
/// The HDF5 C library is not thread-safe — all operations must go through this actor.
public actor HDF5FileActor {
    private let file: HDF5File

    private init(file: HDF5File) {
        self.file = file
    }

    /// Open an existing HDF5 file for reading.
    public static func openReadOnly(path: String) throws -> HDF5FileActor {
        let file = try HDF5File.openReadOnly(path: path)
        return HDF5FileActor(file: file)
    }

    /// Create a new HDF5 file.
    public static func create(path: String) throws -> HDF5FileActor {
        let file = try HDF5File.create(path: path)
        return HDF5FileActor(file: file)
    }

    /// Close the file. After this, no more operations are possible.
    public func close() {
        // The file will be closed by the HDF5File deinit
        // This method exists for explicit cleanup before deinit
    }

    /// The file path.
    public var path: String { file.path }

    // MARK: - Internal file access for SLP reader/writer

    /// Access the underlying file handle. Only for use within SleapHDF5 module.
    func withFile<T>(_ body: (HDF5File) throws -> T) rethrows -> T {
        try body(file)
    }
}
