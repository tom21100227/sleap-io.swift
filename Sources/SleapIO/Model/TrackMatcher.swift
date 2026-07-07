import Foundation

// MARK: - Track matching (M2)
//
// Mirrors `TrackMatchMethod` / `TrackMatcher` and `Track.matches` from
// `sleap_io/model/matching.py`. Determines how incoming tracks map onto
// existing tracks during a project merge.

/// Methods for matching ``Track`` objects.
///
/// Mirrors the upstream `TrackMatchMethod` enum.
public enum TrackMatchMethod: String, Sendable, CaseIterable {
    /// Match tracks by their ``Track/name``.
    case name
    /// Match tracks by object identity (the same ``Track`` instance).
    case identity
}

extension Track {
    /// Whether this track matches `other` under the given method.
    ///
    /// Mirrors `Track.matches`:
    /// - ``TrackMatchMethod/name``: equal ``name`` values.
    /// - ``TrackMatchMethod/identity``: the same object (`===`).
    ///
    /// - Parameters:
    ///   - other: The track to compare against.
    ///   - method: The matching method (defaults to ``TrackMatchMethod/name``).
    /// - Returns: `true` if the tracks match.
    public func matches(_ other: Track, method: TrackMatchMethod = .name) -> Bool {
        switch method {
        case .name:
            return name == other.name
        case .identity:
            return self === other
        }
    }
}

/// Configurable matcher for comparing and matching tracks.
///
/// Mirrors the upstream `TrackMatcher`. It is a thin wrapper that dispatches to
/// ``Track/matches(_:method:)`` using the configured ``method``.
public struct TrackMatcher: Sendable {
    /// The matching method to use. Defaults to ``TrackMatchMethod/name``.
    public var method: TrackMatchMethod

    /// Creates a track matcher.
    ///
    /// - Parameter method: The matching method (defaults to
    ///   ``TrackMatchMethod/name``).
    public init(method: TrackMatchMethod = .name) {
        self.method = method
    }

    /// Whether two tracks match according to ``method``.
    public func match(_ track1: Track, _ track2: Track) -> Bool {
        track1.matches(track2, method: method)
    }

    /// The first track in `candidates` that matches `track`, or `nil`.
    ///
    /// - Parameters:
    ///   - track: The track to look for.
    ///   - candidates: The candidate tracks to search, in order.
    /// - Returns: The first matching candidate, or `nil` if none match.
    public func firstMatch(for track: Track, in candidates: [Track]) -> Track? {
        candidates.first { match(track, $0) }
    }
}

extension TrackMatcher {
    /// Matcher that matches tracks by name. Mirrors `NAME_TRACK_MATCHER`.
    public static let nameMatcher = TrackMatcher(method: .name)

    /// Matcher that matches tracks by object identity.
    /// Mirrors `IDENTITY_TRACK_MATCHER`.
    public static let identityMatcher = TrackMatcher(method: .identity)
}
