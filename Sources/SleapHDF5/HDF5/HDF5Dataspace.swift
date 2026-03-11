import Foundation
import CHDF5

/// Thin wrapper around an HDF5 dataspace (hid_t).
final class HDF5Dataspace {
    let id: hid_t

    init(id: hid_t) {
        self.id = id
    }

    deinit {
        if id >= 0 {
            H5Sclose(id)
        }
    }

    /// Number of dimensions.
    var ndims: Int {
        Int(H5Sget_simple_extent_ndims(id))
    }

    /// Dimensions of the dataspace.
    var dims: [Int] {
        let n = ndims
        guard n > 0 else { return [] }
        var d = [hsize_t](repeating: 0, count: n)
        H5Sget_simple_extent_dims(id, &d, nil)
        return d.map { Int($0) }
    }

    /// Total number of elements.
    var totalElements: Int {
        dims.reduce(1, *)
    }

    /// Create a simple dataspace with given dimensions.
    static func create(dims: [Int]) throws -> HDF5Dataspace {
        var d = dims.map { hsize_t($0) }
        let sid = try hdf5Call("H5Screate_simple") {
            H5Screate_simple(Int32(dims.count), &d, nil)
        }
        return HDF5Dataspace(id: sid)
    }

    /// Create a scalar dataspace.
    static func createScalar() throws -> HDF5Dataspace {
        let sid = try hdf5Call("H5Screate scalar") {
            H5Screate(H5S_SCALAR)
        }
        return HDF5Dataspace(id: sid)
    }

    /// Select a hyperslab within this dataspace.
    func selectHyperslab(offset: [Int], count: [Int]) throws {
        var off = offset.map { hsize_t($0) }
        var cnt = count.map { hsize_t($0) }
        try hdf5Check("H5Sselect_hyperslab") {
            H5Sselect_hyperslab(id, H5S_SELECT_SET, &off, nil, &cnt, nil)
        }
    }
}
