import Foundation

/// Reports cooperative operation progress as a monotonic fraction in `0...1`.
///
/// Long-running operations report `1.0` when complete. Cancellation is
/// cooperative via Swift task cancellation and throws `CancellationError`.
public typealias ProgressReporter = @Sendable (Double) -> Void
