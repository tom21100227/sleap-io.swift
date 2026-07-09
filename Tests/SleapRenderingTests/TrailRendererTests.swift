import CoreGraphics
import XCTest
@testable import SleapIO
@testable import SleapRendering

final class TrailRendererTests: XCTestCase {
    func testTrackedMotionAcrossFourFramesDrawsTrail() {
        let image = makeTrailTestImage()
        let skeleton = makeTrailTestSkeleton(nodeCount: 1)
        let track = Track(name: "animal")
        let history = [
            [makeTrailTestInstance(skeleton: skeleton, track: track, positions: [CGPoint(x: 20, y: 20)])],
            [makeTrailTestInstance(skeleton: skeleton, track: track, positions: [CGPoint(x: 40, y: 35)])],
            [makeTrailTestInstance(skeleton: skeleton, track: track, positions: [CGPoint(x: 60, y: 50)])],
            [makeTrailTestInstance(skeleton: skeleton, track: track, positions: [CGPoint(x: 80, y: 65)])],
        ]

        let result = TrailRenderer(options: RenderOptions(showTrails: true))
            .render(onto: image, history: history, skeleton: skeleton)

        XCTAssertGreaterThan(trailPixelDiffCount(image, result), 0)
    }

    func testShowTrailsFalseGatesRendering() {
        let image = makeTrailTestImage()
        let skeleton = makeTrailTestSkeleton(nodeCount: 1)
        let track = Track(name: "animal")
        let history = makeTrailTestHistory(
            skeleton: skeleton,
            track: track,
            positionsByFrame: [[CGPoint(x: 20, y: 20)], [CGPoint(x: 80, y: 80)]]
        )

        let result = TrailRenderer(options: RenderOptions(showTrails: false))
            .render(onto: image, history: history, skeleton: skeleton)

        XCTAssertEqual(trailPixelDiffCount(image, result), 0)
    }

    func testTrailLengthZeroDrawsNothing() {
        let image = makeTrailTestImage()
        let skeleton = makeTrailTestSkeleton(nodeCount: 1)
        let track = Track(name: "animal")
        let history = makeTrailTestHistory(
            skeleton: skeleton,
            track: track,
            positionsByFrame: [[CGPoint(x: 20, y: 20)], [CGPoint(x: 80, y: 80)]]
        )

        let result = TrailRenderer(options: RenderOptions(showTrails: true, trailLength: 0))
            .render(onto: image, history: history, skeleton: skeleton)

        XCTAssertEqual(trailPixelDiffCount(image, result), 0)
    }

    func testNodeSelectionDrawsSubsetOfAllNodes() {
        let image = makeTrailTestImage()
        let skeleton = makeTrailTestSkeleton(nodeCount: 2)
        let track = Track(name: "animal")
        let history = makeTrailTestHistory(
            skeleton: skeleton,
            track: track,
            positionsByFrame: [
                [CGPoint(x: 20, y: 20), CGPoint(x: 20, y: 90)],
                [CGPoint(x: 45, y: 30), CGPoint(x: 45, y: 80)],
                [CGPoint(x: 70, y: 45), CGPoint(x: 70, y: 65)],
                [CGPoint(x: 95, y: 60), CGPoint(x: 95, y: 50)],
            ]
        )
        let renderer = TrailRenderer(options: RenderOptions(showTrails: true))

        let selected = renderer.render(
            onto: image,
            history: history,
            skeleton: skeleton,
            nodeIndices: [0]
        )
        let allNodes = renderer.render(onto: image, history: history, skeleton: skeleton)
        let selectedDiff = trailPixelDiffCount(image, selected)
        let allNodesDiff = trailPixelDiffCount(image, allNodes)

        XCTAssertGreaterThan(selectedDiff, 0)
        XCTAssertLessThanOrEqual(selectedDiff, allNodesDiff)
    }

    func testUntrackedInstancesDrawNothing() {
        let image = makeTrailTestImage()
        let skeleton = makeTrailTestSkeleton(nodeCount: 1)
        let history = makeTrailTestHistory(
            skeleton: skeleton,
            track: nil,
            positionsByFrame: [[CGPoint(x: 20, y: 20)], [CGPoint(x: 80, y: 80)]]
        )

        let result = TrailRenderer(options: RenderOptions(showTrails: true))
            .render(onto: image, history: history, skeleton: skeleton)

        XCTAssertEqual(trailPixelDiffCount(image, result), 0)
    }
}

private func makeTrailTestSkeleton(nodeCount: Int) -> Skeleton {
    let nodes = (0..<nodeCount).map { Node(name: "trail_node_\($0)") }
    return Skeleton(name: "trail_test", nodes: nodes)
}

private func makeTrailTestInstance(
    skeleton: Skeleton,
    track: Track?,
    positions: [CGPoint]
) -> Instance {
    let points = positions.map {
        Point(x: Float($0.x), y: Float($0.y), visible: true)
    }
    return Instance(skeleton: skeleton, points: PointsArray(points: points), track: track)
}

private func makeTrailTestHistory(
    skeleton: Skeleton,
    track: Track?,
    positionsByFrame: [[CGPoint]]
) -> [[Instance]] {
    positionsByFrame.map { positions in
        [makeTrailTestInstance(skeleton: skeleton, track: track, positions: positions)]
    }
}

private func makeTrailTestImage(width: Int = 120, height: Int = 120) -> CGImage {
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

private func trailPixelDiffCount(_ lhs: CGImage, _ rhs: CGImage) -> Int {
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
