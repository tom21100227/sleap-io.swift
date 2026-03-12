import XCTest
@testable import SleapIO
@testable import SleapHDF5

/// E01-E04: Error handling tests.
final class ErrorHandlingTests: XCTestCase {

    // MARK: - E01: Corrupt data handling

    func testE01_corruptFileThrowsError() async {
        // Create a temp file with garbage data pretending to be an .slp
        let tempDir = FileManager.default.temporaryDirectory
        let corruptURL = tempDir.appendingPathComponent("corrupt_\(UUID().uuidString).slp")

        let garbage = Data([0xDE, 0xAD, 0xBE, 0xEF, 0x00, 0x01, 0x02, 0x03])
        try? garbage.write(to: corruptURL)
        defer { try? FileManager.default.removeItem(at: corruptURL) }

        do {
            let _ = try await Labels.load(from: corruptURL)
            XCTFail("Loading a corrupt file should throw")
        } catch let error as SleapIOError {
            switch error {
            case .corruptData, .hdf5Error:
                break  // Expected
            default:
                XCTFail("Expected corruptData or hdf5Error, got: \(error)")
            }
        } catch is HDF5Error {
            // HDF5Error is also acceptable — the file is not valid HDF5
        } catch {
            // Any error is acceptable — the key invariant is that it doesn't crash
        }
    }

    func testE01_truncatedFileThrows() async {
        let tempDir = FileManager.default.temporaryDirectory
        let truncatedURL = tempDir.appendingPathComponent("truncated_\(UUID().uuidString).slp")

        // Write just the HDF5 magic bytes but truncate the rest
        let hdf5Magic = Data([0x89, 0x48, 0x44, 0x46, 0x0D, 0x0A, 0x1A, 0x0A])
        try? hdf5Magic.write(to: truncatedURL)
        defer { try? FileManager.default.removeItem(at: truncatedURL) }

        do {
            let _ = try await Labels.load(from: truncatedURL)
            XCTFail("Loading a truncated file should throw")
        } catch {
            // Any error is acceptable — the point is it doesn't crash
        }
    }

    // MARK: - E02: Unsupported format handling

    func testE02_unknownExtensionThrowsUnsupportedFormat() async {
        let tempDir = FileManager.default.temporaryDirectory
        let txtURL = tempDir.appendingPathComponent("labels_\(UUID().uuidString).txt")
        try? Data("{}".utf8).write(to: txtURL)
        defer { try? FileManager.default.removeItem(at: txtURL) }

        do {
            let _ = try await Labels.load(from: txtURL)
            XCTFail("Loading unsupported format should throw")
        } catch let error as SleapIOError {
            switch error {
            case .unsupportedFormat:
                break  // Expected
            default:
                XCTFail("Expected unsupportedFormat, got: \(error)")
            }
        } catch {
            XCTFail("Expected SleapIOError.unsupportedFormat, got: \(error)")
        }
    }

    func testE02_labelStudioLoadRequiresExplicitMapping() async {
        let tempDir = FileManager.default.temporaryDirectory
        let jsonURL = tempDir.appendingPathComponent("labels_\(UUID().uuidString).json")
        let taskJSON = """
        [
          {
            "id": 1,
            "data": { "image": "img.png" },
            "annotations": []
          }
        ]
        """
        try? Data(taskJSON.utf8).write(to: jsonURL)
        defer { try? FileManager.default.removeItem(at: jsonURL) }

        do {
            let _ = try await Labels.load(from: jsonURL)
            XCTFail("Loading Label Studio without a mapping should throw")
        } catch let error as SleapIOError {
            switch error {
            case .unsupportedFormat(let message):
                XCTAssertTrue(
                    message.contains("Label Studio"),
                    "Expected a Label Studio guidance message, got: \(message)")
            default:
                XCTFail("Expected unsupportedFormat, got: \(error)")
            }
        } catch {
            XCTFail("Expected SleapIOError.unsupportedFormat, got: \(error)")
        }
    }

    // MARK: - E03: Missing file handling

    func testE03_missingFileThrowsFileNotFound() async {
        let missingURL = URL(fileURLWithPath: "/tmp/definitely_does_not_exist_\(UUID().uuidString).slp")

        do {
            let _ = try await Labels.load(from: missingURL)
            XCTFail("Loading a missing file should throw")
        } catch let error as SleapIOError {
            switch error {
            case .fileNotFound:
                break  // Expected
            default:
                XCTFail("Expected fileNotFound, got: \(error)")
            }
        } catch {
            XCTFail("Expected SleapIOError.fileNotFound, got: \(error)")
        }
    }

    func testE03_missingDirectoryThrowsFileNotFound() async {
        let missingURL = URL(fileURLWithPath: "/nonexistent_dir_\(UUID().uuidString)/file.slp")

        do {
            let _ = try await Labels.load(from: missingURL)
            XCTFail("Loading from a nonexistent directory should throw")
        } catch let error as SleapIOError {
            switch error {
            case .fileNotFound:
                break  // Expected
            default:
                XCTFail("Expected fileNotFound, got: \(error)")
            }
        } catch {
            XCTFail("Expected SleapIOError.fileNotFound, got: \(error)")
        }
    }

    // MARK: - E04: Too-new format handling

    func testE04_formatVersionTooNewErrorType() {
        // Verify the error type can carry version information
        let error = SleapIOError.formatVersionTooNew(99.0)
        switch error {
        case .formatVersionTooNew(let version):
            XCTAssertEqual(version, 99.0)
        default:
            XCTFail("Expected formatVersionTooNew")
        }
    }

    func testE04_formatVersionTooNewFromFile() async throws {
        // Create a valid HDF5 file with format_id > max supported
        let tempDir = FileManager.default.temporaryDirectory
        let path = tempDir.appendingPathComponent("future_\(UUID().uuidString).slp").path
        defer { try? FileManager.default.removeItem(atPath: path) }

        // Create a minimal HDF5 file with a too-new format_id
        let file = try HDF5File.create(path: path)
        let group = try file.createGroup(name: "metadata")
        try group.writeFloatAttribute(name: "format_id", value: 99.0)
        try group.writeStringAttribute(name: "json", value: "{}")
        // File closes on deinit

        do {
            let url = URL(fileURLWithPath: path)
            let _ = try await Labels.load(from: url)
            XCTFail("Loading a too-new format should throw")
        } catch let error as SleapIOError {
            switch error {
            case .formatVersionTooNew(let version):
                XCTAssertEqual(version, 99.0)
            default:
                XCTFail("Expected formatVersionTooNew, got: \(error)")
            }
        }
    }

    // MARK: - Error enum completeness

    func testAllSleapIOErrorCases() {
        // Verify all error cases exist and can carry associated values
        let errors: [SleapIOError] = [
            .fileNotFound("path"),
            .unsupportedFormat("xyz"),
            .corruptData("bad data"),
            .hdf5Error("HDF5 failed"),
            .videoError("video error"),
            .invalidSkeleton("bad skeleton"),
            .formatVersionTooNew(2.0),
            .mutationWhileLazy("cannot mutate"),
        ]
        XCTAssertEqual(errors.count, 8)
    }
}
