import Foundation

/// Library version and capability introspection for sleap-io.swift.
///
/// Mirrors Python `sleap_io.__version__` and the supported-format surface so a GUI
/// can display compatibility info and stamp provenance on save.
public enum SleapIOInfo {

    /// The sleap-io.swift library version.
    public static let version = "0.3.0"

    /// The SLP format versions this build can read/write.
    ///
    /// - Note: Extending the upper bound is tracked by epic E7 (read SLP ≥ 1.6).
    public static let supportedSLPFormatVersions: ClosedRange<Double> = 1.0...1.5

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
        provenance[SleapIOInfo.provenanceVersionKey] = version
        return version
    }
}
