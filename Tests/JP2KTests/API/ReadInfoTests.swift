import Foundation
import Testing
@testable import JP2K

private func jp2(_ stream: [UInt8], width: Int = 8, height: Int = 8,
                 colour: UInt32 = 17) -> [UInt8] {
    let signature = BoxWriter.box("jP  ", [0x0D, 0x0A, 0x87, 0x0A])
    let fileType = BoxWriter.box("ftyp", Array("jp2 ".utf8) + [0, 0, 0, 0] + Array("jp2 ".utf8))
    let imageHeader = BoxWriter.box("ihdr", BoxWriter.u32(UInt32(height)) + BoxWriter.u32(UInt32(width)) + BoxWriter.u16(1) + [7, 7, 0, 0])
    let colr = BoxWriter.box("colr", [1, 0, 0] + BoxWriter.u32(colour))
    return signature + fileType + BoxWriter.box("jp2h", imageHeader + colr) + BoxWriter.box("jp2c", stream)
}

@Test func readInfoChecksContainerAndColour() throws {
    let stream = CodestreamWriter.minimal()
    #expect(throws: JP2KError.invalidContainer(.headerMismatch)) {
        try JP2KDecoder().readInfo(jp2(stream, width: 9))
    }
    for (value, expected): (UInt32, ColorSpace) in [(16, .sRGB), (17, .grayscale), (18, .sYCC), (19, .other(19))] {
        #expect(try JP2KDecoder().readInfo(jp2(stream, colour: value)).colorSpace == expected)
    }
}

@Test func componentGridUsesCeilCoordinates() throws {
    let bytes = CodestreamWriter.soc() + CodestreamWriter.siz(width: 9, height: 10, x0: 3, y0: 1,
        tileWidth: 9, tileHeight: 10, dx: 2, dy: 3) + CodestreamWriter.cod() + CodestreamWriter.qcd() + [0xFF, 0x90]
    let info = try JP2KDecoder().readInfo(bytes)
    #expect(info.components[0].x0 == 2)
    #expect(info.components[0].y0 == 1)
    #expect(info.components[0].width == 3)
    #expect(info.components[0].height == 3)
}

