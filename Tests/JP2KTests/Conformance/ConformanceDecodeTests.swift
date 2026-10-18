import Foundation
import Testing
@testable import JP2K

struct ConformanceDecodeTests {
    private static let nonregressionNames = [
        "a1_mono", "a2_colr", "a3_mono", "a4_colr", "a5_mono", "a6_mono_colr",
        "b1_mono", "b2_mono", "b3_mono", "c1_mono", "c2_mono", "d1_colr",
        "d2_colr", "e1_colr", "e2_colr", "f1_mono", "f2_mono", "g1_colr",
        "g2_colr", "g3_colr", "g4_colr"
    ]

    private var decoder: JP2KDecoder {
        var limits = Limits()
        limits.maxComponents = 16_384
        limits.maxPixels = 1 << 26
        limits.maxMemoryBytes = 2 << 30
        limits.maxInputBytes = 256 << 20
        return JP2KDecoder(limits: limits)
    }

    @Test(arguments: Conformance.class1.filter { $0.resFactor == 0 })
    func classOne(item: ConformanceCase) async throws {
        guard let root = Conformance.root() else { return }
        let input = try Data(contentsOf: Conformance.inputURL(item, root: root))
        let image = try await decoder.decodeComponents(Array(input))
        // The OpenJPEG conformance table checks only four of p0_13's 257 components.
        #expect(image.components.count == (item.name == "p0_13.j2k" ? 257 : item.componentCount))
        for index in 0..<item.componentCount {
            let reference = try PGX.parse(Array(Data(contentsOf: Conformance.referenceURL(item, component: index, root: root))))
            let actual = image.components[index]
            #expect(image.info.components[index].width == reference.width)
            #expect(image.info.components[index].height == reference.height)
            #expect(actual.count == reference.samples.count)
            var peak = 0
            var sum = 0.0
            for (value, expected) in zip(actual, reference.samples) {
                let error = abs(Int(value) - Int(expected))
                peak = max(peak, error)
                sum += Double(error) * Double(error)
            }
            let mse = sum / Double(reference.samples.count)
            print("\(item.name) component \(index): peak \(peak) / \(item.peak[index]), MSE \(mse) / \(item.mse[index])")
            #expect(Double(peak) <= item.peak[index])
            #expect(mse <= item.mse[index])
        }
    }

    @Test(arguments: nonregressionNames)
    func nonregressionPixelsMeetOpenJPEGTolerances(name: String) async throws {
        guard let root = Conformance.root() else { return }
        let input = root.appendingPathComponent("input/conformance/\(name).j2c")
        let baselineDirectory = root.appendingPathComponent("baseline/conformance")
        let bytes = Array(try Data(contentsOf: input))
        let image = try await decoder.decodeComponents(bytes)
        var context = DecodeContext(limits: decoder.limits)
        let origin = try MainHeaderParser.parse(bytes, range: 0..<bytes.count, context: &context).geometry
        let paths = name == "a6_mono_colr"
            ? (0..<4).map { baselineDirectory.appendingPathComponent("\(name)_\($0).pgm") }
            : [baselineDirectory.appendingPathComponent("\(name).ppm")]
        let baselines = try paths.map { try Self.pnm(Array(Data(contentsOf: $0))) }
        let channels = baselines.flatMap(\.components)
        #expect(channels.count == image.components.count)
        for baseline in baselines {
            #expect(image.info.width == baseline.width)
            #expect(image.info.height == baseline.height)
        }
        for index in channels.indices {
            let actual = Self.upsampled(image.components[index], info: image.info.components[index],
                                        imageWidth: image.info.width, imageHeight: image.info.height,
                                        imageX0: origin.x0, imageY0: origin.y0)
            let expected = channels[index]
            #expect(actual.count == expected.count)
            var peak = 0
            var squared = 0.0
            for (value, reference) in zip(actual, expected) {
                let error = abs(Int(value) - Int(reference))
                peak = max(peak, error)
                squared += Double(error * error)
            }
            let mse = squared / Double(expected.count)
            // OpenJPEG's own threshold is PEAK <= 4, MSE <= 1, but these
            // baselines are reproduced exactly, so any pixel drift must fail.
            print("\(name) component \(index): peak \(peak), MSE \(mse) (exact match required)")
            #expect(peak == 0)
            #expect(mse == 0)
        }
    }

