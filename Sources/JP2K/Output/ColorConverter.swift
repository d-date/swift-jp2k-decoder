/*
 * The copyright in this software is being made available under the 2-clauses
 * BSD License, included below. This software may be subject to other third
 * party and contributor rights, including patent rights, and no such rights
 * are granted under this license.
 *
 * Copyright (c) 2002-2014, Universite catholique de Louvain (UCL), Belgium
 * Copyright (c) 2002-2014, Professor Benoit Macq
 * Copyright (c) 2001-2003, David Janssens
 * Copyright (c) 2002-2003, Yannick Verschueren
 * Copyright (c) 2003-2007, Francois-Olivier Devaux
 * Copyright (c) 2003-2014, Antonin Descampe
 * Copyright (c) 2005, Herve Drolon, FreeImage Team
 * Copyright (c) 2010-2011, Kaori Hagihara
 * Copyright (c) 2008, 2011-2012, Centre National d'Etudes Spatiales (CNES), FR
 * Copyright (c) 2012, CS Systemes d'Information, France
 * Copyright (c) 2008, Jerome Fimes, Communications & Systemes <jerome.fimes@c-s.fr>
 * Copyright (c) 2006-2007, Parvatha Elangovan
 * Copyright (c) 2011-2012, Centre National d'Etudes Spatiales (CNES), France
 * Copyright (c) 2017, IntoPIX SA <support@intopix.com>
 * All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions
 * are met:
 * 1. Redistributions of source code must retain the above copyright
 *    notice, this list of conditions and the following disclaimer.
 * 2. Redistributions in binary form must reproduce the above copyright
 *    notice, this list of conditions and the following disclaimer in the
 *    documentation and/or other materials provided with the distribution.
 *
 * THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS `AS IS'
 * AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
 * IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
 * ARE DISCLAIMED.  IN NO EVENT SHALL THE COPYRIGHT OWNER OR CONTRIBUTORS BE
 * LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
 * CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
 * SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
 * INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
 * CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
 * ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
 * POSSIBILITY OF SUCH DAMAGE.
 */
// Ported from OpenJPEG v2.5.4: jp2.c: opj_jp2_check_color, opj_jp2_apply_pclr, opj_jp2_apply_cdef; j2k.c: opj_j2k_update_image_data; color.c: sycc444_to_rgb, sycc422_to_rgb, sycc420_to_rgb
enum ColorConverter {
    static func convert(_ image: ComponentImage, header: JP2Header?, color: ColorInterpretation,
                        region: Region?, referenceOrigin: (Int, Int),
                        context: inout DecodeContext) throws(JP2KError) -> PixelImage {
        let info = image.info
        let mapping = header?.componentMapping
        let palette = header?.palette
        let channelCount = mapping?.count ?? image.components.count
        let format: PixelFormat
        let inferred: Bool
        let sycc: Bool
        switch color {
        case .container:
            inferred = false
            switch info.colorSpace {
            case .sRGB: format = channelCount == 4 ? .rgba8 : .rgb8; sycc = false
            case .grayscale: format = channelCount == 2 ? .grayAlpha8 : .gray8; sycc = false
            case .sYCC: format = channelCount == 4 ? .rgba8 : .rgb8; sycc = true
            case .icc: throw .unsupported(.iccProfile)
            case .unspecified: throw .unsupported(.unspecifiedColour)
            case .other: throw .unsupported(.colourSpace)
            }
        case .assume(let assumed):
            format = assumed; inferred = false; sycc = false
        case .inferFromComponentCount:
            inferred = true; sycc = false
            switch channelCount {
            case 1: format = .gray8
            case 2: format = .grayAlpha8
            case 3: format = .rgb8
            case 4: format = .rgba8
            default: throw .unsupported(.componentCount)
            }
        }
        if channelCount != format.channels { throw .unsupported(.componentCount) }
        if (format == .rgb8 || format == .rgba8) && sycc && channelCount < 3 {
            throw .unsupported(.componentCount)
        }
        if let mapping, let palette { try checkMapping(mapping, palette: palette, sourceCount: image.components.count) }
        let definitions = header?.channelDefinitions ?? []
        var order = try context.budget.array(repeating: 0, count: channelCount)
        for index in order.indices { order[index] = index }
        if !definitions.isEmpty { try applyDefinitions(definitions, order: &order, context: &context) }
        if let palette, palette.bitDepths.contains(where: { $0 > 16 }) { throw .unsupported(.bitDepthAbove16) }
        let crop = try RegionResolver.resolve(region, width: info.width, height: info.height)
        // Component planes cover the full image, but only the requested region's
        // interleaved pixel buffer is allocated and charged to the budget.
        let count = try Checked.mul(try Checked.mul(crop.2, crop.3), channelCount)
        var pixels = try context.budget.array(repeating: UInt8(0), count: count)
        for row in 0..<crop.3 {
            for column in 0..<crop.2 {
                let x = try Checked.add(crop.0, column)
                let y = try Checked.add(crop.1, row)
                let base = try Checked.mul(try Checked.add(try Checked.mul(row, crop.2), column), channelCount)
                if sycc {
                    let yValue = try channelValue(order[0], atX: x, y: y, image: image, mapping: mapping, palette: palette,
                                                  referenceOrigin: referenceOrigin)
                    let cb = try syccChroma(order[1], luma: order[0], atX: x, y: y, image: image, mapping: mapping,
                                            palette: palette, referenceOrigin: referenceOrigin)
                    let cr = try syccChroma(order[2], luma: order[0], atX: x, y: y, image: image, mapping: mapping,
                                            palette: palette, referenceOrigin: referenceOrigin)
                    let depth = try depthOf(order[0], image: image, mapping: mapping, palette: palette)
                    let rgb = syccToRGB(yValue.0, cb.0, cr.0, depth: depth)
                    pixels[base] = scale(rgb.0, precision: depth, signed: false)
                    pixels[base + 1] = scale(rgb.1, precision: depth, signed: false)
                    pixels[base + 2] = scale(rgb.2, precision: depth, signed: false)
                    if channelCount == 4 {
                        let alpha = try channelValue(order[3], atX: x, y: y, image: image, mapping: mapping, palette: palette,
                                                     referenceOrigin: referenceOrigin)
                        pixels[base + 3] = scale(alpha.0, precision: alpha.1, signed: alpha.2)
                    }
                } else {
                    for channel in 0..<channelCount {
                        let value = try channelValue(order[channel], atX: x, y: y, image: image,
                                                     mapping: mapping, palette: palette,
                                                     referenceOrigin: referenceOrigin)
                        pixels[base + channel] = scale(value.0, precision: value.1, signed: value.2)
                    }
                }
            }
        }
        return PixelImage(width: crop.2, height: crop.3, format: format, pixels: pixels,
                          colorWasInferred: inferred, maxMemoryBytes: context.limits.maxMemoryBytes)
    }

