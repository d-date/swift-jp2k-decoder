import Foundation
import Testing
@testable import JP2K

struct MultiTileTests {
    private func parts(_ bytes: [UInt8]) throws -> (prefix: [UInt8], chunks: [(tile: Int, bytes: [UInt8])]) {
        var context = DecodeContext(limits: Limits())
        var offset = try MainHeaderParser.parse(bytes, range: 0..<bytes.count,
                                                context: &context).firstTilePartOffset
        let prefix = Array(bytes[..<offset])
        var chunks: [(tile: Int, bytes: [UInt8])] = []
        while offset + 12 <= bytes.count, bytes[offset] == 0xFF, bytes[offset + 1] == 0x90 {
            let tile = (Int(bytes[offset + 4]) << 8) | Int(bytes[offset + 5])
            let length = (Int(bytes[offset + 6]) << 24) | (Int(bytes[offset + 7]) << 16) |
                         (Int(bytes[offset + 8]) << 8) | Int(bytes[offset + 9])
            let end = offset + length
            guard length >= 14, end <= bytes.count else { throw JP2KError.invalidCodestream(.badSOT) }
            chunks.append((tile, Array(bytes[offset..<end])))
            offset = end
        }
        return (prefix, chunks)
    }

    @Test(arguments: [
        "tiles-127x61.j2k", "tileparts.j2k", "two-tiles-127x61.j2k", "poc.j2k", "precincts.j2k", "layers.j2k",
        "roi.j2k", "subsampled.j2k", "subsampled-4x.j2k", "subsampled-rgb.j2k", "sop-eph.j2k", "origin.j2k",
        "empty-leading-tile.j2k",
        "prog-lrcp.j2k", "prog-rlcp.j2k", "prog-rpcl.j2k", "prog-pcrl.j2k", "prog-cprl.j2k",
        "modes-bypass.j2k", "modes-reset.j2k", "modes-termall.j2k", "modes-vcausal.j2k",
        "modes-pterm.j2k", "modes-segsym.j2k", "modes-all.j2k"
    ])
    func losslessFixtureMatchesOpenJPEG(name: String) async throws {
        let input = Array(try Data(contentsOf: #require(Fixtures.url(name))))
        let image = try await JP2KDecoder().decodeComponents(input)
        let stem = String(name.split(separator: ".").first ?? "")
        // Expected component count comes from the OpenJPEG reference files
        // (<stem>_0.pgx, <stem>_1.pgx, ...), not from the decoder's own output.
        var referenceCount = 0
        while let url = Fixtures.url("\(stem)_\(referenceCount).pgx"),
              FileManager.default.fileExists(atPath: url.path) {
            referenceCount += 1
        }
        #expect(referenceCount > 0)
        #expect(image.components.count == referenceCount)
        #expect(image.info.components.count == referenceCount)
        for index in image.components.indices {
            let reference = try PGX.parse(Array(Data(contentsOf: #require(Fixtures.url("\(stem)_\(index).pgx")))))
            #expect(image.info.components[index].width == reference.width)
            #expect(image.info.components[index].height == reference.height)
            #expect(image.components[index].count == image.info.components[index].width * image.info.components[index].height)
            #expect(image.components[index] == reference.samples)
        }
    }

    @Test func missingSecondTileIsRejected() async throws {
        let input = Array(try Data(contentsOf: #require(Fixtures.url("two-tiles-127x61.j2k"))))
        let (prefix, chunks) = try parts(input)
        #expect(Set(chunks.map(\.tile)) == [0, 1])
        #expect(chunks.contains { $0.tile == 1 })
        var damaged = prefix
        for chunk in chunks where chunk.tile != 1 { damaged.append(contentsOf: chunk.bytes) }
        damaged.append(contentsOf: [0xFF, 0xD9])
        await #expect(throws: JP2KError.invalidCodestream(.badTilePart)) {
            _ = try await JP2KDecoder().decodeComponents(damaged)
        }
    }

    @Test func absentTileWithoutComponentSamplesDecodes() async throws {
        let bytes = Array(try Data(contentsOf: #require(Fixtures.url("empty-leading-tile.j2k"))))
        var context = DecodeContext(limits: Limits())
        let header = try MainHeaderParser.parse(bytes, range: 0..<bytes.count, context: &context)
        #expect(header.geometry.tilesAcross == 2)
        let firstTileRight = header.geometry.tileX0 + header.geometry.tileWidth
        let component = try #require(header.geometry.components.first)
        #expect(try Checked.ceilDiv(header.geometry.x0, component.dx) ==
                Checked.ceilDiv(firstTileRight, component.dx))
        let tiles = try TilePartParser.parse(bytes, header: header, context: &context)
        #expect(tiles.map(\.index) == [1])
        let reference = try PGX.parse(Array(Data(contentsOf: #require(Fixtures.url("empty-leading-tile_0.pgx")))))
        let image = try await JP2KDecoder().decodeComponents(bytes)
        #expect(image.components.count == 1)
        #expect(image.components[0] == reference.samples)
    }

    @Test func tilePartsMayBeInterleavedAcrossTiles() async throws {
        let input = Array(try Data(contentsOf: #require(Fixtures.url("two-tiles-127x61.j2k"))))
        let expected = try await JP2KDecoder().decodeComponents(input)
        let (prefix, chunks) = try parts(input)
        #expect(chunks.count == 10)
        var interleaved = prefix
        for ordinal in 0..<5 {
            for tile in 0..<2 {
                let chunk = try #require(chunks.first(where: { $0.tile == tile && Int($0.bytes[10]) == ordinal }))
                interleaved.append(contentsOf: chunk.bytes)
            }
        }
        interleaved.append(contentsOf: [0xFF, 0xD9])
        #expect(try await JP2KDecoder().decodeComponents(interleaved).components == expected.components)
    }
}
