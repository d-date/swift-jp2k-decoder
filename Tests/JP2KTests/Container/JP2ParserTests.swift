import Testing
@testable import JP2K

private let signature = BoxWriter.box("jP  ", [0x0D, 0x0A, 0x87, 0x0A])
private let fileType = BoxWriter.box("ftyp", Array("jp2 ".utf8) + [0, 0, 0, 0] + Array("jp2 ".utf8))
private let imageHeader = BoxWriter.box("ihdr", BoxWriter.u32(3) + BoxWriter.u32(5) + BoxWriter.u16(1) + [7, 7, 0, 0])
private let colour = BoxWriter.box("colr", [1, 0, 0] + BoxWriter.u32(17))
private let codestream = BoxWriter.box("jp2c", [0xFF, 0x4F, 0xFF, 0x51])

private func file(_ children: [[UInt8]] = [imageHeader, colour],
                  prefix: [[UInt8]] = [], tail: [UInt8] = codestream) -> [UInt8] {
    signature + fileType + prefix.flatMap { $0 } + BoxWriter.box("jp2h", children.flatMap { $0 }) + tail
}

private func parse(_ bytes: [UInt8]) throws(JP2KError) -> JP2File {
    var context = DecodeContext(limits: Limits())
    return try JP2Parser.parse(bytes, context: &context)
}

@Test func detectsInputFormat() throws {
    #expect(try FormatDetector.detect(file()) == .jp2)
    #expect(try FormatDetector.detect([0xFF, 0x4F, 0xFF, 0x51]) == .codestream)
    #expect(throws: JP2KError.invalidContainer(.badSignature)) { try FormatDetector.detect([0, 1]) }
}

@Test func parsesMinimalAndUnrelatedBoxes() throws {
    let parsed = try parse(file(prefix: [BoxWriter.box("xml ", Array("ihdr".utf8))]))
    #expect(parsed.header.imageHeader.width == 5)
    #expect(parsed.header.imageHeader.height == 3)
    #expect(parsed.header.colour == .enumerated(17))
    #expect(parsed.codestream.count == 4)
    #expect(try parse(file([imageHeader, BoxWriter.box("jp2h", imageHeader), colour])).header.imageHeader.width == 5)
}

@Test func rejectsOrderingAndBrand() {
    #expect(throws: JP2KError.invalidContainer(.badFileType)) { try parse(signature + BoxWriter.box("jp2h", imageHeader) + codestream) }
    #expect(throws: JP2KError.invalidContainer(.badFileType)) {
        try parse(signature + BoxWriter.box("ftyp", Array("xxxx".utf8) + [0, 0, 0, 0]) + BoxWriter.box("jp2h", imageHeader) + codestream)
    }
    #expect(throws: JP2KError.invalidContainer(.badFileType)) {
        try parse(signature + BoxWriter.box("ftyp", Array("jp2 ".utf8) + [0, 0, 0, 0]) + BoxWriter.box("jp2h", imageHeader) + codestream)
    }
    #expect(throws: JP2KError.invalidContainer(.missingHeaderBox)) { try parse(signature + fileType + codestream + BoxWriter.box("jp2h", imageHeader)) }
}

@Test func checksBoxLengths() throws {
    #expect(try parse(signature + fileType + BoxWriter.xlBox("jp2h", imageHeader + colour) + codestream).header.imageHeader.width == 5)
    #expect(throws: JP2KError.invalidContainer(.badBoxLength)) { try parse(signature + fileType + BoxWriter.u32(15) + Array("jp2h".utf8) + [UInt8](repeating: 0, count: 8) + codestream) }
    #expect(throws: JP2KError.invalidContainer(.badBoxLength)) { try parse(signature + fileType + BoxWriter.u32(3) + Array("jp2h".utf8) + codestream) }
    #expect(throws: JP2KError.invalidContainer(.badBoxLength)) { try parse(signature + fileType + BoxWriter.u32(1000) + Array("jp2h".utf8) + codestream) }
    #expect(throws: JP2KError.invalidContainer(.badBoxLength)) { try parse(signature + fileType + BoxWriter.zeroLengthBox("jp2h", imageHeader) + codestream) }
    #expect(throws: JP2KError.invalidContainer(.badBoxLength)) { try parse(file(tail: BoxWriter.zeroLengthBox("xml ", []) + codestream)) }
    #expect(try parse(file(tail: BoxWriter.zeroLengthBox("jp2c", [0xFF, 0x4F]))).codestream.count == 2)
}

