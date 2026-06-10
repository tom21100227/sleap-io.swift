import XCTest
@testable import SleapIO

/// E4.5 (partial): Identifiable conformance + stable ids for SwiftUI ForEach.
final class IdentifiableConformanceTests: XCTestCase {

    func testIdsAreStableAndDistinct() {
        let skel = Skeleton(name: "s", nodes: [Node(name: "a")])
        let i1 = Instance(skeleton: skel)
        let i2 = Instance(skeleton: skel)
        XCTAssertEqual(i1.id, i1.id, "id stable across reads")
        XCTAssertNotEqual(i1.id, i2.id, "distinct objects have distinct ids")
    }

    func testIdentifiableTypesUsableInIdKeyedCollection() {
        let v = Video(filename: "v.mp4")
        let t = Track(name: "t")
        let f = LabeledFrame(video: v, frameIndex: 0)
        let labels = Labels()
        // Exercise that .id exists on each conforming type.
        _ = [v.id]
        _ = [t.id]
        _ = [f.id]
        _ = [labels.id]
        _ = [Node(name: "n").id]
        _ = [Skeleton(name: "s").id]
        XCTAssertTrue(true)
    }

    func testPredictedInstanceInheritsIdentifiable() {
        let skel = Skeleton(name: "s", nodes: [Node(name: "a")])
        let pred = PredictedInstance(skeleton: skel, points: PredictedPointsArray(count: 1), score: 1)
        XCTAssertEqual(pred.id, pred.id)
    }
}
