import CoreGraphics
import Foundation

/// Thread-safe frame cache backed by NSCache.
///
/// Uses NSCache for automatic eviction under memory pressure (critical for iPadOS).
final class FrameCache: @unchecked Sendable {
    private let cache: NSCache<NSNumber, CGImageWrapper>

    init(countLimit: Int = 64) {
        self.cache = NSCache()
        self.cache.countLimit = countLimit
        self.cache.totalCostLimit = 256 * 1024 * 1024  // 256 MB
    }

    func get(_ index: Int) -> CGImage? {
        cache.object(forKey: NSNumber(value: index))?.image
    }

    func set(_ image: CGImage, for index: Int) {
        let cost = image.bytesPerRow * image.height
        cache.setObject(CGImageWrapper(image), forKey: NSNumber(value: index), cost: cost)
    }

    func removeAll() {
        cache.removeAllObjects()
    }
}

/// Wrapper to store CGImage in NSCache (requires NSObject values).
private final class CGImageWrapper: NSObject {
    let image: CGImage
    init(_ image: CGImage) {
        self.image = image
    }
}
