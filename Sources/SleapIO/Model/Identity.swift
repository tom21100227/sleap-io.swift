import Foundation

/// Ground-truth animal identity, persistent across sessions and videos.
///
/// Unlike ``Track`` (an ephemeral temporal trajectory within a single video),
/// an `Identity` represents a known animal that can be recognized across videos,
/// sessions, and experiments.
///
/// In multi-view setups, multiple per-camera ``Track`` objects may map to a
/// single `Identity`. The mapping is stored on ``RecordingSession`` metadata.
///
/// Mirrors Python sleap-io's `sleap_io.model.identity.Identity`. It is persisted
/// to the `/identities_json` dataset of an SLP file (one JSON blob per identity).
///
/// - Note: Python models `Identity` with object-identity equality (`eq=False`).
///   Swift models it as a value type with structural (by-field) equality, matching
///   the convention used by the other annotation value types (``ROI``,
///   ``SegmentationMask``) and making round-trip assertions straightforward.
public struct Identity: Equatable, Codable, Sendable {

    /// Human-readable name for this identity (e.g. `"mouse_A"`).
    public var name: String

    /// Optional hex color string for visualization (e.g. `"#e6194b"`).
    public var color: String?

    /// Arbitrary metadata dictionary. Type-preserving via ``JSONValue``.
    public var metadata: [String: JSONValue]

    /// Create an identity.
    ///
    /// - Parameters:
    ///   - name: Human-readable name. Defaults to the empty string.
    ///   - color: Optional hex color string. Defaults to `nil`.
    ///   - metadata: Arbitrary metadata. Defaults to empty.
    public init(name: String = "", color: String? = nil, metadata: [String: JSONValue] = [:]) {
        self.name = name
        self.color = color
        self.metadata = metadata
    }
}
