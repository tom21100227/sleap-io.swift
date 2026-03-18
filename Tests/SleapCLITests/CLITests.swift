import XCTest

final class CLITests: XCTestCase {

    // MARK: - Helpers

    /// Path to the built sleap-io binary.
    private func binaryPath() throws -> String {
        // When running via `swift test`, the build products are in .build/debug/
        var dir = URL(fileURLWithPath: #file)
        while dir.path != "/" {
            dir = dir.deletingLastPathComponent()
            if FileManager.default.fileExists(atPath: dir.appendingPathComponent("Package.swift").path) {
                let binary = dir.appendingPathComponent(".build/debug/sleap-io").path
                if FileManager.default.fileExists(atPath: binary) {
                    return binary
                }
                break
            }
        }
        throw XCTSkip("sleap-io binary not found — run `swift build` first")
    }

    private func fixturePath(_ relativePath: String) -> String {
        var dir = URL(fileURLWithPath: #file)
        while dir.path != "/" {
            dir = dir.deletingLastPathComponent()
            if FileManager.default.fileExists(atPath: dir.appendingPathComponent("Package.swift").path) {
                return dir.appendingPathComponent("Tests/Fixtures/phase4").appendingPathComponent(relativePath).path
            }
        }
        fatalError("Could not find package root")
    }

    /// Run the CLI binary with arguments and return (stdout, stderr, exitCode).
    @discardableResult
    private func runCLI(_ args: [String]) throws -> (stdout: String, stderr: String, exitCode: Int32) {
        let binary = try binaryPath()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = args

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()
        process.waitUntilExit()

        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()

        return (
            stdout: String(data: stdoutData, encoding: .utf8) ?? "",
            stderr: String(data: stderrData, encoding: .utf8) ?? "",
            exitCode: process.terminationStatus
        )
    }

    private func makeTempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sleap_cli_test_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: - C01: info command

    func testC01_infoHumanReadable() throws {
        let fixture = fixturePath("cli_smoke/cli_test.h5")
        let result = try runCLI(["info", fixture])
        XCTAssertEqual(result.exitCode, 0, "info should exit 0. stderr: \(result.stderr)")
        let out = result.stdout.lowercased()
        // Human-readable output should contain summary counts
        XCTAssertTrue(out.contains("frame"), "Output should mention frames")
        XCTAssertTrue(out.contains("video"), "Output should mention videos")
        XCTAssertTrue(out.contains("skeleton"), "Output should mention skeletons")
        XCTAssertTrue(out.contains("track"), "Output should mention tracks")
    }

    func testC01_infoJSON() throws {
        let fixture = fixturePath("cli_smoke/cli_test.h5")
        let result = try runCLI(["info", fixture, "--json"])
        XCTAssertEqual(result.exitCode, 0, "info --json should exit 0. stderr: \(result.stderr)")
        // Output should be valid JSON
        let data = result.stdout.data(using: .utf8)!
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertNotNil(json, "Output should be a JSON object")
        XCTAssertNotNil(json?["frames"], "JSON should contain 'frames' key")
        XCTAssertNotNil(json?["videos"], "JSON should contain 'videos' key")
        XCTAssertNotNil(json?["skeletons"], "JSON should contain 'skeletons' key")
        XCTAssertNotNil(json?["tracks"], "JSON should contain 'tracks' key")
    }

    // MARK: - C02: show command

    func testC02_showDefault() throws {
        let fixture = fixturePath("cli_smoke/cli_test.h5")
        let result = try runCLI(["show", fixture])
        XCTAssertEqual(result.exitCode, 0, "show should exit 0. stderr: \(result.stderr)")
        XCTAssertFalse(result.stdout.isEmpty, "show should produce output")
    }

    func testC02_showFrame() throws {
        let fixture = fixturePath("cli_smoke/cli_test.h5")
        let result = try runCLI(["show", fixture, "--frame", "0"])
        XCTAssertEqual(result.exitCode, 0, "show --frame 0 should exit 0. stderr: \(result.stderr)")
        XCTAssertFalse(result.stdout.isEmpty, "show --frame should produce output")
    }

    func testC02_showLimit() throws {
        let fixture = fixturePath("cli_smoke/cli_test.h5")
        let result = try runCLI(["show", fixture, "--limit", "1"])
        XCTAssertEqual(result.exitCode, 0, "show --limit 1 should exit 0. stderr: \(result.stderr)")
        XCTAssertFalse(result.stdout.isEmpty, "show --limit should produce output")
    }

    func testC02_showJSON() throws {
        let fixture = fixturePath("cli_smoke/cli_test.h5")
        let result = try runCLI(["show", fixture, "--json"])
        XCTAssertEqual(result.exitCode, 0, "show --json should exit 0. stderr: \(result.stderr)")
        // Output should be valid JSON
        let data = result.stdout.data(using: .utf8)!
        XCTAssertNoThrow(try JSONSerialization.jsonObject(with: data), "show --json should output valid JSON")
    }

    // MARK: - C03: convert command

    func testC03_convertSuccess() throws {
        let fixture = fixturePath("cli_smoke/cli_test.h5")
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let outputPath = tempDir.appendingPathComponent("output.csv").path
        let result = try runCLI(["convert", fixture, outputPath])
        XCTAssertEqual(result.exitCode, 0, "convert should exit 0. stderr: \(result.stderr)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: outputPath), "Output file should exist")
    }

    func testC03_convertNoOverwrite() throws {
        let fixture = fixturePath("cli_smoke/cli_test.h5")
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let outputPath = tempDir.appendingPathComponent("output.csv").path
        // Create existing file
        FileManager.default.createFile(atPath: outputPath, contents: Data("existing".utf8))

        let result = try runCLI(["convert", fixture, outputPath])
        XCTAssertNotEqual(result.exitCode, 0, "convert without --force to existing file should fail")
    }

    func testC03_convertForce() throws {
        let fixture = fixturePath("cli_smoke/cli_test.h5")
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let outputPath = tempDir.appendingPathComponent("output.csv").path
        // Create existing file
        FileManager.default.createFile(atPath: outputPath, contents: Data("existing".utf8))

        let result = try runCLI(["convert", fixture, outputPath, "--force"])
        XCTAssertEqual(result.exitCode, 0, "convert with --force should exit 0. stderr: \(result.stderr)")
    }

    func testC03_convertAmbiguousH5() throws {
        let fixture = fixturePath("cli_smoke/cli_test.h5")
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let outputPath = tempDir.appendingPathComponent("output.h5").path
        let result = try runCLI(["convert", fixture, outputPath])
        XCTAssertNotEqual(result.exitCode, 0, "convert to .h5 without --output-format should fail (ambiguous)")
    }

    func testC03_convertExplicitFormat() throws {
        let fixture = fixturePath("cli_smoke/cli_test.h5")
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let outputPath = tempDir.appendingPathComponent("output.h5").path
        let result = try runCLI(["convert", fixture, outputPath, "--output-format", "analysis_h5"])
        XCTAssertEqual(result.exitCode, 0, "convert with --output-format should exit 0. stderr: \(result.stderr)")
    }

    // MARK: - C04: config options

    func testC04_jabsWithoutConfig() throws {
        let fixture = fixturePath("cli_smoke/cli_test.h5")
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let outputPath = tempDir.appendingPathComponent("output.jabs.h5").path
        let result = try runCLI(["convert", fixture, outputPath, "--output-format", "jabs"])
        // JABS export works without explicit node names — uses skeleton node names as default
        XCTAssertEqual(result.exitCode, 0, "JABS conversion should succeed using skeleton node names")
    }

    // MARK: - C05: exit codes

    func testC05_successExitZero() throws {
        let fixture = fixturePath("cli_smoke/cli_test.h5")
        let result = try runCLI(["info", fixture])
        XCTAssertEqual(result.exitCode, 0, "Successful info should exit 0")
    }

    func testC05_argErrorExitTwo() throws {
        // No arguments at all should produce a usage error
        let result = try runCLI([])
        XCTAssertNotEqual(result.exitCode, 0, "No arguments should produce nonzero exit")
    }

    func testC05_runtimeErrorExitOne() throws {
        let result = try runCLI(["info", "/nonexistent/file.slp"])
        XCTAssertEqual(result.exitCode, 1, "Nonexistent file should exit 1")
    }
}
