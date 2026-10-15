import Foundation
import Testing
@testable import JP2K

private func packetFixture(_ name: String, limits: Limits = Limits()) throws -> ([PacketPosition], TileGeometry, TileCodingParameters) {
    let bytes = Array(try Data(contentsOf: try #require(Fixtures.url(name))))
    var context = DecodeContext(limits: limits)
    try context.budget.reserve(bytes: bytes.count)
    let header = try MainHeaderParser.parse(bytes, range: 0..<bytes.count, context: &context)
    let tiles = try TilePartParser.parse(bytes, header: header, context: &context)
    let tile = try #require(tiles.first)
    let geometry = try TileGeometryBuilder.build(tile: tile, header: header, context: &context)
    let positions = try PacketIterator.positions(geometry: geometry, parameters: tile.parameters,
                                                 header: header, tileIndex: tile.index, context: &context)
    return (positions, geometry, tile.parameters)
}

@Test(arguments: ["prog-lrcp.j2k", "prog-rlcp.j2k", "prog-rpcl.j2k", "prog-pcrl.j2k", "prog-cprl.j2k"])
func progressionFixturesCoverEveryPacket(_ name: String) throws {
    let (positions, geometry, parameters) = try packetFixture(name)
    let precincts = geometry.components.reduce(0) { total, component in
        total + component.resolutions.reduce(0) { sum, resolution in
            sum + resolution.precinctsWide * resolution.precinctsHigh
        }
    }
    #expect(positions.count == parameters.cod.layers * precincts)
    #expect(Set(positions.map { "\($0.layer),\($0.resolution),\($0.component),\($0.precinct)" }).count == positions.count)
    try expectReferenceOrder(positions, name: name)
}

@Test func pocFixtureMatchesSelectedPacketOrder() throws {
    let (positions, geometry, parameters) = try packetFixture("poc.j2k")
    let precincts = geometry.components.reduce(0) { total, component in
        total + component.resolutions.reduce(0) { sum, resolution in
            sum + resolution.precinctsWide * resolution.precinctsHigh
        }
    }
    #expect(parameters.poc.count == 2)
    #expect(precincts == 15)
    #expect(positions.count == 12)
    #expect(Set(positions.map { "\($0.layer),\($0.resolution),\($0.component),\($0.precinct)" }).count == positions.count)
    try expectReferenceOrder(positions, name: "poc.j2k")
}

@Test func packetLimitIsEnforced() throws {
    let bytes = Array(try Data(contentsOf: try #require(Fixtures.url("prog-lrcp.j2k"))))
    var limits = Limits()
    limits.maxPackets = 3
    var context = DecodeContext(limits: limits)
    let header = try MainHeaderParser.parse(bytes, range: 0..<bytes.count, context: &context)
    let tile = try #require(TilePartParser.parse(bytes, header: header, context: &context).first)
    var geometry = try TileGeometryBuilder.build(tile: tile, header: header, context: &context)
    geometry.components[0].resolutions = Array(geometry.components[0].resolutions.prefix(2))
    var parameters = tile.parameters
    parameters.cod.layers = 2
    parameters.cod.component.decompositionLevels = 1
    parameters.cod.component.precinctSizes = Array(parameters.cod.component.precinctSizes.prefix(2))
    #expect(throws: JP2KError.limitExceeded(.packets)) {
        _ = try PacketIterator.positions(geometry: geometry, parameters: parameters,
                                         header: header, tileIndex: 0, context: &context)
    }
}

// Scripts/make-packet-orders.sh regenerates these files from OpenJPEG v2.5.4.
private func expectReferenceOrder(_ actual: [PacketPosition], name: String) throws {
    let referenceName = "packet-order-\(name.dropLast(4)).txt"
    let url = try #require(Fixtures.url(referenceName))
    let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n")
    let expected = try lines.map { line -> PacketPosition in
        let fields = line.split(separator: " ").compactMap { Int($0) }
        try #require(fields.count == 4)
        return PacketPosition(layer: fields[0], resolution: fields[1], component: fields[2], precinct: fields[3])
    }
    #expect(actual == expected)
}

@Test func toyLayerAndResolutionOrder() throws {
    let bytes = Array(try Data(contentsOf: try #require(Fixtures.url("prog-lrcp.j2k"))))
    var context = DecodeContext(limits: Limits())
    let header = try MainHeaderParser.parse(bytes, range: 0..<bytes.count, context: &context)
    let tile = try #require(TilePartParser.parse(bytes, header: header, context: &context).first)
    var geometry = try TileGeometryBuilder.build(tile: tile, header: header, context: &context)
    geometry.components[0].resolutions = Array(geometry.components[0].resolutions.prefix(2))
    var parameters = tile.parameters
    parameters.cod.layers = 2
    parameters.cod.component.decompositionLevels = 1
    parameters.cod.component.precinctSizes = Array(parameters.cod.component.precinctSizes.prefix(2))
    let lrcp = try PacketIterator.positions(geometry: geometry, parameters: parameters,
                                            header: header, tileIndex: 0, context: &context)
    #expect(lrcp == [PacketPosition(layer: 0, resolution: 0, component: 0, precinct: 0),
                     PacketPosition(layer: 0, resolution: 1, component: 0, precinct: 0),
                     PacketPosition(layer: 1, resolution: 0, component: 0, precinct: 0),
                     PacketPosition(layer: 1, resolution: 1, component: 0, precinct: 0)])
    parameters.cod.progression = .rlcp
    let rlcp = try PacketIterator.positions(geometry: geometry, parameters: parameters,
                                            header: header, tileIndex: 0, context: &context)
    #expect(rlcp == [PacketPosition(layer: 0, resolution: 0, component: 0, precinct: 0),
                     PacketPosition(layer: 1, resolution: 0, component: 0, precinct: 0),
                     PacketPosition(layer: 0, resolution: 1, component: 0, precinct: 0),
                     PacketPosition(layer: 1, resolution: 1, component: 0, precinct: 0)])
}

@Test func conformancePOCCoversAllPackets() throws {
    guard let root = Conformance.root() else { return }
    for name in ["p0_03.j2k", "p0_07.j2k", "e1_colr.j2c"] {
        let url = root.appendingPathComponent("input/conformance").appendingPathComponent(name)
        let bytes = Array(try Data(contentsOf: url))
        var limits = Limits()
        limits.maxMemoryBytes = 2 << 30
        limits.maxPixels = 1 << 26
        limits.maxComponents = 16_384
        var context = DecodeContext(limits: limits)
        try context.budget.reserve(bytes: bytes.count)
        let header = try MainHeaderParser.parse(bytes, range: 0..<bytes.count, context: &context)
        let tiles = try TilePartParser.parse(bytes, header: header, context: &context)
        var found = 0
        var expected = 0
        for tile in tiles {
            let geometry = try TileGeometryBuilder.build(tile: tile, header: header, context: &context)
            let positions = try PacketIterator.positions(geometry: geometry, parameters: tile.parameters,
                                                         header: header, tileIndex: tile.index, context: &context)
            found += positions.count
            for component in geometry.components {
                for resolution in component.resolutions {
                    expected += tile.parameters.cod.layers * resolution.precinctsWide * resolution.precinctsHigh
                }
            }
        }
        #expect(found == expected)
    }
}

@Test(arguments: [ProgressionOrder.rpcl, .pcrl, .cprl])
func spatialProgressionsMatchOpenJPEG(_ order: ProgressionOrder) throws {
    let bytes = Array(try Data(contentsOf: try #require(Fixtures.url("precincts.j2k"))))
    var context = DecodeContext(limits: Limits())
    let header = try MainHeaderParser.parse(bytes, range: 0..<bytes.count, context: &context)
    let tile = try #require(TilePartParser.parse(bytes, header: header, context: &context).first)
    let geometry = try TileGeometryBuilder.build(tile: tile, header: header, context: &context)
    var parameters = tile.parameters
    parameters.cod.progression = order
    parameters.cod.layers = 2
    let positions = try PacketIterator.positions(geometry: geometry, parameters: parameters,
                                                 header: header, tileIndex: 0, context: &context)
    let name: String
    switch order {
    case .rpcl: name = "spatial-rpcl.j2k"
    case .pcrl: name = "spatial-pcrl.j2k"
    case .cprl: name = "spatial-cprl.j2k"
    default: name = "spatial-rpcl.j2k"
    }
    try expectReferenceOrder(positions, name: name)
}

@Test func overlappingPOCRecordsEmitPacketsOnce() throws {
    let bytes = Array(try Data(contentsOf: try #require(Fixtures.url("poc.j2k"))))
    var context = DecodeContext(limits: Limits())
    let header = try MainHeaderParser.parse(bytes, range: 0..<bytes.count, context: &context)
    let tile = try #require(TilePartParser.parse(bytes, header: header, context: &context).first)
    let geometry = try TileGeometryBuilder.build(tile: tile, header: header, context: &context)
    var parameters = tile.parameters
    let first = try #require(parameters.poc.first)
    parameters.poc = [first, first]
    let positions = try PacketIterator.positions(geometry: geometry, parameters: parameters,
                                                 header: header, tileIndex: 0, context: &context)
    #expect(positions.count == 6)
    #expect(Set(positions.map { "\($0.layer),\($0.resolution),\($0.component),\($0.precinct)" }).count == 6)
}

@Test func overlappingPOCAtPacketLimitSucceeds() throws {
    let bytes = Array(try Data(contentsOf: try #require(Fixtures.url("poc.j2k"))))
    var limits = Limits()
    limits.maxPackets = 6
    var context = DecodeContext(limits: limits)
    let header = try MainHeaderParser.parse(bytes, range: 0..<bytes.count, context: &context)
    let tile = try #require(TilePartParser.parse(bytes, header: header, context: &context).first)
    let geometry = try TileGeometryBuilder.build(tile: tile, header: header, context: &context)
    var parameters = tile.parameters
    let first = try #require(parameters.poc.first)
    parameters.poc = [first, first]
    let positions = try PacketIterator.positions(geometry: geometry, parameters: parameters,
                                                 header: header, tileIndex: 0, context: &context)
    #expect(positions.count == limits.maxPackets)
    #expect(context.packets == limits.maxPackets)
    #expect(context.packetWork > limits.maxPackets)
}

@Test func packetScanLimitHasItsOwnError() throws {
    var limits = Limits()
    limits.maxPackets = 1
    var context = DecodeContext(limits: limits)
    for _ in 0..<1_000_000 { try context.countPacketWork() }
    #expect(context.packetWork == 1_000_000)
    #expect(throws: JP2KError.limitExceeded(.packetIteration)) {
        try context.countPacketWork()
    }
    #expect(context.packets == 0)
}

@Test func emptySpatialCandidatesStopAtScanLimit() throws {
    let bytes = Array(try Data(contentsOf: try #require(Fixtures.url("prog-lrcp.j2k"))))
    var limits = Limits()
    limits.maxPackets = 1
    var context = DecodeContext(limits: limits)
    let header = try MainHeaderParser.parse(bytes, range: 0..<bytes.count, context: &context)
    let tile = try #require(TilePartParser.parse(bytes, header: header, context: &context).first)
    var geometry = try TileGeometryBuilder.build(tile: tile, header: header, context: &context)
    geometry.components[0].resolutions = Array(geometry.components[0].resolutions.prefix(1))
    geometry.x1 = geometry.x0 + 1_000_001
    geometry.y1 = geometry.y0 + 1
    var parameters = tile.parameters
    parameters.cod.layers = 1
    parameters.cod.progression = .pcrl
    parameters.cod.component.decompositionLevels = 0
    parameters.cod.component.precinctSizes = [(ppx: 0, ppy: 0)]
    #expect(throws: JP2KError.limitExceeded(.packetIteration)) {
        _ = try PacketIterator.positions(geometry: geometry, parameters: parameters,
                                         header: header, tileIndex: 0, context: &context)
    }
}

@Test(arguments: [ProgressionOrder.rpcl, .pcrl, .cprl])
func largePrecinctShiftRetainsFirstPacket(_ order: ProgressionOrder) throws {
    let bytes = Array(try Data(contentsOf: try #require(Fixtures.url("origin.j2k"))))
    var context = DecodeContext(limits: Limits())
    let header = try MainHeaderParser.parse(bytes, range: 0..<bytes.count, context: &context)
    let tile = try #require(TilePartParser.parse(bytes, header: header, context: &context).first)
    var geometry = try TileGeometryBuilder.build(tile: tile, header: header, context: &context)
    let firstResolution = try #require(geometry.components[0].resolutions.first)
    geometry.components[0].resolutions = Array(repeating: firstResolution, count: 18)
    var parameters = tile.parameters
    parameters.cod.layers = 1
    parameters.cod.progression = order
    parameters.cod.component.decompositionLevels = 17
    parameters.cod.component.precinctSizes = Array(repeating: (ppx: 15, ppy: 15), count: 18)
    parameters.poc = [ProgressionChange(resStart: 0, compStart: 0, layerEnd: 1,
                                        resEnd: 1, compEnd: 1, order: order)]
    let packets = try PacketIterator.positions(geometry: geometry, parameters: parameters,
                                               header: header, tileIndex: 0, context: &context)
    // At tile origin (3,5), OpenJPEG's first-position exception applies to
    // 1 << (15 + 17), leaving exactly the first precinct in this POC window.
    #expect(packets == [PacketPosition(layer: 0, resolution: 0, component: 0, precinct: 0)])
}

@Test func invalidPacketIteratorParametersHaveExactErrors() throws {
    let bytes = Array(try Data(contentsOf: try #require(Fixtures.url("prog-lrcp.j2k"))))
    var context = DecodeContext(limits: Limits())
    let header = try MainHeaderParser.parse(bytes, range: 0..<bytes.count, context: &context)
    let tile = try #require(TilePartParser.parse(bytes, header: header, context: &context).first)
    let geometry = try TileGeometryBuilder.build(tile: tile, header: header, context: &context)
    #expect(throws: JP2KError.invalidCodestream(.badSOT)) {
        _ = try PacketIterator.positions(geometry: geometry, parameters: tile.parameters,
                                         header: header, tileIndex: 1, context: &context)
    }
    var parameters = tile.parameters
    parameters.cod.layers = 0
    #expect(throws: JP2KError.invalidCodestream(.badCOD)) {
        _ = try PacketIterator.positions(geometry: geometry, parameters: parameters,
                                         header: header, tileIndex: 0, context: &context)
    }
    parameters = tile.parameters
    parameters.poc = [ProgressionChange(resStart: 0, compStart: 1, layerEnd: 1,
                                        resEnd: 1, compEnd: 2, order: .lrcp)]
    #expect(throws: JP2KError.invalidCodestream(.badPOC)) {
        _ = try PacketIterator.positions(geometry: geometry, parameters: parameters,
                                         header: header, tileIndex: 0, context: &context)
    }
}
