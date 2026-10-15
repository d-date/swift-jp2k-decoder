import Foundation
import Testing
@testable import JP2K

private func geometry(_ name: String, limits: Limits = Limits()) throws -> [TileGeometry] {
    let bytes = Array(try Data(contentsOf: try #require(Fixtures.url(name))))
    var context = DecodeContext(limits: limits)
    try context.budget.reserve(bytes: bytes.count)
    let header = try MainHeaderParser.parse(bytes, range: 0..<bytes.count, context: &context)
    let tiles = try TilePartParser.parse(bytes, header: header, context: &context)
    return try tiles.map { try TileGeometryBuilder.build(tile: $0, header: header, context: &context) }
}

@Test func tagTreeHandEncodedValues() throws {
    var budget = MemoryBudget(limit: 4096)
    var tree = try TagTree(leavesWide: 3, leavesHigh: 2, budget: &budget)
    var bits = PacketBitReader([0x70, 0x6B, 0x80])
    let values = [1, 3, 2, 3, 2, 3]
    for threshold in 1...4 {
        for leaf in 0..<6 {
            #expect(try tree.decode(&bits, leaf: leaf, threshold: threshold) == (values[leaf] < threshold))
        }
    }
    for leaf in 0..<6 { #expect(tree.value(leaf: leaf) == values[leaf]) }
    tree.reset()
    #expect(tree.value(leaf: 0) == 999)
}

@Test func tagTreeRejectsInvalidInput() throws {
    var budget = MemoryBudget(limit: 0)
    #expect(throws: JP2KError.limitExceeded(.memory)) {
        try TagTree(leavesWide: 3, leavesHigh: 2, budget: &budget)
    }
    var enough = MemoryBudget(limit: 4096)
    #expect(throws: JP2KError.invalidCodestream(.badPacketHeader)) {
        try TagTree(leavesWide: 0, leavesHigh: 2, budget: &enough)
    }
    var tree = try TagTree(leavesWide: 1, leavesHigh: 1, budget: &enough)
    var bits = PacketBitReader([])
    #expect(throws: JP2KError.invalidCodestream(.badPacketHeader)) {
        try tree.decode(&bits, leaf: 1, threshold: 1)
    }
    #expect(throws: JP2KError.invalidCodestream(.truncated)) {
        try tree.decode(&bits, leaf: 0, threshold: 1)
    }
}

@Test func precinctGeometryMatchesFixture() throws {
    let tiles = try geometry("precincts.j2k")
    let resolutions = try #require(tiles.first?.components.first?.resolutions)
    #expect(!resolutions.isEmpty)
    let low = try #require(resolutions.first)
    let high = try #require(resolutions.last)
    #expect(low.precinctsWide == 8 && low.precinctsHigh == 4)
    #expect(low.bands[0].precincts.count == 32)
    #expect(low.bands[0].precincts.map { $0.codeBlocks.count } == Array(repeating: 1, count: 32))
    #expect(high.precinctsWide == 8 && high.precinctsHigh == 4)
    #expect(high.bands.count == 3)
    for band in high.bands {
        #expect(band.precincts.count == 32)
        #expect(band.precincts.map { $0.codeBlocks.count } == Array(repeating: 1, count: 32))
        #expect(band.precincts.map { $0.codeBlocksWide } == Array(repeating: 1, count: 32))
        #expect(band.precincts.map { $0.codeBlocksHigh } == Array(repeating: 1, count: 32))
    }
}

@Test func originTileBounds() throws {
    let tiles = try geometry("origin.j2k")
    let first = try #require(tiles.first)
    #expect(first.x0 == 3 && first.y0 == 5 && first.x1 == 130 && first.y1 == 66)
    #expect(first.x0 < first.x1 && first.y0 < first.y1)
}

private struct ExpectedBand {
    let orientation: Int
    let rect: [Int]
    let blockGrids: [String]
}

private struct ExpectedResolution {
    let rect: [Int]
    let precinctGrid: [Int]
    let bands: [ExpectedBand]
}