    private static func checkMapping(_ mapping: [ComponentMapping], palette: PaletteBox,
                                     sourceCount: Int) throws(JP2KError) {
        for (index, item) in mapping.enumerated() {
            if item.cmp < 0 || item.cmp >= sourceCount || item.mtyp > 1 ||
                item.pcol < 0 || item.pcol >= palette.entries.count ||
                (item.mtyp == 0 && item.pcol != 0) || (item.mtyp == 1 && item.pcol != index) ||
                (item.mtyp == 1 && mapping[..<index].contains { $0.mtyp == 1 && $0.pcol == item.pcol }) {
                throw .invalidContainer(.badComponentMapping)
            }
        }
    }

    private static func applyDefinitions(_ definitions: [ChannelDefinition],
                                         order: inout [Int], context: inout DecodeContext) throws(JP2KError) {
        var channels = try context.budget.array(repeating: 0, count: definitions.count)
        for i in definitions.indices { channels[i] = definitions[i].cn }
        for i in definitions.indices {
            let item = definitions[i]
            let cn = channels[i]
            if cn < 0 || cn >= order.count { throw .invalidContainer(.badChannelDefinition) }
            if item.typ == 0 && item.asoc > 0 && item.asoc != 65_535 {
                let target = item.asoc - 1
                if target >= order.count { throw .invalidContainer(.badChannelDefinition) }
                if cn != target {
                    order.swapAt(cn, target)
                    if i + 1 < channels.count {
                        for j in (i + 1)..<channels.count {
                            if channels[j] == cn { channels[j] = target } else if channels[j] == target { channels[j] = cn }
                        }
                    }
                }
            }
        }
        context.budget.release(bytes: try Checked.mul(channels.count, MemoryLayout<Int>.stride))
    }

    private static func depthOf(_ channel: Int, image: ComponentImage, mapping: [ComponentMapping]?,
                                palette: PaletteBox?) throws(JP2KError) -> Int {
        if let mapping, let palette, channel < mapping.count {
            return palette.bitDepths[channel]
        }
        let source = try sourceComponent(channel, mapping: mapping)
        if source >= image.info.components.count { throw .invalidContainer(.badComponentMapping) }
        return image.info.components[source].precision
    }

