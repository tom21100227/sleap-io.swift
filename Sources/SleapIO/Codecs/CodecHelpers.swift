import Foundation

/// Shared utilities for interchange format codecs.
enum CodecHelpers {
    /// Read and parse a JSON file, returning the parsed object.
    /// Throws fileNotFound if path doesn't exist, corruptData if JSON is malformed.
    static func readJSONFile(_ path: String) throws -> Any {
        let url = URL(fileURLWithPath: path)
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw SleapIOError.fileNotFound("File not found: \(path)")
        }
        do {
            return try JSONSerialization.jsonObject(with: data)
        } catch {
            throw SleapIOError.corruptData("Malformed JSON in \(path): \(error.localizedDescription)")
        }
    }

    /// Extract Int from a JSON Any? value (handles Int, Double, NSNumber).
    static func intValue(_ value: Any?) -> Int? {
        if let i = value as? Int { return i }
        if let d = value as? Double { return Int(d) }
        if let n = value as? NSNumber { return n.intValue }
        return nil
    }

    /// Extract Double from a JSON Any? value.
    static func doubleValue(_ value: Any?) -> Double? {
        if let d = value as? Double { return d }
        if let i = value as? Int { return Double(i) }
        if let n = value as? NSNumber { return n.doubleValue }
        return nil
    }

    /// Extract Float from a JSON Any? value.
    static func floatValue(_ value: Any?) -> Float? {
        if let f = value as? Float { return f }
        if let d = value as? Double { return Float(d) }
        if let i = value as? Int { return Float(i) }
        if let n = value as? NSNumber { return n.floatValue }
        return nil
    }
}
