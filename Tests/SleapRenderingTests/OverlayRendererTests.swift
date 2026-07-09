import CoreGraphics
import simd
import XCTest
@testable import SleapIO
@testable import SleapRendering

final class OverlayRendererTests: XCTestCase {
    func testPolygonROIToggleGatesRendering() {
        let image = makeOverlayTestImage()
        let roi = ROI(
            annotationType: .polygon,
            name: "polygon",
            points: [
                SIMD2<Float>(20, 20),
                SIMD2<Float>(80, 20),
                SIMD2<Float>(60, 80),
            ]
        )

        let enabled = OverlayRenderer(options: RenderOptions(showROIs: true))
            .render(onto: image, rois: [roi])
        let disabled = OverlayRenderer(options: RenderOptions(showROIs: false))
            .render(onto: image, rois: [roi])

        XCTAssertGreaterThan(overlayPixelDiffCount(image, enabled), 0)
        XCTAssertEqual(overlayPixelDiffCount(image, disabled), 0)
    }

    func testOtherROITypesRenderWithoutCrashing() {
        let image = makeOverlayTestImage()
        let renderer = OverlayRenderer(options: RenderOptions(showROIs: true))
        let rois = [
            ROI(
                annotationType: .boundingBox,
                name: "box",
                points: [SIMD2<Float>(10, 10), SIMD2<Float>(70, 50)]
            ),
            ROI(
                annotationType: .ellipse,
                name: "ellipse",
                points: [SIMD2<Float>(60, 60), SIMD2<Float>(85, 75)]
            ),
            ROI(
                annotationType: .point,
                name: "point",
                points: [SIMD2<Float>(90, 90)]
            ),
        ]

        let result = renderer.render(onto: image, rois: rois)

        XCTAssertGreaterThan(overlayPixelDiffCount(image, result), 0)
    }

    func testSegmentationMaskToggleGatesRendering() {
        let image = makeOverlayTestImage()
        var denseMask = Array(repeating: Array(repeating: false, count: 120), count: 120)
        for row in 30..<50 {
            for col in 40..<70 {
                denseMask[row][col] = true
            }
        }
        let mask = SegmentationMask.encode(mask: denseMask, name: "mask")

        let enabled = OverlayRenderer(options: RenderOptions(showMasks: true))
            .render(onto: image, masks: [mask])
        let disabled = OverlayRenderer(options: RenderOptions(showMasks: false))
            .render(onto: image, masks: [mask])

        XCTAssertGreaterThan(overlayPixelDiffCount(image, enabled), 0)
        XCTAssertEqual(overlayPixelDiffCount(image, disabled), 0)
    }

    func testBoundingBoxesAndCentroidsRender() {
        let image = makeOverlayTestImage()
        let boundingBoxResult = OverlayRenderer(options: RenderOptions(showBoundingBoxes: true))
            .render(onto: image, boundingBoxes: [CGRect(x: 20, y: 30, width: 50, height: 40)])
        let centroidResult = OverlayRenderer(options: RenderOptions(showCentroids: true))
            .render(onto: image, centroids: [CGPoint(x: 80, y: 70)])

        XCTAssertGreaterThan(overlayPixelDiffCount(image, boundingBoxResult), 0)
        XCTAssertGreaterThan(overlayPixelDiffCount(image, centroidResult), 0)
    }

    func testScaledContextTransformDraws() {
        let image = makeOverlayTestImage()
        guard let context = makeOverlayFlippedContext(width: image.width, height: image.height) else {
            XCTFail("Expected CGContext")
            return
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))

        let roi = ROI(
            annotationType: .polygon,
            name: "scaled",
            points: [
                SIMD2<Float>(20, 20),
                SIMD2<Float>(100, 20),
                SIMD2<Float>(100, 100),
            ]
        )
        OverlayRenderer(options: RenderOptions(showROIs: true)).render(
            rois: [roi],
            in: context,
            transform: CGAffineTransform(scaleX: 0.5, y: 0.5)
        )

        guard let result = context.makeImage() else {
            XCTFail("Expected rendered image")
            return
        }
        XCTAssertGreaterThan(overlayPixelDiffCount(image, result), 0)
    }
}

private func makeOverlayTestImage(width: Int = 120, height: Int = 120) -> CGImage {
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

private func makeOverlayFlippedContext(width: Int, height: Int) -> CGContext? {
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    guard let context = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: width * 4,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }
    context.translateBy(x: 0, y: CGFloat(height))
    context.scaleBy(x: 1, y: -1)
    return context
}

private func overlayPixelDiffCount(_ lhs: CGImage, _ rhs: CGImage) -> Int {
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
