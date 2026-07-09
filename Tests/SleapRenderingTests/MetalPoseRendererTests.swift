#if canImport(Metal)
import CoreGraphics
import XCTest
@testable import SleapIO
@testable import SleapRendering

final class MetalPoseRendererTests: XCTestCase {
    func testBufferLayoutMatchesMetalShaderContract() {
        XCTAssertEqual(MemoryLayout<SIMD2<Float>>.stride, 8)
        XCTAssertEqual(MemoryLayout<SIMD4<Float>>.stride, 16)
        XCTAssertEqual(MetalPoseRenderer.edgeVertexStride, 32)
        XCTAssertEqual(MetalPoseRenderer.edgeVertexColorOffset, 16)
        XCTAssertEqual(MetalPoseRenderer.nodeInstanceStride, 32)
        XCTAssertEqual(MetalPoseRenderer.nodeInstanceColorOffset, 16)
    }

    func testSingleInstanceWithEdgesProducesNonEmptyImage() throws {
        let options = RenderOptions(nodeRadius: 5, palette: "standard")
        guard let renderer = MetalPoseRenderer(options: options) else {
            throw XCTSkip("No Metal device available")
        }

        let skeleton = metalTestSkeleton()
        let instance = metalTestInstance(skeleton: skeleton, offsetX: 0, offsetY: 0)

        let image = try XCTUnwrap(renderer.render(
            instances: [instance],
            skeleton: skeleton,
            width: 96,
            height: 96
        ))

        XCTAssertEqual(image.width, 96)
        XCTAssertEqual(image.height, 96)
        XCTAssertGreaterThan(metalNonTransparentPixelCount(in: image), 0)
        XCTAssertGreaterThan(
            metalNonTransparentPixelCount(in: image, rect: CGRect(x: 15, y: 15, width: 60, height: 45)),
            0
        )
    }

    func testRendering120InstancesProducesNonEmptyImage() throws {
        guard let renderer = MetalPoseRenderer(options: RenderOptions(nodeRadius: 3, palette: "alphabet")) else {
            throw XCTSkip("No Metal device available")
        }

        let skeleton = metalTestSkeleton()
        var instances: [Instance] = []
        instances.reserveCapacity(120)
        for index in 0..<120 {
            let offsetX = Float((index % 12) * 7)
            let offsetY = Float((index / 12) * 7)
            let instance = metalTestInstance(skeleton: skeleton, offsetX: offsetX, offsetY: offsetY)
            instances.append(instance)
        }

        let image = try XCTUnwrap(renderer.render(
            instances: instances,
            skeleton: skeleton,
            width: 160,
            height: 120
        ))

        XCTAssertEqual(image.width, 160)
        XCTAssertEqual(image.height, 120)
        XCTAssertGreaterThan(metalNonTransparentPixelCount(in: image), 0)
    }

    func testEmptyInstancesProducesTransparentImage() throws {
        guard let renderer = MetalPoseRenderer(options: .defaults) else {
            throw XCTSkip("No Metal device available")
        }

        let image = try XCTUnwrap(renderer.render(
            instances: [],
            skeleton: metalTestSkeleton(),
            width: 64,
            height: 48
        ))

        XCTAssertEqual(image.width, 64)
        XCTAssertEqual(image.height, 48)
        XCTAssertEqual(metalNonTransparentPixelCount(in: image), 0)
    }

    func testPredictedInstanceHonorsPredictionOpacity() throws {
        let options = RenderOptions(
            nodeRadius: 8,
            palette: "standard",
            predictionOpacity: 0.4,
            showEdges: false
        )
        guard let renderer = MetalPoseRenderer(options: options) else {
            throw XCTSkip("No compatible Metal device available")
        }

        let skeleton = metalTestSkeleton()
        let instance = metalTestPredictedInstance(skeleton: skeleton)
        let image = try XCTUnwrap(renderer.render(
            instances: [instance],
            skeleton: skeleton,
            width: 64,
            height: 64
        ))
        let counts = metalAlphaCounts(in: image)

        XCTAssertGreaterThan(counts.nonTransparent, 0)
        XCTAssertGreaterThan(counts.semiTransparent, 0)
    }

