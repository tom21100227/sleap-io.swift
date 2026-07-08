import CoreGraphics
import XCTest
@testable import SleapIO
@testable import SleapRendering

final class ColorSchemeTests: XCTestCase {
    func testTrackColorStableAcrossInstancesSharingTrack() {
        let skeleton = makeColorSchemeSkeleton(nodeCount: 2)
        let track = Track(name: "animal_1")
        let tracks = [track]
        let instanceA = makeColorSchemeInstance(skeleton: skeleton, track: track)
        let instanceB = makeColorSchemeInstance(skeleton: skeleton, track: track)
        let scheme = ColorScheme(paletteName: "standard", colorBy: .track)

        let colorA = scheme.color(for: instanceA, instanceIndex: 0, tracks: tracks)
        let colorB = scheme.color(for: instanceB, instanceIndex: 4, tracks: tracks)

        XCTAssertTrue(colorsMatch(colorA, colorB))
    }

    func testTrackColorDiffersForDifferentTracks() {
        let skeleton = makeColorSchemeSkeleton(nodeCount: 2)
        let trackA = Track(name: "animal_1")
        let trackB = Track(name: "animal_2")
        let tracks = [trackA, trackB]
        let instanceA = makeColorSchemeInstance(skeleton: skeleton, track: trackA)
        let instanceB = makeColorSchemeInstance(skeleton: skeleton, track: trackB)
        let scheme = ColorScheme(paletteName: "standard", colorBy: .track)

        let colorA = scheme.color(for: instanceA, instanceIndex: 0, tracks: tracks)
        let colorB = scheme.color(for: instanceB, instanceIndex: 0, tracks: tracks)

        XCTAssertFalse(colorsMatch(colorA, colorB))
    }

    func testInstanceColorUsesInstanceIndex() {
        let scheme = ColorScheme(paletteName: "standard", colorBy: .instance)

        XCTAssertTrue(colorsMatch(
            scheme.color(forTrackIndex: 2, instanceIndex: 1, nodeIndex: 5),
            ColorPalette.color(at: 1, palette: "standard")
        ))
    }

    func testUnknownPaletteFallsBackToStandard() {
        let scheme = ColorScheme(paletteName: "missing", colorBy: .instance)

        XCTAssertTrue(colorsMatch(
            scheme.color(forTrackIndex: nil, instanceIndex: 0, nodeIndex: 0),
            ColorPalette.standard[0]
        ))
    }

    func testAutoUsesTrackWhenPresentAndInstanceWhenTrackIsNil() {
        let scheme = ColorScheme(paletteName: "standard", colorBy: .auto)

        XCTAssertTrue(colorsMatch(
            scheme.color(forTrackIndex: 2, instanceIndex: 0, nodeIndex: 0),
            ColorPalette.color(at: 2, palette: "standard")
        ))
        XCTAssertTrue(colorsMatch(
            scheme.color(forTrackIndex: nil, instanceIndex: 3, nodeIndex: 0),
            ColorPalette.color(at: 3, palette: "standard")
        ))
    }
}

private func makeColorSchemeSkeleton(nodeCount: Int) -> Skeleton {
    let nodes = (0..<nodeCount).map { Node(name: "node_\($0)") }
    return Skeleton(name: "test", nodes: nodes, edges: [])
}

private func makeColorSchemeInstance(skeleton: Skeleton, track: Track?) -> Instance {
    let points = skeleton.nodes.enumerated().map { index, _ in
        let value = Float(index * 10 + 10)
        return Point(x: value, y: value, visible: true, complete: true)
    }
    return Instance(skeleton: skeleton, points: PointsArray(points: points), track: track)
}

private func colorsMatch(_ lhs: CGColor, _ rhs: CGColor, accuracy: CGFloat = 0.0001) -> Bool {
    guard let lhs = lhs.converted(to: CGColorSpaceCreateDeviceRGB(), intent: .defaultIntent, options: nil),
          let rhs = rhs.converted(to: CGColorSpaceCreateDeviceRGB(), intent: .defaultIntent, options: nil),
          let lhsComponents = lhs.components,
          let rhsComponents = rhs.components,
          lhsComponents.count == rhsComponents.count else {
        return false
    }

    return zip(lhsComponents, rhsComponents).allSatisfy { abs($0 - $1) <= accuracy }
}
