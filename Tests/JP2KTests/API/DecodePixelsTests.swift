import Foundation
import Testing
@testable import JP2K

struct DecodePixelsTests {
    private func fixture(_ name: String) throws -> [UInt8] {
        Array(try Data(contentsOf: #require(Fixtures.url(name))))
    }

    private func minimumMemory(for bytes: [UInt8], color: ColorInterpretation = .container,
                               region: Region? = nil) async throws -> Int {
        var lower = 0
        var upper = Limits().maxMemoryBytes
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            var limits = Limits()
            limits.maxMemoryBytes = middle
            do {
                let image = try await JP2KDecoder(limits: limits).decodePixels(bytes, color: color, region: region)
                #expect(!image.pixels.isEmpty)
                upper = middle
            } catch {
                if error == .limitExceeded(.memory) { lower = middle + 1 } else { throw error }
            }
        }
        return lower
    }

    @Test func regionBudgetChargesOnlyCroppedPixels() async throws {
        let bytes = try fixture("rgb-64-53-mct.jp2")
        let region = Region.pixels(x: 3, y: 5, width: 1, height: 1)
        let fullMinimum = try await minimumMemory(for: bytes)
        let cropMinimum = try await minimumMemory(for: bytes, region: region)
        #expect(cropMinimum < fullMinimum)
        // Allocator rounding makes success non-monotonic within a few bytes of
        // a boundary, so test well inside the gap: the crop minimum plus a
        // quarter of the full RGB buffer (64x64x3 bytes) fits a 1-pixel crop
        // but not the full-image pixel buffer.
        let fullPixelBytes = 64 * 64 * 3
        #expect(cropMinimum + fullPixelBytes / 2 < fullMinimum)
        var limits = Limits()
        limits.maxMemoryBytes = cropMinimum + fullPixelBytes / 4
        let cropped = try await JP2KDecoder(limits: limits).decodePixels(bytes, region: region)
        #expect(cropped.pixels.count == 3)
        await #expect(throws: JP2KError.limitExceeded(.memory)) {
            _ = try await JP2KDecoder(limits: limits).decodePixels(bytes)
        }
    }

    @Test func decoderBudgetCanAllowPixelsButRejectBMP() async throws {
        let bytes = try fixture("subsampled-4x.j2k")
        let minimum = try await minimumMemory(for: bytes, color: .assume(.gray8))
        var limits = Limits()
        // glibc's allocation rounding varies from run to run, so the exact
        // minimum can fail on a second decode; a small margin keeps the limit
        // well short of what the pixels plus the BMP need.
        limits.maxMemoryBytes = minimum + 1_024
        let image = try await JP2KDecoder(limits: limits).decodePixels(bytes, color: .assume(.gray8))
        let bmpBytes = 54 + image.width * image.height * 4
        try #require(image.pixels.count + bmpBytes > limits.maxMemoryBytes)
        #expect(throws: JP2KError.limitExceeded(.memory)) { _ = try image.bmp() }
    }

    @Test func containerAndExplicitColour() async throws {
        let gray = try await JP2KDecoder().decodePixels(fixture("gray-378x472-53.jp2"))
        #expect(gray.format == .gray8)
        #expect(gray.pixels.count == gray.width * gray.height)
        let rgb = try await JP2KDecoder().decodePixels(fixture("rgb-64-53-mct.jp2"))
        #expect(rgb.format == .rgb8)
        let raw = try fixture("gray-378x472-53.j2k")
        await #expect(throws: JP2KError.unsupported(.unspecifiedColour)) {
            try await JP2KDecoder().decodePixels(raw)
        }
        await #expect(throws: JP2KError.unsupported(.componentCount)) {
            try await JP2KDecoder().decodePixels(raw, color: .assume(.rgb8))
        }
        let assumed = try await JP2KDecoder().decodePixels(raw, color: .assume(.gray8))
        let inferred = try await JP2KDecoder().decodePixels(raw, color: .inferFromComponentCount)
        #expect(assumed.pixels == gray.pixels)
        let wasInferred = inferred.colorWasInferred
        #expect(wasInferred)
    }

    @Test func regionsAndBMP() async throws {
        let bytes = try fixture("rgb-64-53-mct.jp2")
        let full = try await JP2KDecoder().decodePixels(bytes)
        let crop = try await JP2KDecoder().decodePixels(bytes, region: .pixels(x: 3, y: 5, width: 11, height: 7))
        #expect(crop.width == 11 && crop.height == 7)
        for y in 0..<7 {
            #expect(Array(crop.pixels[y * 33..<(y + 1) * 33]) ==
                    Array(full.pixels[((y + 5) * 64 + 3) * 3..<((y + 5) * 64 + 14) * 3]))
        }
        let half = try await JP2KDecoder().decodePixels(bytes, region: .fraction(left: 0, top: 0, right: 0.5, bottom: 0.5))
        #expect(half.width == 32 && half.height == 32)
        await #expect(throws: JP2KError.regionOutOfBounds) {
            try await JP2KDecoder().decodePixels(bytes, region: .pixels(x: 64, y: 0, width: 1, height: 1))
        }
        await #expect(throws: JP2KError.regionOutOfBounds) {
            try await JP2KDecoder().decodePixels(bytes, region: .fraction(left: .nan, top: 0, right: 1, bottom: 1))
        }
        for invalid in [Region.pixels(x: 0, y: 0, width: 0, height: 1),
                        .pixels(x: -1, y: 0, width: 1, height: 1),
                        .pixels(x: 63, y: 63, width: 2, height: 1),
                        .fraction(left: 0.5, top: 0, right: 0.5, bottom: 1),
                        .fraction(left: 0, top: 0, right: .infinity, bottom: 1)] {
            await #expect(throws: JP2KError.regionOutOfBounds) {
                try await JP2KDecoder().decodePixels(bytes, region: invalid)
            }
        }
        let edge = try await JP2KDecoder().decodePixels(bytes, region: .pixels(x: 63, y: 63, width: 1, height: 1))
        #expect(Array(edge.pixels) == Array(full.pixels.suffix(3)))
        let bmp = try full.bmp()
        #expect(Array(bmp.prefix(2)) == [0x42, 0x4D])
        let bmpSize = 54 + 64 * 64 * 4
        #expect(bmp.count == bmpSize)
        #expect(Array(bmp[18..<22]) == [64, 0, 0, 0])
        #expect(Array(bmp[22..<26]) == [0xC0, 0xFF, 0xFF, 0xFF])
        #expect(Array(bmp[26..<30]) == [1, 0, 32, 0])
        #expect(Array(bmp[54..<58]) == [full.pixels[2], full.pixels[1], full.pixels[0], 255])
    }
}
