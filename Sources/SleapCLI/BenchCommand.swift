import ArgumentParser
import Foundation
import SleapIO
import SleapHDF5

/// Benchmark in-process `.slp` load (and optionally save) time over N iterations.
///
/// Loads labels only (`openVideos: false`) so the measurement reflects SLP/HDF5
/// parsing, comparable to a Python `sleap_io.load_file` load loop.
struct BenchCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "bench",
        abstract: "Benchmark load/save of a .slp file (in-process, N iterations)"
    )

    @Argument(help: "Path to a .slp file")
    var path: String

    @Option(name: .shortAndLong, help: "Number of timed iterations")
    var iterations: Int = 7

    @Flag(name: .shortAndLong, help: "Also benchmark save")
    var save: Bool = false

    @Flag(help: "Emit a single JSON line instead of human-readable text")
    var json: Bool = false

    mutating func run() async throws {
        let url = URL(fileURLWithPath: path)

        func median(_ xs: [Double]) -> Double {
            let s = xs.sorted(); let n = s.count
            guard n > 0 else { return 0 }
            return n % 2 == 1 ? s[n / 2] : (s[n / 2 - 1] + s[n / 2]) / 2
        }
        func ms(since t: DispatchTime) -> Double {
            Double(DispatchTime.now().uptimeNanoseconds - t.uptimeNanoseconds) / 1_000_000
        }

        // One warm-up load (page cache / lazy inits) that is not timed.
        _ = try await Labels.load(from: url, openVideos: false)

        // Lazy load: what the GUI does when opening a file (metadata + lazy frames).
        var loadMs: [Double] = []
        for _ in 0..<iterations {
            let t = DispatchTime.now()
            _ = try await Labels.load(from: url, openVideos: false)
            loadMs.append(ms(since: t))
        }

        // Eager load: materialize every frame into memory — the fair comparison
        // against Python `sleap_io.load_file`, which is eager.
        var eagerMs: [Double] = []
        for _ in 0..<iterations {
            let t = DispatchTime.now()
            _ = try await Labels.loadEager(from: url, openVideos: false)
            eagerMs.append(ms(since: t))
        }

        var saveMs: [Double]?
        if save {
            let labels = try await Labels.load(from: url, openVideos: false)
            var s: [Double] = []
            for _ in 0..<iterations {
                let dst = FileManager.default.temporaryDirectory
                    .appendingPathComponent("bench-\(UUID().uuidString).slp")
                let t = DispatchTime.now()
                try await labels.save(to: dst)
                s.append(ms(since: t))
                try? FileManager.default.removeItem(at: dst)
            }
            saveMs = s
        }

        let sizeBytes = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? 0
        let sizeKB = (Double(sizeBytes ?? 0) / 1024 * 10).rounded() / 10
        func r2(_ x: Double) -> Double { (x * 100).rounded() / 100 }

        if json {
            var obj: [String: Any] = [
                "file": url.lastPathComponent,
                "size_kb": sizeKB,
                "iterations": iterations,
                "load_lazy_ms_median": r2(median(loadMs)),
                "load_eager_ms_median": r2(median(eagerMs)),
                "load_eager_ms_min": r2(eagerMs.min() ?? 0),
            ]
            if let saveMs { obj["save_ms_median"] = r2(median(saveMs)) }
            let data = try JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])
            print(String(data: data, encoding: .utf8)!)
        } else {
            var line = String(format: "%@  %.1fKB  load median %.2fms (min %.2f)",
                              url.lastPathComponent, sizeKB, median(loadMs), loadMs.min() ?? 0)
            if let saveMs { line += String(format: "  save median %.2fms", median(saveMs)) }
            print(line)
        }
    }
}
