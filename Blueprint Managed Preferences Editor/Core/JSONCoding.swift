import Foundation

// MARK: - Parsing

nonisolated struct JSONParseError: Error, LocalizedError, Sendable {
    let message: String
    let offset: Int

    var errorDescription: String? { "Invalid JSON at byte \(offset): \(message)" }
}

nonisolated extension JSONValue {
    /// Parses UTF-8 JSON data, preserving key order and number literals.
    init(data: Data) throws {
        var parser = JSONParser(bytes: Array(data))
        self = try parser.parseDocument()
    }

    init(string: String) throws {
        try self.init(data: Data(string.utf8))
    }
}

/// A small recursive-descent JSON parser (RFC 8259).
nonisolated private struct JSONParser {
    private let bytes: [UInt8]
    private var index = 0
    private var depth = 0
    /// Keeps recursion well within the ~512 KB stacks of secondary threads.
    private static let maxDepth = 100

    init(bytes: [UInt8]) {
        self.bytes = bytes
    }

    mutating func parseDocument() throws -> JSONValue {
        // Skip a UTF-8 byte-order mark if present.
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { index = 3 }
        skipWhitespace()
        let value = try parseValue()
        skipWhitespace()
        guard index == bytes.count else { throw error("Unexpected trailing characters") }
        return value
    }

    private func error(_ message: String) -> JSONParseError {
        JSONParseError(message: message, offset: index)
    }

    private var current: UInt8? { index < bytes.count ? bytes[index] : nil }

    private mutating func skipWhitespace() {
        while let byte = current, byte == 0x20 || byte == 0x0A || byte == 0x0D || byte == 0x09 {
            index += 1
        }
    }

    private mutating func expect(_ literal: String) throws {
        for byte in literal.utf8 {
            guard current == byte else { throw error("Expected '\(literal)'") }
            index += 1
        }
    }

    private mutating func parseValue() throws -> JSONValue {
        guard let byte = current else { throw error("Unexpected end of input") }
        switch byte {
        case UInt8(ascii: "{"): return try parseObject()
        case UInt8(ascii: "["): return try parseArray()
        case UInt8(ascii: "\""): return .string(try parseString())
        case UInt8(ascii: "t"): try expect("true"); return .bool(true)
        case UInt8(ascii: "f"): try expect("false"); return .bool(false)
        case UInt8(ascii: "n"): try expect("null"); return .null
        case UInt8(ascii: "-"), UInt8(ascii: "0")...UInt8(ascii: "9"): return .number(try parseNumber())
        default: throw error("Unexpected character '\(Character(UnicodeScalar(byte)))'")
        }
    }

    private mutating func enterContainer() throws {
        depth += 1
        guard depth <= Self.maxDepth else { throw error("Nesting too deep") }
    }

    private mutating func parseObject() throws -> JSONValue {
        try enterContainer()
        defer { depth -= 1 }
        index += 1 // {
        var members: [JSONObject.Member] = []
        skipWhitespace()
        if current == UInt8(ascii: "}") {
            index += 1
            return .object(JSONObject(members))
        }
        while true {
            skipWhitespace()
            guard current == UInt8(ascii: "\"") else { throw error("Expected object key") }
            let key = try parseString()
            skipWhitespace()
            guard current == UInt8(ascii: ":") else { throw error("Expected ':'") }
            index += 1
            skipWhitespace()
            let value = try parseValue()
            members.append(JSONObject.Member(key: key, value: value))
            skipWhitespace()
            switch current {
            case UInt8(ascii: ","): index += 1
            case UInt8(ascii: "}"): index += 1; return .object(JSONObject(members))
            default: throw error("Expected ',' or '}'")
            }
        }
    }

    private mutating func parseArray() throws -> JSONValue {
        try enterContainer()
        defer { depth -= 1 }
        index += 1 // [
        var elements: [JSONValue] = []
        skipWhitespace()
        if current == UInt8(ascii: "]") {
            index += 1
            return .array(elements)
        }
        while true {
            skipWhitespace()
            elements.append(try parseValue())
            skipWhitespace()
            switch current {
            case UInt8(ascii: ","): index += 1
            case UInt8(ascii: "]"): index += 1; return .array(elements)
            default: throw error("Expected ',' or ']'")
            }
        }
    }

    private mutating func parseNumber() throws -> JSONNumber {
        let start = index
        func isDigit(_ byte: UInt8?) -> Bool {
            guard let byte else { return false }
            return byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9")
        }
        if current == UInt8(ascii: "-") { index += 1 }
        if current == UInt8(ascii: "0") {
            index += 1
        } else if isDigit(current) {
            while isDigit(current) { index += 1 }
        } else {
            throw error("Invalid number")
        }
        if current == UInt8(ascii: ".") {
            index += 1
            guard isDigit(current) else { throw error("Expected digit after '.'") }
            while isDigit(current) { index += 1 }
        }
        if current == UInt8(ascii: "e") || current == UInt8(ascii: "E") {
            index += 1
            if current == UInt8(ascii: "+") || current == UInt8(ascii: "-") { index += 1 }
            guard isDigit(current) else { throw error("Expected digit in exponent") }
            while isDigit(current) { index += 1 }
        }
        let literal = String(decoding: bytes[start..<index], as: UTF8.self)
        return JSONNumber(literal: literal)
    }

    private mutating func parseString() throws -> String {
        index += 1 // opening quote
        var buffer: [UInt8] = []
        while true {
            guard let byte = current else { throw error("Unterminated string") }
            switch byte {
            case UInt8(ascii: "\""):
                index += 1
                guard let string = String(validating: buffer, as: UTF8.self) else {
                    throw error("Invalid UTF-8 in string")
                }
                return string
            case UInt8(ascii: "\\"):
                index += 1
                try parseEscape(into: &buffer)
            case 0x00..<0x20:
                throw error("Unescaped control character in string")
            default:
                buffer.append(byte)
                index += 1
            }
        }
    }

    private mutating func parseEscape(into buffer: inout [UInt8]) throws {
        guard let byte = current else { throw error("Unterminated escape") }
        index += 1
        switch byte {
        case UInt8(ascii: "\""): buffer.append(UInt8(ascii: "\""))
        case UInt8(ascii: "\\"): buffer.append(UInt8(ascii: "\\"))
        case UInt8(ascii: "/"): buffer.append(UInt8(ascii: "/"))
        case UInt8(ascii: "b"): buffer.append(0x08)
        case UInt8(ascii: "f"): buffer.append(0x0C)
        case UInt8(ascii: "n"): buffer.append(0x0A)
        case UInt8(ascii: "r"): buffer.append(0x0D)
        case UInt8(ascii: "t"): buffer.append(0x09)
        case UInt8(ascii: "u"):
            var scalar = try parseHex4()
            // Combine UTF-16 surrogate pairs.
            if (0xD800...0xDBFF).contains(scalar) {
                guard current == UInt8(ascii: "\\"), index + 1 < bytes.count, bytes[index + 1] == UInt8(ascii: "u") else {
                    throw error("Unpaired high surrogate")
                }
                index += 2
                let low = try parseHex4()
                guard (0xDC00...0xDFFF).contains(low) else { throw error("Invalid low surrogate") }
                scalar = 0x10000 + ((scalar - 0xD800) << 10) + (low - 0xDC00)
            } else if (0xDC00...0xDFFF).contains(scalar) {
                throw error("Unpaired low surrogate")
            }
            guard let unicode = Unicode.Scalar(scalar) else { throw error("Invalid unicode escape") }
            buffer.append(contentsOf: Array(String(Character(unicode)).utf8))
        default:
            throw error("Invalid escape '\\\(Character(UnicodeScalar(byte)))'")
        }
    }

    private mutating func parseHex4() throws -> UInt32 {
        guard index + 4 <= bytes.count else { throw error("Truncated unicode escape") }
        var value: UInt32 = 0
        for _ in 0..<4 {
            let byte = bytes[index]
            let digit: UInt32
            switch byte {
            case UInt8(ascii: "0")...UInt8(ascii: "9"): digit = UInt32(byte - UInt8(ascii: "0"))
            case UInt8(ascii: "a")...UInt8(ascii: "f"): digit = UInt32(byte - UInt8(ascii: "a") + 10)
            case UInt8(ascii: "A")...UInt8(ascii: "F"): digit = UInt32(byte - UInt8(ascii: "A") + 10)
            default: throw error("Invalid hex digit in unicode escape")
            }
            value = value * 16 + digit
            index += 1
        }
        return value
    }
}

