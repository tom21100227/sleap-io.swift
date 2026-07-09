# sleap-io.swift vs Python sleap_io — Load/Save Benchmark

Median wall-clock over 7–9 in-process iterations (after one warm-up), macOS arm64.

- **Swift**: `sleap-io bench` (release build), `Labels.loadEager` / `Labels.load` / `Labels.save`, `openVideos:false`.
- **Python**: `sleap_io 0.5.5` (CPython 3.12), `sleap_io.load_file` / `save_file` in a timed loop.
- **Eager load** is the fair like-for-like comparison (both materialize all frames). **Lazy load** is what the GUI actually does when opening a file (metadata + on-demand frames).

## Load (eager) — fair comparison

| Fixture | Size | Frames | Python | Swift (eager) | Speedup |
|---|--:|--:|--:|--:|--:|
| `centered_pair_predictions.slp` | 1572 KB | 1100 | 36.13 ms | 4.82 ms | **7.5×** |
| `centered_pair_small.predictions.slp` | 13 KB | 10 | 2.01 ms | 0.45 ms | **4.5×** |
| `clip.2node.slp` | 344 KB | 1500 | 31.09 ms | 1.93 ms | **16.1×** |
| `minimal_instance.pkg.slp` | 42 KB | 1 | 2.23 ms | 0.57 ms | **3.9×** |
| `minimal_instance.slp` | 16 KB | 1 | 1.77 ms | 0.45 ms | **3.9×** |
| `small_robot_minimal.slp` | 16 KB | 2 | 1.72 ms | 0.41 ms | **4.2×** |
| `test_grid_labels.legacy.slp` | 16 KB | 1 | 1.69 ms | 0.45 ms | **3.8×** |
| `test_grid_labels.midpoint.slp` | 16 KB | 1 | 1.72 ms | 0.43 ms | **4.0×** |

## Save

| Fixture | Size | Frames | Python | Swift | Speedup |
|---|--:|--:|--:|--:|--:|
| `centered_pair_predictions.slp` | 1572 KB | 1100 | 86.36 ms | 4.40 ms | **19.6×** |
| `centered_pair_small.predictions.slp` | 13 KB | 10 | 1.99 ms | 0.45 ms | **4.4×** |
| `clip.2node.slp` | 344 KB | 1500 | 12.15 ms | 1.46 ms | **8.3×** |
| `minimal_instance.pkg.slp` | 42 KB | 1 | 1.72 ms | 0.44 ms | **3.9×** |
| `minimal_instance.slp` | 16 KB | 1 | 1.64 ms | 0.47 ms | **3.5×** |
| `small_robot_minimal.slp` | 16 KB | 2 | 1.64 ms | 0.37 ms | **4.4×** |
| `test_grid_labels.legacy.slp` | 16 KB | 1 | 1.69 ms | 0.48 ms | **3.5×** |
| `test_grid_labels.midpoint.slp` | 16 KB | 1 | 1.64 ms | 0.46 ms | **3.6×** |

## GUI open latency (Swift lazy load)

What a user experiences when opening a file in the app — Swift defers per-frame decode:

| Fixture | Frames | Swift lazy load |
|---|--:|--:|
| `centered_pair_predictions.slp` | 1100 | 3.72 ms |
| `centered_pair_small.predictions.slp` | 10 | 0.48 ms |
| `clip.2node.slp` | 1500 | 1.06 ms |
| `minimal_instance.pkg.slp` | 1 | 0.59 ms |
| `minimal_instance.slp` | 1 | 0.41 ms |
| `small_robot_minimal.slp` | 2 | 0.45 ms |
| `test_grid_labels.legacy.slp` | 1 | 0.46 ms |
| `test_grid_labels.midpoint.slp` | 1 | 0.42 ms |

## Summary

- **Eager load**: Swift is **3.8×–16.1×** faster (median **4.1×**).
- **Save**: Swift is **3.5×–19.6×** faster (median **4.2×**).
- The gap widens on large multi-frame files: on `centered_pair_predictions` (1100 frames, 1.5 MB) Swift loads eagerly in 4.82 ms vs Python's 36.13 ms, and saves in 4.4 ms vs 86.36 ms.

### Method notes / caveats
- Times exclude process/interpreter startup (in-process loops); Python numbers exclude `import sleap_io`.
- `openVideos:false` on both sides — this measures SLP/HDF5 label parsing, not video decoding.
- Same 8 fixtures, copied from Python SLEAP (`~/work/sleap`) and sleap-nn (`~/work/sleap-nn`) test assets; skeletons verified byte-identical to Python parsing (see CrossPlatformTests/SkeletonParsingTests).
- Small-file times (~0.4 ms Swift) approach measurement noise; the large-file rows are the meaningful signal.
- Swift built `-c release`; a Debug build (what Xcode runs by default) is slower.
