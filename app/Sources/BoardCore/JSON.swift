// A JSON value that remembers the order of an object's keys and the exact text of
// its numbers. The board rewrites other tools' config files (the agents' hooks), and
// those must come back out the way they went in apart from the change itself.
// Foundation's JSONSerialization keeps neither, and cannot tell `true` from `1`.

import Foundation

public enum JSON: Equatable {
    case null
    case bool(Bool)
    case number(String)  // the literal as written
    case string(String)
    case array([JSON])
    case object(JSONObject)
}

public struct JSONObject: Equatable, ExpressibleByDictionaryLiteral {
    public private(set) var keys: [String] = []
    private var values: [String: JSON] = [:]

    public init() {}

    public init(dictionaryLiteral elements: (String, JSON)...) {
        for (key, value) in elements { self[key] = value }
    }

    public subscript(key: String) -> JSON? {
        get { values[key] }
        set {
            if let newValue = newValue {
                if values[key] == nil { keys.append(key) }
                values[key] = newValue
            } else if values.removeValue(forKey: key) != nil {
                keys.removeAll { $0 == key }
            }
        }
    }

    public var isEmpty: Bool { keys.isEmpty }
    public var pairs: [(String, JSON)] { keys.map { ($0, values[$0]!) } }
}

extension JSON: ExpressibleByDictionaryLiteral, ExpressibleByArrayLiteral, ExpressibleByStringLiteral,
    ExpressibleByBooleanLiteral, ExpressibleByIntegerLiteral, ExpressibleByNilLiteral {
    public init(dictionaryLiteral elements: (String, JSON)...) {
        var object = JSONObject()
        for (key, value) in elements { object[key] = value }
        self = .object(object)
    }
    public init(arrayLiteral elements: JSON...) { self = .array(elements) }
    public init(stringLiteral value: String) { self = .string(value) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(integerLiteral value: Int) { self = .number(String(value)) }
    public init(nilLiteral: ()) { self = .null }

    public init(_ value: Int) { self = .number(String(value)) }
    public init(_ value: Bool) { self = .bool(value) }
    public init(_ value: String) { self = .string(value) }
    public init(_ value: Double) {
        self = value == value.rounded() && abs(value) < 1e15 ? .number(String(Int(value))) : .number(String(value))
    }
    public init(_ value: [String]) { self = .array(value.map(JSON.string)) }
}

extension JSON {
    public var string: String? { if case .string(let v) = self { return v }; return nil }
    public var bool: Bool? { if case .bool(let v) = self { return v }; return nil }
    public var array: [JSON]? { if case .array(let v) = self { return v }; return nil }
    public var object: JSONObject? { if case .object(let v) = self { return v }; return nil }
    public var double: Double? { if case .number(let v) = self { return Double(v) }; return nil }
    public var isNull: Bool { self == .null }

    /// A whole number, and not one written with a fraction or an exponent.
    public var int: Int? { if case .number(let v) = self { return Int(v) }; return nil }

    public subscript(key: String) -> JSON? { object?[key] }

    /// What Python calls truthy, for the places a missing, null, empty or false value all mean "no".
    public var truthy: Bool {
        switch self {
        case .null: return false
        case .bool(let v): return v
        case .number(let v): return Double(v) != 0
        case .string(let v): return !v.isEmpty
        case .array(let v): return !v.isEmpty
        case .object(let v): return !v.isEmpty
        }
    }
}

// MARK: - reading

public struct JSONError: Error {}

extension JSON {
    public init(parsing data: Data) throws {
        guard let text = String(data: data, encoding: .utf8) else { throw JSONError() }
        try self.init(parsing: text)
    }

    public init(parsing text: String) throws {
        var parser = Parser(text: Array(text.unicodeScalars))
        parser.skipSpace()
        self = try parser.value()
        parser.skipSpace()
        guard parser.at == parser.text.count else { throw JSONError() }
    }

    private struct Parser {
        let text: [Unicode.Scalar]
        var at = 0

        var next: Unicode.Scalar? { at < text.count ? text[at] : nil }

        mutating func skipSpace() {
            while let c = next, c == " " || c == "\n" || c == "\r" || c == "\t" { at += 1 }
        }

        mutating func take(_ word: String) throws {
            for scalar in word.unicodeScalars {
                guard next == scalar else { throw JSONError() }
                at += 1
            }
        }

        mutating func value(depth: Int = 0) throws -> JSON {
            guard depth < 200, let c = next else { throw JSONError() }
            switch c {
            case "{":
                at += 1
                var object = JSONObject()
                skipSpace()
                if next == "}" { at += 1; return .object(object) }
                while true {
                    skipSpace()
                    let key = try string()
                    skipSpace()
                    try take(":")
                    skipSpace()
                    object[key] = try value(depth: depth + 1)
                    skipSpace()
                    if next == "," { at += 1; continue }
                    try take("}")
                    return .object(object)
                }
            case "[":
                at += 1
                var items: [JSON] = []
                skipSpace()
                if next == "]" { at += 1; return .array(items) }
                while true {
                    skipSpace()
                    items.append(try value(depth: depth + 1))
                    skipSpace()
                    if next == "," { at += 1; continue }
                    try take("]")
                    return .array(items)
                }
            case "\"": return .string(try string())
            case "t": try take("true"); return .bool(true)
            case "f": try take("false"); return .bool(false)
            case "n": try take("null"); return .null
            default:
                let start = at
                while let d = next, "+-.eE0123456789".unicodeScalars.contains(d) { at += 1 }
                let literal = String(String.UnicodeScalarView(text[start..<at]))
                guard Double(literal) != nil else { throw JSONError() }
                return .number(literal)
            }
        }

        mutating func hex4() throws -> UInt32 {
            guard at + 4 <= text.count, let code = UInt32(String(String.UnicodeScalarView(text[at..<at + 4])), radix: 16) else {
                throw JSONError()
            }
            at += 4
            return code
        }

        mutating func string() throws -> String {
            try take("\"")
            var out = String.UnicodeScalarView()
            while let c = next {
                at += 1
                if c == "\"" { return String(out) }
                guard c == "\\" else { out.append(c); continue }
                guard let escape = next else { throw JSONError() }
                at += 1
                switch escape {
                case "n": out.append("\n")
                case "t": out.append("\t")
                case "r": out.append("\r")
                case "b": out.append("\u{08}")
                case "f": out.append("\u{0C}")
                case "u":
                    var code = try hex4()
                    if (0xD800..<0xDC00).contains(code), next == "\\", at + 1 < text.count, text[at + 1] == "u" {
                        let mark = at
                        at += 2
                        let low = try hex4()
                        if (0xDC00..<0xE000).contains(low) {
                            code = 0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00)
                        } else {
                            at = mark
                        }
                    }
                    out.append(Unicode.Scalar(code) ?? "\u{FFFD}")  // half of a pair on its own
                default: out.append(escape)  // \" \\ \/
                }
            }
            throw JSONError()
        }
    }
}