private func builtGeometry(componentRect: [Int], tileOrigin: [Int], tileSize: [Int],
                           levels: Int, precinctExponent: Int, memory: Int = 1_000_000) throws -> TileGeometry {
    let component = SIZComponent(precision: 8, isSigned: false, dx: 1, dy: 1)
    let image = ImageGeometry(rsiz: 0, x1: componentRect[2], y1: componentRect[3],
                              x0: componentRect[0], y0: componentRect[1],
                              tileWidth: tileSize[0], tileHeight: tileSize[1],
                              tileX0: tileOrigin[0], tileY0: tileOrigin[1],
                              components: [component], tilesAcross: 1, tilesDown: 1)
    let componentCoding = ComponentCodingStyle(decompositionLevels: levels, codeBlockWidthExp: 2,
                                               codeBlockHeightExp: 2, codeBlockStyle: 0, reversible: true,
                                               precinctSizes: Array(repeating: (ppx: precinctExponent, ppy: precinctExponent),
                                                                    count: levels + 1))
    let cod = CodingStyle(usesPrecincts: true, usesSOP: false, usesEPH: false,
                          progression: .lrcp, layers: 1, mct: false, component: componentCoding)
    let qcd = QuantizationStyle(style: 1, guardBits: 2, stepSizes: [(exponent: 8, mantissa: 0)])
    let header = MainHeader(geometry: image, cod: cod, coc: [:], qcd: qcd, qcc: [:],
                            rgn: [:], poc: [], ppm: [], firstTilePartOffset: 0)
    let tile = TileData(index: 0, parameters: TileCodingParameters(cod: cod, coc: [:], qcd: qcd,
                                                                    qcc: [:], rgn: [:], poc: []),
                        body: [], packedPacketHeaders: nil, tilePartCount: 1)
    var limits = Limits()
    limits.maxMemoryBytes = memory
    var context = DecodeContext(limits: limits)
    return try TileGeometryBuilder.build(tile: tile, header: header, context: &context)
}

private func checkGeometry(_ geometry: TileGeometry, componentRect: [Int],
                           expected: [ExpectedResolution], emptyBands: Int) throws {
    let component = try #require(geometry.components.first)
    #expect([component.x0, component.y0, component.x1, component.y1] == componentRect)
    #expect(component.resolutions.count == expected.count)
    var empty = 0
    for (resolution, reference) in zip(component.resolutions, expected) {
        #expect([resolution.x0, resolution.y0, resolution.x1, resolution.y1] == reference.rect)
        #expect([resolution.precinctsWide, resolution.precinctsHigh] == reference.precinctGrid)
        #expect(resolution.bands.count == reference.bands.count)
        for (band, bandReference) in zip(resolution.bands, reference.bands) {
            #expect(band.orientation == bandReference.orientation)
            #expect([band.x0, band.y0, band.x1, band.y1] == bandReference.rect)
            #expect(band.precincts.count == bandReference.blockGrids.count)
            #expect(band.precincts.map { "\($0.codeBlocksWide)x\($0.codeBlocksHigh)" } == bandReference.blockGrids)
            #expect(band.precincts.map { $0.codeBlocks.count } == bandReference.blockGrids.map {
                let parts = $0.split(separator: "x")
                return (Int(parts[0]) ?? 0) * (Int(parts[1]) ?? 0)
            })
            if band.x0 >= band.x1 || band.y0 >= band.y1 { empty += 1 }
        }
    }
    #expect(empty == emptyBands)
}

