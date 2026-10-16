import Foundation
import Testing
@testable import JP2K

struct ColorConverterTests {
    @Test func mappedChannelBeyondCmapCountIsRejected() throws {
        let mapping = [ComponentMapping(cmp: 0, mtyp: 0, pcol: 0),
                       ComponentMapping(cmp: 1, mtyp: 0, pcol: 0)]
        // A cdef-selected channel 2 cannot be looked up in a two-entry cmap.
        #expect(throws: JP2KError.invalidContainer(.badComponentMapping)) {
            _ = try ColorConverter.sourceComponent(2, mapping: mapping)
        }
    }

    @Test(arguments: [1, 2])
    func syccUsesCdefOrderedLumaForSubsampledChroma(chromaDY: Int) throws {
        let cb = ComponentInfo(x0: 1, y0: 1, width: 1, height: chromaDY == 2 ? 1 : 3,
                               dx: 2, dy: chromaDY, precision: 8, isSigned: false)
        let cr = cb
        let y = ComponentInfo(x0: 1, y0: 1, width: 3, height: 3,
                              dx: 1, dy: 1, precision: 8, isSigned: false)
        let info = ImageInfo(width: 3, height: 3, components: [cb, cr, y],
                             colorSpace: .sYCC, isJP2Container: true)
        let chroma = [Int32](repeating: 128, count: cb.width * cb.height)
        let image = ComponentImage(info: info,
                                   components: [chroma, chroma, [Int32](repeating: 128, count: 9)],
                                   iccProfile: nil)
        // OpenJPEG applies cdef before sycc420_to_rgb/sycc422_to_rgb. These
        // records move codestream component 2 (Y) ahead of components 0/1.
        let header = JP2Header(imageHeader: ImageHeaderBox(height: 3, width: 3, nc: 3,
                                                            bpc: 7, c: 7, unkC: 0, ipr: 0),
                               bitsPerComponent: nil, colour: .enumerated(18), palette: nil,
                               componentMapping: nil,
                               channelDefinitions: [ChannelDefinition(cn: 2, typ: 0, asoc: 1),
                                                    ChannelDefinition(cn: 0, typ: 0, asoc: 2),
                                                    ChannelDefinition(cn: 1, typ: 0, asoc: 3)])
        var context = DecodeContext(limits: Limits())
        let pixels = try ColorConverter.convert(image, header: header, color: .container,
                                                region: nil, referenceOrigin: (1, 1), context: &context)
        // Y=128 and Cb=Cr=128 gives (128,128,128). At a leading edge
        // OpenJPEG substitutes Cb=Cr=0: R clamps from 128+int(1.402*-128),
        // G clamps from 128-int(0.344*-128+0.714*-128), and B clamps from
        // 128+int(1.772*-128), giving (0,255,0). For 4:2:0 the first row
        // is zero chroma; the first column is zero only on the first row
        // of each following pair. For 4:2:2 every first-column pixel is zero.
        let zero: [UInt8] = [0, 255, 0]
        let neutral: [UInt8] = [128, 128, 128]
        let expected = (0..<3).flatMap { row in
            (0..<3).flatMap { column in
                let leading = chromaDY == 2 ? row == 0 || (column == 0 && row == 1) : column == 0
                return leading ? zero : neutral
            }
        }
        #expect(pixels.pixels == expected)
    }

    @Test func unalignedReferenceOriginUpsamplesEachComponent() throws {
        let subsampled = ComponentInfo(x0: 1, y0: 0, width: 3, height: 1,
                                       dx: 2, dy: 1, precision: 8, isSigned: false)
        let fullRate = ComponentInfo(x0: 1, y0: 0, width: 5, height: 1,
                                     dx: 1, dy: 1, precision: 8, isSigned: false)
        let info = ImageInfo(width: 5, height: 1, components: [subsampled, fullRate],
                             colorSpace: .unspecified, isJP2Container: false)
        let components = ComponentImage(info: info, components: [[10, 20, 30], [1, 2, 3, 4, 5]],
                                        iccProfile: nil)
        var context = DecodeContext(limits: Limits())
        let image = try ColorConverter.convert(components, header: nil, color: .assume(.grayAlpha8),
                                               region: nil, referenceOrigin: (1, 0), context: &context)
        // Reference x=1...5: the first component covers pairs, while alpha is full rate.
        #expect(image.pixels == [10, 1, 10, 2, 20, 3, 20, 4, 30, 5])
    }

    private func fixture(_ name: String) throws -> [UInt8] {
        Array(try Data(contentsOf: #require(Fixtures.url(name))))
    }

    private func jp2(stream: [UInt8], width: Int, height: Int, components: Int,
                     colour: UInt32, extra: [[UInt8]] = [], colourBox: [UInt8]? = nil) -> [UInt8] {
        let signature = BoxWriter.box("jP  ", [0x0D, 0x0A, 0x87, 0x0A])
        let type = BoxWriter.box("ftyp", Array("jp2 ".utf8) + BoxWriter.u32(0) + Array("jp2 ".utf8))
        let ihdr = BoxWriter.box("ihdr", BoxWriter.u32(UInt32(height)) + BoxWriter.u32(UInt32(width)) +
                                 BoxWriter.u16(UInt16(components)) + [7, 7, 0, 0])
        let colr = BoxWriter.box("colr", [1, 0, 0] + BoxWriter.u32(colour))
        return signature + type + BoxWriter.box("jp2h", ihdr + (colourBox ?? colr) + extra.flatMap { $0 }) +
            BoxWriter.box("jp2c", stream)
    }

    @Test func paletteAndChannelDefinition() throws {
        let raw = try fixture("gray-378x472-53.j2k")
        var entries: [UInt8] = []
        for index in 0..<256 {
            entries += [UInt8(index), UInt8(255 - index), UInt8(index / 2)]
        }
        let palette = BoxWriter.box("pclr", BoxWriter.u16(256) + [3, 7, 7, 7] + entries)
        let mapping = BoxWriter.box("cmap", [0, 0, 1, 0, 0, 0, 1, 1, 0, 0, 1, 2])
        let bytes = jp2(stream: raw, width: 378, height: 472, components: 1, colour: 16,
                        extra: [palette, mapping])
        let image = try JP2KDecoder().decodePixels(bytes)
        let source = try JP2KDecoder().decodeComponents(raw)
        for index in [0, 1, 100, 1000] {
            let value = Int(source.components[0][index])
            #expect(Array(image.pixels[index * 3..<index * 3 + 3]) ==
                    [UInt8(value), UInt8(255 - value), UInt8(value / 2)])
        }
        let cdef = BoxWriter.box("cdef", BoxWriter.u16(3) +
                     BoxWriter.u16(0) + BoxWriter.u16(0) + BoxWriter.u16(3) +
                     BoxWriter.u16(1) + BoxWriter.u16(0) + BoxWriter.u16(2) +
                     BoxWriter.u16(2) + BoxWriter.u16(0) + BoxWriter.u16(1))
        let swapped = try JP2KDecoder().decodePixels(jp2(stream: raw, width: 378, height: 472,
                                                           components: 1, colour: 16,
                                                           extra: [palette, mapping, cdef]))
        #expect(Array(swapped.pixels.prefix(3)) == Array(image.pixels.prefix(3).reversed()))
    }

    @Test func directMappingUsesPaletteColumnPrecision() throws {
        let raw = try fixture("gray-378x472-53.j2k")
        var entries: [UInt8] = []
        for index in 0..<256 { entries += [UInt8(index & 15), UInt8(index), UInt8(index)] }
        let palette = BoxWriter.box("pclr", BoxWriter.u16(256) + [3, 0x83, 7, 7] + entries)
        let mapping = BoxWriter.box("cmap", [0, 0, 0, 0, 0, 0, 1, 1, 0, 0, 1, 2])
        let bytes = jp2(stream: raw, width: 378, height: 472, components: 1, colour: 16,
                        extra: [palette, mapping])
        let source = try JP2KDecoder().decodeComponents(raw)
        let index = try #require(source.components[0].indices.first {
            source.components[0][$0] >= 1 && source.components[0][$0] <= 7
        })
        let image = try JP2KDecoder().decodePixels(bytes)
        let value = Int(source.components[0][index])
        #expect(image.pixels[index * 3] == UInt8(((value + 8) * 255 + 7) / 15))
    }

    @Test func channelDefinitionAlpha() throws {
        let source = try fixture("rgba-33x17.jp2")
        var context = DecodeContext(limits: Limits())
        let file = try JP2Parser.parse(source, context: &context)
        let raw = Array(source[file.codestream])
        var records: [UInt8] = BoxWriter.u16(4)
        for channel in 0..<4 {
            records += BoxWriter.u16(UInt16(channel))
            records += BoxWriter.u16(channel == 3 ? 1 : 0)
            records += BoxWriter.u16(channel == 3 ? 0 : UInt16(channel + 1))
        }
        let cdef = BoxWriter.box("cdef", records)
        let bytes = jp2(stream: raw, width: 33, height: 17, components: 4, colour: 16, extra: [cdef])
        let image = try JP2KDecoder().decodePixels(bytes)
        #expect(image.format == .rgba8)
        let native = try JP2KDecoder().decodeComponents(source)
        #expect(image.pixels[3] == UInt8(native.components[3][0]))
        let bmp = try image.bmp()
        #expect(bmp[57] == image.pixels[3])
    }

    @Test func subsamplingAndScaling() throws {
        let raw = try fixture("subsampled-rgb.j2k")
        let image = try JP2KDecoder().decodePixels(raw, color: .assume(.rgb8))
        let source = try JP2KDecoder().decodeComponents(raw)
        #expect(image.pixels.count == image.width * image.height * 3)
        for (x, y) in [(0, 0), (1, 0), (2, 2), (image.width - 1, image.height - 1)] {
            for channel in 0..<3 {
                let desc = source.info.components[channel]
                let cx = (x + desc.dx - 1) / desc.dx - desc.x0
                let cy = (y + desc.dy - 1) / desc.dy - desc.y0
                let value = Int(source.components[channel][cy * desc.width + cx])
                let maximum = (1 << desc.precision) - 1
                let expected = UInt8((value * 255 + maximum / 2) / maximum)
                #expect(image.pixels[(y * image.width + x) * 3 + channel] == expected)
            }
        }
    }

    @Test func nativePrecisionScaling() throws {
        for name in ["signed12-31x19.j2k", "gray16-40x30.jp2"] {
            let bytes = try fixture(name)
            let native = try JP2KDecoder().decodeComponents(bytes)
            let pixels = try JP2KDecoder().decodePixels(bytes, color: .assume(.gray8))
            let descriptor = native.info.components[0]
            let maximum = (1 << descriptor.precision) - 1
            for index in [0, native.components[0].count / 2, native.components[0].count - 1] {
                let sample = Int(native.components[0][index]) + (descriptor.isSigned ? 1 << (descriptor.precision - 1) : 0)
                let expected = UInt8((sample * 255 + maximum / 2) / maximum)
                #expect(pixels.pixels[index] == expected)
            }
        }
    }

    @Test func colourErrors() throws {
        let raw = try fixture("gray-378x472-53.j2k")
        let icc = BoxWriter.box("colr", [2, 0, 0, 1, 2, 3])
        let bytes = jp2(stream: raw, width: 378, height: 472, components: 1, colour: 17, colourBox: icc)
        let error = JP2KError.unsupported(.iccProfile)
        #expect(throws: error) { try JP2KDecoder().decodePixels(bytes) }
    }
    @Test func syccFormula() throws {
        let source = try fixture("rgb-64-53-mct.jp2")
        var context = DecodeContext(limits: Limits())
        let file = try JP2Parser.parse(source, context: &context)
        var raw = Array(source[file.codestream])
        let cod = try #require(raw.indices.first(where: { index in
            index + 8 < raw.count && raw[index] == 0xFF && raw[index + 1] == 0x52
        }))
        try #require(raw[cod + 8] == 1)
        raw[cod + 8] = 0 // Disable MCT so the three decoded components are used as Y, Cb, Cr.
        let components = try JP2KDecoder().decodeComponents(raw)
        let bytes = jp2(stream: raw, width: 64, height: 64, components: 3, colour: 18)
        let image = try JP2KDecoder().decodePixels(bytes)
        let y = Int(components.components[0][0])
        let cb = Int(components.components[1][0]) - 128
        let cr = Int(components.components[2][0]) - 128
        let expected = [min(max(y + Int(1.402 * Double(Float(cr))), 0), 255),
                        min(max(y - Int(0.344 * Double(Float(cb)) + 0.714 * Double(Float(cr))), 0), 255),
                        min(max(y + Int(1.772 * Double(Float(cb))), 0), 255)]
        #expect(Array(image.pixels.prefix(3)) == expected.map(UInt8.init))
    }

    @Test func conformanceColourCases() throws {
        guard let root = Conformance.root() else { return }
        let directory = root.appendingPathComponent("input/conformance")
        // Reference hashes: Scripts/make-color-trace.sh (opj_decompress 2.5.4 PPM pixel data).
        for name in ["file2.jp2", "file3.jp2", "file9.jp2"] {
            let bytes = Array(try Data(contentsOf: directory.appendingPathComponent(name)))
            var limits = Limits()
            limits.maxInputBytes = max(limits.maxInputBytes, bytes.count)
            let image = try JP2KDecoder(limits: limits).decodePixels(bytes)
            #expect(image.width > 0 && image.height > 0)
            #expect(image.pixels.count == image.width * image.height * image.format.channels)
            if name == "file2.jp2" {
                // Whole image vs opj_decompress 2.5.4 output, except one pixel:
                // at (339, 417) G = 152 - int(0.344 * -39 + 0.714 * 44), whose
                // sum is exactly 18 in real arithmetic. Unfused double math
                // (this decoder, and OpenJPEG built without FMA) gives 18 -> 134;
                // the reference build fused it into an FMA (clang
                // -ffp-contract=on on arm64), giving 17.99… -> 135. This decoder
                // never fuses, so its output is identical on every platform.
                var adjusted = image.pixels
                let green = (417 * image.width + 339) * 3 + 1
                #expect(adjusted[green] == 134)
                adjusted[green] = 135
                #expect(SHA256.hex(adjusted) == "c361925aaa5196ddb9fe7d5064edc9604acc0555a61a7c42d9667383838ed07a")
            }
            if name == "file9.jp2" {
                #expect(SHA256.hex(image.pixels) == "c189c30a239bc892b01981825c8d9e0568eede7ab26e128e46315acabc1bf1e0")
            }
            if name == "file3.jp2" {
                #expect(SHA256.hex(image.pixels) == "f11b275bc77b00ecdeaf466ebb1a167c379c68e3969721fd64202f911ad2788a")
            }
        }
    }

}
