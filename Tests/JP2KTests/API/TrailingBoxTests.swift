import Foundation
import Testing
@testable import JP2K

/// Boxes may follow the contiguous codestream box (conformance file8 has an
/// `xml ` box after `jp2c`); tile-part parsing must stop at the box end.
struct TrailingBoxTests {
    private func fixture(_ name: String) throws -> [UInt8] {
        Array(try Data(contentsOf: #require(Fixtures.url(name))))
    }

    private func jp2(_ stream: [UInt8], trailing: [UInt8]) -> [UInt8] {
        let signature = BoxWriter.box("jP  ", [0x0D, 0x0A, 0x87, 0x0A])
        let type = BoxWriter.box("ftyp", Array("jp2 ".utf8) + BoxWriter.u32(0) + Array("jp2 ".utf8))
        let ihdr = BoxWriter.box("ihdr", BoxWriter.u32(472) + BoxWriter.u32(378) +
                                 BoxWriter.u16(1) + [7, 7, 0, 0])
        let colr = BoxWriter.box("colr", [1, 0, 0] + BoxWriter.u32(17))
        return signature + type + BoxWriter.box("jp2h", ihdr + colr) + BoxWriter.box("jp2c", stream) + trailing
    }

    /// Sets Psot of the first (only) tile-part to 0, i.e. "runs to EOC".
    private func zeroPsot(_ stream: [UInt8]) throws -> [UInt8] {
        let sot = try #require(stream.indices.dropLast().first { stream[$0] == 0xFF && stream[$0 + 1] == 0x90 })
        var patched = stream
        for offset in 6..<10 { patched[sot + offset] = 0 }
        return patched
    }

    @Test(arguments: [false, true])
    func boxAfterCodestreamIsIgnored(zeroLengthTilePart: Bool) throws {
        var stream = try fixture("gray-378x472-53.j2k")
        if zeroLengthTilePart { stream = try zeroPsot(stream) }
        let expected = try JP2KDecoder().decodeComponents(stream).components
        let trailing = BoxWriter.box("xml ", Array("<x/>".utf8))
        let decoded = try JP2KDecoder().decodeComponents(jp2(stream, trailing: trailing)).components
        #expect(decoded == expected)
    }
}