@Test func oddOriginGeometryHasIndependentCoordinatesAndCounts() throws {
    // Tile 0: [max(1,3), min(1+32,80)) x [max(2,5), min(2+16,45)) = [3,33)x[5,18).
    // Resolution bounds use ceil(tile / 2^level): /8=[1,1,5,3], /4=[1,2,9,5],
    // /2=[2,3,17,9], /1=[3,5,33,18]. With P=8, precinct widths are
    // ceil(x1/8)-floor(x0/8): 1,2,3,5; heights are 1,1,2,3.
    // B.5 high-band bounds use ceil((tile - (x0b,y0b)*2^level)/2^(level+1));
    // for HL at level 2, x=[ceil((3-4)/8),ceil((33-4)/8)]=[0,4],
    // y=[ceil(5/8),ceil(18/8)]=[1,3]. At levels 1 and 0 the offsets are
    // 2 and 1: HL x=[ceil((3-2)/4),ceil((33-2)/4)]=[1,8], then
    // [ceil((3-1)/2),ceil((33-1)/2)]=[1,16]. LH uses those offsets on y:
    // [ceil((5-2)/4),ceil((18-2)/4)]=[1,4], then [2,9]. HH uses both.
    // High-band precinct width is P/2=4. With 4x4 code blocks clipped to 4x4,
    // each nonempty precinct has one block. Example HL level 2 second precinct:
    // x=[4,8) intersect [0,4) is empty; the placeholder has a 0x0 block grid.
    // At resolution 2, the 3x2 precinct grid yields HL rows 1,1,0 each,
    // LH rows 1,1,1 then 0,0,0; at resolution 3 the 5x3 grid yields
    // HL/HH rows 1,1,1,1,0 and LH rows 1,1,1,1,1.
    let tile = try builtGeometry(componentRect: [3, 5, 80, 45], tileOrigin: [1, 2],
                                 tileSize: [32, 16], levels: 3, precinctExponent: 3)
    let tileBounds: [Int] = [tile.x0, tile.y0, tile.x1, tile.y1]
    let expectedTileBounds: [Int] = [3, 5, 33, 18]
    #expect(tileBounds == expectedTileBounds)
    let two = ["1x1", "1x1"]
    let five = ["1x1", "1x1", "1x1", "1x1", "0x0"]
    let expected = [
        ExpectedResolution(rect: [1, 1, 5, 3], precinctGrid: [1, 1], bands: [
            ExpectedBand(orientation: 0, rect: [1, 1, 5, 3], blockGrids: ["2x1"])]),
        ExpectedResolution(rect: [1, 2, 9, 5], precinctGrid: [2, 1], bands: [
            ExpectedBand(orientation: 1, rect: [0, 1, 4, 3], blockGrids: ["1x1", "0x0"]),
            ExpectedBand(orientation: 2, rect: [1, 1, 5, 2], blockGrids: two),
            ExpectedBand(orientation: 3, rect: [0, 1, 4, 2], blockGrids: ["1x1", "0x0"])]),
        ExpectedResolution(rect: [2, 3, 17, 9], precinctGrid: [3, 2], bands: [
            ExpectedBand(orientation: 1, rect: [1, 2, 8, 5], blockGrids: ["1x1", "1x1", "0x0", "1x1", "1x1", "0x0"]),
            ExpectedBand(orientation: 2, rect: [1, 1, 9, 4], blockGrids: ["1x1", "1x1", "1x1", "0x0", "0x0", "0x0"]),
            ExpectedBand(orientation: 3, rect: [1, 1, 8, 4], blockGrids: ["1x1", "1x1", "0x0", "0x0", "0x0", "0x0"])]),
        ExpectedResolution(rect: [3, 5, 33, 18], precinctGrid: [5, 3], bands: [
            ExpectedBand(orientation: 1, rect: [1, 3, 16, 9], blockGrids: five + five + five),
            ExpectedBand(orientation: 2, rect: [2, 2, 17, 9], blockGrids: Array(repeating: "1x1", count: 15)),
            ExpectedBand(orientation: 3, rect: [1, 2, 16, 9], blockGrids: five + five + five)])
    ]
    try checkGeometry(tile, componentRect: [3, 5, 33, 18], expected: expected, emptyBands: 0)
}

@Test func tinyTileHasEmptyResolutionsAndBands() throws {
    // [1,2)x[1,2), three levels: ceil(1/8)=ceil(2/8)=1, likewise /4 and /2.
    // Thus resolutions 0...2 have zero precincts, and 1+3+3=7 empty bands.
    // At level 0, B.5 gives HL [ceil((1-1)/2),ceil((2-1)/2)) x
    // [ceil(1/2),ceil(2/2)) = [0,1)x[1,1); LH reverses x/y; HH=[0,1)^2.
    // With P=2, the final resolution has one precinct; high-band block grids
    // use P/2=1. The first two are empty placeholders (0x0); HH is 1x1.
    let tile = try builtGeometry(componentRect: [1, 1, 2, 2], tileOrigin: [1, 1],
                                 tileSize: [1, 1], levels: 3, precinctExponent: 1)
    let low = ExpectedResolution(rect: [1, 1, 1, 1], precinctGrid: [0, 0], bands: [
        ExpectedBand(orientation: 0, rect: [1, 1, 1, 1], blockGrids: [])])
    let middle = ExpectedResolution(rect: [1, 1, 1, 1], precinctGrid: [0, 0], bands: [
        ExpectedBand(orientation: 1, rect: [0, 1, 0, 1], blockGrids: []),
        ExpectedBand(orientation: 2, rect: [1, 0, 1, 0], blockGrids: []),
        ExpectedBand(orientation: 3, rect: [0, 0, 0, 0], blockGrids: [])])
    let high = ExpectedResolution(rect: [1, 1, 2, 2], precinctGrid: [1, 1], bands: [
        ExpectedBand(orientation: 1, rect: [0, 1, 1, 1], blockGrids: ["0x0"]),
        ExpectedBand(orientation: 2, rect: [1, 0, 1, 1], blockGrids: ["0x0"]),
        ExpectedBand(orientation: 3, rect: [0, 0, 1, 1], blockGrids: ["1x1"])])
    try checkGeometry(tile, componentRect: [1, 1, 2, 2], expected: [low, middle, middle, high], emptyBands: 9)
}

