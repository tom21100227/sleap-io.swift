import Foundation

/// Library version and capability introspection for sleap-io.swift.
///
/// Mirrors Python `sleap_io.__version__` and the supported-format surface so a GUI
/// can display compatibility info and stamp provenance on save.
public enum SleapIOInfo {

    /// The sleap-io.swift library version.
    public static let version = "0.3.0"

    /// SLP format versions this build reads AND writes at full fidelity.
    public static let supportedSLPFormatVersions: ClosedRange<Double> = 1.0...1.5

    /// SLP format versions this build can READ. 1.6...2.4 are best-effort: modeled
    /// data (frames/instances/points/videos/tracks/rois/masks) is read and
    /// not-yet-modeled datasets are skipped. Writes still target
    /// ``supportedSLPFormatVersions``. Kept in sync with the reader's cap.
    public static let readableSLPFormatVersions: ClosedRange<Double> = 1.0...2.4

    /// The provenance key under which the library stamps its version on save.
    public static let provenanceVersionKey = "sleap_io_swift_version"
}

extension Labels {

    /// Record the sleap-io.swift version in ``provenance`` (under
    /// ``SleapIOInfo/provenanceVersionKey``). Called automatically when saving an
    /// `.slp`, mirroring Python writing `provenance["sleap_io_version"]`.
    ///
    /// - Returns: The stamped version string.
    @discardableResult
    public func stampSleapIOVersion() -> String {
        let version = SleapIOInfo.version
        provenance[SleapIOInfo.provenanceVersionKey] = .string(version)
        return version
    }
}
