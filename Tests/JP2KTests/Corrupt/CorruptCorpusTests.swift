import Foundation
import Testing
@testable import JP2K

struct CorruptCorpusTests {
    private var exhaustive: Bool { ProcessInfo.processInfo.environment["JP2K_EXHAUSTIVE"] == "1" }

    private func fixtureNames() throws -> [String] {
        let url = try #require(Fixtures.url("MANIFEST.sha256"))
        let manifest = try String(contentsOf: url, encoding: .utf8)
        return manifest.split(separator: "\n").compactMap { line in
            guard let name = line.split(separator: " ").last else { return nil }
            let value = String(name)
            return (value.hasSuffix(".j2k") || value.hasSuffix(".jp2")) && !value.hasPrefix("corrupt/")
                ? value : nil
        }.sorted()
    }

    private func decodeBoth(_ bytes: [UInt8], name: String, timed: Bool) async {
        let start = Date()
        let decoder = JP2KDecoder()
        do { _ = try await decoder.decodeComponents(bytes) } catch { /* Typed decoder error is expected. */ }
        do { _ = try await decoder.decodePixels(bytes, color: .inferFromComponentCount) }
        catch { /* Typed decoder error is expected. */ }
        if timed { #expect(Date().timeIntervalSince(start) < 2, "Slow corrupt case: \(name)") }
    }

    @Test func truncationSweep() async throws {
        let names = try exhaustive ? fixtureNames() : ["levels-0.j2k", "rgba-33x17.jp2"]
        for name in names {
            let bytes = Array(try Data(contentsOf: #require(Fixtures.url(name))))
            let lengths: [Int]
            if exhaustive {
                if bytes.count <= 4_096 { lengths = Array(0..<bytes.count) }
                else {
                    lengths = Array(Set((0..<257).map { $0 * bytes.count / 257 }
                        + Array(max(0, bytes.count - 64)..<bytes.count))).sorted()
                }
            } else {
                lengths = Array(Set((0..<80).map { $0 * bytes.count / 80 })).sorted()
            }
            for length in lengths {
                await decodeBoth(Array(bytes.prefix(length)), name: "\(name) prefix \(length)", timed: exhaustive)
            }
        }
    }

    @Test func bitFlipSweep() async throws {
        let names = try exhaustive ? fixtureNames() : ["levels-0.j2k", "rgba-33x17.jp2"]
        for name in names {
            let source = Array(try Data(contentsOf: #require(Fixtures.url(name))))
            var state: UInt64 = 0xA076_1D64_78BD_642F
            for iteration in 0..<(exhaustive ? 2_000 : 80) {
                state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                let offset = Int(state % UInt64(source.count))
                let bit = UInt8(1 << ((state >> 32) & 7))
                var bytes = source
                bytes[offset] ^= bit
                await decodeBoth(bytes, name: "\(name) flip \(iteration) at \(offset)", timed: exhaustive)
            }
        }
    }

    @Test(arguments: [
        ("huge-siz.j2k", JP2KError.limitExceeded(.pixels)),
        ("huge-box.jp2", JP2KError.invalidContainer(.badBoxLength)),
        ("packet-header.j2k", JP2KError.invalidCodestream(.badPacketHeader))
    ])
    func craftedRejections(name: String, expected: JP2KError) async throws {
        let bytes = Array(try Data(contentsOf: #require(Fixtures.url("corrupt/\(name)"))))
        await #expect(throws: expected) { _ = try await JP2KDecoder().decodeComponents(bytes) }
    }

    @Test func packetHeaderFixtureReachesSegmentLengthWidth() async throws {
        let bytes = Array(try Data(contentsOf: #require(Fixtures.url("corrupt/packet-header.j2k"))))
        let sod = try #require(bytes.indices.dropLast().first { bytes[$0] == 0xFF && bytes[$0 + 1] == 0x93 })
        var bits = PacketBitReader(bytes, range: (sod + 2)..<bytes.count)
        #expect(try bits.read(bits: 1) == 1) // packet present
        #expect(try bits.read(bits: 1) == 1) // first block included
        #expect(try bits.read(bits: 1) == 1) // zero bitplanes
        let passes = try PacketDecoder.numberOfPasses(&bits)
        #expect(passes == 2)
        let increment = try PacketDecoder.commaCode(&bits)
        #expect(increment == 29)
        // Lblock is 3+29=32, still permitted. With two passes, the segment
        // length field needs 32+floor(log2(2))=33 bits. No body or pass cap
        // check can reject this packet before the length-width check.
        #expect(throws: JP2KError.invalidCodestream(.badPacketHeader)) {
            _ = try PacketDecoder.segmentLengthBitCount(3 + increment, passes: passes)
        }
        await #expect(throws: JP2KError.invalidCodestream(.badPacketHeader)) {
            _ = try await JP2KDecoder().decodeComponents(bytes)
        }
    }

    @Test func tilePartFlood() async throws {
        let bytes = Array(try Data(contentsOf: #require(Fixtures.url("corrupt/tile-part-flood.j2k"))))
        var limits = Limits()
        limits.maxTileParts = 9_999
        await #expect(throws: JP2KError.limitExceeded(.tileParts)) {
            _ = try await JP2KDecoder(limits: limits).decodeComponents(bytes)
        }
    }

    @Test func ppmFlood() throws {
        let bytes = Array(try Data(contentsOf: #require(Fixtures.url("corrupt/ppm-flood.j2k"))))
        var limits = Limits()
        limits.maxMarkerDataBytes = 4_096
        #expect(throws: JP2KError.limitExceeded(.markerData)) {
            _ = try JP2KDecoder(limits: limits).readInfo(bytes)
        }
    }
}