@Test func planStorageIsIncludedInMinimumMemoryBudget() throws {
    // For the tiny tile above, persistent storage at the final band is one
    // component, four resolutions, ten bands, three precincts, one code block,
    // ten segments, and six one-node trees. Three one-entry plans have also
    // been allocated. The coefficient array is one Int32 and is allocated later.
    let persistent = MemoryLayout<TileComponent>.stride + 4 * MemoryLayout<Resolution>.stride +
        10 * MemoryLayout<Band>.stride + 3 * MemoryLayout<Precinct>.stride +
        MemoryLayout<CodeBlock>.stride + 10 * MemoryLayout<CodeBlockSegment>.stride +
        6 * 3 * MemoryLayout<Int>.stride
    let planBytes = 3 * 8 * MemoryLayout<Int>.stride
    let lowerBound = persistent + planBytes
    func succeeds(_ maximum: Int) -> Bool {
        (try? builtGeometry(componentRect: [1, 1, 2, 2], tileOrigin: [1, 1],
                            tileSize: [1, 1], levels: 3, precinctExponent: 1,
                            memory: maximum)) != nil
    }
    var lower = 0
    var upper = 1_000_000
    #expect(succeeds(upper))
    while lower < upper {
        let middle = lower + (upper - lower) / 2
        if succeeds(middle) { upper = middle } else { lower = middle + 1 }
    }
    #expect(lower >= lowerBound)
    #expect(throws: JP2KError.limitExceeded(.memory)) {
        try builtGeometry(componentRect: [1, 1, 2, 2], tileOrigin: [1, 1],
                          tileSize: [1, 1], levels: 3, precinctExponent: 1,
                          memory: lower - 1)
    }
}

@Test func geometryBudgetBeforeAllocation() throws {
    var limits = Limits()
    limits.maxMemoryBytes = 20_000
    #expect(throws: JP2KError.limitExceeded(.memory)) { try geometry("precincts.j2k", limits: limits) }
}

@Test func hugeSinglePrecinctChargesCodeBlocks() throws {
    let bytes = CodestreamWriter.soc() +
        CodestreamWriter.siz(width: 4096, height: 4096, tileWidth: 4096, tileHeight: 4096) +
        CodestreamWriter.marker(0xFF52, [1, 0, 0, 1, 0, 0, 4, 4, 0, 1, 0xFF]) +
        CodestreamWriter.qcd() +
        [0xFF, 0x90, 0, 10, 0, 0, 0, 0, 0, 14, 0, 1, 0xFF, 0x93, 0xFF, 0xD9]
    var limits = Limits()
    limits.maxPixels = 16_777_216
    var parserContext = DecodeContext(limits: limits)
    let header = try MainHeaderParser.parse(bytes, range: 0..<bytes.count, context: &parserContext)
    let tile = try #require(TilePartParser.parse(bytes, header: header, context: &parserContext).first)
    limits.maxMemoryBytes = 16_384
    var buildContext = DecodeContext(limits: limits)
    #expect(throws: JP2KError.limitExceeded(.memory)) {
        try TileGeometryBuilder.build(tile: tile, header: header, context: &buildContext)
    }
}

@Test func geometryBuildsFixtureRange() throws {
    let names = ["gray-378x472-53.j2k", "gray-378x472-97.jp2", "cblk-8x8.j2k",
                 "levels-0.j2k", "levels-max.j2k", "origin.j2k", "subsampled.j2k",
                 "tiles-127x61.j2k", "rgb-64-53-mct.jp2", "signed12-31x19.j2k"]
    for name in names {
        let bytes = Array(try Data(contentsOf: try #require(Fixtures.url(name))))
        var context = DecodeContext(limits: Limits())
        let codestream: [UInt8]
        if name.hasSuffix(".jp2") {
            let parsed = try JP2Parser.parse(bytes, context: &context)
            codestream = Array(bytes[parsed.codestream])
        } else { codestream = bytes }
        let header = try MainHeaderParser.parse(codestream, range: 0..<codestream.count, context: &context)
        let tiles = try TilePartParser.parse(codestream, header: header, context: &context)
        for tile in tiles {
            let geometry = try TileGeometryBuilder.build(tile: tile, header: header, context: &context)
            #expect(geometry.components.count == header.geometry.components.count)
        }
    }
}

@Test func packetBitReaderHandlesStuffingAndTruncation() throws {
    var bits = PacketBitReader([0xFF, 0x7F])
    for _ in 0..<15 { #expect(try bits.readBit() == 1) }
    #expect(throws: JP2KError.invalidCodestream(.truncated)) { try bits.readBit() }
}
