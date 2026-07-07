import Foundation

/// Errors raised by camera math and shape validation.
public enum CameraError: Error, Equatable, Sendable {
    /// An array parameter did not have the expected element count.
    case invalidShape(String)
}

/// Camera intrinsic and extrinsic parameters.
///
/// Mirrors Python sleap-io's `Camera`. Rotation is stored as an unnormalized
/// axis-angle rotation vector (``rvec``); the extrinsic matrix is derived from
/// ``rvec``/``tvec`` on demand and can also be set to decompose back into them.
public final class Camera: Hashable, @unchecked Sendable {
    public var name: String
    /// 3x3 intrinsic matrix as row-major [Float]. Length = 9.
    public var matrix: [Float]?
    /// Radial-tangential distortion coefficients `[k1, k2, p1, p2, k3]`. Length = 5.
    public var distortionCoefficients: [Float]?
    /// Image size (width, height).
    public var size: (width: Int, height: Int)?
    /// Rotation vector (unnormalized axis-angle, Rodrigues). Length = 3.
    public var rvec: [Float]?
    /// Translation vector. Length = 3.
    public var tvec: [Float]?

    public init(
        name: String,
        matrix: [Float]? = nil,
        distortionCoefficients: [Float]? = nil,
        size: (width: Int, height: Int)? = nil,
        rvec: [Float]? = nil,
        tvec: [Float]? = nil
    ) {
        self.name = name
        self.matrix = matrix
        self.distortionCoefficients = distortionCoefficients
        self.size = size
        self.rvec = rvec
        self.tvec = tvec
    }

    // MARK: - Rodrigues transformation

    /// Convert a rotation vector (axis-angle) to a 3x3 rotation matrix.
    ///
    /// This is the forward Rodrigues transformation. It is the inverse of
    /// ``rotationVector(fromRotationMatrix:)`` up to the usual axis-angle
    /// ambiguities (a rotation and its `2π` complements map to the same matrix).
    ///
    /// - Parameter rvec: Rotation vector of length 3.
    /// - Returns: Row-major 3x3 rotation matrix of length 9.
    /// - Throws: ``CameraError/invalidShape(_:)`` if `rvec` is not length 3.
    public static func rotationMatrix(fromRotationVector rvec: [Float]) throws -> [Float] {
        guard rvec.count == 3 else {
            throw CameraError.invalidShape(
                "rotation vector must have 3 elements, but received \(rvec.count)"
            )
        }

        let r0 = Double(rvec[0]), r1 = Double(rvec[1]), r2 = Double(rvec[2])
        let theta = (r0 * r0 + r1 * r1 + r2 * r2).squareRoot()

        // Near-zero rotation: identity matrix.
        guard theta > 1e-9 else {
            return [1, 0, 0,
                    0, 1, 0,
                    0, 0, 1]
        }

        // Normalized rotation axis.
        let kx = r0 / theta, ky = r1 / theta, kz = r2 / theta
        let ct = cos(theta)
        let st = sin(theta)
        let omc = 1 - ct

        // R = cos(θ)·I + sin(θ)·K + (1 - cos(θ))·k·kᵀ
        let r00 = ct + kx * kx * omc
        let r01 = kx * ky * omc - kz * st
        let r02 = kx * kz * omc + ky * st
        let r10 = ky * kx * omc + kz * st
        let r11 = ct + ky * ky * omc
        let r12 = ky * kz * omc - kx * st
        let r20 = kz * kx * omc - ky * st
        let r21 = kz * ky * omc + kx * st
        let r22 = ct + kz * kz * omc

        return [Float(r00), Float(r01), Float(r02),
                Float(r10), Float(r11), Float(r12),
                Float(r20), Float(r21), Float(r22)]
    }

    /// Convert a 3x3 rotation matrix to a rotation vector (axis-angle).
    ///
    /// This is the inverse Rodrigues transformation. Round-tripping a rotation
    /// through ``rotationMatrix(fromRotationVector:)`` and back recovers the
    /// original vector within floating-point tolerance (for angles in `(0, π)`;
    /// the `π` case is canonicalized to a fixed axis sign).
    ///
    /// - Parameter matrix: Row-major 3x3 rotation matrix of length 9.
    /// - Returns: Rotation vector of length 3.
    /// - Throws: ``CameraError/invalidShape(_:)`` if `matrix` is not length 9.
    public static func rotationVector(fromRotationMatrix matrix: [Float]) throws -> [Float] {
        guard matrix.count == 9 else {
            throw CameraError.invalidShape(
                "rotation matrix must have 9 elements (3x3 row-major), "
                    + "but received \(matrix.count)"
            )
        }

        let m00 = Double(matrix[0]), m01 = Double(matrix[1]), m02 = Double(matrix[2])
        let m10 = Double(matrix[3]), m11 = Double(matrix[4]), m12 = Double(matrix[5])
        let m20 = Double(matrix[6]), m21 = Double(matrix[7]), m22 = Double(matrix[8])

        // trace(R) = 1 + 2·cos(θ)
        let cosTheta = min(max((m00 + m11 + m22 - 1) / 2, -1), 1)
        let theta = acos(cosTheta)

        // Near-zero rotation (identity): zero vector.
        guard theta > 1e-9 else {
            return [0, 0, 0]
        }

        // Near-π rotation: R is symmetric and the antisymmetric part vanishes,
        // so recover the axis from the largest diagonal element instead.
        if Double.pi - theta < 1e-3 {
            let diag = [m00, m11, m22]
            var k = 0
            if diag[1] > diag[k] { k = 1 }
            if diag[2] > diag[k] { k = 2 }

            var axis = [0.0, 0.0, 0.0]
            if diag[k] > -1 {
                axis[k] = 1
                // v = column-k of R + e_k, then normalized.
                let col = [matrix[k], matrix[3 + k], matrix[6 + k]].map(Double.init)
                var vx = col[0] + axis[0]
                var vy = col[1] + axis[1]
                var vz = col[2] + axis[2]
                let norm = (vx * vx + vy * vy + vz * vz).squareRoot()
                if norm > 0 {
                    vx /= norm; vy /= norm; vz /= norm
                }
                axis = [vx, vy, vz]
            }
            return [Float(theta * axis[0]), Float(theta * axis[1]), Float(theta * axis[2])]
        }

        // General case: extract the axis from the skew-symmetric part.
        let sinTheta = sin(theta)
        var ax = (m21 - m12) / (2 * sinTheta)
        var ay = (m02 - m20) / (2 * sinTheta)
        var az = (m10 - m01) / (2 * sinTheta)
        let norm = (ax * ax + ay * ay + az * az).squareRoot()
        if norm > 0 {
            ax /= norm; ay /= norm; az /= norm
        }
        return [Float(theta * ax), Float(theta * ay), Float(theta * az)]
    }

