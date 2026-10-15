import Testing
@testable import JP2K

@Test func minimalHeaderAndGeometry() throws {
    let bytes = CodestreamWriter.minimal()
    let info = try JP2KDecoder().readInfo(bytes)
    #expect(info.width == 8 && info.height == 8)
    #expect(info.components.count == 1)
    #expect(info.components[0].width == 8)
    #expect(info.colorSpace == .unspecified)
    let offset = bytes.count - 2
    var context = DecodeContext(limits: Limits())
    let header = try MainHeaderParser.parse(bytes, range: 0..<bytes.count, context: &context)
    #expect(header.firstTilePartOffset == offset)
}

@Test func malformedMainHeaders() throws {
    let base = CodestreamWriter.soc()
    let cod = CodestreamWriter.cod()
    let qcd = CodestreamWriter.qcd()
    let cases: [([UInt8], JP2KError)] = [
        (base + cod + qcd + [0xFF, 0x90], .invalidCodestream(.missingSIZ)),
        (base + CodestreamWriter.siz(components: 0) + cod + qcd + [0xFF, 0x90], .invalidCodestream(.badSIZ)),
        (base + CodestreamWriter.siz(width: 3, x0: 3) + cod + qcd + [0xFF, 0x90], .invalidCodestream(.badSIZ)),
        (base + CodestreamWriter.siz(tileWidth: 0) + cod + qcd + [0xFF, 0x90], .invalidCodestream(.badSIZ)),
        (base + CodestreamWriter.siz(descriptor: 16) + cod + qcd + [0xFF, 0x90], .unsupported(.bitDepthAbove16)),
        (base + CodestreamWriter.siz() + CodestreamWriter.cod(levels: 33) + qcd + [0xFF, 0x90], .invalidCodestream(.specRange)),
        (base + CodestreamWriter.siz() + cod + qcd + CodestreamWriter.marker(0xFF50, [0]), .unsupported(.htj2k)),
        (base + CodestreamWriter.siz() + cod + qcd + CodestreamWriter.marker(0xFF99, [0]), .invalidCodestream(.badMarker)),
        (base + CodestreamWriter.siz() + cod + qcd + [0xFF, 0x64, 0, 9], .invalidCodestream(.badMarkerLength))
    ]
    for (bytes, expected) in cases {
        #expect(throws: expected) { try JP2KDecoder().readInfo(bytes) }
    }
    var inconsistent = CodestreamWriter.siz()
    inconsistent[2] = 0
    inconsistent[3] = 40
    #expect(throws: JP2KError.invalidCodestream(.badSIZ)) {
        try JP2KDecoder().readInfo(base + inconsistent + cod + qcd + [0xFF, 0x90])
    }
}

@Test func limitsAndReservedMarkers() throws {
    var bytes = CodestreamWriter.soc() + CodestreamWriter.siz(width: 60_000, height: 60_000,
        tileWidth: 60_000, tileHeight: 60_000) + CodestreamWriter.cod() + CodestreamWriter.qcd() + [0xFF, 0x90]
    #expect(throws: JP2KError.limitExceeded(.pixels)) { try JP2KDecoder().readInfo(bytes) }
    bytes = CodestreamWriter.soc() + CodestreamWriter.siz(components: 5) + CodestreamWriter.cod() + CodestreamWriter.qcd() + [0xFF, 0x90]
    #expect(throws: JP2KError.limitExceeded(.components)) { try JP2KDecoder().readInfo(bytes) }
    bytes = CodestreamWriter.soc() + CodestreamWriter.siz() + [0xFF, 0x30] + CodestreamWriter.cod() + CodestreamWriter.qcd() + [0xFF, 0x90]
    #expect(try JP2KDecoder().readInfo(bytes).width == 8)
}

@Test func oversizedGeometryFailsBeforePlaneReservation() throws {
    let bytes = CodestreamWriter.soc() + CodestreamWriter.siz(width: 60_000, height: 60_000,
        tileWidth: 60_000, tileHeight: 60_000) + CodestreamWriter.cod() + CodestreamWriter.qcd() + [0xFF, 0x90]
    var context = DecodeContext(limits: Limits())
    try context.budget.reserve(bytes: bytes.count)
    #expect(throws: JP2KError.limitExceeded(.pixels)) {
        try MainHeaderParser.parse(bytes, range: 0..<bytes.count, context: &context)
    }
    #expect(context.budget.used == bytes.count)
}

@Test func parsesComponentOverridesAndPPM() throws {
    let bytes = CodestreamWriter.soc() + CodestreamWriter.siz() + CodestreamWriter.cod() +
        CodestreamWriter.marker(0xFF53, [0, 0, 0, 4, 4, 0, 1]) + CodestreamWriter.qcd() +
        CodestreamWriter.marker(0xFF5D, [0, 0, 0x40]) +
        CodestreamWriter.marker(0xFF5E, [0, 0, 1]) +
        CodestreamWriter.marker(0xFF60, [0, 3, 4]) +
        CodestreamWriter.marker(0xFF60, [1, 1, 2]) + [0xFF, 0x90]
    var context = DecodeContext(limits: Limits())
    let header = try MainHeaderParser.parse(bytes, range: 0..<bytes.count, context: &context)
    #expect(header.coc[0]?.decompositionLevels == 0)
    #expect(header.qcc[0]?.stepSizes.count == 1)
    #expect(header.rgn[0] == 1)
    #expect(header.ppm == [[3, 4], [1, 2]])
}

@Test func rejectsHTCodeBlockStyle() {
    var cod = CodestreamWriter.cod()
    cod[12] = 0x40
    let bytes = CodestreamWriter.soc() + CodestreamWriter.siz() + cod + CodestreamWriter.qcd() + [0xFF, 0x90]
    #expect(throws: JP2KError.unsupported(.htj2k)) { try JP2KDecoder().readInfo(bytes) }
}
