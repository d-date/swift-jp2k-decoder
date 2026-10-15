/// A bounded big-endian reader over a byte array.
struct ByteReader {
    let bytes: [UInt8]
    private(set) var offset: Int
    let end: Int
    let truncationError: JP2KError

    init(_ bytes: [UInt8], range: Range<Int>, truncationError: JP2KError) {
        self.bytes = bytes
        let start = min(max(range.lowerBound, 0), bytes.count)
        offset = start
        end = max(start, min(range.upperBound, bytes.count))
        self.truncationError = truncationError
    }

    var remaining: Int { end - offset }

    mutating func u8() throws(JP2KError) -> UInt8 {
        try require(1)
        let value = bytes[offset]
        offset += 1
        return value
    }

    mutating func u16() throws(JP2KError) -> UInt16 {
        try require(2)
        let value = (UInt16(bytes[offset]) << 8) | UInt16(bytes[offset + 1])
        offset += 2
        return value
    }

    mutating func u32() throws(JP2KError) -> UInt32 {
        try require(4)
        var value: UInt32 = 0
        for index in offset..<(offset + 4) {
            value = (value << 8) | UInt32(bytes[index])
        }
        offset += 4
        return value
    }

    mutating func u64() throws(JP2KError) -> UInt64 {
        try require(8)
        var value: UInt64 = 0
        for index in offset..<(offset + 8) {
            value = (value << 8) | UInt64(bytes[index])
        }
        offset += 8
        return value
    }

    func peekU16() throws(JP2KError) -> UInt16 {
        try require(2)
        return (UInt16(bytes[offset]) << 8) | UInt16(bytes[offset + 1])
    }

    mutating func skip(_ count: Int) throws(JP2KError) {
        try require(count)
        offset = try Checked.add(offset, count)
    }

    mutating func subReader(length: Int) throws(JP2KError) -> ByteReader {
        try require(length)
        let start = offset
        offset = try Checked.add(offset, length)
        return ByteReader(bytes, range: start..<offset, truncationError: truncationError)
    }

    mutating func bytes(count: Int) throws(JP2KError) -> ArraySlice<UInt8> {
        try require(count)
        let start = offset
        offset = try Checked.add(offset, count)
        return bytes[start..<offset]
    }

    private func require(_ count: Int) throws(JP2KError) {
        if count < 0 || count > remaining { throw truncationError }
    }
}
