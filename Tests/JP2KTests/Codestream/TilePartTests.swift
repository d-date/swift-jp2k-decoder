import Foundation
import Testing
@testable import JP2K

private func parseTiles(_ bytes: [UInt8], limits: Limits = Limits()) throws -> [TileData] {
    var context = DecodeContext(limits: limits)
    try context.budget.reserve(bytes: bytes.count)
    let header = try MainHeaderParser.parse(bytes, range: 0..<bytes.count, context: &context)
    return try TilePartParser.parse(bytes, header: header, context: &context)
}

private func sot(tile: Int = 0, length: Int = 14, part: Int = 0, total: Int = 1,
                 body: [UInt8] = []) -> [UInt8] {
    [0xFF, 0x90, 0, 10] + CodestreamWriter.u16(tile) + CodestreamWriter.u32(length) +
        [UInt8(part), UInt8(total), 0xFF, 0x93] + body
}

private func base(tileWidth: Int = 8, ppm: [[UInt8]] = []) -> [UInt8] {
    CodestreamWriter.soc() + CodestreamWriter.siz(width: 16, tileWidth: tileWidth) +
        CodestreamWriter.cod() + CodestreamWriter.qcd() +
        ppm.enumerated().flatMap { CodestreamWriter.marker(0xFF60, [UInt8($0.offset)] + $0.element) }
}

private func part(tile: Int, ordinal: Int, total: Int, ppt: [(Int, [UInt8])] = [], body: [UInt8] = []) -> [UInt8] {
    let markers = ppt.flatMap { CodestreamWriter.marker(0xFF61, [UInt8($0.0)] + $0.1) }
    let header = [0xFF, 0x90, 0, 10] + CodestreamWriter.u16(tile) +
        CodestreamWriter.u32(14 + markers.count + body.count) + [UInt8(ordinal), UInt8(total)]
    return header + markers + [0xFF, 0x93] + body
}

