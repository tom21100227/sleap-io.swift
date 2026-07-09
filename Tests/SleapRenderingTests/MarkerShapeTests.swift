import CoreGraphics
import XCTest
@testable import SleapIO
@testable import SleapRendering

final class MarkerShapeTests: XCTestCase {
    func testEachMarkerShapeRendersNonEmptyImage() {
        let skeleton = makeMarkerShapeSkeleton(nodeCount: 3)
        let instance = makeMarkerShapeInstance(skeleton: skeleton, complete: true)
        let image = makeMarkerShapeTestImage()

        for shape in MarkerShape.allCases {
            let renderer = PoseRenderer(options: RenderOptions(markerShape: shape))
            let result = renderer.render(instances: [instance], onto: image, skeleton: skeleton)

            XCTAssertGreaterThan(pixelDiffCount(image, result), 0, "Expected \(shape) to draw pixels")
        }
    }

    func testFullyIncompleteInstanceRendersHollowMarkers() {
        let skeleton = makeMarkerShapeSkeleton(nodeCount: 3)
        let instance = makeMarkerShapeInstance(skeleton: skeleton, complete: false)
        let image = makeMarkerShapeTestImage()

        let result = PoseRenderer(options: RenderOptions(markerShape: .diamond))
            .render(instances: [instance], onto: image, skeleton: skeleton)

        XCTAssertGreaterThan(pixelDiffCount(image, result), 0)
    }

    func testShowScoresOnPredictedInstanceRenders() {
        let skeleton = makeMarkerShapeSkeleton(nodeCount: 3)
        let instance = makeMarkerShapePredictedInstance(skeleton: skeleton)
        let image = makeMarkerShapeTestImage()

        let result = PoseRenderer(options: RenderOptions(showScores: true))
            .render(instances: [instance], onto: image, skeleton: skeleton)

        XCTAssertGreaterThan(pixelDiffCount(image, result), 0)
    }
}

private func makeMarkerShapeSkeleton(nodeCount: Int) -> Skeleton {
    let nodes = (0..<nodeCount).map { Node(name: "node_\($0)") }
    let edges = (0..<max(0, nodeCount - 1)).map { index in
        Edge(source: nodes[index], destination: nodes[index + 1])
    }
    return Skeleton(name: "test", nodes: nodes, edges: edges)
}

private func makeMarkerShapeInstance(skeleton: Skeleton, complete: Bool) -> Instance {
    let points = skeleton.nodes.enumerated().map { index, _ in
        let value = Float(index * 20 + 20)
        return Point(x: value, y: value, visible: true, complete: complete)
    }
    return Instance(skeleton: skeleton, points: PointsArray(points: points))
}

private func makeMarkerShapePredictedInstance(skeleton: Skeleton) -> PredictedInstance {
    let points = skeleton.nodes.enumerated().map { index, _ in
        let value = Float(index * 20 + 20)
        return PredictedPoint(x: value, y: value, visible: true, complete: true, score: Float(index + 1) / 10)
    }
    return PredictedInstance(skeleton: skeleton, points: PredictedPointsArray(points: points), score: 0.9)
}

private func makeMarkerShapeTestImage(width: Int = 120, height: Int = 120) -> CGImage {
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let context = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: width * 4,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    return context.makeImage()!
}

private func pixelDiffCount(_ lhs: CGImage, _ rhs: CGImage) -> Int {
    guard lhs.width == rhs.width && lhs.height == rhs.height else { return -1 }

    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let bytesPerRow = lhs.width * 4
    let totalBytes = bytesPerRow * lhs.height
    var lhsData = [UInt8](repeating: 0, count: totalBytes)
    var rhsData = [UInt8](repeating: 0, count: totalBytes)

    CGContext(
        data: &lhsData,
        width: lhs.width,
        height: lhs.height,
        bitsPerComponent: 8,
        bytesPerRow: bytesPerRow,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!.draw(lhs, in: CGRect(x: 0, y: 0, width: lhs.width, height: lhs.height))

    CGContext(
        data: &rhsData,
        width: rhs.width,
        height: rhs.height,
        bitsPerComponent: 8,
        bytesPerRow: bytesPerRow,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!.draw(rhs, in: CGRect(x: 0, y: 0, width: rhs.width, height: rhs.height))

    var count = 0
    for index in stride(from: 0, to: totalBytes, by: 4) {
        if lhsData[index] != rhsData[index] ||
            lhsData[index + 1] != rhsData[index + 1] ||
            lhsData[index + 2] != rhsData[index + 2] ||
            lhsData[index + 3] != rhsData[index + 3] {
            count += 1
        }
    }
    return count
}
