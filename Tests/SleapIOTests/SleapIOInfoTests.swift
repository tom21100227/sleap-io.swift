import XCTest
@testable import SleapIO

/// E4.2: Library version + provenance stamping.
final class SleapIOInfoTests: XCTestCase {

    func testVersionIsNonEmptySemver() {
        let v = SleapIOInfo.version
        XCTAssertFalse(v.isEmpty)
        let parts = v.split(separator: ".")
        XCTAssertEqual(parts.count, 3, "expected major.minor.patch")
        XCTAssertTrue(parts.allSatisfy { Int($0) != nil }, "all components numeric")
    }

    func testSupportedSLPRange() {
        XCTAssertTrue(SleapIOInfo.supportedSLPFormatVersions.contains(1.0))
        XCTAssertTrue(SleapIOInfo.supportedSLPFormatVersions.contains(1.5))
    }

    func testStampSleapIOVersion() {
        let labels = Labels()
        XCTAssertNil(labels.provenance[SleapIOInfo.provenanceVersionKey])
        let stamped = labels.stampSleapIOVersion()
        XCTAssertEqual(stamped, SleapIOInfo.version)
        XCTAssertEqual(labels.provenance[SleapIOInfo.provenanceVersionKey], .string(SleapIOInfo.version))
    }

    func testStampOverwritesPreviousValue() {
        let labels = Labels()
        labels.provenance[SleapIOInfo.provenanceVersionKey] = "0.0.1"
        labels.stampSleapIOVersion()
        XCTAssertEqual(labels.provenance[SleapIOInfo.provenanceVersionKey], .string(SleapIOInfo.version))
    }
}
