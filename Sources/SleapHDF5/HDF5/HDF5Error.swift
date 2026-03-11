import Foundation
import CHDF5

/// Errors from HDF5 operations.
public enum HDF5Error: Error, Sendable {
    case openFailed(String)
    case createFailed(String)
    case readFailed(String)
    case writeFailed(String)
    case datasetNotFound(String)
    case groupNotFound(String)
    case attributeNotFound(String)
    case typeMismatch(String)
    case invalidOperation(String)
}

/// Execute an HDF5 C call that returns a negative value on error.
@discardableResult
func hdf5Call(_ description: String = "", _ body: () -> hid_t) throws -> hid_t {
    let result = body()
    if result < 0 {
        throw HDF5Error.invalidOperation(description.isEmpty ? "HDF5 call failed with code \(result)" : description)
    }
    return result
}

/// Execute an HDF5 C call that returns herr_t (negative on error).
func hdf5Check(_ description: String = "", _ body: () -> herr_t) throws {
    let result = body()
    if result < 0 {
        throw HDF5Error.invalidOperation(description.isEmpty ? "HDF5 call failed with code \(result)" : description)
    }
}
