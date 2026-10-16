import Foundation
import Testing
@testable import JP2K

private func decodePacketFixture(_ name: String, limits: Limits = Limits()) throws -> (TileData, TileGeometry) {
    let bytes = Array(try Data(contentsOf: try #require(Fixtures.url(name))))
    var context = DecodeContext(limits: limits)
    try context.budget.reserve(bytes: bytes.count)
    let header = try MainHeaderParser.parse(bytes, range: 0..<bytes.count, context: &context)
    let tile = try #require(TilePartParser.parse(bytes, header: header, context: &context).first)
    var geometry = try TileGeometryBuilder.build(tile: tile, header: header, context: &context)
    let positions = try PacketIterator.positions(geometry: geometry, parameters: tile.parameters,
                                                 header: header, tileIndex: tile.index, context: &context)
    try PacketDecoder.decodeTile(tile, geometry: &geometry, positions: positions, context: &context)
    return (tile, geometry)
}

@Test func packetBitStuffingAndBounds() throws {
    var bits = PacketBitReader([0xFF, 0x7F, 0x80], range: 0..<3)
    #expect(try bits.read(bits: 8) == 255)
    #expect(try bits.read(bits: 7) == 127)
    #expect(try bits.read(bits: 1) == 1)
    #expect(try bits.alignAndFinish() == 3)
    #expect(throws: JP2KError.invalidCodestream(.badPacketHeader)) { _ = try bits.read(bits: 1) }
}

@Test func packetPassCodes() throws {
    for (value, code, width) in [(1, 0, 1), (2, 2, 2), (3, 12, 4), (5, 14, 4),
                                 (6, 480, 9), (36, 510, 9), (37, 65408, 16), (164, 65535, 16)] {
        var bytes: [UInt8] = []
        var remaining = width
        while remaining > 0 {
            let available = bytes.last == 0xFF ? 7 : 8
            let count = min(available, remaining)
            let shift = remaining - count
            let mask = (1 << count) - 1
            bytes.append(UInt8(((code >> shift) & mask) << (available - count)))
            remaining -= count
        }
        var bits = PacketBitReader(bytes, range: 0..<bytes.count)
        #expect(try PacketDecoder.numberOfPasses(&bits) == value)
    }
    var comma = PacketBitReader([0b1110_0000], range: 0..<1)
    #expect(try PacketDecoder.commaCode(&comma) == 3)
}

@Test(arguments: ["gray-378x472-53.j2k", "sop-eph.j2k", "layers.j2k", "modes-termall.j2k", "modes-bypass.j2k", "precincts.j2k"])
func packetFixtureDecodes(_ name: String) throws {
    let (_, geometry) = try decodePacketFixture(name)
    let blocks = geometry.components.flatMap { $0.resolutions.flatMap { $0.bands.flatMap { $0.precincts.flatMap(\.codeBlocks) } } }
    #expect(blocks.contains { $0.totalPasses > 0 })
    #expect(blocks.allSatisfy { $0.totalPasses <= 109 })
    #expect(blocks.allSatisfy { $0.segments.reduce(0) { $0 + $1.length } == $0.data.count })
}

@Test func packetPassLimit() throws {
    var limits = Limits()
    limits.maxCodingPasses = 0
    #expect(throws: JP2KError.limitExceeded(.codingPasses)) {
        _ = try decodePacketFixture("gray-378x472-53.j2k", limits: limits)
    }
}

private func singleBlockPacket(passes: Int) throws -> (TileData, TileGeometry, DecodeContext) {
    let fixture = Array(try Data(contentsOf: #require(Fixtures.url("gray-378x472-53.j2k"))))
    var context = DecodeContext(limits: Limits())
    let header = try MainHeaderParser.parse(fixture, range: 0..<fixture.count, context: &context)
    var budget = MemoryBudget(limit: 1 << 20)
    let inclusion = try TagTree(leavesWide: 1, leavesHigh: 1, budget: &budget)
    let zeros = try TagTree(leavesWide: 1, leavesHigh: 1, budget: &budget)
    let precinct = Precinct(x0: 0, y0: 0, x1: 1, y1: 1,
                            codeBlocksWide: 1, codeBlocksHigh: 1,
                            codeBlocks: [CodeBlock(x0: 0, y0: 0, x1: 1, y1: 1)],
                            inclusionTree: inclusion, zeroBitPlaneTree: zeros)
    let band = Band(orientation: 0, x0: 0, y0: 0, x1: 1, y1: 1,
                    precincts: [precinct], stepSize: 1, numBitPlanes: 1)
    let resolution = Resolution(x0: 0, y0: 0, x1: 1, y1: 1,
                                precinctsWide: 1, precinctsHigh: 1, bands: [band])
    let geometry = TileGeometry(x0: 0, y0: 0, x1: 1, y1: 1,
                                components: [TileComponent(x0: 0, y0: 0, x1: 1, y1: 1,
                                                           resolutions: [resolution], coefficients: [])])
    // Present, included, two zero bitplanes, then the OpenJPEG 37...164 pass code.
    let prefix = "1101" + "111111111" + String(passes - 37, radix: 2).leftPadded(to: 7)
    let bits = prefix + "0" + String(repeating: "0", count: 9)
    var body: [UInt8] = []
    var cursor = 0
    while cursor < bits.count {
        let width = body.last == 0xFF ? 7 : 8
        let end = min(cursor + width, bits.count)
        let value = try #require(UInt8(bits[bits.index(bits.startIndex, offsetBy: cursor)..<bits.index(bits.startIndex, offsetBy: end)], radix: 2))
        body.append(value << (width - (end - cursor)))
        cursor = end
    }
    let tile = TileData(index: 0, parameters: TileCodingParameters(cod: header.cod, coc: header.coc,
                        qcd: header.qcd, qcc: header.qcc, rgn: header.rgn, poc: header.poc),
                        body: body, packedPacketHeaders: nil, tilePartCount: 1)
    return (tile, geometry, context)
}

private extension String {
    func leftPadded(to width: Int) -> String { String(repeating: "0", count: max(0, width - count)) + self }
}

@Test func packetROIZeroBitplanesAndExactPassCeiling() throws {
    let position = [PacketPosition(layer: 0, resolution: 0, component: 0, precinct: 0)]
    let acceptedCase = try singleBlockPacket(passes: 109)
    let accepted = acceptedCase.0
    var geometry = acceptedCase.1
    var context = acceptedCase.2
    try PacketDecoder.decodeTile(accepted, geometry: &geometry, positions: position, context: &context)
    let block = geometry.components[0].resolutions[0].bands[0].precincts[0].codeBlocks[0]
    #expect(block.zeroBitPlanes == 2)
    #expect(block.totalPasses == 109)
    let rejectedCase = try singleBlockPacket(passes: 110)
    let rejected = rejectedCase.0
    var rejectedGeometry = rejectedCase.1
    var rejectedContext = rejectedCase.2
    #expect(throws: JP2KError.invalidCodestream(.badPacketHeader)) {
        try PacketDecoder.decodeTile(rejected, geometry: &rejectedGeometry,
                                     positions: position, context: &rejectedContext)
    }
}

private func packetMemory(_ name: String, limit: Int) throws -> (steady: Int, data: Int, records: Int) {
    let bytes = Array(try Data(contentsOf: try #require(Fixtures.url(name))))
    var limits = Limits()
    limits.maxMemoryBytes = limit
    var context = DecodeContext(limits: limits)
    try context.budget.reserve(bytes: bytes.count)
    let header = try MainHeaderParser.parse(bytes, range: 0..<bytes.count, context: &context)
    let tile = try #require(TilePartParser.parse(bytes, header: header, context: &context).first)
    var geometry = try TileGeometryBuilder.build(tile: tile, header: header, context: &context)
    let positions = try PacketIterator.positions(geometry: geometry, parameters: tile.parameters,
                                                 header: header, tileIndex: tile.index, context: &context)
    let beforePackets = context.budget.used
    try PacketDecoder.decodeTile(tile, geometry: &geometry, positions: positions, context: &context)
    let blocks = geometry.components.flatMap { $0.resolutions.flatMap { $0.bands.flatMap { $0.precincts.flatMap(\.codeBlocks) } } }
    let data = blocks.reduce(0) { $0 + $1.data.capacity }
    let records = blocks.reduce(0) { $0 + $1.packetSegments.capacity * MemoryLayout<CodeBlockPacketSegment>.stride }
    let segmentGrowth = blocks.reduce(0) { $0 + max(0, $1.segments.capacity - 10) * MemoryLayout<CodeBlockSegment>.stride }
    #expect(context.budget.used == beforePackets + data + records + segmentGrowth)
    return (context.budget.used, data, records)
}

@Test func multilayerPacketMemoryTracksLiveStorage() throws {
    let one = try packetMemory("prog-lrcp.j2k", limit: 1 << 24)
    let many = try packetMemory("layers.j2k", limit: 1 << 24)
    func minimum(_ name: String, ceiling: Int) throws -> Int {
        var low = 0
        var high = ceiling
        while low + 1 < high {
            let middle = (low + high) / 2
            if (try? packetMemory(name, limit: middle)) != nil { high = middle } else { low = middle }
        }
        return high
    }
    let oneMinimum = try minimum("prog-lrcp.j2k", ceiling: one.steady + 16_384)
    let manyMinimum = try minimum("layers.j2k", ceiling: many.steady + 16_384)
    // Both fixtures encode the same generated 127 × 61 gray image.
    #expect(manyMinimum - oneMinimum <= many.data + many.records + 4_096)
    #expect(manyMinimum <= many.steady + 4_096)
    _ = try packetMemory("layers.j2k", limit: many.steady + 4_096)
}

private func packetTrace(_ geometry: TileGeometry) -> [String] {
    var actual: [String] = []
    for component in geometry.components.indices {
        for resolution in geometry.components[component].resolutions.indices {
            let bands = geometry.components[component].resolutions[resolution].bands
            for bandIndex in bands.indices {
                let band = bands[bandIndex]
                for precinctIndex in band.precincts.indices {
                    for blockIndex in band.precincts[precinctIndex].codeBlocks.indices {
                        let block = band.precincts[precinctIndex].codeBlocks[blockIndex]
                        for record in block.packetSegments {
                            actual.append("\(record.layer) \(resolution) \(component) \(precinctIndex) \(bandIndex) \(blockIndex) \(band.numBitPlanes + 1 - block.zeroBitPlanes) \(record.passes) \(record.length)")
                        }
                    }
                }
            }
        }
    }
    return actual
}

// Scripts/make-packet-segments.sh instruments OpenJPEG v2.5.4 to regenerate these values.
@Test(arguments: ["gray-378x472-53", "sop-eph", "layers", "modes-termall", "modes-bypass", "precincts"])
func packetSegmentsMatchOpenJPEG(_ name: String) throws {
    let (_, geometry) = try decodePacketFixture("\(name).j2k")
    let url = try #require(Fixtures.url("packet-segments-\(name).txt"))
    let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n")
    let actual = packetTrace(geometry)
    #expect(actual.sorted() == lines.map(String.init).sorted())
}

@Test(arguments: ["p1_02.j2k", "p1_06.j2k"])
func packedHeaderConformancePackets(_ name: String) throws {
    guard let root = Conformance.root() else { return }
    let url = root.appendingPathComponent("input/conformance").appendingPathComponent(name)
    let bytes = Array(try Data(contentsOf: url))
    var context = DecodeContext(limits: Limits())
    try context.budget.reserve(bytes: bytes.count)
    let header = try MainHeaderParser.parse(bytes, range: 0..<bytes.count, context: &context)
    let tiles = try TilePartParser.parse(bytes, header: header, context: &context)
    #expect(tiles.contains { $0.packedPacketHeaders != nil })
    var actual: [String] = []
    for tile in tiles {
        var geometry = try TileGeometryBuilder.build(tile: tile, header: header, context: &context)
        let positions = try PacketIterator.positions(geometry: geometry, parameters: tile.parameters,
                                                     header: header, tileIndex: tile.index, context: &context)
        try PacketDecoder.decodeTile(tile, geometry: &geometry, positions: positions, context: &context)
        actual.append(contentsOf: packetTrace(geometry))
    }
    let reference = "packet-segments-conformance-\(name.dropLast(4)).txt"
    let referenceURL = try #require(Fixtures.url(reference))
    let lines = try String(contentsOf: referenceURL, encoding: .utf8).split(separator: "\n")
    #expect(actual.sorted() == lines.map(String.init).sorted())
}

@Test func truncatedPacketBodyIsRejected() throws {
    let bytes = Array(try Data(contentsOf: try #require(Fixtures.url("gray-378x472-53.j2k"))))
    var context = DecodeContext(limits: Limits())
    let header = try MainHeaderParser.parse(bytes, range: 0..<bytes.count, context: &context)
    var tile = try #require(TilePartParser.parse(bytes, header: header, context: &context).first)
    var geometry = try TileGeometryBuilder.build(tile: tile, header: header, context: &context)
    let positions = try PacketIterator.positions(geometry: geometry, parameters: tile.parameters,
                                                 header: header, tileIndex: tile.index, context: &context)
    tile.body.removeLast()
    #expect(throws: JP2KError.invalidCodestream(.badPacketHeader)) {
        try PacketDecoder.decodeTile(tile, geometry: &geometry, positions: positions, context: &context)
    }
}

@Test func packetDataRespectsMemoryBudget() throws {
    let bytes = Array(try Data(contentsOf: try #require(Fixtures.url("gray-378x472-53.j2k"))))
    var context = DecodeContext(limits: Limits())
    let header = try MainHeaderParser.parse(bytes, range: 0..<bytes.count, context: &context)
    let tile = try #require(TilePartParser.parse(bytes, header: header, context: &context).first)
    var geometry = try TileGeometryBuilder.build(tile: tile, header: header, context: &context)
    let positions = try PacketIterator.positions(geometry: geometry, parameters: tile.parameters,
                                                 header: header, tileIndex: tile.index, context: &context)
    context.budget = MemoryBudget(limit: 0)
    #expect(throws: JP2KError.limitExceeded(.memory)) {
        try PacketDecoder.decodeTile(tile, geometry: &geometry, positions: positions, context: &context)
    }
}

@Test func flippedPacketHeadersNeverTrap() throws {
    let bytes = Array(try Data(contentsOf: try #require(Fixtures.url("layers.j2k"))))
    var setup = DecodeContext(limits: Limits())
    let header = try MainHeaderParser.parse(bytes, range: 0..<bytes.count, context: &setup)
    let original = try #require(TilePartParser.parse(bytes, header: header, context: &setup).first)
    for index in 0..<min(64, original.body.count) {
        var context = DecodeContext(limits: Limits())
        var tile = original
        tile.body[index] ^= 0x01
        var geometry = try TileGeometryBuilder.build(tile: tile, header: header, context: &context)
        let positions = try PacketIterator.positions(geometry: geometry, parameters: tile.parameters,
                                                     header: header, tileIndex: tile.index, context: &context)
        do {
            try PacketDecoder.decodeTile(tile, geometry: &geometry, positions: positions, context: &context)
        } catch {
            if case .invalidCodestream = error { continue }
            Issue.record("Unexpected error: \(error)")
        }
    }
}

@Test func packetLengthBitCountIsBounded() throws {
    #expect(try PacketDecoder.segmentLengthBitCount(3, passes: 1) == 3)
    #expect(try PacketDecoder.segmentLengthBitCount(3, passes: 8) == 6)
    #expect(throws: JP2KError.invalidCodestream(.badPacketHeader)) {
        _ = try PacketDecoder.segmentLengthBitCount(32, passes: 2)
    }
}
