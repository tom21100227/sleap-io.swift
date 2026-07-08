import CoreGraphics
import ImageIO
import XCTest
@testable import SleapIO
@testable import SleapRendering

final class RenderImageTests: XCTestCase {
    func testSolidBackgroundRenderReturnsSizeAndDrawsPixels() {
        let skeleton = makeRenderImageSkeleton()
        let instance = makeRenderImageInstance(skeleton: skeleton)
        let renderer = RenderImage()
        let plain = makeRenderImageTestImage(
            width: 100,
            height: 80,
            color: CGColor(red: 0, green: 0, blue: 0, alpha: 1)
        )

        let result = renderer.render(
            instances: [instance],
            skeleton: skeleton,
            background: .solid(CGColor(red: 0, green: 0, blue: 0, alpha: 1), width: 100, height: 80)
        )

        XCTAssertEqual(result.width, 100)
        XCTAssertEqual(result.height, 80)
        XCTAssertGreaterThan(renderImagePixelDiffCount(plain, result), 0)
    }

    func testSolidBackgroundConvenienceOverloadReturnsSizeAndDrawsPixels() {
        let skeleton = makeRenderImageSkeleton()
        let instance = makeRenderImageInstance(skeleton: skeleton)
        let renderer = RenderImage()
        let plain = makeRenderImageTestImage(
            width: 90,
            height: 70,
            color: CGColor(red: 1, green: 1, blue: 1, alpha: 1)
        )

        let result = renderer.render(
            instances: [instance],
            skeleton: skeleton,
            width: 90,
            height: 70,
            backgroundColor: CGColor(red: 1, green: 1, blue: 1, alpha: 1)
        )

        XCTAssertEqual(result.width, 90)
        XCTAssertEqual(result.height, 70)
        XCTAssertGreaterThan(renderImagePixelDiffCount(plain, result), 0)
    }

    func testImageBackgroundRenderKeepsBackgroundSize() {
        let skeleton = makeRenderImageSkeleton()
        let instance = makeRenderImageInstance(skeleton: skeleton)
        let background = makeRenderImageTestImage(
            width: 64,
            height: 48,
            color: CGColor(red: 0.25, green: 0.5, blue: 0.75, alpha: 1)
        )

        let result = RenderImage().render(
            instances: [instance],
            skeleton: skeleton,
            background: .image(background)
        )

        XCTAssertEqual(result.width, background.width)
        XCTAssertEqual(result.height, background.height)
    }

    func testWritePNGAndJPEGRoundTrip() throws {
        let skeleton = makeRenderImageSkeleton()
        let instance = makeRenderImageInstance(skeleton: skeleton)
        let image = RenderImage().render(
            instances: [instance],
            skeleton: skeleton,
            width: 80,
            height: 60,
            backgroundColor: CGColor(red: 1, green: 1, blue: 1, alpha: 1)
        )
        let renderer = RenderImage()
        let directory = FileManager.default.temporaryDirectory
        let pngURL = directory.appendingPathComponent("sleap_render_image_tests_round_trip.png")
        let jpegURL = directory.appendingPathComponent("sleap_render_image_tests_round_trip.jpg")
        try? FileManager.default.removeItem(at: pngURL)
        try? FileManager.default.removeItem(at: jpegURL)
        defer {
            try? FileManager.default.removeItem(at: pngURL)
            try? FileManager.default.removeItem(at: jpegURL)
        }

        try renderer.write(image, to: pngURL, format: .png)
        try renderer.write(image, to: jpegURL, format: .jpeg(quality: 0.8))

        let png = try XCTUnwrap(makeImageSourceImage(at: pngURL))
        let jpeg = try XCTUnwrap(makeImageSourceImage(at: jpegURL))
        XCTAssertEqual(png.width, image.width)
        XCTAssertEqual(png.height, image.height)
        XCTAssertEqual(jpeg.width, image.width)
        XCTAssertEqual(jpeg.height, image.height)
    }
}

private func makeRenderImageSkeleton() -> Skeleton {
    let nodes = [
        Node(name: "head"),
        Node(name: "thorax"),
        Node(name: "abdomen"),
    ]
    let edges = [
        Edge(source: nodes[0], destination: nodes[1]),
        Edge(source: nodes[1], destination: nodes[2]),
    ]
    return Skeleton(name: "render_image_test", nodes: nodes, edges: edges)
}

private func makeRenderImageInstance(skeleton: Skeleton) -> Instance {
    let points = [
        Point(x: 20, y: 20, visible: true),
        Point(x: 40, y: 35, visible: true),
        Point(x: 60, y: 50, visible: true),
    ]
    return Instance(skeleton: skeleton, points: PointsArray(points: points))
}

private func makeRenderImageTestImage(width: Int, height: Int, color: CGColor) -> CGImage {
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
    context.setFillColor(color)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    return context.makeImage()!
}

private func makeImageSourceImage(at url: URL) -> CGImage? {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
        return nil
    }
    return CGImageSourceCreateImageAtIndex(source, 0, nil)
}

private func renderImagePixelDiffCount(_ lhs: CGImage, _ rhs: CGImage) -> Int {
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
