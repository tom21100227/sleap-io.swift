import Foundation
import CHDF5

/// Thin wrapper around an HDF5 datatype (hid_t).
final class HDF5Datatype {
    let id: hid_t
    let owned: Bool

    init(id: hid_t, owned: Bool = true) {
        self.id = id
        self.owned = owned
    }

    deinit {
        if owned && id >= 0 {
            H5Tclose(id)
        }
    }

    /// Get the type class.
    var typeClass: H5T_class_t {
        H5Tget_class(id)
    }

    /// Get the size of the datatype in bytes.
    var size: Int {
        H5Tget_size(id)
    }

    /// Number of members in a compound type.
    var memberCount: Int {
        guard typeClass == shim_H5T_COMPOUND() else { return 0 }
        return Int(H5Tget_nmembers(id))
    }

    /// Name of a compound member at given index.
    func memberName(at index: Int) -> String? {
        guard let cName = H5Tget_member_name(id, UInt32(index)) else { return nil }
        let name = String(cString: cName)
        H5free_memory(cName)
        return name
    }

    /// Offset of a compound member at given index.
    func memberOffset(at index: Int) -> Int {
        H5Tget_member_offset(id, UInt32(index))
    }

    /// Type of a compound member at given index.
    func memberType(at index: Int) -> HDF5Datatype {
        HDF5Datatype(id: H5Tget_member_type(id, UInt32(index)), owned: true)
    }

    // MARK: - Factory methods

    /// Create a compound datatype with the given total size.
    static func createCompound(size: Int) throws -> HDF5Datatype {
        let tid = try hdf5Call("H5Tcreate compound") {
            H5Tcreate(shim_H5T_COMPOUND(), size)
        }
        return HDF5Datatype(id: tid, owned: true)
    }

    /// Insert a field into a compound type.
    func insertField(name: String, offset: Int, type: hid_t) throws {
        try hdf5Check("H5Tinsert \(name)") {
            H5Tinsert(id, name, offset, type)
        }
    }

    /// Create a variable-length string type.
    static func createVariableLengthString() throws -> HDF5Datatype {
        let tid = try hdf5Call("H5Tcopy C_S1") {
            H5Tcopy(shim_H5T_C_S1())
        }
        try hdf5Check("H5Tset_size VARIABLE") {
            H5Tset_size(tid, shim_H5T_VARIABLE())
        }
        return HDF5Datatype(id: tid, owned: true)
    }

    /// Create a variable-length type wrapping another type.
    static func createVLen(of baseType: hid_t) throws -> HDF5Datatype {
        let tid = try hdf5Call("H5Tvlen_create") {
            H5Tvlen_create(baseType)
        }
        return HDF5Datatype(id: tid, owned: true)
    }

    /// Create a copy of a native type.
    static func copy(_ nativeType: hid_t) throws -> HDF5Datatype {
        let tid = try hdf5Call("H5Tcopy") {
            H5Tcopy(nativeType)
        }
        return HDF5Datatype(id: tid, owned: true)
    }
}