    // MARK: - Extrinsic matrix

    /// The 4x4 extrinsic matrix `[R | t; 0 0 0 1]` as row-major [Float] (length 16).
    ///
    /// Getting composes the matrix from ``rvec``/``tvec`` (returns `nil` when
    /// either is unset). Setting decomposes a 4x4 matrix back into ``rvec``
    /// (inverse Rodrigues of the rotation block) and ``tvec`` (translation
    /// column); assigning `nil` clears both. A non-`nil` value that is not
    /// length 16 is ignored — use ``setExtrinsicMatrix(_:)`` for a checked set.
    public var extrinsicMatrix: [Float]? {
        get {
            guard let rvec = rvec, rvec.count == 3,
                  let tvec = tvec, tvec.count == 3,
                  let r = try? Camera.rotationMatrix(fromRotationVector: rvec)
            else { return nil }

            return [r[0], r[1], r[2], tvec[0],
                    r[3], r[4], r[5], tvec[1],
                    r[6], r[7], r[8], tvec[2],
                    0,    0,    0,    1]
        }
        set {
            guard let value = newValue else {
                rvec = nil
                tvec = nil
                return
            }
            try? setExtrinsicMatrix(value)
        }
    }

    /// Set the extrinsic matrix, decomposing it into ``rvec`` and ``tvec``.
    ///
    /// - Parameter value: Row-major 4x4 extrinsic matrix of length 16.
    /// - Throws: ``CameraError/invalidShape(_:)`` if `value` is not length 16.
    public func setExtrinsicMatrix(_ value: [Float]) throws {
        guard value.count == 16 else {
            throw CameraError.invalidShape(
                "extrinsic matrix must have 16 elements (4x4 row-major), "
                    + "but received \(value.count)"
            )
        }
        let rotation = [value[0], value[1], value[2],
                        value[4], value[5], value[6],
                        value[8], value[9], value[10]]
        rvec = try Camera.rotationVector(fromRotationMatrix: rotation)
        tvec = [value[3], value[7], value[11]]
    }

    // MARK: - Shape validation

    /// Set ``rvec`` after validating it has exactly 3 elements.
    ///
    /// - Throws: ``CameraError/invalidShape(_:)`` if `value` is non-`nil` and not length 3.
    public func setRotationVector(_ value: [Float]?) throws {
        if let value = value, value.count != 3 {
            throw CameraError.invalidShape(
                "rvec must have 3 elements, but received \(value.count)"
            )
        }
        rvec = value
    }

    /// Set ``tvec`` after validating it has exactly 3 elements.
    ///
    /// - Throws: ``CameraError/invalidShape(_:)`` if `value` is non-`nil` and not length 3.
    public func setTranslationVector(_ value: [Float]?) throws {
        if let value = value, value.count != 3 {
            throw CameraError.invalidShape(
                "tvec must have 3 elements, but received \(value.count)"
            )
        }
        tvec = value
    }

    /// Validate the shapes of all set parameters, mirroring Python's `_validate_shape`.
    ///
    /// - Throws: ``CameraError/invalidShape(_:)`` if any set parameter has the wrong length.
    public func validate() throws {
        if let matrix = matrix, matrix.count != 9 {
            throw CameraError.invalidShape(
                "matrix must have 9 elements (3x3), but received \(matrix.count)"
            )
        }
        if let dist = distortionCoefficients, dist.count != 5 {
            throw CameraError.invalidShape(
                "distortionCoefficients must have 5 elements, but received \(dist.count)"
            )
        }
        if let rvec = rvec, rvec.count != 3 {
            throw CameraError.invalidShape(
                "rvec must have 3 elements, but received \(rvec.count)"
            )
        }
        if let tvec = tvec, tvec.count != 3 {
            throw CameraError.invalidShape(
                "tvec must have 3 elements, but received \(tvec.count)"
            )
        }
    }

    // MARK: - Identity equality

    public static func == (lhs: Camera, rhs: Camera) -> Bool {
        lhs === rhs
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(ObjectIdentifier(self))
    }
}

/// A group of cameras used to record a multi-view ``RecordingSession``.
///
/// Mirrors Python sleap-io's `CameraGroup`: an ordered list of ``Camera``
/// objects plus free-form metadata.
public final class CameraGroup: @unchecked Sendable {
    /// Cameras in the group, in order.
    public var cameras: [Camera]
    /// Free-form metadata, mirroring Python sleap-io's `dict[str, Any]`.
    public var metadata: [String: JSONValue]

    public init(cameras: [Camera] = [], metadata: [String: JSONValue] = [:]) {
        self.cameras = cameras
        self.metadata = metadata
    }
}