    private struct PNM {
        let width: Int
        let height: Int
        let components: [[Int32]]
    }

    @Test func pnmParserReadsSixteenBitAndASCIIChannels() throws {
        let sixteen = try Self.pnm(Array("P5\n2 1\n65535\n".utf8) + [0x01, 0x02, 0xFF, 0xFE])
        #expect(sixteen.components == [[258, 65534]])
        let ascii = try Self.pnm(Array("P3\n# comment\n1 1\n255\n7 8 9\n".utf8))
        #expect(ascii.components == [[7], [8], [9]])
    }

    private static func upsampled(_ samples: [Int32], info: ComponentInfo,
                                  imageWidth: Int, imageHeight: Int,
                                  imageX0: Int, imageY0: Int) -> [Int32] {
        let xoff = info.dx * info.x0 - imageX0
        let yoff = info.dy * info.y0 - imageY0
        var output = [Int32](repeating: 0, count: imageWidth * imageHeight)
        for y in yoff..<imageHeight {
            for x in xoff..<imageWidth {
                let sourceY = min((y - yoff) / info.dy, info.height - 1)
                let sourceX = min((x - xoff) / info.dx, info.width - 1)
                output[y * imageWidth + x] = samples[sourceY * info.width + sourceX]
            }
        }
        return output
    }

    private static func pnm(_ bytes: [UInt8]) throws -> PNM {
        var tokens: [String] = []
        var offset = 0
        while tokens.count < 4 && offset < bytes.count {
            if bytes[offset] == 35 {
                while offset < bytes.count && bytes[offset] != 10 { offset += 1 }
            } else if bytes[offset] <= 32 {
                offset += 1
            } else {
                let start = offset
                while offset < bytes.count && bytes[offset] > 32 { offset += 1 }
                tokens.append(String(decoding: bytes[start..<offset], as: UTF8.self))
            }
        }
        guard tokens.count == 4, ["P2", "P3", "P5", "P6"].contains(tokens[0]),
              let width = Int(tokens[1]), let height = Int(tokens[2]),
              let maximum = Int(tokens[3]), width > 0, height > 0, (1...65535).contains(maximum) else {
            throw PGX.Error.invalidHeader
        }
        let count = tokens[0] == "P3" || tokens[0] == "P6" ? 3 : 1
        let sampleCount = width * height * count
        let values: [Int32]
        if tokens[0] == "P2" || tokens[0] == "P3" {
            values = try Self.asciiSamples(bytes[offset...], count: sampleCount)
        } else {
            guard offset < bytes.count, bytes[offset] <= 32 else { throw PGX.Error.invalidHeader }
            offset += 1
            let sampleBytes = maximum < 256 ? 1 : 2
            guard bytes.count - offset == sampleCount * sampleBytes else { throw PGX.Error.invalidHeader }
            if sampleBytes == 1 {
                values = bytes[offset...].map(Int32.init)
            } else {
                values = stride(from: offset, to: bytes.count, by: 2).map {
                    Int32(bytes[$0]) << 8 | Int32(bytes[$0 + 1])
                }
            }
        }
        var components = Array(repeating: [Int32](), count: count)
        for channel in 0..<count {
            components[channel] = stride(from: channel, to: values.count, by: count).map { values[$0] }
        }
        return PNM(width: width, height: height, components: components)
    }

    private static func asciiSamples(_ bytes: ArraySlice<UInt8>, count: Int) throws -> [Int32] {
        var values: [Int32] = []
        var offset = bytes.startIndex
        while offset < bytes.endIndex {
            if bytes[offset] == 35 {
                while offset < bytes.endIndex && bytes[offset] != 10 { offset += 1 }
            } else if bytes[offset] <= 32 {
                offset += 1
            } else {
                let start = offset
                while offset < bytes.endIndex && bytes[offset] > 32 { offset += 1 }
                guard let value = Int32(String(decoding: bytes[start..<offset], as: UTF8.self)) else {
                    throw PGX.Error.invalidHeader
                }
                values.append(value)
            }
        }
        guard values.count == count else { throw PGX.Error.invalidHeader }
        return values
    }
}
