import XCTest
import CoreGraphics
@testable import SleapRendering
@testable import SleapIO

// MARK: - Test Helpers

private func makeSkeleton(nodeCount: Int) -> Skeleton {
    let nodes = (0..<nodeCount).map { Node(name: "node_\($0)") }
    var edges: [Edge] = []
    for i in 0..<(nodeCount - 1) {
        edges.append(Edge(source: nodes[i], destination: nodes[i + 1]))
    }
    return Skeleton(name: "test", nodes: nodes, edges: edges)
}

private func makeInstance(skeleton: Skeleton, track: Track? = nil, allVisible: Bool = true) -> Instance {
    let points = skeleton.nodes.enumerated().map { (i, _) in
        Point(x: Float(10 * i + 10), y: Float(10 * i + 10), visible: allVisible)
    }
    return Instance(skeleton: skeleton, points: PointsArray(points: points), track: track)
}

private func makePredictedInstance(skeleton: Skeleton, score: Float = 0.95) -> PredictedInstance {
    let points = skeleton.nodes.enumerated().map { (i, _) in
        PredictedPoint(x: Float(10 * i + 10), y: Float(10 * i + 10), visible: true, score: 0.9)
    }
    return PredictedInstance(skeleton: skeleton, points: PredictedPointsArray(points: points), score: score)
}

private func makePartiallyVisibleInstance(skeleton: Skeleton) -> Instance {
    let points = skeleton.nodes.enumerated().map { (i, _) in
        Point(x: Float(10 * i + 10), y: Float(10 * i + 10), visible: i % 2 == 0)
    }
    return Instance(skeleton: skeleton, points: PointsArray(points: points))
}

