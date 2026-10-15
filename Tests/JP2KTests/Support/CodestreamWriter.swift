enum CodestreamWriter {
    static func u16(_ value: Int) -> [UInt8] { [UInt8((value >> 8) & 255), UInt8(value & 255)] }
    static func u32(_ value: Int) -> [UInt8] { [UInt8((value >> 24) & 255), UInt8((value >> 16) & 255), UInt8((value >> 8) & 255), UInt8(value & 255)] }
    static func soc() -> [UInt8] { [0xFF, 0x4F] }
    static func marker(_ code: UInt16, _ payload: [UInt8]) -> [UInt8] {
        u16(Int(code)) + u16(payload.count + 2) + payload
    }
    static func siz(width: Int = 8, height: Int = 8, x0: Int = 0, y0: Int = 0,
                    tileWidth: Int = 8, tileHeight: Int = 8, components: Int = 1,
                    descriptor: UInt8 = 7, dx: UInt8 = 1, dy: UInt8 = 1) -> [UInt8] {
        var body = u16(0) + u32(width) + u32(height) + u32(x0) + u32(y0)
        body += u32(tileWidth) + u32(tileHeight) + u32(0) + u32(0) + u16(components)
        for _ in 0..<components { body += [descriptor, dx, dy] }
        return marker(0xFF51, body)
    }
    static func cod(levels: UInt8 = 0) -> [UInt8] { marker(0xFF52, [0, 0, 0, 1, 0, levels, 4, 4, 0, 1]) }
    static func qcd() -> [UInt8] { marker(0xFF5C, [0, 0x40]) }
    static func minimal() -> [UInt8] { soc() + siz() + cod() + qcd() + [0xFF, 0x90] }
}
