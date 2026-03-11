import Foundation
import CHDF5

/// Thin wrapper around HDF5 attribute operations.
struct HDF5Attribute {

    /// Read a string attribute from a location (group or dataset).
    static func readString(from locId: hid_t, name: String) throws -> String {
        let aid = try hdf5Call("H5Aopen \(name)") {
            H5Aopen(locId, name, shim_H5P_DEFAULT())
        }
        defer { H5Aclose(aid) }

        let tid = H5Aget_type(aid)
        defer { H5Tclose(tid) }

        let typeClass = H5Tget_class(tid)

        if typeClass == shim_H5T_STRING() {
            let isVarLen = H5Tis_variable_str(tid) > 0
            if isVarLen {
                var ptr: UnsafeMutablePointer<CChar>?
                // Use the file's own type to avoid charset mismatch (ASCII vs UTF-8)
                let memType = try HDF5Datatype.copy(tid)
                try hdf5Check("H5Aread vlen string") {
                    H5Aread(aid, memType.id, &ptr)
                }
                guard let cStr = ptr else {
                    throw HDF5Error.readFailed("Null variable-length string for attribute '\(name)'")
                }
                let result = String(cString: cStr)
                H5free_memory(cStr)
                return result
            } else {
                let size = H5Tget_size(tid)
                // Read raw bytes using the file's own type to avoid
                // NULLPAD-to-NULLTERM conversion truncating the last byte.
                var buffer = [UInt8](repeating: 0, count: size + 1)
                try hdf5Check("H5Aread fixed string") {
                    H5Aread(aid, tid, &buffer)
                }
                buffer[size] = 0  // ensure null terminator after content
                // Strip trailing null bytes (HDF5 null-padded or null-terminated)
                var end = size
                while end > 0 && buffer[end - 1] == 0 { end -= 1 }
                return String(bytes: buffer[0..<end], encoding: .utf8)
                    ?? String(bytes: buffer[0..<end], encoding: .ascii)
                    ?? ""
            }
        }

        throw HDF5Error.typeMismatch("Attribute '\(name)' is not a string type")
    }

    /// Read a numeric attribute (Float or Double).
    static func readFloat(from locId: hid_t, name: String) throws -> Float {
        let aid = try hdf5Call("H5Aopen \(name)") {
            H5Aopen(locId, name, shim_H5P_DEFAULT())
        }
        defer { H5Aclose(aid) }

        let tid = H5Aget_type(aid)
        defer { H5Tclose(tid) }

        let typeClass = H5Tget_class(tid)
        if typeClass == shim_H5T_FLOAT() {
            let size = H5Tget_size(tid)
            if size == 8 {
                var value: Double = 0
                try hdf5Check("H5Aread double") {
                    H5Aread(aid, shim_H5T_NATIVE_DOUBLE(), &value)
                }
                return Float(value)
            } else {
                var value: Float = 0
                try hdf5Check("H5Aread float") {
                    H5Aread(aid, shim_H5T_NATIVE_FLOAT(), &value)
                }
                return value
            }
        } else if typeClass == shim_H5T_INTEGER() {
            var value: Int64 = 0
            try hdf5Check("H5Aread int") {
                H5Aread(aid, shim_H5T_NATIVE_INT64(), &value)
            }
            return Float(value)
        }

        throw HDF5Error.typeMismatch("Attribute '\(name)' is not a numeric type")
    }

    /// Write a string attribute to a location.
    static func writeString(to locId: hid_t, name: String, value: String) throws {
        let memType = try HDF5Datatype.createVariableLengthString()
        let space = try HDF5Dataspace.createScalar()

        // Delete existing attribute if present
        if H5Aexists(locId, name) > 0 {
            H5Adelete(locId, name)
        }

        let aid = try hdf5Call("H5Acreate2 \(name)") {
            H5Acreate2(locId, name, memType.id, space.id, shim_H5P_DEFAULT(), shim_H5P_DEFAULT())
        }
        defer { H5Aclose(aid) }

        try value.withCString { cStr in
            var ptr: UnsafePointer<CChar>? = cStr
            try hdf5Check("H5Awrite string") {
                H5Awrite(aid, memType.id, &ptr)
            }
        }
    }

    /// Write a float attribute to a location.
    static func writeFloat(to locId: hid_t, name: String, value: Float) throws {
        let space = try HDF5Dataspace.createScalar()

        if H5Aexists(locId, name) > 0 {
            H5Adelete(locId, name)
        }

        let aid = try hdf5Call("H5Acreate2 \(name)") {
            H5Acreate2(locId, name, shim_H5T_NATIVE_FLOAT(), space.id, shim_H5P_DEFAULT(), shim_H5P_DEFAULT())
        }
        defer { H5Aclose(aid) }

        var val = value
        try hdf5Check("H5Awrite float") {
            H5Awrite(aid, shim_H5T_NATIVE_FLOAT(), &val)
        }
    }

    /// Check if an attribute exists on a location.
    static func exists(on locId: hid_t, name: String) -> Bool {
        H5Aexists(locId, name) > 0
    }
}
