import Foundation

/// Factory for building 3x3 affine transform matrices in row-major layout.
///
/// Matrix format: `[a, b, tx, c, d, ty, 0, 0, 1]`
/// Transform: `x' = a*x + b*y + tx`, `y' = c*x + d*y + ty`
public enum AffineTransform2D {
    /// Identity matrix (no-op transform).
    public static let identity: [Float] = [1, 0, 0, 0, 1, 0, 0, 0, 1]

    /// Translation matrix.
    public static func translation(dx: Float, dy: Float) -> [Float] {
        [1, 0, dx, 0, 1, dy, 0, 0, 1]
    }

    /// Scale matrix relative to an origin point.
    public static func scale(sx: Float, sy: Float, origin: SIMD2<Float> = .zero) -> [Float] {
        if origin == .zero {
            return [sx, 0, 0, 0, sy, 0, 0, 0, 1]
        }
        return [sx, 0, origin.x * (1 - sx),
                0, sy, origin.y * (1 - sy),
                0, 0, 1]
    }

    /// Rotation matrix (radians, counterclockwise) around an origin point.
    public static func rotation(radians: Float, around origin: SIMD2<Float> = .zero) -> [Float] {
        let c = cos(radians)
        let s = sin(radians)
        if origin == .zero {
            return [c, -s, 0, s, c, 0, 0, 0, 1]
        }
        let tx = origin.x * (1 - c) + origin.y * s
        let ty = origin.y * (1 - c) - origin.x * s
        return [c, -s, tx, s, c, ty, 0, 0, 1]
    }

    /// Compose two transforms: result applies `b` first, then `a`.
    public static func compose(_ a: [Float], _ b: [Float]) -> [Float] {
        precondition(a.count == 9 && b.count == 9)
        var result = [Float](repeating: 0, count: 9)
        for row in 0..<3 {
            for col in 0..<3 {
                var sum: Float = 0
                for k in 0..<3 {
                    sum += a[row * 3 + k] * b[k * 3 + col]
                }
                result[row * 3 + col] = sum
            }
        }
        return result
    }
}