// MARK: - Serialization

nonisolated extension JSONValue {
    /// Serializes to UTF-8 JSON. Compact output has no insignificant whitespace;
    /// pretty output uses two-space indentation. Key order and number literals are
    /// preserved exactly. Only characters that JSON requires to be escaped are escaped.
    func serialized(pretty: Bool = false) -> Data {
        Data(serializedString(pretty: pretty).utf8)
    }

    func serializedString(pretty: Bool = false) -> String {
        var output = ""
        write(to: &output, pretty: pretty, indent: 0)
        return output
    }

    private func write(to output: inout String, pretty: Bool, indent: Int) {
        switch self {
        case .null:
            output += "null"
        case .bool(let value):
            output += value ? "true" : "false"
        case .number(let number):
            output += number.literal
        case .string(let string):
            Self.writeString(string, to: &output)
        case .array(let array):
            guard !array.isEmpty else { output += "[]"; return }
            output += "["
            for (offset, element) in array.enumerated() {
                if offset > 0 { output += "," }
                if pretty { Self.newline(&output, indent: indent + 1) }
                element.write(to: &output, pretty: pretty, indent: indent + 1)
            }
            if pretty { Self.newline(&output, indent: indent) }
            output += "]"
        case .object(let object):
            guard !object.isEmpty else { output += "{}"; return }
            output += "{"
            for (offset, member) in object.members.enumerated() {
                if offset > 0 { output += "," }
                if pretty { Self.newline(&output, indent: indent + 1) }
                Self.writeString(member.key, to: &output)
                output += pretty ? ": " : ":"
                member.value.write(to: &output, pretty: pretty, indent: indent + 1)
            }
            if pretty { Self.newline(&output, indent: indent) }
            output += "}"
        }
    }

    private static func newline(_ output: inout String, indent: Int) {
        output += "\n"
        output += String(repeating: "  ", count: indent)
    }

    private static func writeString(_ string: String, to output: inout String) {
        output += "\""
        for scalar in string.unicodeScalars {
            switch scalar {
            case "\"": output += "\\\""
            case "\\": output += "\\\\"
            case "\n": output += "\\n"
            case "\r": output += "\\r"
            case "\t": output += "\\t"
            case "\u{08}": output += "\\b"
            case "\u{0C}": output += "\\f"
            case "\u{00}"..."\u{1F}":
                output += String(format: "\\u%04x", scalar.value)
            default:
                output.unicodeScalars.append(scalar)
            }
        }
        output += "\""
    }
}