    private static func channelValue(_ channel: Int, atX x: Int, y: Int, image: ComponentImage,
                                     mapping: [ComponentMapping]?, palette: PaletteBox?,
                                     referenceOrigin: (Int, Int),
                                     position: (Int, Int)? = nil) throws(JP2KError) -> (Int, Int, Bool) {
        let source = try sourceComponent(channel, mapping: mapping)
        if source < 0 || source >= image.components.count { throw .invalidContainer(.badComponentMapping) }
        let descriptor = image.info.components[source]
        let absoluteX = try Checked.add(x, referenceOrigin.0)
        let absoluteY = try Checked.add(y, referenceOrigin.1)
        let column: Int
        let row: Int
        if let position {
            column = position.0
            row = position.1
        } else {
            column = min(max(0, try Checked.sub(Checked.ceilDiv(absoluteX, descriptor.dx), descriptor.x0)), descriptor.width - 1)
            row = min(max(0, try Checked.sub(Checked.ceilDiv(absoluteY, descriptor.dy), descriptor.y0)), descriptor.height - 1)
        }
        if column < 0 || row < 0 || column >= descriptor.width || row >= descriptor.height {
            throw .invalidCodestream(.badSIZ)
        }
        let index = try Checked.add(try Checked.mul(row, descriptor.width), column)
        if index >= image.components[source].count { throw .invalidCodestream(.badSIZ) }
        let value = Int(image.components[source][index])
        if let mapping, let palette, mapping[channel].mtyp == 1 {
            if channel >= palette.entries.count || palette.entries[channel].isEmpty {
                throw .invalidContainer(.badPalette)
            }
            let paletteIndex = min(max(0, value), palette.entries[channel].count - 1)
            return (Int(palette.entries[channel][paletteIndex]), palette.bitDepths[channel], palette.signed[channel])
        }
        if let mapping, let palette, channel < mapping.count {
            return (value, palette.bitDepths[channel], palette.signed[channel])
        }
        return (value, descriptor.precision, descriptor.isSigned)
    }

    /// Codestream component feeding output channel `channel` (through cmap
    /// when present); out-of-range channels are rejected instead of trapping.
    static func sourceComponent(_ channel: Int, mapping: [ComponentMapping]?) throws(JP2KError) -> Int {
        guard let mapping else { return channel }
        guard channel >= 0 && channel < mapping.count else { throw .invalidContainer(.badComponentMapping) }
        return mapping[channel].cmp
    }

    /// `luma` is the channel that cdef placed first: OpenJPEG converts sYCC
    /// after cdef has reordered the components, so the 4:2:2 / 4:2:0 layout
    /// is judged against that channel, not the codestream's component 0.
    private static func syccChroma(_ channel: Int, luma lumaChannel: Int, atX x: Int, y: Int,
                                   image: ComponentImage, mapping: [ComponentMapping]?, palette: PaletteBox?,
                                   referenceOrigin: (Int, Int)) throws(JP2KError) -> (Int, Int, Bool) {
        let source = try sourceComponent(channel, mapping: mapping)
        let lumaSource = try sourceComponent(lumaChannel, mapping: mapping)
        let count = image.info.components.count
        if source < 0 || source >= count || lumaSource < 0 || lumaSource >= count {
            throw .invalidContainer(.badComponentMapping)
        }
        let luma = image.info.components[lumaSource]
        let chroma = image.info.components[source]
        if luma.dx != 1 || luma.dy != 1 || chroma.dx != 2 || (chroma.dy != 1 && chroma.dy != 2) {
            return try channelValue(channel, atX: x, y: y, image: image, mapping: mapping, palette: palette,
                                    referenceOrigin: referenceOrigin)
        }
        let offx = luma.x0 & 1
        let offy = chroma.dy == 2 ? luma.y0 & 1 : 0
        // OpenJPEG's 4:2:2 and 4:2:0 paths use zero chroma at an odd leading edge.
        let leadingX = x < offx && (chroma.dy == 1 || (y - offy) % 2 == 0)
        if leadingX || y < offy { return (0, chroma.precision, false) }
        let cx = x < offx ? 0 : (x - offx) / 2
        let cy = chroma.dy == 2 ? (y - offy) / 2 : y
        if cx < 0 || cy < 0 || cx >= chroma.width || cy >= chroma.height {
            return (0, chroma.precision, false)
        }
        return try channelValue(channel, atX: x, y: y, image: image, mapping: mapping,
                                palette: palette, referenceOrigin: referenceOrigin, position: (cx, cy))
    }

    private static func scale(_ value: Int, precision: Int, signed: Bool) -> UInt8 {
        if precision < 1 || precision > 16 { return 0 }
        let maximum = (1 << precision) - 1
        let shifted = value + (signed ? 1 << (precision - 1) : 0)
        let clipped = min(max(shifted, 0), maximum)
        return UInt8((clipped * 255 + maximum / 2) / maximum)
    }

    private static func syccToRGB(_ y: Int, _ cb: Int, _ cr: Int, depth: Int) -> (Int, Int, Int) {
        let offset = 1 << (depth - 1)
        let maximum = (1 << depth) - 1
        let chromaB = cb - offset
        let chromaR = cr - offset
        let red = y + Int(1.402 * Double(Float(chromaR)))
        let green = y - Int(0.344 * Double(Float(chromaB)) + 0.714 * Double(Float(chromaR)))
        let blue = y + Int(1.772 * Double(Float(chromaB)))
        return (min(max(red, 0), maximum), min(max(green, 0), maximum), min(max(blue, 0), maximum))
    }
}
