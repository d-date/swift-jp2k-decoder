import Testing
@testable import JP2K

struct BMPWriterTests {
    @Test func budgetIncludesPixelsAndBMP() throws {
        let pixels: [UInt8] = [10, 20, 30]
        let required = try BMPWriter.fileSize(width: 1, height: 1) + pixels.count
        let image = PixelImage(width: 1, height: 1, format: .rgb8, pixels: pixels,
                               colorWasInferred: false, maxMemoryBytes: required - 1)
        #expect(throws: JP2KError.limitExceeded(.memory)) { try image.bmp() }
    }

    @Test func fileSizeOverflow() {
        #expect(throws: JP2KError.limitExceeded(.memory)) {
            try BMPWriter.fileSize(width: 40_000, height: 40_000)
        }
    }
}
