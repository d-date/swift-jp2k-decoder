#if canImport(ImageIO)
import CoreGraphics
import Foundation
import ImageIO
import JP2K
import Testing

private struct ComparisonCase {
    let name: String
    let tolerance: Int
    let conformance: Bool
    let compareAlpha: Bool
}

private enum ComparisonError: Error {
    case imageSource(String)
    case bitmap(String)
}

private func inputURL(_ item: ComparisonCase) throws -> URL {
    if item.conformance {
        let root = try #require(ProcessInfo.processInfo.environment["JP2K_CONFORMANCE_DIR"])
        return URL(fileURLWithPath: root, isDirectory: true)
            .appendingPathComponent("input/conformance").appendingPathComponent(item.name)
    }
    let path = ProcessInfo.processInfo.environment["JP2K_FIXTURES_DIR"]
        .map { URL(fileURLWithPath: $0, isDirectory: true) }
        ?? URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("JP2KTests/Fixtures")
    return path.appendingPathComponent(item.name)
}

private func imageIOPixels(_ data: Data, name: String, gray: Bool) throws -> (Int, Int, [UInt8]) {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
        throw ComparisonError.imageSource(name)
    }
    let channels = gray ? 1 : 4
    let space = gray ? CGColorSpaceCreateDeviceGray() : CGColorSpaceCreateDeviceRGB()
    let bitmapInfo = gray ? CGImageAlphaInfo.none.rawValue : CGImageAlphaInfo.premultipliedLast.rawValue
    let rowBytes = image.width * channels
    guard let context = CGContext(data: nil, width: image.width, height: image.height,
                                  bitsPerComponent: 8, bytesPerRow: rowBytes,
                                  space: space, bitmapInfo: bitmapInfo) else {
        throw ComparisonError.bitmap(name)
    }
    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    guard let pointer = context.data else { throw ComparisonError.bitmap(name) }
    let pixels = Array(UnsafeBufferPointer(start: pointer.assumingMemoryBound(to: UInt8.self),
                                           count: rowBytes * image.height))
    return (image.width, image.height, pixels)
}

@Test func fixturePixelsMatchImageIO() async throws {
    let cases = [
        ComparisonCase(name: "gray-378x472-53.jp2", tolerance: 0, conformance: false, compareAlpha: true),
        ComparisonCase(name: "gray-378x472-97.jp2", tolerance: 2, conformance: false, compareAlpha: true),
        ComparisonCase(name: "rgb-64-53-mct.jp2", tolerance: 0, conformance: false, compareAlpha: true),
        ComparisonCase(name: "rgb-64-97.jp2", tolerance: 2, conformance: false, compareAlpha: true),
        // This fixture has four components without cdef; ImageIO treats the fourth as opaque.
        ComparisonCase(name: "rgba-33x17.jp2", tolerance: 0, conformance: false, compareAlpha: false),
        // Both decoders are lossless at native depth; their 16-to-8-bit rounding differs by one.
        ComparisonCase(name: "gray16-40x30.jp2", tolerance: 1, conformance: false, compareAlpha: true),
    ]
    for item in cases { try await compare(item) }
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["JP2K_CONFORMANCE_DIR"] != nil))
func conformancePixelsMatchImageIO() async throws {
    // file5, file7 and file8 carry ICC profiles, which decodePixels(.container)
    // reports as unsupported by design (ImageIO applies them), so they are not
    // pixel-compared. file1/4/9 are lossless 8-bit and must match exactly;
    // file6 is lossless 12-bit, whose 12-to-8-bit rounding differs by one.
    let cases = [
        ComparisonCase(name: "file1.jp2", tolerance: 0, conformance: true, compareAlpha: true),
        ComparisonCase(name: "file2.jp2", tolerance: 3, conformance: true, compareAlpha: true),
        ComparisonCase(name: "file3.jp2", tolerance: 3, conformance: true, compareAlpha: true),
        ComparisonCase(name: "file4.jp2", tolerance: 0, conformance: true, compareAlpha: true),
        ComparisonCase(name: "file6.jp2", tolerance: 1, conformance: true, compareAlpha: true),
        ComparisonCase(name: "file9.jp2", tolerance: 0, conformance: true, compareAlpha: true),
    ]
    for item in cases { try await compare(item) }
}

private func compare(_ item: ComparisonCase) async throws {
    let data = try Data(contentsOf: inputURL(item))
    let image = try await JP2KDecoder().decodePixels([UInt8](data))
    let gray: Bool
    switch image.format {
    case .gray8: gray = true
    default: gray = false
    }
    let (width, height, reference) = try imageIOPixels(data, name: item.name, gray: gray)
    #expect(image.width == width, "\(item.name)")
    #expect(image.height == height, "\(item.name)")
    let channels = gray ? 1 : 4
    let sourceChannels: Int
    switch image.format {
    case .gray8: sourceChannels = 1
    case .grayAlpha8: sourceChannels = 2
    case .rgb8: sourceChannels = 3
    case .rgba8: sourceChannels = 4
    }
    #expect(reference.count == width * height * channels, "\(item.name)")
    #expect(image.pixels.count == width * height * sourceChannels, "\(item.name)")
    var maximum = 0
    for pixel in 0..<(width * height) {
        for channel in 0..<channels {
            if channel == 3 && !item.compareAlpha { continue }
            let actual: Int
            if gray { actual = Int(image.pixels[pixel]) }
            else if channel == 3 {
                actual = sourceChannels == 4 ? Int(image.pixels[pixel * sourceChannels + 3]) : 255
            } else if sourceChannels == 1 || sourceChannels == 2 {
                actual = Int(image.pixels[pixel * sourceChannels])
            } else { actual = Int(image.pixels[pixel * sourceChannels + channel]) }
            maximum = max(maximum, abs(actual - Int(reference[pixel * channels + channel])))
        }
    }
    #expect(maximum <= item.tolerance, "\(item.name): maximum difference \(maximum)")
}
#endif
