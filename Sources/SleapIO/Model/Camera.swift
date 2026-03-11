import Foundation

/// Camera intrinsic and extrinsic parameters.
public final class Camera: Hashable, @unchecked Sendable {
    public var name: String
    /// 3x3 intrinsic matrix as row-major [Float]. Length = 9.
    public var matrix: [Float]?
    /// Distortion coefficients.
    public var distortionCoefficients: [Float]?
    /// Image size (width, height).
    public var size: (width: Int, height: Int)?
    /// Rotation vector (Rodrigues).
    public var rvec: [Float]?
    /// Translation vector.
    public var tvec: [Float]?

    public init(name: String) {
        self.name = name
    }

    /// Compute the 3x4 extrinsic matrix from rvec/tvec.
    public var extrinsicMatrix: [Float]? {
        guard let rvec = rvec, rvec.count == 3,
              let tvec = tvec, tvec.count == 3 else { return nil }

        // Rodrigues rotation: convert rotation vector to 3x3 matrix
        let theta = sqrt(rvec[0] * rvec[0] + rvec[1] * rvec[1] + rvec[2] * rvec[2])
        guard theta > .ulpOfOne else {
            // Identity rotation
            return [1, 0, 0, tvec[0],
                    0, 1, 0, tvec[1],
                    0, 0, 1, tvec[2]]
        }

        let k = rvec.map { $0 / theta }
        let ct = cos(theta)
        let st = sin(theta)
        let omc = 1 - ct

        let r00 = ct + k[0] * k[0] * omc
        let r01 = k[0] * k[1] * omc - k[2] * st
        let r02 = k[0] * k[2] * omc + k[1] * st
        let r10 = k[1] * k[0] * omc + k[2] * st
        let r11 = ct + k[1] * k[1] * omc
        let r12 = k[1] * k[2] * omc - k[0] * st
        let r20 = k[2] * k[0] * omc - k[1] * st
        let r21 = k[2] * k[1] * omc + k[0] * st
        let r22 = ct + k[2] * k[2] * omc

        return [r00, r01, r02, tvec[0],
                r10, r11, r12, tvec[1],
                r20, r21, r22, tvec[2]]
    }

    // MARK: - Identity equality

    public static func == (lhs: Camera, rhs: Camera) -> Bool {
        lhs === rhs
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(ObjectIdentifier(self))
    }
}
