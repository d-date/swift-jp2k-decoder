import Foundation

struct PGX {
    enum Error: Swift.Error { case invalidHeader, invalidSamples }

    let width: Int
    let height: Int
    let bits: Int
    let signed: Bool
    let samples: [Int32]

    static func parse(_ bytes: [UInt8]) throws -> PGX {
        guard let newline = bytes.firstIndex(of: 10), newline < 128,
              let header = String(bytes: bytes[..<newline], encoding: .ascii) else {
            throw Error.invalidHeader
        }
        let fields = header.split(separator: " ", omittingEmptySubsequences: true)
        guard fields.count == 5 || fields.count == 6 else { throw Error.invalidHeader }
        let splitSign = fields.count == 6
        let signField = fields[2]
        let bitField = splitSign ? fields[3] : fields[2].dropFirst()
        let widthField = splitSign ? fields[4] : fields[3]
        let heightField = splitSign ? fields[5] : fields[4]
        guard fields[0] == "PG", fields[1] == "ML" || fields[1] == "LM",
              let sign = signField.first, sign == "+" || sign == "-",
              splitSign ? signField.count == 1 : signField.count > 1,
              let bits = Int(bitField), (1...32).contains(bits),
              let width = Int(widthField), width > 0,
              let height = Int(heightField), height > 0 else { throw Error.invalidHeader }
        let (count, overflow) = width.multipliedReportingOverflow(by: height)
        let stride = bits <= 8 ? 1 : (bits <= 16 ? 2 : 4)
        let (byteCount, byteOverflow) = count.multipliedReportingOverflow(by: stride)
        guard !overflow, !byteOverflow, byteCount <= bytes.count - newline - 1,
              byteCount == bytes.count - newline - 1 else { throw Error.invalidSamples }
        var samples: [Int32] = []
        samples.reserveCapacity(count)
        let littleEndian = fields[1] == "LM"
        for index in 0..<count {
            let start = newline + 1 + index * stride
            var value: UInt32 = 0
            for byte in 0..<stride {
                let offset = littleEndian ? (start + stride - 1 - byte) : (start + byte)
                value = (value << 8) | UInt32(bytes[offset])
            }
            let mask: UInt32 = bits == 32 ? UInt32.max : (UInt32(1) << bits) - 1
            value &= mask
            if sign == "-", (value & (UInt32(1) << (bits - 1))) != 0 {
                value |= ~mask
            }
            samples.append(Int32(bitPattern: value))
        }
        return PGX(width: width, height: height, bits: bits, signed: sign == "-", samples: samples)
    }
}
