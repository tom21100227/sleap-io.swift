import Accelerate

extension PointsArray {
    /// Apply a 3x3 affine transform matrix in-place using Accelerate.
    ///
    /// Matrix is row-major: `[a, b, tx, c, d, ty, 0, 0, 1]`.
    /// Transform: `x' = a*x + b*y + tx`, `y' = c*x + d*y + ty`.
    public mutating func apply(transform matrix: [Float]) {
        precondition(matrix.count == 9)
        let n = count
        guard n > 0 else { return }

        let a = matrix[0], b = matrix[1], tx = matrix[2]
        let c = matrix[3], d = matrix[4], ty = matrix[5]

        // Deinterleave into separate x, y arrays (2 allocations)
        var xs = [Float](repeating: 0, count: n)
        var ys = [Float](repeating: 0, count: n)

        coordinates.withUnsafeBufferPointer { buf in
            cblas_scopy(Int32(n), buf.baseAddress!, 2, &xs, 1)
            cblas_scopy(Int32(n), buf.baseAddress! + 1, 2, &ys, 1)
        }

        // Compute x' = a*xs + b*ys + tx and y' = c*xs + d*ys + ty
        // directly into interleaved coordinates (stride 2)
        coordinates.withUnsafeMutableBufferPointer { buf in
            let base = buf.baseAddress!

            // x' = tx (fill every other element), then x' += a*xs, then x' += b*ys
            var txVal = tx
            vDSP_vfill(&txVal, base, 2, vDSP_Length(n))
            cblas_saxpy(Int32(n), a, &xs, 1, base, 2)
            cblas_saxpy(Int32(n), b, &ys, 1, base, 2)

            // y' = ty (fill every other element at offset 1), then y' += c*xs, then y' += d*ys
            var tyVal = ty
            vDSP_vfill(&tyVal, base + 1, 2, vDSP_Length(n))
            cblas_saxpy(Int32(n), c, &xs, 1, base + 1, 2)
            cblas_saxpy(Int32(n), d, &ys, 1, base + 1, 2)
        }
    }
}

extension PredictedPointsArray {
    /// Apply a 3x3 affine transform matrix in-place (delegates to underlying PointsArray).
    public mutating func apply(transform matrix: [Float]) {
        points.apply(transform: matrix)
    }
}