@Test func validatesHeaderChildren() {
    #expect(throws: JP2KError.invalidContainer(.duplicateBox)) { try parse(file([imageHeader, imageHeader, colour])) }
    #expect(throws: JP2KError.invalidContainer(.badPalette)) { try parse(file([imageHeader, BoxWriter.box("pclr", [0, 0, 1, 7]), colour])) }
    let palette = BoxWriter.box("pclr", [0, 1, 1, 7, 42])
    #expect(throws: JP2KError.invalidContainer(.badComponentMapping)) { try parse(file([imageHeader, palette, BoxWriter.box("cmap", [0, 0, 1, 1]), colour])) }
    let cdef = BoxWriter.box("cdef", [0, 2, 0, 0, 0, 0, 0, 1, 0, 0, 0, 1, 0, 1])
    #expect(throws: JP2KError.invalidContainer(.badChannelDefinition)) { try parse(file([imageHeader, colour, cdef])) }
}

@Test func readsColourVariants() throws {
    for value: UInt32 in [16, 17, 18] {
        #expect(try parse(file([imageHeader, BoxWriter.box("colr", [1, 0, 0] + BoxWriter.u32(value))])).header.colour == .enumerated(value))
    }
    #expect(try parse(file([imageHeader, BoxWriter.box("colr", [2, 0, 0, 1, 2, 3])])).header.colour == .restrictedICC([1, 2, 3]))
    #expect(try parse(file([imageHeader, colour, BoxWriter.box("colr", [1, 0, 0] + BoxWriter.u32(16))])).header.colour == .enumerated(17))
}

@Test func readsPaletteMappingAndChannelDefinition() throws {
    let palette = BoxWriter.box("pclr", [0, 2, 1, 7, 10, 20])
    let mapping = BoxWriter.box("cmap", [0, 0, 1, 0])
    let definition = BoxWriter.box("cdef", [0, 1, 0, 0, 0, 0, 0, 1])
    let header = try parse(file([imageHeader, palette, mapping, definition, colour])).header
    #expect(header.palette?.entries == [[10, 20]])
    #expect(header.palette?.bitDepths == [8])
    #expect(header.componentMapping == [ComponentMapping(cmp: 0, mtyp: 1, pcol: 0)])
    #expect(header.channelDefinitions == [ChannelDefinition(cn: 0, typ: 0, asoc: 1)])
    let varied = BoxWriter.box("ihdr", BoxWriter.u32(3) + BoxWriter.u32(5) + BoxWriter.u16(1) + [255, 7, 0, 0])
    #expect(try parse(file([varied, BoxWriter.box("bpcc", [7]), colour])).header.bitsPerComponent == [7])
}

@Test func chargesPaletteAndMappingToMemoryBudget() {
    var limits = Limits()
    limits.maxMemoryBytes = 1
    var context = DecodeContext(limits: limits)
    let palette = BoxWriter.box("pclr", [0, 1, 1, 7, 42])
    #expect(throws: JP2KError.limitExceeded(.memory)) {
        try JP2Parser.parse(file([imageHeader, palette, colour]), context: &context)
    }
}

@Test func rejectsUnpairedPaletteAndMapping() {
    let palette = BoxWriter.box("pclr", [0, 1, 1, 7, 42])
    let mapping = BoxWriter.box("cmap", [0, 0, 1, 0])
    #expect(throws: JP2KError.invalidContainer(.badPalette)) {
        try parse(file([imageHeader, palette, colour]))
    }
    #expect(throws: JP2KError.invalidContainer(.badComponentMapping)) {
        try parse(file([imageHeader, mapping, colour]))
    }
}

