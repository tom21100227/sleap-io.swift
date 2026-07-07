import XCTest
@testable import SleapIO

/// Issue 49: `JSONValue` provenance (stop data loss).
///
/// Verifies that `JSONValue` round-trips arbitrary/nested/mixed JSON through both
/// `Codable` and the `JSONSerialization` (Foundation-object) bridge used by the SLP
/// writer/reader, and that a `Labels` with mixed-type provenance survives a
/// serialization round trip intact instead of being coerced to strings.
final class JSONValueTests: XCTestCase {

    // MARK: - Literal expressibility

    func testExpressibleByLiterals() {
        let string: JSONValue = "hello"
        let int: JSONValue = 42
        let double: JSONValue = 3.14
        let bool: JSONValue = true
        let array: JSONValue = ["a", 1, false]
        let object: JSONValue = ["key": "value", "n": 7]

        XCTAssertEqual(string, .string("hello"))
        XCTAssertEqual(int, .int(42))
        XCTAssertEqual(double, .double(3.14))
        XCTAssertEqual(bool, .bool(true))
        XCTAssertEqual(array, .array([.string("a"), .int(1), .bool(false)]))
        XCTAssertEqual(object, .object(["key": .string("value"), "n": .int(7)]))
    }

    func testDictionaryLiteralOfProvenance() {
        // A [String: JSONValue] can be written with plain literals thanks to the
        // ExpressibleBy*Literal conformances (string values do NOT become .string
        // by accident — they are chosen by literal type).
        let provenance: [String: JSONValue] = [
            "sleap_version": "1.5.0",
            "frame_count": 120,
            "fps": 29.97,
            "trained": true,
        ]
        XCTAssertEqual(provenance["sleap_version"], .string("1.5.0"))
        XCTAssertEqual(provenance["frame_count"], .int(120))
        XCTAssertEqual(provenance["fps"], .double(29.97))
        XCTAssertEqual(provenance["trained"], .bool(true))
    }

    // MARK: - Convenience accessors

    func testConvenienceAccessors() {
        XCTAssertEqual(JSONValue.string("s").stringValue, "s")
        XCTAssertEqual(JSONValue.int(5).intValue, 5)
        XCTAssertEqual(JSONValue.double(2.5).doubleValue, 2.5)
        XCTAssertEqual(JSONValue.bool(true).boolValue, true)
        XCTAssertEqual(JSONValue.array([.int(1)]).arrayValue, [.int(1)])
        XCTAssertEqual(JSONValue.object(["a": .int(1)]).objectValue, ["a": .int(1)])

        // Accessors return nil for a mismatched case.
        XCTAssertNil(JSONValue.int(5).stringValue)
        XCTAssertNil(JSONValue.string("s").intValue)
        XCTAssertNil(JSONValue.bool(true).doubleValue)
        XCTAssertNil(JSONValue.null.boolValue)
        XCTAssertNil(JSONValue.null.arrayValue)
        XCTAssertNil(JSONValue.null.objectValue)
    }

    // MARK: - Codable round-trip

    func testCodableRoundTripNestedMixed() throws {
        let original: JSONValue = .object([
            "sleap_version": .string("1.5.0"),
            "frame_count": .int(120),
            "fps": .double(29.97),
            "trained": .bool(true),
            "labels": .array([.string("a"), .string("b"), .int(3)]),
            "config": .object([
                "lr": .double(0.001),
                "epochs": .int(100),
                "augment": .bool(false),
                "layers": .array([.int(16), .int(32), .int(64)]),
            ]),
            "note": .null,
        ])

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(JSONValue.self, from: data)

        XCTAssertEqual(decoded, original)
    }

