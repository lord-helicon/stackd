import Foundation

/// Minimal proto3 wire-format codec — just enough for the boxd API messages we use.
/// Unknown fields are skipped on decode, so server-side additions stay compatible.

enum WireType {
    static let varint = 0
    static let fixed64 = 1
    static let lengthDelimited = 2
    static let startGroup = 3 // deprecated; treated as malformed
    static let endGroup = 4   // deprecated; treated as malformed
    static let fixed32 = 5
}

enum ProtoError: LocalizedError {
    case truncated
    case badGroup(Int)

    var errorDescription: String? {
        switch self {
        case .truncated: return "malformed protobuf (truncated)"
        case .badGroup(let f): return "malformed protobuf (group field \(f))"
        }
    }
}

// MARK: - Writer

struct ProtoWriter {
    private(set) var bytes = [UInt8]()

    @inline(__always)
    mutating func appendRawVarint(_ value: UInt64) {
        var v = value
        repeat {
            var b = UInt8(v & 0x7f)
            v >>= 7
            if v != 0 { b |= 0x80 }
            bytes.append(b)
        } while v != 0
    }

    @inline(__always)
    mutating func tag(_ field: Int, _ wireType: Int) {
        appendRawVarint(UInt64((field << 3) | wireType))
    }

    /// proto3: default values (0 / "" / false) are not written.
    mutating func appendString(_ field: Int, _ value: String) {
        guard !value.isEmpty else { return }
        let utf8 = Array(value.utf8)
        tag(field, WireType.lengthDelimited)
        appendRawVarint(UInt64(utf8.count))
        bytes.append(contentsOf: utf8)
    }

    mutating func appendBool(_ field: Int, _ value: Bool) {
        guard value else { return }
        tag(field, WireType.varint)
        appendRawVarint(1)
    }

    mutating func appendUInt32(_ field: Int, _ value: UInt32) {
        guard value != 0 else { return }
        tag(field, WireType.varint)
        appendRawVarint(UInt64(value))
    }

    mutating func appendUInt64(_ field: Int, _ value: UInt64) {
        guard value != 0 else { return }
        tag(field, WireType.varint)
        appendRawVarint(value)
    }

    mutating func appendInt64(_ field: Int, _ value: Int64) {
        guard value != 0 else { return }
        tag(field, WireType.varint)
        appendRawVarint(UInt64(bitPattern: value))
    }

    mutating func appendMessage(_ field: Int, _ sub: ProtoWriter) {
        guard !sub.bytes.isEmpty else { return }
        tag(field, WireType.lengthDelimited)
        appendRawVarint(UInt64(sub.bytes.count))
        bytes.append(contentsOf: sub.bytes)
    }

    var data: Data { Data(bytes) }
}

// MARK: - Reader

struct ProtoReader {
    private let bytes: [UInt8]
    private var pos = 0

    init(_ data: Data) {
        bytes = [UInt8](data)
    }

    var isAtEnd: Bool { pos >= bytes.count }

    mutating func readVarint() -> UInt64? {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while pos < bytes.count {
            let b = bytes[pos]
            pos += 1
            result |= UInt64(b & 0x7f) << shift
            if b & 0x80 == 0 { return result }
            shift += 7
            if shift >= 64 { return nil } // >10 bytes: malformed varint
        }
        return nil // truncated
    }

    /// Next (field number, wire type), or `nil` when the buffer is exhausted.
    mutating func nextField() throws -> (field: Int, wire: Int)? {
        guard pos < bytes.count else { return nil }
        guard let tag = readVarint() else { throw ProtoError.truncated }
        return (Int(tag >> 3), Int(tag & 0x7))
    }

    /// Skip a field of the given wire type. Returns false if malformed.
    mutating func skip(_ wire: Int) throws {
        switch wire {
        case WireType.varint:
            guard readVarint() != nil else { throw ProtoError.truncated }
        case WireType.fixed64:
            guard pos + 8 <= bytes.count else { throw ProtoError.truncated }
            pos += 8
        case WireType.lengthDelimited:
            guard let len = readVarint() else { throw ProtoError.truncated }
            guard len <= UInt64(bytes.count - pos) else { throw ProtoError.truncated }
            pos += Int(len)
        case WireType.fixed32:
            guard pos + 4 <= bytes.count else { throw ProtoError.truncated }
            pos += 4
        default:
            throw ProtoError.badGroup(wire)
        }
    }

    /// Read a length-delimited payload (string or bytes).
    mutating func readLengthDelimited() throws -> [UInt8] {
        guard let len = readVarint() else { throw ProtoError.truncated }
        guard len <= UInt64(bytes.count - pos) else { throw ProtoError.truncated }
        let out = Array(bytes[pos..<(pos + Int(len))])
        pos += Int(len)
        return out
    }

    mutating func readString() throws -> String {
        let raw = try readLengthDelimited()
        return String(decoding: raw, as: UTF8.self)
    }

    mutating func readUInt64() throws -> UInt64 {
        guard let v = readVarint() else { throw ProtoError.truncated }
        return v
    }

    mutating func readInt64() throws -> Int64 {
        Int64(bitPattern: try readUInt64())
    }

    mutating func readBool() throws -> Bool {
        (try readUInt64()) != 0
    }

    mutating func readFixed32() throws -> UInt32 {
        guard pos + 4 <= bytes.count else { throw ProtoError.truncated }
        let v = UInt32(bytes[pos]) | (UInt32(bytes[pos + 1]) << 8)
            | (UInt32(bytes[pos + 2]) << 16) | (UInt32(bytes[pos + 3]) << 24)
        pos += 4
        return v
    }

    mutating func readFixed64() throws -> UInt64 {
        guard pos + 8 <= bytes.count else { throw ProtoError.truncated }
        var v: UInt64 = 0
        for i in 0..<8 { v |= UInt64(bytes[pos + i]) << (8 * i) }
        pos += 8
        return v
    }
}
