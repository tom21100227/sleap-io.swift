import Foundation

/// Controls how recoverable errors are handled during operations such as
/// loading, merging, or resolving missing resources.
///
/// - `strict`: throw on the first recoverable error.
/// - `warn`: collect the error and continue.
/// - `ignore`: silently drop the error and continue.
public enum ErrorMode: Sendable {
    case strict
    case warn
    case ignore
}

/// Recoverable errors that can be surfaced (and optionally collected) instead
/// of aborting an operation outright.
///
/// These are distinct from ``SleapIOError`` so that callers can opt into a
/// non-fatal, accumulating error-handling strategy via ``ErrorMode``.
public enum RecoverableSleapError: Error, Sendable, Equatable {
    /// A referenced video file could not be located.
    case missingVideo(filename: String)
    /// A skeleton's node names did not match what was expected.
    case skeletonMismatch(expected: [String], found: [String])
    /// A conflict was encountered while merging.
    case mergeConflict(description: String)
}

/// Accumulator for recoverable errors used in `warn` mode.
///
/// Pass each recoverable error through ``handle(_:mode:)`` along with the
/// active ``ErrorMode``. In `strict` mode the error is thrown immediately; in
/// `warn` mode it is appended to ``errors``; in `ignore` mode it is dropped.
public struct ErrorCollector {
    /// The recoverable errors accumulated while running in `warn` mode.
    public private(set) var errors: [RecoverableSleapError]

    /// Creates an empty collector.
    public init() {
        self.errors = []
    }

    /// Handles a recoverable error according to the supplied mode.
    ///
    /// - Parameters:
    ///   - error: The recoverable error to process.
    ///   - mode: The active error-handling mode.
    /// - Throws: `error` itself when `mode` is `.strict`.
    public mutating func handle(_ error: RecoverableSleapError, mode: ErrorMode) throws {
        switch mode {
        case .strict:
            throw error
        case .warn:
            errors.append(error)
        case .ignore:
            break
        }
    }
}
