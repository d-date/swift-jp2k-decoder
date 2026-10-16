enum BMPWriter {
    static func fileSize(width: Int, height: Int) throws(JP2KError) -> Int {
        if width < 1 || height < 1 || width > Int(Int32.max) || height > Int(Int32.max) {
            throw .limitExceeded(.memory)
        }
        let (count, a) = width.multipliedReportingOverflow(by: height)
        let (bytes, b) = count.multipliedReportingOverflow(by: 4)
        let (size, c) = bytes.addingReportingOverflow(54)
        if a || b || c || size > UInt32.max { throw .limitExceeded(.memory) }
        return size
    }

    static func write(_ image: PixelImage, maxMemoryBytes: Int) throws(JP2KError) -> [UInt8] {
        let size = try fileSize(width: image.width, height: image.height)
        var budget = MemoryBudget(limit: maxMemoryBytes)
        try budget.reserve(bytes: image.pixels.count)
        var result = try budget.array(repeating: UInt8(0), count: size)
        result[0] = 0x42
        result[1] = 0x4D
        put(UInt32(size), in: &result, at: 2)
        put(54, in: &result, at: 10)
        put(40, in: &result, at: 14)
        put(UInt32(image.width), in: &result, at: 18)
        put(UInt32(bitPattern: Int32(-image.height)), in: &result, at: 22)
        put16(1, in: &result, at: 26)
        put16(32, in: &result, at: 28)
        put(UInt32(size - 54), in: &result, at: 34)
        for i in 0..<(image.width * image.height) {
            let src = i * image.format.channels
            let dst = 54 + i * 4
            switch image.format {
            case .gray8:
                let gray = image.pixels[src]
                result[dst] = gray; result[dst + 1] = gray; result[dst + 2] = gray; result[dst + 3] = 255
            case .grayAlpha8:
                let gray = image.pixels[src]
                result[dst] = gray; result[dst + 1] = gray; result[dst + 2] = gray
                result[dst + 3] = image.pixels[src + 1]
            case .rgb8, .rgba8:
                result[dst] = image.pixels[src + 2]
                result[dst + 1] = image.pixels[src + 1]
                result[dst + 2] = image.pixels[src]
                result[dst + 3] = image.format == .rgba8 ? image.pixels[src + 3] : 255
            }
        }
        return result
    }

    private static func put(_ value: UInt32, in bytes: inout [UInt8], at offset: Int) {
        for i in 0..<4 { bytes[offset + i] = UInt8(truncatingIfNeeded: value >> (i * 8)) }
    }

    private static func put16(_ value: UInt16, in bytes: inout [UInt8], at offset: Int) {
        for i in 0..<2 { bytes[offset + i] = UInt8(truncatingIfNeeded: value >> (i * 8)) }
    }
}
