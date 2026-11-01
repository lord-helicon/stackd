import Foundation
import Testing
@testable import stackd

extension ProtoWriter {
    /// Test helper: append raw bytes (all < 0x80, so each is a one-byte varint).
    mutating func raw(_ bytes: [UInt8]) {
        for b in bytes { appendRawVarint(UInt64(b)) }
    }
}

struct WireFormatTests {
    private func reader(_ bytes: [UInt8]) -> ProtoReader { ProtoReader(Data(bytes)) }

    @Test(arguments: [UInt64(0), 1, 127, 128, 300, UInt64(UInt32.max), UInt64.max])
    func varintRoundTrip(value: UInt64) throws {
        var w = ProtoWriter()
        w.appendRawVarint(value)
        var r = ProtoReader(w.data)
        #expect(r.readVarint() == value)
        #expect(r.isAtEnd)
    }

    @Test func varintEncodings() {
        var w = ProtoWriter()
        w.appendRawVarint(300)
        #expect(w.bytes == [0xAC, 0x02])
        var m = ProtoWriter()
        m.appendRawVarint(UInt64.max)
        #expect(m.bytes.count == 10)
    }

    @Test func proto3DefaultsAreSkipped() {
        var w = ProtoWriter()
        w.appendString(1, "")
        w.appendBool(2, false)
        w.appendUInt32(3, 0)
        w.appendUInt64(4, 0)
        w.appendInt64(5, 0)
        w.appendMessage(6, ProtoWriter())
        #expect(w.bytes.isEmpty)
    }

    @Test func nonDefaultsAreWritten() throws {
        var w = ProtoWriter()
        w.appendString(1, "hi")
        w.appendBool(2, true)
        w.appendInt64(3, -1)
        var r = ProtoReader(w.data)
        var f = try #require(try r.nextField())
        #expect(f.field == 1 && f.wire == WireType.lengthDelimited)
        #expect(try r.readString() == "hi")
        f = try #require(try r.nextField())
        #expect(f.field == 2 && f.wire == WireType.varint)
        #expect(try r.readBool())
        f = try #require(try r.nextField())
        #expect(f.field == 3)
        #expect(try r.readInt64() == -1)
        #expect(try r.nextField() == nil)
    }

    @Test func nextFieldNilAtEnd() throws {
        var r = reader([])
        #expect(try r.nextField() == nil)
    }

    @Test func skipsUnknownFieldsOfEveryWireType() throws {
        var w = ProtoWriter()
        w.tag(1, WireType.varint); w.appendRawVarint(300)
        w.tag(2, WireType.fixed64); w.raw([UInt8](repeating: 0x7F, count: 8))
        w.tag(3, WireType.lengthDelimited); w.appendRawVarint(3); w.raw([1, 2, 3])
        w.tag(4, WireType.fixed32); w.raw([1, 2, 3, 4])
        w.appendString(5, "end")

        var r = ProtoReader(w.data)
        var seen: [Int] = []
        while let f = try r.nextField() {
            seen.append(f.field)
            if f.field == 5 {
                #expect(try r.readString() == "end")
            } else {
                try r.skip(f.wire)
            }
        }
        #expect(seen == [1, 2, 3, 4, 5])
        #expect(r.isAtEnd)
    }

    @Test func fixedReads() throws {
        var r = reader([1, 2, 3, 4, 1, 0, 0, 0, 0, 0, 0, 0])
        #expect(try r.readFixed32() == 0x04030201)
        #expect(try r.readFixed64() == 1)
    }

    @Test func truncatedVarintThrows() {
        var r = reader([0x80])
        #expect(throws: ProtoError.self) { try r.nextField() }
        var r2 = reader([0x80])
        #expect(throws: ProtoError.self) { try r2.skip(WireType.varint) }
        var r3 = reader([0x80])
        #expect(throws: ProtoError.self) { try r3.readUInt64() }
    }

    @Test func truncatedFixedThrows() {
        var a = reader([1, 2, 3])
        #expect(throws: ProtoError.self) { try a.skip(WireType.fixed32) }
        var b = reader([1, 2, 3, 4, 5, 6, 7])
        #expect(throws: ProtoError.self) { try b.skip(WireType.fixed64) }
        var c = reader([1, 2, 3])
        #expect(throws: ProtoError.self) { try c.readFixed32() }
        var d = reader([1, 2, 3, 4, 5, 6, 7])
        #expect(throws: ProtoError.self) { try d.readFixed64() }
    }

    @Test func truncatedLengthThrows() {
        var a = reader([])
        #expect(throws: ProtoError.self) { try a.skip(WireType.lengthDelimited) }
        var b = reader([0x80])
        #expect(throws: ProtoError.self) { try b.readLengthDelimited() }
    }

    @Test func lengthLargerThanRemainingThrows() {
        var a = reader([5, 1, 2])
        #expect(throws: ProtoError.self) { try a.skip(WireType.lengthDelimited) }
        var b = reader([5, 1, 2])
        #expect(throws: ProtoError.self) { try b.readLengthDelimited() }
        var c = reader([5, 1, 2])
        #expect(throws: ProtoError.self) { try c.readString() }
        // Huge length (UInt64.max) must not trap.
        var w = ProtoWriter()
        w.appendRawVarint(UInt64.max)
        var d = ProtoReader(w.data)
        #expect(throws: ProtoError.self) { try d.readLengthDelimited() }
    }

    @Test func groupWireTypesThrowBadGroup() {
        for wire in [WireType.startGroup, WireType.endGroup] {
            var r = reader([])
            do {
                try r.skip(wire)
                Issue.record("expected badGroup")
            } catch ProtoError.badGroup(let w) {
                #expect(w == wire)
            } catch {
                Issue.record("wrong error \(error)")
            }
        }
    }

    @Test func overlongVarintThrows() {
        let bytes = [UInt8](repeating: 0x80, count: 11) + [0x01]
        var r = ProtoReader(Data(bytes))
        #expect(r.readVarint() == nil)
        var r2 = ProtoReader(Data(bytes))
        #expect(throws: ProtoError.self) { try r2.readUInt64() }
    }

    @Test func errorDescriptions() {
        #expect(ProtoError.truncated.errorDescription?.contains("truncated") == true)
        #expect(ProtoError.badGroup(3).errorDescription?.contains("group") == true)
    }
}
