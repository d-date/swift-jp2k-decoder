import Testing
@testable import JP2K

private func stream(_ marker: [UInt8], siz: [UInt8] = CodestreamWriter.siz()) -> [UInt8] {
    CodestreamWriter.soc() + siz + CodestreamWriter.cod() + CodestreamWriter.qcd() + marker + [0xFF, 0x90]
}

@Test func headerMarkerDataLimitCountsRepeatedPOC() {
    let poc = CodestreamWriter.marker(0xFF5F, [0, 0, 0, 1, 1, 1, 0])
    var limits = Limits()
    limits.maxMarkerDataBytes = 100
    let bytes = stream(Array(repeating: poc, count: 20).flatMap { $0 })
    #expect(throws: JP2KError.limitExceeded(.markerData)) {
        try JP2KDecoder(limits: limits).readInfo(bytes)
    }
}

@Test func headerCollectionMemoryLimit() {
    let bytes = stream(CodestreamWriter.marker(0xFF5F, [0, 0, 0, 1, 1, 1, 0]))
    let headerCollectionBytes = MemoryLayout<SIZComponent>.stride +
        MemoryLayout<(ppx: Int, ppy: Int)>.stride + MemoryLayout<(exponent: Int, mantissa: Int)>.stride
    var limits = Limits()
    limits.maxMemoryBytes = headerCollectionBytes
    var context = DecodeContext(limits: limits)
    #expect(throws: JP2KError.limitExceeded(.memory)) {
        try MainHeaderParser.parse(bytes, range: 0..<bytes.count, context: &context)
    }
    #expect(context.budget.used == headerCollectionBytes)
}

@Test(arguments: [
    (0x8000, JP2KError.unsupported(.part2)),
    (0x4000, JP2KError.unsupported(.htj2k))
]) func rejectsExtendedRsiz(value: Int, expected: JP2KError) {
    var siz = CodestreamWriter.siz()
    siz[4] = UInt8(value >> 8)
    siz[5] = UInt8(value & 255)
    #expect(throws: expected) { try JP2KDecoder().readInfo(stream([], siz: siz)) }
}

@Test func rejectsHTCOCAndPart2Marker() {
    let coc = CodestreamWriter.marker(0xFF53, [0, 0, 0, 4, 4, 0x40, 1])
    #expect(throws: JP2KError.unsupported(.htj2k)) { try JP2KDecoder().readInfo(stream(coc)) }
    #expect(throws: JP2KError.unsupported(.part2)) {
        try JP2KDecoder().readInfo(stream(CodestreamWriter.marker(0xFF65, [])))
    }
}

@Test(arguments: [
    (0xFF53, [1, 0, 0, 4, 4, 0, 1], JP2KError.invalidCodestream(.badCOC)),
    (0xFF5C, [0x20], JP2KError.invalidCodestream(.badQCD)),
    (0xFF5D, [1, 0, 0x40], JP2KError.invalidCodestream(.badQCC)),
    (0xFF5E, [1, 0, 1], JP2KError.invalidCodestream(.badRGN)),
    (0xFF5E, [0, 0, 255], JP2KError.invalidCodestream(.badRGN)),
    (0xFF5F, [0, 0, 0, 0, 1, 1, 0], JP2KError.invalidCodestream(.badPOC)),
    (0xFF5F, [0, 0, 0, 1, 1, 0, 0], JP2KError.invalidCodestream(.badPOC)),
    (0xFF60, [0], JP2KError.invalidCodestream(.badPPM)),
    (0xFF55, [0], JP2KError.invalidCodestream(.badMarkerLength)),
    (0xFF57, [], JP2KError.invalidCodestream(.badMarkerLength)),
    (0xFF63, [0, 0], JP2KError.invalidCodestream(.badMarkerLength)),
    (0xFF64, [0], JP2KError.invalidCodestream(.badMarkerLength))
]) func rejectsMalformedMarker(code: Int, payload: [UInt8], expected: JP2KError) {
    #expect(throws: expected) {
        try JP2KDecoder().readInfo(stream(CodestreamWriter.marker(UInt16(code), payload)))
    }
}

@Test func rejectsDuplicatePPMAndOrdersPartsByIndex() throws {
    let ppm0 = CodestreamWriter.marker(0xFF60, [0, 1])
    let ppm1 = CodestreamWriter.marker(0xFF60, [1, 2])
    #expect(throws: JP2KError.invalidCodestream(.badPPM)) {
        try JP2KDecoder().readInfo(stream(ppm0 + ppm0))
    }
    let bytes = stream(ppm1 + ppm0)
    var context = DecodeContext(limits: Limits())
    let header = try MainHeaderParser.parse(bytes, range: 0..<bytes.count, context: &context)
    #expect(header.ppm == [[1], [2]])
}

@Test func rejectsPOCRecordTotalAcrossMarkers() throws {
    let record: [UInt8] = [0, 0, 0, 1, 1, 1, 0]
    let poc16 = CodestreamWriter.marker(0xFF5F, Array(repeating: record, count: 16).flatMap { $0 })
    let poc15 = CodestreamWriter.marker(0xFF5F, Array(repeating: record, count: 15).flatMap { $0 })
    _ = try JP2KDecoder().readInfo(stream(poc16 + poc15))
    #expect(throws: JP2KError.invalidCodestream(.badPOC)) {
        try JP2KDecoder().readInfo(stream(poc16 + poc16))
    }
}
