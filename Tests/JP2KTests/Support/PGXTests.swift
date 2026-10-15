import Foundation
import Testing

struct PGXTests {
    @Test func parsesUnsignedEightBit() throws {
        let image = try PGX.parse(Array("PG ML +8 2 2\n".utf8) + [0, 127, 128, 255])
        #expect(image.width == 2)
        #expect(image.height == 2)
        #expect(image.bits == 8)
        #expect(!image.signed)
        #expect(image.samples == [0, 127, 128, 255])
    }

    @Test func parsesSignedSixteenBitAndLittleEndian() throws {
        let big = try PGX.parse(Array("PG ML -16 2 1\n".utf8) + [0xff, 0xfe, 0x7f, 0xff])
        let little = try PGX.parse(Array("PG LM -16 2 1\n".utf8) + [0xfe, 0xff, 0xff, 0x7f])
        #expect(big.samples == [-2, 32767])
        #expect(little.samples == big.samples)
    }

    @Test func parsesGeneratedReference() throws {
        let url = try #require(Fixtures.url("gray16-40x30_0.pgx"))
        let image = try PGX.parse(Array(Data(contentsOf: url)))
        #expect(image.width == 40)
        #expect(image.height == 30)
        #expect(image.bits == 16)
        #expect(image.samples.count == 1_200)
    }

    @Test func signedTwelveBitFixtureUsesFullRange() throws {
        let referenceURL = try #require(Fixtures.url("signed12-31x19_0.pgx"))
        let bytes = Array(try Data(contentsOf: referenceURL))
        let newline = try #require(bytes.firstIndex(of: 10))
        let header = try #require(String(bytes: bytes[..<newline], encoding: .ascii))
        #expect(header == "PG ML - 12 31 19")
        let reference = try PGX.parse(bytes)
        #expect(reference.bits == 12)
        #expect(reference.signed)
        #expect(reference.samples.contains(-2048))
        #expect(reference.samples.contains(2047))
    }

    @Test func parsesAllGeneratedReferences() throws {
        let manifestURL = try #require(Fixtures.url("MANIFEST.sha256"))
        let manifest = try String(contentsOf: manifestURL, encoding: .utf8)
        for line in manifest.split(separator: "\n") {
            let name = String(line.split(separator: " ").last ?? "")
            guard name.hasSuffix(".pgx") else { continue }
            let url = try #require(Fixtures.url(name))
            let image = try PGX.parse(Array(Data(contentsOf: url)))
            #expect(image.samples.count == image.width * image.height, "\(name)")
        }
    }

    @Test func rejectsMalformedHeaderAndTruncatedData() {
        #expect(throws: PGX.Error.self) { try PGX.parse(Array("PX ML +8 1 1\n".utf8) + [0]) }
        #expect(throws: PGX.Error.self) { try PGX.parse(Array("PG XX +8 1 1\n".utf8) + [0]) }
        #expect(throws: PGX.Error.self) { try PGX.parse(Array("PG ML +0 1 1\n".utf8) + [0]) }
        #expect(throws: PGX.Error.self) { try PGX.parse(Array("PG ML +8 2 1\n".utf8) + [0]) }
    }
}