// MARK: - writing

extension JSON {
    /// On one line, for answers to the settings page.
    public var compact: String { written(indent: nil, colon: ":", level: 0) }

    /// The way Python's `json.dumps(indent=2, ensure_ascii=False)` writes it, which is the
    /// style of the files this goes back into. `colon` is " : " for files Swift tools wrote.
    public func pretty(colon: String = ": ") -> String { written(indent: 2, colon: colon, level: 0) }

    private func written(indent: Int?, colon: String, level: Int) -> String {
        let pad = indent.map { "\n" + String(repeating: " ", count: $0 * (level + 1)) } ?? ""
        let close = indent.map { "\n" + String(repeating: " ", count: $0 * level) } ?? ""
        switch self {
        case .null: return "null"
        case .bool(let v): return v ? "true" : "false"
        case .number(let v): return v
        case .string(let v): return JSON.quoted(v)
        case .array(let items):
            if items.isEmpty { return "[]" }
            return "[" + items.map { pad + $0.written(indent: indent, colon: colon, level: level + 1) }.joined(separator: ",") + close + "]"
        case .object(let object):
            if object.isEmpty { return "{}" }
            return "{" + object.pairs.map { pad + JSON.quoted($0.0) + colon + $0.1.written(indent: indent, colon: colon, level: level + 1) }
                .joined(separator: ",") + close + "}"
        }
    }

    static func quoted(_ text: String) -> String {
        var out = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "\""
    }
}
