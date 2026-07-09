import CoreGraphics
import SleapIO

/// Strategy for choosing pose rendering colors.
public enum ColorBy: String, Sendable, CaseIterable {
    case track
    case instance
    case node
    case auto
}

/// Color palette and indexing strategy for pose rendering.
public struct ColorScheme: Sendable {
    public var paletteName: String
    public var colorBy: ColorBy

    public init(paletteName: String = "standard", colorBy: ColorBy = .auto) {
        self.paletteName = paletteName
        self.colorBy = colorBy
    }

    public func color(forTrackIndex trackIndex: Int?, instanceIndex: Int, nodeIndex: Int) -> CGColor {
        let colorIndex: Int
        switch colorBy {
        case .track:
            colorIndex = trackIndex ?? instanceIndex
        case .instance:
            colorIndex = instanceIndex
        case .node:
            colorIndex = nodeIndex
        case .auto:
            colorIndex = trackIndex ?? instanceIndex
        }
        return ColorPalette.color(at: colorIndex, palette: paletteName)
    }

    public func color(
        for instance: Instance,
        instanceIndex: Int,
        tracks: [Track],
        nodeIndex: Int = 0
    ) -> CGColor {
        let trackIndex = instance.track.flatMap { track in
            tracks.firstIndex { $0 === track }
        }
        return color(forTrackIndex: trackIndex, instanceIndex: instanceIndex, nodeIndex: nodeIndex)
    }
}