private func makeTestImage(width: Int = 100, height: Int = 100) -> CGImage {
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let ctx = CGContext(data: nil, width: width, height: height,
                        bitsPerComponent: 8, bytesPerRow: width * 4,
                        space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    return ctx.makeImage()!
}

private func imagesAreIdentical(_ a: CGImage, _ b: CGImage) -> Bool {
    pixelDiffCount(a, b) == 0
}

private func pixelDiffCount(_ a: CGImage, _ b: CGImage) -> Int {
    guard a.width == b.width && a.height == b.height else { return -1 }
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let bytesPerRow = a.width * 4
    let totalBytes = bytesPerRow * a.height
    var dataA = [UInt8](repeating: 0, count: totalBytes)
    var dataB = [UInt8](repeating: 0, count: totalBytes)
    CGContext(data: &dataA, width: a.width, height: a.height, bitsPerComponent: 8,
              bytesPerRow: bytesPerRow, space: colorSpace,
              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        .draw(a, in: CGRect(x: 0, y: 0, width: a.width, height: a.height))
    CGContext(data: &dataB, width: b.width, height: b.height, bitsPerComponent: 8,
              bytesPerRow: bytesPerRow, space: colorSpace,
              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        .draw(b, in: CGRect(x: 0, y: 0, width: b.width, height: b.height))
    var count = 0
    for i in stride(from: 0, to: totalBytes, by: 4) {
        if dataA[i] != dataB[i] || dataA[i+1] != dataB[i+1] ||
           dataA[i+2] != dataB[i+2] || dataA[i+3] != dataB[i+3] {
            count += 1
        }
    }
    return count
}

// MARK: - RenderOptions Tests

final class RenderOptionsTests: XCTestCase {

    func testDefaultValues() {
        let opts = RenderOptions.defaults
        XCTAssertEqual(opts.nodeRadius, 4.0)
        XCTAssertEqual(opts.edgeWidth, 2.0)
        XCTAssertEqual(opts.palette, "alphabet")
        XCTAssertFalse(opts.showLabels)
        XCTAssertFalse(opts.showTrackNames)
        XCTAssertFalse(opts.showBoundingBoxes)
        XCTAssertEqual(opts.predictionOpacity, 0.6)
    }

    func testCustomInitialization() {
        let opts = RenderOptions(nodeRadius: 8, edgeWidth: 3, palette: "catscale",
                                 showLabels: true, showTrackNames: true,
                                 showBoundingBoxes: true, predictionOpacity: 0.5)
        XCTAssertEqual(opts.nodeRadius, 8.0)
        XCTAssertEqual(opts.palette, "catscale")
        XCTAssertTrue(opts.showLabels)
    }
}

// MARK: - Color Palette Tests

final class ColorPaletteTests: XCTestCase {

    func testAlphabetPaletteHas26Colors() {
        XCTAssertEqual(ColorPalette.alphabet.count, 26)
    }

    func testCatscalePaletteHas10Colors() {
        XCTAssertEqual(ColorPalette.catscale.count, 10)
    }

    func testColorByIndexWrapsAround() {
        let c0 = ColorPalette.color(at: 0, palette: "alphabet")
        let c26 = ColorPalette.color(at: 26, palette: "alphabet")
        XCTAssertEqual(c0.components?.count, c26.components?.count)
    }

    func testUnknownPaletteFallsBackToAlphabet() {
        let pal = ColorPalette.palette(named: "nonexistent")
        XCTAssertEqual(pal.count, 26)
    }

    func testAlphabetFirstColorMatchesSLEAP() {
        let c = ColorPalette.alphabet[0]
        guard let rgb = c.converted(to: CGColorSpaceCreateDeviceRGB(), intent: .defaultIntent, options: nil),
              let comp = rgb.components, comp.count >= 3 else { XCTFail("No RGB"); return }
        XCTAssertEqual(comp[0], 240.0 / 255.0, accuracy: 0.03)
        XCTAssertEqual(comp[1], 163.0 / 255.0, accuracy: 0.08)
        XCTAssertEqual(comp[2], 255.0 / 255.0, accuracy: 0.03)
    }
}

// MARK: - PoseRenderer Tests

final class PoseRendererTests: XCTestCase {

    func testRenderReturnsSameDimensions() {
        let skel = makeSkeleton(nodeCount: 3)
        let image = makeTestImage(width: 200, height: 150)
        let result = PoseRenderer().render(instances: [makeInstance(skeleton: skel)], onto: image, skeleton: skel)
        XCTAssertEqual(result.width, 200)
        XCTAssertEqual(result.height, 150)
    }

    func testRenderEmptyInstancesUnchanged() {
        let skel = makeSkeleton(nodeCount: 3)
        let image = makeTestImage(width: 50, height: 50)
        let result = PoseRenderer().render(instances: [], onto: image, skeleton: skel)
        XCTAssertTrue(imagesAreIdentical(image, result))
    }

    func testRenderDrawsSomething() {
        let skel = makeSkeleton(nodeCount: 4)
        let image = makeTestImage()
        let result = PoseRenderer().render(instances: [makeInstance(skeleton: skel)], onto: image, skeleton: skel)
        XCTAssertGreaterThan(pixelDiffCount(image, result), 0)
    }

    func testInvisiblePointsSkipped() {
        let skel = makeSkeleton(nodeCount: 4)
        let image = makeTestImage()
        let renderer = PoseRenderer()
        let full = renderer.render(instances: [makeInstance(skeleton: skel)], onto: image, skeleton: skel)
        let partial = renderer.render(instances: [makePartiallyVisibleInstance(skeleton: skel)], onto: image, skeleton: skel)
        XCTAssertGreaterThan(pixelDiffCount(image, full), pixelDiffCount(image, partial))
    }

    func testAllInvisibleDrawsNothing() {
        let skel = makeSkeleton(nodeCount: 3)
        let pts = (0..<3).map { Point(x: Float($0 * 10 + 20), y: Float($0 * 10 + 20), visible: false) }
        let inst = Instance(skeleton: skel, points: PointsArray(points: pts))
        let image = makeTestImage()
        let result = PoseRenderer().render(instances: [inst], onto: image, skeleton: skel)
        XCTAssertTrue(imagesAreIdentical(image, result))
    }

    func testPredictedInstanceRendering() {
        let skel = makeSkeleton(nodeCount: 3)
        let image = makeTestImage()
        let result = PoseRenderer().render(instances: [makePredictedInstance(skeleton: skel)], onto: image, skeleton: skel)
        XCTAssertGreaterThan(pixelDiffCount(image, result), 0)
    }

    func testPredictionOpacityDiffers() {
        let skel = makeSkeleton(nodeCount: 3)
        let pred = makePredictedInstance(skeleton: skel)
        let image = makeTestImage()
        let opaque = PoseRenderer(options: RenderOptions(predictionOpacity: 1.0))
            .render(instances: [pred], onto: image, skeleton: skel)
        let half = PoseRenderer(options: RenderOptions(predictionOpacity: 0.5))
            .render(instances: [pred], onto: image, skeleton: skel)
        XCTAssertFalse(imagesAreIdentical(opaque, half))
    }

    func testShowLabelsDrawsMore() {
        let skel = makeSkeleton(nodeCount: 3)
        let inst = makeInstance(skeleton: skel)
        let image = makeTestImage()
        let noL = PoseRenderer(options: RenderOptions(showLabels: false)).render(instances: [inst], onto: image, skeleton: skel)
        let withL = PoseRenderer(options: RenderOptions(showLabels: true)).render(instances: [inst], onto: image, skeleton: skel)
        XCTAssertGreaterThan(pixelDiffCount(image, withL), pixelDiffCount(image, noL))
    }

    func testShowBoundingBoxesDrawsMore() {
        let skel = makeSkeleton(nodeCount: 3)
        let inst = makeInstance(skeleton: skel)
        let image = makeTestImage()
        let noB = PoseRenderer(options: RenderOptions(showBoundingBoxes: false)).render(instances: [inst], onto: image, skeleton: skel)
        let withB = PoseRenderer(options: RenderOptions(showBoundingBoxes: true)).render(instances: [inst], onto: image, skeleton: skel)
        XCTAssertGreaterThan(pixelDiffCount(image, withB), pixelDiffCount(image, noB))
    }

    func testShowTrackNamesDrawsMore() {
        let skel = makeSkeleton(nodeCount: 3)
        let inst = makeInstance(skeleton: skel, track: Track(name: "animal_1"))
        let image = makeTestImage()
        let noN = PoseRenderer(options: RenderOptions(showTrackNames: false)).render(instances: [inst], onto: image, skeleton: skel)
        let withN = PoseRenderer(options: RenderOptions(showTrackNames: true)).render(instances: [inst], onto: image, skeleton: skel)
        XCTAssertGreaterThan(pixelDiffCount(image, withN), pixelDiffCount(image, noN))
    }

    func testSingleNodeSkeleton() {
        let skel = Skeleton(name: "one", nodes: [Node(name: "single")], edges: [])
        let inst = Instance(skeleton: skel, points: PointsArray(points: [Point(x: 50, y: 50, visible: true)]))
        let image = makeTestImage()
        let result = PoseRenderer().render(instances: [inst], onto: image, skeleton: skel)
        XCTAssertGreaterThan(pixelDiffCount(image, result), 0)
    }

    func testLargerNodeRadiusDrawsMore() {
        let skel = makeSkeleton(nodeCount: 2)
        let inst = makeInstance(skeleton: skel)
        let image = makeTestImage()
        let small = PoseRenderer(options: RenderOptions(nodeRadius: 2)).render(instances: [inst], onto: image, skeleton: skel)
        let large = PoseRenderer(options: RenderOptions(nodeRadius: 10)).render(instances: [inst], onto: image, skeleton: skel)
        XCTAssertGreaterThan(pixelDiffCount(image, large), pixelDiffCount(image, small))
    }

    func testNaNCoordinatesDoNotCrash() {
        let skel = makeSkeleton(nodeCount: 3)
        let inst = Instance(skeleton: skel)
        let image = makeTestImage()
        let result = PoseRenderer().render(instances: [inst], onto: image, skeleton: skel)
        XCTAssertEqual(result.width, image.width)
    }
}