    func testRoughParityWithCoreGraphicsGeneralArea() throws {
        let options = RenderOptions(nodeRadius: 5, palette: "standard")
        guard let metalRenderer = MetalPoseRenderer(options: options) else {
            throw XCTSkip("No Metal device available")
        }

        let skeleton = metalTestSkeleton()
        let instance = metalTestInstance(skeleton: skeleton, offsetX: 0, offsetY: 0)
        let width = 96
        let height = 96

        let base = try XCTUnwrap(metalTransparentImage(width: width, height: height))
        let coreGraphicsImage = PoseRenderer(options: options).render(
            instances: [instance],
            onto: base,
            skeleton: skeleton
        )
        let metalImage = try XCTUnwrap(metalRenderer.render(
            instances: [instance],
            skeleton: skeleton,
            width: width,
            height: height
        ))

        let region = CGRect(x: 15, y: 15, width: 60, height: 45)
        XCTAssertGreaterThan(metalNonTransparentPixelCount(in: coreGraphicsImage), 0)
        XCTAssertGreaterThan(metalNonTransparentPixelCount(in: metalImage), 0)
        XCTAssertGreaterThan(metalNonTransparentPixelCount(in: coreGraphicsImage, rect: region), 0)
        XCTAssertGreaterThan(metalNonTransparentPixelCount(in: metalImage, rect: region), 0)
    }
}

private func metalTestSkeleton() -> Skeleton {
    let nodes = [
        Node(name: "head"),
        Node(name: "thorax"),
        Node(name: "abdomen"),
    ]
    let edges = [
        Edge(source: nodes[0], destination: nodes[1]),
        Edge(source: nodes[1], destination: nodes[2]),
    ]
    return Skeleton(name: "metal_test", nodes: nodes, edges: edges)
}

private func metalTestInstance(skeleton: Skeleton, offsetX: Float, offsetY: Float) -> Instance {
    let points = [
        Point(x: 20 + offsetX, y: 20 + offsetY),
        Point(x: 42 + offsetX, y: 36 + offsetY),
        Point(x: 68 + offsetX, y: 48 + offsetY),
    ]
    return Instance(skeleton: skeleton, points: PointsArray(points: points))
}

private func metalTestPredictedInstance(skeleton: Skeleton) -> PredictedInstance {
    let points = [
        PredictedPoint(x: 24, y: 24, score: 0.9),
        PredictedPoint(x: 40, y: 24, score: 0.8),
        PredictedPoint(x: 32, y: 42, score: 0.7),
    ]
    return PredictedInstance(
        skeleton: skeleton,
        points: PredictedPointsArray(points: points),
        score: 0.9
    )
}

private func metalTransparentImage(width: Int, height: Int) -> CGImage? {
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let context = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: width * 4,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )
    return context?.makeImage()
}

private func metalNonTransparentPixelCount(in image: CGImage, rect: CGRect? = nil) -> Int {
    metalAlphaCounts(in: image, rect: rect).nonTransparent
}

private func metalAlphaCounts(in image: CGImage, rect: CGRect? = nil) -> (nonTransparent: Int, semiTransparent: Int) {
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let bytesPerRow = image.width * 4
    var bytes = [UInt8](repeating: 0, count: bytesPerRow * image.height)

    guard let context = CGContext(
        data: &bytes,
        width: image.width,
        height: image.height,
        bitsPerComponent: 8,
        bytesPerRow: bytesPerRow,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        return (0, 0)
    }

    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))

    let bounds = rect ?? CGRect(x: 0, y: 0, width: image.width, height: image.height)
    let minX = max(0, Int(bounds.minX.rounded(.down)))
    let maxX = min(image.width, Int(bounds.maxX.rounded(.up)))
    let minY = max(0, Int(bounds.minY.rounded(.down)))
    let maxY = min(image.height, Int(bounds.maxY.rounded(.up)))

    guard minX < maxX, minY < maxY else { return (0, 0) }

    var nonTransparent = 0
    var semiTransparent = 0
    for y in minY..<maxY {
        for x in minX..<maxX {
            let alphaIndex = y * bytesPerRow + x * 4 + 3
            let alpha = bytes[alphaIndex]
            if alpha > 0 {
                nonTransparent += 1
            }
            if alpha > 0 && alpha < 255 {
                semiTransparent += 1
            }
        }
    }
    return (nonTransparent, semiTransparent)
}
#endif
