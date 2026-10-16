/// An eight-bit interleaved image with no row padding.
public struct PixelImage: ~Copyable, Sendable {
    public let width: Int
    public let height: Int
    public let format: PixelFormat
    public let pixels: [UInt8]
    public let colorWasInferred: Bool
    private let maxMemoryBytes: Int

    internal init(width: Int, height: Int, format: PixelFormat, pixels: [UInt8],
                  colorWasInferred: Bool, maxMemoryBytes: Int) {
        self.width = width
        self.height = height
        self.format = format
        self.pixels = pixels
        self.colorWasInferred = colorWasInferred
        self.maxMemoryBytes = maxMemoryBytes
    }

    /// Writes a top-down 32-bit BGRA BMP. File-size overflow is a memory-limit error.
    public borrowing func bmp() throws(JP2KError) -> [UInt8] {
        try BMPWriter.write(self, maxMemoryBytes: maxMemoryBytes)
    }
}

public enum PixelFormat: Sendable {
    case gray8, grayAlpha8, rgb8, rgba8

    var channels: Int {
        switch self {
        case .gray8: 1
        case .grayAlpha8: 2
        case .rgb8: 3
        case .rgba8: 4
        }
    }
}