@Test func parsesFixtureTileParts() throws {
    for name in ["tiles-127x61.j2k", "tileparts.j2k", "sop-eph.j2k"] {
        let tiles = try parseTiles(Array(Data(contentsOf: try #require(Fixtures.url(name)))))
        #expect(!tiles.isEmpty)
        #expect(tiles.allSatisfy { $0.tilePartCount > 0 && !$0.body.isEmpty })
        if name == "tiles-127x61.j2k" { #expect(tiles.count == 16 && tiles.allSatisfy { $0.tilePartCount == 1 }) }
        if name == "tileparts.j2k" { #expect(tiles.count == 16 && tiles.allSatisfy { $0.tilePartCount == 5 }) }
    }
}

@Test func rejectsBadSOTAndLimits() throws {
    let prefix = base()
    let cases: [([UInt8], JP2KError)] = [
        (prefix + sot(tile: 2) + [0xFF, 0xD9], .invalidCodestream(.badSOT)),
        (prefix + sot(length: 99) + [0xFF, 0xD9], .invalidCodestream(.badSOT)),
        (prefix + sot(part: 1) + [0xFF, 0xD9], .invalidCodestream(.badTilePart)),
        (prefix + sot(length: 14, part: 0, total: 2) + sot(part: 0, total: 2) + [0xFF, 0xD9],
         .invalidCodestream(.badTilePart))
    ]
    for (bytes, error) in cases { #expect(throws: error) { try parseTiles(bytes) } }
    var limits = Limits()
    limits.maxTileParts = 1
    #expect(throws: JP2KError.limitExceeded(.tileParts)) {
        try parseTiles(prefix + sot(total: 2) + sot(part: 1, total: 2) + [0xFF, 0xD9], limits: limits)
    }
}

@Test func ppmAndPptOrdering() throws {
    let ppm = base(ppm: [[0, 0, 0, 3, 1], [2, 3, 0, 0, 0, 0]])
    let tiles = try parseTiles(ppm + sot(length: 15, body: [9]) + sot(tile: 1, length: 15, body: [8]) + [0xFF, 0xD9])
    #expect(tiles.map(\.packedPacketHeaders) == [[1, 2, 3], []])
    let ppt1 = CodestreamWriter.marker(0xFF61, [1, 3])
    let ppt0 = CodestreamWriter.marker(0xFF61, [0, 2])
    let part = sot(length: 14 + ppt1.count + ppt0.count, body: [])
    let pptBytes = base() + Array(part.prefix(12)) + ppt1 + ppt0 + [0xFF, 0x93]
    #expect(try parseTiles(pptBytes + sot(tile: 1) + [0xFF, 0xD9]).first?.packedPacketHeaders == [2, 3])
    let duplicate = base() + Array(part.prefix(12)) + ppt0 + ppt0 + [0xFF, 0x93] + sot(tile: 1) + [0xFF, 0xD9]
    #expect(throws: JP2KError.invalidCodestream(.badPPT)) { try parseTiles(duplicate) }
}

@Test func conformancePackedHeaders() throws {
    guard let root = Conformance.root() else { return }
    for name in ["g1_colr.j2c", "g2_colr.j2c", "g3_colr.j2c", "g4_colr.j2c", "p1_02.j2k", "p1_03.j2k", "p1_05.j2k", "p1_06.j2k"] {
        let url = root.appendingPathComponent("input/conformance/").appendingPathComponent(name)
        var limits = Limits()
        limits.maxComponents = 16_384
        limits.maxPixels = 1 << 26
        limits.maxMemoryBytes = 2 << 30
        let tiles = try parseTiles(Array(Data(contentsOf: url)), limits: limits)
        #expect(!tiles.isEmpty)
        #expect(tiles.allSatisfy { $0.tilePartCount > 0 })
        #expect(tiles.allSatisfy { ($0.packedPacketHeaders?.count ?? 0) > 0 })
    }
}

@Test func packedHeaderLimitsAndExclusion() throws {
    let ppm = base(ppm: [[0, 0, 0, 1, 42]])
    var limits = Limits()
    limits.maxMarkerDataBytes = 51
    #expect(throws: JP2KError.limitExceeded(.markerData)) {
        try parseTiles(ppm + sot() + sot(tile: 1) + [0xFF, 0xD9], limits: limits)
    }
    let ppt = CodestreamWriter.marker(0xFF61, [0, 7])
    let mixed = ppm + Array(sot(length: 14 + ppt.count).prefix(12)) + ppt +
        [0xFF, 0x93] + sot(tile: 1) + [0xFF, 0xD9]
    #expect(throws: JP2KError.invalidCodestream(.badPPT)) { try parseTiles(mixed) }
}

@Test func acceptsLastZeroLengthAndMissingEOC() throws {
    let bytes = base() + sot(tile: 0) + sot(tile: 1, length: 0, body: [1, 2])
    let tiles = try parseTiles(bytes)
    #expect(tiles.count == 2)
    #expect(tiles[1].body == [1, 2])
}

@Test func zeroLengthPartRequiresTerminalBody() throws {
    let prefix = base() + sot(tile: 0)
    let last = sot(tile: 1, length: 0, body: [0x11, 0xFF, 0, 0x22])
    #expect(try parseTiles(prefix + last + [0xFF, 0xD9])[1].body == [0x11, 0xFF, 0, 0x22])
    #expect(try parseTiles(prefix + last)[1].body == [0x11, 0xFF, 0, 0x22])
    #expect(throws: JP2KError.invalidCodestream(.badTilePart)) {
        try parseTiles(prefix + last + [0xFF, 0xD9, 0])
    }
    #expect(throws: JP2KError.invalidCodestream(.badTilePart)) {
        try parseTiles(prefix + last + sot(tile: 1, part: 1, total: 2) + [0xFF, 0xD9])
    }
}

@Test func pptIndicesSpanTileParts() throws {
    let first = part(tile: 0, ordinal: 0, total: 2, ppt: [(1, [0xB2])])
    let second = part(tile: 0, ordinal: 1, total: 2, ppt: [(0, [0xA1])])
    let other = part(tile: 1, ordinal: 0, total: 1, ppt: [(1, [0xD1])])
    let tiles = try parseTiles(base() + first + other + second + [0xFF, 0xD9])
    #expect(tiles[0].packedPacketHeaders == [0xA1, 0xB2])
    #expect(tiles[1].packedPacketHeaders == [0xD1])
    #expect(throws: JP2KError.invalidCodestream(.badPPT)) {
        try parseTiles(base() + first + part(tile: 0, ordinal: 1, total: 2, ppt: [(1, [0xA1])]) +
                       part(tile: 1, ordinal: 0, total: 1) + [0xFF, 0xD9])
    }
}

@Test func ppmRecordsFollowCodestreamTilePartOrder() throws {
    let records: [[UInt8]] = [[0xA1, 0xA2], [0xB1], [0xC1, 0xC2, 0xC3]]
    let ppm = records.flatMap { CodestreamWriter.u32($0.count) + $0 }
    let parts = part(tile: 0, ordinal: 0, total: 2) + part(tile: 1, ordinal: 0, total: 1) +
        part(tile: 0, ordinal: 1, total: 2) + [0xFF, 0xD9]
    let tiles = try parseTiles(base(ppm: [Array(ppm.prefix(7)), Array(ppm.dropFirst(7))]) + parts)
    #expect(tiles[0].packedPacketHeaders == [0xA1, 0xA2, 0xC1, 0xC2, 0xC3])
    #expect(tiles[1].packedPacketHeaders == [0xB1])
    #expect(throws: JP2KError.invalidCodestream(.badPPM)) {
        try parseTiles(base(ppm: [Array(ppm.dropLast(7))]) + parts)
    }
    #expect(throws: JP2KError.invalidCodestream(.badPPM)) {
        try parseTiles(base(ppm: [ppm + CodestreamWriter.u32(1) + [0xD1]]) + parts)
    }
}

