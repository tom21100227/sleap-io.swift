import XCTest
import simd
@testable import SleapIO

/// E1.6: Labels annotation query families (getRois/getMasks/getBboxes/getCentroids/getLabelImages).
final class LabelsAnnotationQueriesTests: XCTestCase {

    // MARK: - Fixtures

    private func makeROI(_ name: String) -> ROI {
        ROI(
            annotationType: .boundingBox,
            name: name,
            points: [SIMD2<Float>(0, 0), SIMD2<Float>(10, 10)]
        )
    }

    private func makeMask(_ name: String) -> SegmentationMask {
        SegmentationMask(rleCounts: [2, 2], height: 2, width: 2, name: name)
    }

    // MARK: - getRois

    func testGetRoisReturnsLabelsRois() {
        let labels = Labels()
        let r0 = makeROI("roi0")
        let r1 = makeROI("roi1")
        labels.rois = [r0, r1]

        let result = labels.getRois()
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result, labels.rois)
        XCTAssertEqual(result.map { $0.name }, ["roi0", "roi1"])
    }

    func testGetRoisEmptyWhenNoneSet() {
        let labels = Labels()
        XCTAssertTrue(labels.getRois().isEmpty)
    }

    // MARK: - getMasks

    func testGetMasksReturnsLabelsMasks() {
        let labels = Labels()
        let m0 = makeMask("mask0")
        let m1 = makeMask("mask1")
        labels.masks = [m0, m1]

        let result = labels.getMasks()
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result, labels.masks)
        XCTAssertEqual(result.map { $0.name }, ["mask0", "mask1"])
    }

    func testGetMasksEmptyWhenNoneSet() {
        let labels = Labels()
        XCTAssertTrue(labels.getMasks().isEmpty)
    }

    // MARK: - Not-yet-modeled families (E7 placeholders)

    func testGetBboxesReturnsEmpty() {
        let labels = Labels()
        XCTAssertTrue(labels.getBboxes().isEmpty)

        // Still empty even when rois/masks are populated.
        labels.rois = [makeROI("roi0")]
        labels.masks = [makeMask("mask0")]
        XCTAssertTrue(labels.getBboxes().isEmpty)
    }

    func testGetCentroidsReturnsEmpty() {
        let labels = Labels()
        XCTAssertTrue(labels.getCentroids().isEmpty)

        labels.rois = [makeROI("roi0")]
        labels.masks = [makeMask("mask0")]
        XCTAssertTrue(labels.getCentroids().isEmpty)
    }

    func testGetLabelImagesReturnsEmpty() {
        let labels = Labels()
        XCTAssertTrue(labels.getLabelImages().isEmpty)

        labels.rois = [makeROI("roi0")]
        labels.masks = [makeMask("mask0")]
        XCTAssertTrue(labels.getLabelImages().isEmpty)
    }

    // MARK: - Empty Labels behavior across all families

    func testAllQueriesOnEmptyLabels() {
        let labels = Labels()
        XCTAssertTrue(labels.getRois().isEmpty)
        XCTAssertTrue(labels.getMasks().isEmpty)
        XCTAssertTrue(labels.getBboxes().isEmpty)
        XCTAssertTrue(labels.getCentroids().isEmpty)
        XCTAssertTrue(labels.getLabelImages().isEmpty)
    }

    // MARK: - Return-type sanity for placeholders

    func testPlaceholderReturnTypes() {
        let labels = Labels()
        let bboxes: [[Float]] = labels.getBboxes()
        let centroids: [[Float]] = labels.getCentroids()
        let labelImages: [Int] = labels.getLabelImages()
        XCTAssertEqual(bboxes.count, 0)
        XCTAssertEqual(centroids.count, 0)
        XCTAssertEqual(labelImages.count, 0)
    }
}