    func testCodableDecodesArbitraryJSONString() throws {
        let json = #"""
        {
            "a": "text",
            "b": 10,
            "c": 1.5,
            "d": false,
            "e": [1, 2, 3],
            "f": {"nested": null}
        }
        """#
        let data = Data(json.utf8)
        let value = try JSONDecoder().decode(JSONValue.self, from: data)

        XCTAssertEqual(value.objectValue?["a"], .string("text"))
        XCTAssertEqual(value.objectValue?["b"], .int(10))
        XCTAssertEqual(value.objectValue?["c"], .double(1.5))
        XCTAssertEqual(value.objectValue?["d"], .bool(false))
        XCTAssertEqual(value.objectValue?["e"], .array([.int(1), .int(2), .int(3)]))
        XCTAssertEqual(value.objectValue?["f"], .object(["nested": .null]))
    }

    // MARK: - Foundation (JSONSerialization) bridge

    /// This mirrors what `SLPWriter` (jsonObject -> JSONSerialization) and
    /// `SLPMetadata` (JSONSerialization -> JSONValue) do on disk.
    func testFoundationBridgeRoundTrip() throws {
        let original: [String: JSONValue] = [
            "sleap_version": "1.5.0",
            "frame_count": 120,
            "fps": 29.97,
            "trained": true,
            "labels": ["a", "b"],
            "config": ["lr": 0.001, "epochs": 100, "augment": false],
            "note": .null,
        ]

        // Emit exactly as SLPWriter does.
        let foundation = original.mapValues { $0.jsonObject }
        let data = try JSONSerialization.data(withJSONObject: foundation, options: [.sortedKeys])

        // Parse exactly as SLPMetadata does.
        let parsedAny = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let reparsed = try XCTUnwrap(parsedAny)
        var reloaded: [String: JSONValue] = [:]
        for (k, v) in reparsed { reloaded[k] = JSONValue(jsonObject: v) }

        XCTAssertEqual(reloaded, original)
    }

    /// Regression: the old parser string-coerced every provenance value
    /// (`provenance[k] = "\(v)"`), turning `120` into `"120"` and `true` into
    /// `"true"`. Types must now be preserved through the Foundation bridge.
    func testFoundationBridgePreservesTypesNotStringCoerced() throws {
        let foundation: [String: Any] = [
            "count": 120,
            "flag": true,
            "ratio": 0.5,
            "name": "fly",
        ]
        let data = try JSONSerialization.data(withJSONObject: foundation)
        let parsed = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])

        var provenance: [String: JSONValue] = [:]
        for (k, v) in parsed { provenance[k] = JSONValue(jsonObject: v) }

        XCTAssertEqual(provenance["count"], .int(120))
        XCTAssertEqual(provenance["flag"], .bool(true))
        XCTAssertEqual(provenance["ratio"], .double(0.5))
        XCTAssertEqual(provenance["name"], .string("fly"))

        // Explicitly assert they are NOT strings.
        XCTAssertNil(provenance["count"]?.stringValue)
        XCTAssertNil(provenance["flag"]?.stringValue)
    }

    func testNSNumberDisambiguation() {
        // Bool, Int, and Double NSNumbers must not be conflated.
        XCTAssertEqual(JSONValue(jsonObject: NSNumber(value: true)), .bool(true))
        XCTAssertEqual(JSONValue(jsonObject: NSNumber(value: false)), .bool(false))
        XCTAssertEqual(JSONValue(jsonObject: NSNumber(value: 7)), .int(7))
        XCTAssertEqual(JSONValue(jsonObject: NSNumber(value: 2.5)), .double(2.5))
        XCTAssertEqual(JSONValue(jsonObject: NSNull()), .null)
    }

    // MARK: - Labels provenance round trip (SleapIO-level)

    /// A `Labels` carrying mixed-type provenance survives a `DictionaryCodec`
    /// encode/decode round trip with all value types intact. (The equivalent
    /// on-disk `.slp` round trip lives in SleapHDF5Tests — see integrator notes.)
    func testLabelsMixedProvenanceRoundTripViaDictionaryCodec() throws {
        let labels = Labels()
        labels.provenance = [
            "sleap_version": "1.5.0",
            "frame_count": 120,
            "fps": 29.97,
            "trained": true,
            "sources": ["a.mp4", "b.mp4"],
            "params": ["lr": 0.001, "epochs": 100],
            "note": .null,
        ]

        let dict = DictionaryCodec.encode(labels)
        let decoded = try DictionaryCodec.decode(dict)

        XCTAssertEqual(decoded.provenance, labels.provenance)
        XCTAssertEqual(decoded.provenance["frame_count"], .int(120))
        XCTAssertEqual(decoded.provenance["trained"], .bool(true))
        XCTAssertEqual(decoded.provenance["params"],
                       .object(["lr": .double(0.001), "epochs": .int(100)]))
    }
}
