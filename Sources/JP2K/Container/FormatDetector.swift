enum InputFormat { case jp2, codestream }

enum FormatDetector {
    static func detect(_ bytes: [UInt8]) throws(JP2KError) -> InputFormat {
        if bytes.starts(with: [0, 0, 0, 12, 0x6A, 0x50, 0x20, 0x20, 0x0D, 0x0A, 0x87, 0x0A]) {
            return .jp2
        }
        if bytes.starts(with: [0xFF, 0x4F, 0xFF, 0x51]) { return .codestream }
        throw .invalidContainer(.badSignature)
    }
}
