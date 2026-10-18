import Foundation
import JP2K
#if canImport(ImageIO)
import CoreGraphics
import ImageIO
#endif

private struct Case {
    let name: String
    let url: URL
    let color: ColorInterpretation
}

/// Linear interpolation between closest ranks, so the median of an even
/// count is the mean of the two middle samples and p90 of few samples
/// lies between the upper ones.
private func percentile(_ samples: [Double], _ fraction: Double) -> Double {
    let sorted = samples.sorted()
    guard let first = sorted.first else { return 0 }
    let position = Double(sorted.count - 1) * fraction
    let lower = Int(position.rounded(.down))
    let upper = min(lower + 1, sorted.count - 1)
    guard lower < sorted.count else { return first }
    let weight = position - Double(lower)
    return sorted[lower] + (sorted[upper] - sorted[lower]) * weight
}

private func time(_ warmups: Int, _ iterations: Int, _ action: () throws -> Void) throws -> (Double, Double) {
    for _ in 0..<warmups { try action() }
    var samples: [Double] = []
    samples.reserveCapacity(iterations)
    for _ in 0..<iterations {
        let start = DispatchTime.now().uptimeNanoseconds
        try action()
        let end = DispatchTime.now().uptimeNanoseconds
        samples.append(Double(end - start) / 1_000_000)
    }
    return (percentile(samples, 0.5), percentile(samples, 0.9))
}

#if canImport(ImageIO)
/// Forces ImageIO's lazy decode by drawing into a bitmap whose layout is as
/// close as CoreGraphics allows to decodePixels' output: 8-bit gray for gray
/// images (same bytes), RGBA for colour (CoreGraphics has no packed RGB8).
private func decodeImageIO(_ data: Data, gray: Bool) throws {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
        throw BenchError.decodeFailed
    }
    let channels = gray ? 1 : 4
    let space = gray ? CGColorSpaceCreateDeviceGray() : CGColorSpaceCreateDeviceRGB()
    let alpha = gray ? CGImageAlphaInfo.none : CGImageAlphaInfo.premultipliedLast
    guard let context = CGContext(data: nil, width: image.width, height: image.height,
                                  bitsPerComponent: 8, bytesPerRow: image.width * channels,
                                  space: space, bitmapInfo: alpha.rawValue) else {
        throw BenchError.decodeFailed
    }
    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
}
#endif

private enum BenchError: Error {
    case missingFixture(String)
    case decodeFailed
}

private func run() throws {
    let arguments = Array(CommandLine.arguments.dropFirst())
    let quick = arguments.contains("--quick")
    let fixtureDirectory = ProcessInfo.processInfo.environment["JP2K_FIXTURES_DIR"]
        .map { URL(fileURLWithPath: $0, isDirectory: true) }
        ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
            .appendingPathComponent("Tests/JP2KTests/Fixtures", isDirectory: true)
    let fixtureNames = quick ? ["gray-378x472-53.jp2"] : [
        "gray-378x472-53.jp2", "gray-378x472-97.jp2",
        "rgb-64-53-mct.jp2", "rgb-64-97.jp2"
    ]
    var cases = fixtureNames.map { Case(name: $0, url: fixtureDirectory.appendingPathComponent($0), color: .container) }
    if !quick, let conformance = ProcessInfo.processInfo.environment["JP2K_CONFORMANCE_DIR"] {
        let directory = URL(fileURLWithPath: conformance, isDirectory: true)
            .appendingPathComponent("input/conformance", isDirectory: true)
        cases.append(Case(name: "p0_07.j2k (2048x2048)", url: directory.appendingPathComponent("p0_07.j2k"),
                          color: .inferFromComponentCount))
        cases.append(Case(name: "file2.jp2 (sYCC 480x640)", url: directory.appendingPathComponent("file2.jp2"),
                          color: .container))
    }
    let warmups = quick ? 1 : 5
    let iterations = quick ? 3 : 50
    print("case,decoder,median_ms,p90_ms")
    for item in cases {
        guard FileManager.default.fileExists(atPath: item.url.path) else { throw BenchError.missingFixture(item.url.path) }
        let data = try Data(contentsOf: item.url)
        let bytes = [UInt8](data)
        let swift = try time(warmups, iterations) {
            let image = try JP2KDecoder().decodePixels(bytes, color: item.color)
            _ = image.pixels.count
        }
        print("\(item.name),JP2K,\(String(format: "%.3f", swift.0)),\(String(format: "%.3f", swift.1))")
        #if canImport(ImageIO)
        let format = try JP2KDecoder().decodePixels(bytes, color: item.color).format
        let gray = format == .gray8
        let imageIO = try time(warmups, iterations) { try decodeImageIO(data, gray: gray) }
        print("\(item.name),ImageIO,\(String(format: "%.3f", imageIO.0)),\(String(format: "%.3f", imageIO.1))")
        #endif
    }
}

do {
    try run()
} catch {
    FileHandle.standardError.write(Data("jp2k-bench: \(error)\n".utf8))
    exit(1)
}