@Test func zeroLengthPartKeepsSOPAndEPH() throws {
    // SOP (FF91, Lsop=4, Nsop) and EPH (FF92) are legal inside packet data.
    let body: [UInt8] = [0xFF, 0x91, 0, 4, 0, 0, 0x80, 0xFF, 0x92, 0x33]
    let bytes = base() + sot(tile: 0) + sot(tile: 1, length: 0, body: body) + [0xFF, 0xD9]
    #expect(try parseTiles(bytes)[1].body == body)
    #expect(throws: JP2KError.invalidCodestream(.badTilePart)) {
        try parseTiles(base() + sot(tile: 0) + sot(tile: 1, length: 0, body: body + [0xFF, 0xD9, 0x44]) + [0xFF, 0xD9])
    }
}

@Test func ppmGrowthIsChargedWhileOldStorageIsLive() throws {
    // Equal PPM byte totals: in `grown` tile 0 receives two records, so the
    // second append grows a live n-byte array; in `flat` no array grows. Without
    // charging the transient growth both need about the same budget.
    let n = 4096
    func ppm(_ sizes: [Int]) -> [[UInt8]] {
        [sizes.flatMap { CodestreamWriter.u32($0) + [UInt8](repeating: 0xA1, count: $0) }]
    }
    let grown = base(ppm: ppm([n, n, 1])) + part(tile: 0, ordinal: 0, total: 2) +
        part(tile: 0, ordinal: 1, total: 2) + part(tile: 1, ordinal: 0, total: 1) + [0xFF, 0xD9]
    let flat = base(ppm: ppm([n, n + 1])) + part(tile: 0, ordinal: 0, total: 1) +
        part(tile: 1, ordinal: 0, total: 1) + [0xFF, 0xD9]
    func minimumBudget(_ bytes: [UInt8]) throws -> Int {
        var limits = Limits()
        limits.maxMemoryBytes = 1 << 20
        _ = try parseTiles(bytes, limits: limits)
        var low = 0, high = 1 << 20
        while low + 1 < high {
            let mid = (low + high) / 2
            limits.maxMemoryBytes = mid
            if (try? parseTiles(bytes, limits: limits)) != nil { high = mid } else { low = mid }
        }
        return high
    }
    #expect(try minimumBudget(grown) - minimumBudget(flat) >= n / 2)
}

@Test func zeroLengthPartSkipsSOPSequenceNumber() throws {
    // Nsop = 0xFF90 must not be mistaken for an SOT marker.
    let body: [UInt8] = [0xFF, 0x91, 0, 4, 0xFF, 0x90, 0x80, 0x00]
    let bytes = base() + sot(tile: 0) + sot(tile: 1, length: 0, body: body) + [0xFF, 0xD9]
    #expect(try parseTiles(bytes)[1].body == body)
}
