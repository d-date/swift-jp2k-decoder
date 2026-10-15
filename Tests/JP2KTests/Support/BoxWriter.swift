enum BoxWriter {
    static func u16(_ value: UInt16) -> [UInt8] {
        [UInt8(truncatingIfNeeded: value >> 8), UInt8(truncatingIfNeeded: value)]
    }

    static func u32(_ value: UInt32) -> [UInt8] {
        [UInt8(truncatingIfNeeded: value >> 24), UInt8(truncatingIfNeeded: value >> 16),
         UInt8(truncatingIfNeeded: value >> 8), UInt8(truncatingIfNeeded: value)]
    }

    static func box(_ type: String, _ payload: [UInt8]) -> [UInt8] {
        u32(UInt32(payload.count + 8)) + Array(type.utf8) + payload
    }

    static func xlBox(_ type: String, _ payload: [UInt8]) -> [UInt8] {
        u32(1) + Array(type.utf8) + u32(0) + u32(UInt32(payload.count + 16)) + payload
    }

    static func zeroLengthBox(_ type: String, _ payload: [UInt8]) -> [UInt8] {
        u32(0) + Array(type.utf8) + payload
    }
}
