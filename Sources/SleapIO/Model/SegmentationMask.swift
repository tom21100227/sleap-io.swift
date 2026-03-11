import Foundation

/// A run-length encoded binary segmentation mask.
public struct SegmentationMask: Hashable, Codable, Sendable {
    public var annotationType: AnnotationType
    public var name: String
    public var category: String?
    public var score: Float?
    public var source: String?

    /// RLE-encoded counts (COCO-style).
    public var rleCounts: [Int]
    public var height: Int
    public var width: Int

    public var videoIndex: Int?
    public var frameIndex: Int?
    public var trackIndex: Int?
    public var instanceIndex: Int?

    public init(rleCounts: [Int], height: Int, width: Int, name: String) {
        self.rleCounts = rleCounts
        self.height = height
        self.width = width
        self.name = name
        self.annotationType = .segmentationMask
    }

    /// Decode to a dense boolean mask. `true` = foreground.
    public func decode() -> [[Bool]] {
        var mask = Array(repeating: Array(repeating: false, count: width), count: height)
        var pos = 0
        var value = false
        for count in rleCounts {
            for _ in 0..<count {
                if pos < height * width {
                    let row = pos / width
                    let col = pos % width
                    mask[row][col] = value
                    pos += 1
                }
            }
            value.toggle()
        }
        return mask
    }

    /// Encode from a dense boolean mask.
    public static func encode(mask: [[Bool]], name: String) -> SegmentationMask {
        let height = mask.count
        let width = mask.first?.count ?? 0
        var counts: [Int] = []
        var currentValue = false
        var currentCount = 0

        for row in 0..<height {
            for col in 0..<width {
                let val = mask[row][col]
                if val == currentValue {
                    currentCount += 1
                } else {
                    counts.append(currentCount)
                    currentValue = val
                    currentCount = 1
                }
            }
        }
        if currentCount > 0 {
            counts.append(currentCount)
        }

        return SegmentationMask(rleCounts: counts, height: height, width: width, name: name)
    }
}
