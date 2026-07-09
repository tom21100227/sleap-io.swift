import Foundation

/// Concurrency and isolation contract for the sleap-io.swift model layer.
///
/// The model types (`Labels`, `LabeledFrame`, `Instance`, `Skeleton`, `Track`,
/// `Video`, …) are reference types marked `@unchecked Sendable`. That annotation is
/// an **escape hatch**, not a guarantee: the objects are *freely mutable* and are
/// **not internally synchronized**. Treat them like any other shared mutable state.
///
/// ## Rules
///
/// 1. **Confine a `Labels` graph to one isolation domain at a time.** A typical app
///    keeps the live graph on `@MainActor` (the document model). Do not mutate the
///    same object graph from two tasks concurrently.
///
/// 2. **To hand work to a background task, pass an independent snapshot.** Use
///    ``Labels/copy()`` to make a deep, identity-preserving clone, then send the
///    clone across the isolation boundary. The clone shares no mutable state with the
///    original, so the GUI can keep editing while a background exporter/trainer reads
///    the snapshot:
///    ```swift
///    let snapshot = labels.copy()            // on @MainActor
///    Task.detached {                          // background
///        let tensor = TensorCodec.toTensor(snapshot)
///        …
///    }
///    ```
///
/// 3. **File I/O is already serialized.** All HDF5 access goes through a single
///    `HDF5FileActor`, and `Labels.load`/`save` are `async`. You still must not
///    mutate a graph while it is being saved — snapshot first (rule 2) or gate edits.
///
/// 4. **Lazy stores mutate on read.** Materializing a lazy frame populates an
///    internal cache, so a "read" is not pure. Do not share a lazy `Labels` across
///    tasks; ``Labels/copy()`` materializes before cloning, yielding a safe snapshot.
public enum ConcurrencyContract {
    /// A human-readable summary of the safe-handoff pattern (rule 2).
    public static let safeHandoffSummary =
        "Snapshot with Labels.copy() before sending a graph to another isolation domain."
}