@Test func rejectsDuplicateTopLevelBoxes() {
    let header = BoxWriter.box("jp2h", imageHeader + colour)
    for duplicate in [signature, fileType] {
        #expect(throws: JP2KError.invalidContainer(.duplicateBox)) {
            try parse(signature + fileType + duplicate + header + codestream)
        }
        #expect(throws: JP2KError.invalidContainer(.duplicateBox)) {
            try parse(signature + fileType + header + codestream + duplicate)
        }
    }
    #expect(throws: JP2KError.invalidContainer(.duplicateBox)) {
        try parse(signature + fileType + header + header + codestream)
    }
    #expect(throws: JP2KError.invalidContainer(.duplicateBox)) {
        try parse(signature + fileType + header + codestream + codestream)
    }
}

@Test func rejectsMissingRequiredBoxes() {
    #expect(throws: JP2KError.invalidContainer(.missingImageHeader)) {
        try parse(file([colour]))
    }
    #expect(throws: JP2KError.invalidContainer(.missingCodestream)) {
        try parse(signature + fileType + BoxWriter.box("jp2h", imageHeader + colour))
    }
}

@Test func rejectsDuplicateColourMetadata() {
    let palette = BoxWriter.box("pclr", [0, 1, 1, 7, 42])
    let mapping = BoxWriter.box("cmap", [0, 0, 1, 0])
    let definition = BoxWriter.box("cdef", [0, 1, 0, 0, 0, 0, 0, 1])
    for children in [
        [imageHeader, palette, palette, mapping, colour],
        [imageHeader, palette, mapping, mapping, colour],
        [imageHeader, definition, definition, colour]
    ] {
        #expect(throws: JP2KError.invalidContainer(.duplicateBox)) { try parse(file(children)) }
    }
}

@Test func retainedMetadataMemoryBoundary() throws {
    let palette = BoxWriter.box("pclr", [0, 1, 1, 7, 42])
    let mapping = BoxWriter.box("cmap", [0, 0, 1, 0])
    let small = file([imageHeader, BoxWriter.box("bpcc", [7]),
                      BoxWriter.box("colr", [2, 0, 0, 1, 2, 3]), colour])
    let heavyPalette = BoxWriter.box("pclr", [4, 0, 8] + [UInt8](repeating: 7, count: 8) +
                                     [UInt8](repeating: 42, count: 1024 * 8))
    let heavyMapping = BoxWriter.box("cmap", (0..<8).flatMap { [UInt8(0), 0, 1, UInt8($0)] })
    for bytes in [small, file([imageHeader, palette, mapping, colour]),
                  file([imageHeader, heavyPalette, heavyMapping, colour])] {
        var measured = DecodeContext(limits: Limits())
        _ = try JP2Parser.parse(bytes, context: &measured)
        let required = measured.budget.used
        #expect(required > 0)

        var exactLimits = Limits()
        exactLimits.maxMemoryBytes = required
        var exact = DecodeContext(limits: exactLimits)
        _ = try JP2Parser.parse(bytes, context: &exact)
        #expect(exact.budget.used == required)

        var shortLimits = Limits()
        shortLimits.maxMemoryBytes = required - 1
        var short = DecodeContext(limits: shortLimits)
        #expect(throws: JP2KError.limitExceeded(.memory)) {
            try JP2Parser.parse(bytes, context: &short)
        }
    }
}

@Test func paletteChargeCoversDecodedEntries() throws {
    // 1024 entries x 8 columns of 8-bit values: the decoded table alone is
    // 1024 * 8 Int32 values, independent of how the parser accounts for it.
    let heavyPalette = BoxWriter.box("pclr", [4, 0, 8] + [UInt8](repeating: 7, count: 8) +
                                     [UInt8](repeating: 42, count: 1024 * 8))
    let heavyMapping = BoxWriter.box("cmap", (0..<8).flatMap { [UInt8(0), 0, 1, UInt8($0)] })
    var context = DecodeContext(limits: Limits())
    _ = try JP2Parser.parse(file([imageHeader, heavyPalette, heavyMapping, colour]), context: &context)
    #expect(context.budget.used >= 1024 * 8 * MemoryLayout<Int32>.stride +
            8 * MemoryLayout<ComponentMapping>.stride)
}