@Test func allConformanceHeaders() throws {
    guard let root = ProcessInfo.processInfo.environment["JP2K_CONFORMANCE_DIR"], !root.isEmpty else { return }
    let directory = URL(fileURLWithPath: root).appendingPathComponent("input/conformance")
    let paths = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        .filter { ["j2k", "jp2", "j2c"].contains($0.pathExtension.lowercased()) }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
    var limits = Limits()
    limits.maxInputBytes = 256 << 20
    limits.maxPixels = 1 << 28
    limits.maxComponents = 16_384
    limits.maxTiles = 1 << 20
    limits.maxLayers = 65_535
    limits.maxMemoryBytes = 4 << 30
    limits.maxMarkerDataBytes = 256 << 20
    let decoder = JP2KDecoder(limits: limits)
    var rejected: [String] = []
    for url in paths {
        let bytes = [UInt8](try Data(contentsOf: url))
        do {
            let info = try decoder.readInfo(bytes)
            print("CONFORMANCE ACCEPT \(url.lastPathComponent) \(info.width)x\(info.height) components=\(info.components.count)")
            if url.lastPathComponent == "file1.jp2" { #expect(info.colorSpace == .sRGB) }
            if url.lastPathComponent == "file2.jp2" { #expect(info.colorSpace == .sYCC) }
            if url.lastPathComponent == "file4.jp2" { #expect(info.colorSpace == .grayscale) }
            if url.lastPathComponent == "file5.jp2" { #expect(info.colorSpace == .icc) }
            let reducedBaselines: Set<String> = ["p0_02", "p0_08", "p0_10", "p1_01", "p1_07"]
            if (url.lastPathComponent.hasPrefix("p0_") || url.lastPathComponent.hasPrefix("p1_")) &&
                !reducedBaselines.contains(url.deletingPathExtension().lastPathComponent) {
                let stem = url.deletingPathExtension().lastPathComponent
                let baselineName = "c1" + stem + "_0.pgx"
                let baseline = URL(fileURLWithPath: root).appendingPathComponent("baseline/conformance/" + baselineName)
                // A missing or unreadable baseline is a failure, not a skip.
                let data = try Data(contentsOf: baseline)
                let newline = try #require(data.firstIndex(of: 10))
                let line = try #require(String(data: data.prefix(upTo: newline), encoding: .ascii))
                let words = line.split(separator: " ")
                try #require(words.count >= 5)
                #expect(info.width == Int(words[3]))
                #expect(info.height == Int(words[4]))
            }
        } catch let error as JP2KError {
            print("CONFORMANCE REJECT \(url.lastPathComponent) \(error)")
            rejected.append(url.lastPathComponent)
        }
    }
    #expect(paths.count > 0)
    #expect(rejected.isEmpty)
}

@Test func readsAvailableFixtureHeaders() throws {
    guard let directory = Fixtures.url(".gitkeep")?.deletingLastPathComponent(),
          let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return }
    let images = names.filter { name in
        let ext = URL(fileURLWithPath: name).pathExtension.lowercased()
        return ext == "j2k" || ext == "jp2" || ext == "j2c"
    }
    for name in images {
        guard let url = Fixtures.url(name) else { continue }
        let info = try JP2KDecoder().readInfo([UInt8](Data(contentsOf: url)))
        #expect(info.width > 0 && info.height > 0)
        let stem = url.deletingPathExtension().lastPathComponent
        if let expectedURL = Fixtures.url(stem + "_0.pgx"),
           let data = try? Data(contentsOf: expectedURL) {
            let reference = try PGX.parse(Array(data))
            #expect(info.components[0].width == reference.width)
            #expect(info.components[0].height == reference.height)
        }
    }
}

@Test func signedTwelveBitFixtureReportsSignedPrecision() throws {
    let url = try #require(Fixtures.url("signed12-31x19.j2k"))
    let info = try JP2KDecoder().readInfo(Array(Data(contentsOf: url)))
    #expect(info.components.count == 1)
    #expect(info.components[0].precision == 12)
    #expect(info.components[0].isSigned)
}

@Test(arguments: [
    (2, UInt8(7), nil as [UInt8]?, JP2KError.invalidContainer(.headerMismatch)),
    (1, UInt8(8), nil as [UInt8]?, JP2KError.invalidContainer(.headerMismatch)),
    (1, UInt8(255), [UInt8(8)], JP2KError.invalidContainer(.headerMismatch)),
    (1, UInt8(255), nil as [UInt8]?, JP2KError.invalidContainer(.headerMismatch))
]) func rejectsJP2HeaderSIZMismatch(count: Int, bpc: UInt8, bpcc: [UInt8]?, expected: JP2KError) {
    let signature = BoxWriter.box("jP  ", [0x0D, 0x0A, 0x87, 0x0A])
    let fileType = BoxWriter.box("ftyp", Array("jp2 ".utf8) + [0, 0, 0, 0] + Array("jp2 ".utf8))
    let ihdr = BoxWriter.box("ihdr", BoxWriter.u32(8) + BoxWriter.u32(8) +
        BoxWriter.u16(UInt16(count)) + [bpc, 7, 0, 0])
    let components = bpcc.map { BoxWriter.box("bpcc", $0) } ?? []
    let colr = BoxWriter.box("colr", [1, 0, 0] + BoxWriter.u32(17))
    let bytes = signature + fileType + BoxWriter.box("jp2h", ihdr + components + colr) +
        BoxWriter.box("jp2c", CodestreamWriter.minimal())
    #expect(throws: expected) { try JP2KDecoder().readInfo(bytes) }
}
