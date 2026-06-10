import XCTest
@testable import SleapIO

/// E4.3: ErrorMode + recoverable error taxonomy tests.
final class ErrorModeTests: XCTestCase {

    // MARK: - ErrorMode

    func testErrorModeHasThreeCases() {
        let modes: [ErrorMode] = [.strict, .warn, .ignore]
        XCTAssertEqual(modes.count, 3, "ErrorMode should expose strict, warn, and ignore")
    }

    func testErrorModeIsSwitchable() {
        // Sanity-check that all three cases are distinct and switchable.
        func describe(_ mode: ErrorMode) -> String {
            switch mode {
            case .strict: return "strict"
            case .warn: return "warn"
            case .ignore: return "ignore"
            }
        }
        XCTAssertEqual(describe(.strict), "strict")
        XCTAssertEqual(describe(.warn), "warn")
        XCTAssertEqual(describe(.ignore), "ignore")
    }

    // MARK: - RecoverableSleapError payloads + Equatable

    func testMissingVideoCarriesFilename() {
        let error = RecoverableSleapError.missingVideo(filename: "clip.mp4")
        guard case let .missingVideo(filename) = error else {
            return XCTFail("Expected missingVideo case")
        }
        XCTAssertEqual(filename, "clip.mp4")
    }

    func testSkeletonMismatchCarriesExpectedAndFound() {
        let error = RecoverableSleapError.skeletonMismatch(
            expected: ["head", "thorax"],
            found: ["head", "abdomen"]
        )
        guard case let .skeletonMismatch(expected, found) = error else {
            return XCTFail("Expected skeletonMismatch case")
        }
        XCTAssertEqual(expected, ["head", "thorax"])
        XCTAssertEqual(found, ["head", "abdomen"])
    }

    func testMergeConflictCarriesDescription() {
        let error = RecoverableSleapError.mergeConflict(description: "duplicate frame")
        guard case let .mergeConflict(description) = error else {
            return XCTFail("Expected mergeConflict case")
        }
        XCTAssertEqual(description, "duplicate frame")
    }

    func testRecoverableSleapErrorEquatable() {
        XCTAssertEqual(
            RecoverableSleapError.missingVideo(filename: "a.mp4"),
            RecoverableSleapError.missingVideo(filename: "a.mp4")
        )
        XCTAssertNotEqual(
            RecoverableSleapError.missingVideo(filename: "a.mp4"),
            RecoverableSleapError.missingVideo(filename: "b.mp4")
        )

        XCTAssertEqual(
            RecoverableSleapError.skeletonMismatch(expected: ["a"], found: ["b"]),
            RecoverableSleapError.skeletonMismatch(expected: ["a"], found: ["b"])
        )
        XCTAssertNotEqual(
            RecoverableSleapError.skeletonMismatch(expected: ["a"], found: ["b"]),
            RecoverableSleapError.skeletonMismatch(expected: ["a"], found: ["c"])
        )

        XCTAssertEqual(
            RecoverableSleapError.mergeConflict(description: "x"),
            RecoverableSleapError.mergeConflict(description: "x")
        )

        // Different cases are not equal.
        XCTAssertNotEqual(
            RecoverableSleapError.missingVideo(filename: "a.mp4"),
            RecoverableSleapError.mergeConflict(description: "a.mp4")
        )
    }

    // MARK: - ErrorCollector

    func testErrorCollectorStartsEmpty() {
        let collector = ErrorCollector()
        XCTAssertTrue(collector.errors.isEmpty)
    }

    func testErrorCollectorThrowsInStrictMode() {
        var collector = ErrorCollector()
        let error = RecoverableSleapError.missingVideo(filename: "missing.mp4")
        XCTAssertThrowsError(try collector.handle(error, mode: .strict)) { thrown in
            XCTAssertEqual(thrown as? RecoverableSleapError, error)
        }
        // Strict mode does not accumulate.
        XCTAssertTrue(collector.errors.isEmpty)
    }

    func testErrorCollectorAccumulatesInWarnMode() throws {
        var collector = ErrorCollector()
        let first = RecoverableSleapError.missingVideo(filename: "a.mp4")
        let second = RecoverableSleapError.mergeConflict(description: "dup")

        try collector.handle(first, mode: .warn)
        try collector.handle(second, mode: .warn)

        XCTAssertEqual(collector.errors, [first, second])
    }

    func testErrorCollectorDropsInIgnoreMode() throws {
        var collector = ErrorCollector()
        try collector.handle(.missingVideo(filename: "a.mp4"), mode: .ignore)
        try collector.handle(.mergeConflict(description: "dup"), mode: .ignore)
        XCTAssertTrue(collector.errors.isEmpty, "Ignore mode should drop errors silently")
    }

    func testErrorCollectorMixedModes() throws {
        var collector = ErrorCollector()
        // warn accumulates, ignore drops, then a strict throws.
        try collector.handle(.missingVideo(filename: "warn.mp4"), mode: .warn)
        try collector.handle(.missingVideo(filename: "ignored.mp4"), mode: .ignore)

        XCTAssertEqual(collector.errors, [.missingVideo(filename: "warn.mp4")])

        XCTAssertThrowsError(
            try collector.handle(.mergeConflict(description: "boom"), mode: .strict)
        )
        // The strict failure is not appended.
        XCTAssertEqual(collector.errors, [.missingVideo(filename: "warn.mp4")])
    }
}
