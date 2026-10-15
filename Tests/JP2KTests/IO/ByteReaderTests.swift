import Testing
@testable import JP2K

@Test func readsBigEndian() throws {
    var reader = ByteReader(
        [0x12, 0x34, 0x56, 0x78, 0x9A],
        range: 0..<5,
        truncationError: .invalidCodestream(.truncated)
    )
    #expect(try reader.peekU16() == 0x1234)
    #expect(reader.offset == 0)
    #expect(try reader.u16() == 0x1234)
    #expect(try reader.u16() == 0x5678)
    #expect(throws: JP2KError.invalidCodestream(.truncated)) { try reader.u16() }
    #expect(reader.offset == 4)
    #expect(try reader.u8() == 0x9A)
    #expect(reader.remaining == 0)
}

@Test func readsWideValuesAndSlices() throws {
    var reader = ByteReader(
        [0x01, 0x23, 0x45, 0x67, 0x89, 0xAB, 0xCD, 0xEF, 0x77],
        range: 0..<9,
        truncationError: .invalidContainer(.truncated)
    )
    #expect(try reader.u32() == 0x01234567)
    #expect(try reader.bytes(count: 2).elementsEqual([0x89, 0xAB]))
    #expect(reader.offset == 6)
    #expect(try reader.bytes(count: 0).isEmpty)
    #expect(try reader.peekU16() == 0xCDEF)
    var child = try reader.subReader(length: 2)
    #expect(try child.u16() == 0xCDEF)
    #expect(reader.offset == 8)
    #expect(try reader.u8() == 0x77)

    var wide = ByteReader(
        [0x01, 0x23, 0x45, 0x67, 0x89, 0xAB, 0xCD, 0xEF],
        range: 0..<8,
        truncationError: .invalidCodestream(.truncated)
    )
    #expect(try wide.u64() == 0x0123456789ABCDEF)
}

@Test func failedReadsDoNotAdvance() {
    var reader = ByteReader(
        [1, 2, 3], range: 0..<3, truncationError: .invalidContainer(.truncated)
    )
    #expect(throws: JP2KError.invalidContainer(.truncated)) {
        _ = try reader.subReader(length: 4)
    }
    #expect(throws: JP2KError.invalidContainer(.truncated)) { try reader.skip(-1) }
    #expect(throws: JP2KError.invalidContainer(.truncated)) { _ = try reader.bytes(count: Int.max) }
    #expect(reader.offset == 0)
}

@Test func rangeOutsideArrayIsClamped() throws {
    var reader = ByteReader(
        [1], range: 0..<10, truncationError: .invalidContainer(.truncated)
    )
    #expect(reader.remaining == 1)
    #expect(try reader.u8() == 1)
    let empty = ByteReader(
        [1], range: 3..<10, truncationError: .invalidContainer(.truncated)
    )
    #expect(empty.remaining == 0)
}
