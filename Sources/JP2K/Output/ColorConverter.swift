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
        if crop.2 > 0 && crop.3 > 0 {
            var planes: [ChannelPlane] = []
            // Declared before the planes are built so a later channel's
            // failure still returns the tables of the earlier ones.
            defer { for plane in planes { context.budget.release(bytes: plane.tableBytes) } }
            if sycc {
                // Built in the order the per-pixel conversion reads them
                // (Y, Cb, Cr, alpha), so the first failing check is the same.
                planes.append(try ChannelPlane(order[0], image: image, mapping: mapping, palette: palette,
                                               crop: crop, referenceOrigin: referenceOrigin,
                                               budget: &context.budget))
                for channel in order[1...2] {
                    planes.append(try ChannelPlane(chroma: channel, luma: order[0], image: image, mapping: mapping,
                                                   palette: palette, crop: crop, referenceOrigin: referenceOrigin,
                                                   budget: &context.budget))
                }
                if channelCount == 4 {
                    planes.append(try ChannelPlane(order[3], image: image, mapping: mapping, palette: palette,
                                                   crop: crop, referenceOrigin: referenceOrigin,
                                                   budget: &context.budget))
                }
                let depth = try channelFormat(order[0], image: image, mapping: mapping, palette: palette).precision
                convertSYCC(planes, depth: depth, width: crop.2, height: crop.3, pixels: &pixels)
            } else {
                for channel in 0..<channelCount {
                    planes.append(try ChannelPlane(order[channel], image: image, mapping: mapping, palette: palette,
                                                   crop: crop, referenceOrigin: referenceOrigin,
                                                   budget: &context.budget))
                }
                interleave(planes, width: crop.2, height: crop.3, pixels: &pixels)
            }
        }
        return PixelImage(width: crop.2, height: crop.3, format: format, pixels: pixels,
                          colorWasInferred: inferred, maxMemoryBytes: context.limits.maxMemoryBytes)
    }

    private static func interleave(_ planes: [ChannelPlane], width: Int, height: Int, pixels: inout [UInt8]) {
        let channelCount = planes.count
        for channel in 0..<channelCount {
            let plane = planes[channel]
            for row in 0..<height {
                let rowOffset = plane.rows[row]
                var target = row * width * channelCount + channel
                for column in 0..<width {
                    pixels[target] = plane.value(at: rowOffset + plane.columns[column])
                    target += channelCount
                }
            }
        }
    }

    /// sycc_to_rgb over the Y, Cb, Cr (and alpha) planes, whose tables
    /// were validated when built, so the loop cannot fail.
    private static func convertSYCC(_ planes: [ChannelPlane], depth: Int, width: Int, height: Int,
                                    pixels: inout [UInt8]) {
        let colour = ChannelScale(precision: depth, signed: false)
        let channelCount = planes.count
        var target = 0
        for row in 0..<height {
            for column in 0..<width {
                let rgb = syccToRGB(planes[0].sample(row: row, column: column),
                                    planes[1].sample(row: row, column: column),
                                    planes[2].sample(row: row, column: column), depth: depth)
                pixels[target] = colour.apply(rgb.0)
                pixels[target + 1] = colour.apply(rgb.1)
                pixels[target + 2] = colour.apply(rgb.2)
                if channelCount == 4 {
                    pixels[target + 3] = planes[3].scale.apply(planes[3].sample(row: row, column: column))
                }
                target += channelCount
            }
        }
    }

    /// One output channel resolved up front: its source plane, the source
    /// column for each output column and the row offset for each output row,
    /// the palette column if cmap maps through pclr, and its 8-bit scale.
    /// A negative table entry reads as a zero sample (sYCC chroma edges).
    /// Building it validates everything a per-pixel lookup would, so the
    /// loops that read it cannot fail.
    private struct ChannelPlane {
        let samples: [Int32]
        let columns: [Int]
        let rows: [Int]
        let palette: [Int32]?
        let scale: ChannelScale
        let tableBytes: Int
        /// 4:2:0 chroma whose luma starts on an odd x: output column 0 reads
        /// zero on rows whose low bit equals this (each pair's first row).
        let leadingZeroParity: Int?

        /// Upsamples by repeating each component sample over its dx × dy
        /// reference grid cell, clamped to the component edges.
        init(_ channel: Int, image: ComponentImage, mapping: [ComponentMapping]?, palette: PaletteBox?,
             crop: (Int, Int, Int, Int), referenceOrigin: (Int, Int),
             budget: inout MemoryBudget) throws(JP2KError) {
            try self.init(channel, image: image, mapping: mapping, palette: palette, crop: crop,
                          leadingZeroParity: nil, mayBeEmpty: false, budget: &budget,
                          column: { column, descriptor throws(JP2KError) in
                              let absolute = try Checked.add(Checked.add(crop.0, column), referenceOrigin.0)
                              let position = try Checked.sub(Checked.ceilDiv(absolute, descriptor.dx), descriptor.x0)
                              return min(max(0, position), descriptor.width - 1)
                          },
                          row: { row, descriptor throws(JP2KError) in
                              let absolute = try Checked.add(Checked.add(crop.1, row), referenceOrigin.1)
                              let position = try Checked.sub(Checked.ceilDiv(absolute, descriptor.dy), descriptor.y0)
                              return min(max(0, position), descriptor.height - 1) * descriptor.width
                          })
        }

        /// sYCC chroma. `luma` is the channel that cdef placed first:
        /// OpenJPEG converts sYCC after cdef has reordered the components,
        /// so the 4:2:2 / 4:2:0 layout is judged against that channel, not
        /// the codestream's component 0. Other layouts upsample as usual.
        init(chroma channel: Int, luma lumaChannel: Int, image: ComponentImage, mapping: [ComponentMapping]?,
             palette: PaletteBox?, crop: (Int, Int, Int, Int), referenceOrigin: (Int, Int),
             budget: inout MemoryBudget) throws(JP2KError) {
            let source = try sourceComponent(channel, mapping: mapping)
            let lumaSource = try sourceComponent(lumaChannel, mapping: mapping)
            let count = image.info.components.count
            if source < 0 || source >= count || lumaSource < 0 || lumaSource >= count {
                throw .invalidContainer(.badComponentMapping)
            }
            let luma = image.info.components[lumaSource]
            let chroma = image.info.components[source]
            guard luma.dx == 1, luma.dy == 1, chroma.dx == 2, chroma.dy == 1 || chroma.dy == 2 else {
                try self.init(channel, image: image, mapping: mapping, palette: palette, crop: crop,
                              referenceOrigin: referenceOrigin, budget: &budget)
                return
            }
            // sycc422_to_rgb / sycc420_to_rgb walk the component grids
            // directly, so positions here are image coordinates; an odd
            // leading edge reads as zero chroma. A single luma column or
            // row on an odd origin leaves the chroma with no samples at
            // all, and every pixel then takes that zero path.
            let offx = luma.x0 & 1
            let offy = chroma.dy == 2 ? luma.y0 & 1 : 0
            let halfRows = chroma.dy == 2
            try self.init(channel, image: image, mapping: mapping, palette: palette, crop: crop,
                          leadingZeroParity: halfRows && crop.0 < offx ? try Checked.sub(crop.1, offy) & 1 : nil,
                          mayBeEmpty: true, budget: &budget,
                          column: { column, descriptor throws(JP2KError) in
                              let x = try Checked.add(crop.0, column)
                              // 4:2:2 zeroes the whole leading column; 4:2:0
                              // only on each pair's first row (leadingZeroParity)
                              // and reads chroma column 0 on the others.
                              if x < offx && !halfRows { return -1 }
                              let position = x < offx ? 0 : try Checked.sub(x, offx) / 2
                              return position < descriptor.width ? position : -1
                          },
                          row: { row, descriptor throws(JP2KError) in
                              let y = try Checked.add(crop.1, row)
                              if y < offy { return -1 }
                              let position = halfRows ? try Checked.sub(y, offy) / 2 : y
                              return position < descriptor.height ? try Checked.mul(position, descriptor.width) : -1
                          })
        }

        private init(_ channel: Int, image: ComponentImage, mapping: [ComponentMapping]?, palette: PaletteBox?,
                     crop: (Int, Int, Int, Int), leadingZeroParity: Int?, mayBeEmpty: Bool,
                     budget: inout MemoryBudget,
                     column: (Int, ComponentInfo) throws(JP2KError) -> Int,
                     row: (Int, ComponentInfo) throws(JP2KError) -> Int) throws(JP2KError) {
            let source = try sourceComponent(channel, mapping: mapping)
            guard source >= 0, source < image.components.count,
                  source < image.info.components.count else { throw .invalidContainer(.badComponentMapping) }
            let descriptor = image.info.components[source]
            guard mayBeEmpty || (descriptor.width > 0 && descriptor.height > 0) else {
                throw .invalidCodestream(.badSIZ)
            }
            guard try Checked.mul(descriptor.width, descriptor.height) <= image.components[source].count else {
                throw .invalidCodestream(.badSIZ)
            }
            if let mapping, let palette, mapping[channel].mtyp == 1 {
                if channel >= palette.entries.count || palette.entries[channel].isEmpty {
                    throw .invalidContainer(.badPalette)
                }
                self.palette = palette.entries[channel]
            } else {
                self.palette = nil
            }
            let format = try channelFormat(channel, image: image, mapping: mapping, palette: palette)
            scale = ChannelScale(precision: format.precision, signed: format.signed)
            self.leadingZeroParity = leadingZeroParity
            var columns = try budget.array(repeating: 0, count: crop.2)
            var rows: [Int]
            do {
                rows = try budget.array(repeating: 0, count: crop.3)
            } catch {
                budget.release(bytes: columns.capacity * MemoryLayout<Int>.stride)
                throw error
            }
            tableBytes = (columns.capacity + rows.capacity) * MemoryLayout<Int>.stride
            do {
                for index in columns.indices { columns[index] = try column(index, descriptor) }
                for index in rows.indices { rows[index] = try row(index, descriptor) }
            } catch {
                budget.release(bytes: tableBytes)
                throw error
            }
            self.columns = columns
            self.rows = rows
            samples = image.components[source]
        }

        /// Sample at a table index, through the palette when there is one.
        @inline(__always) func raw(at index: Int) -> Int {
            let value = Int(samples[index])
            guard let palette else { return value }
            return Int(palette[min(max(0, value), palette.count - 1)])
        }

        @inline(__always) func value(at index: Int) -> UInt8 { scale.apply(raw(at: index)) }

        /// Sample for an output position, honouring zero-chroma entries.
        func sample(row: Int, column: Int) -> Int {
            let offset = rows[row]
            let position = columns[column]
            if offset < 0 || position < 0 { return 0 }
            if column == 0, let parity = leadingZeroParity, row & 1 == parity { return 0 }
            return raw(at: offset + position)
        }
    }

    private struct ChannelScale {
        let maximum: Int
        let offset: Int

        init(precision: Int, signed: Bool) {
            maximum = (1...16).contains(precision) ? (1 << precision) - 1 : 0
            offset = signed && (1...16).contains(precision) ? 1 << (precision - 1) : 0
        }

        @inline(__always) func apply(_ value: Int) -> UInt8 {
            if maximum == 0 { return 0 }
            let clipped = min(max(value + offset, 0), maximum)
            return UInt8((clipped * 255 + maximum / 2) / maximum)
        }
    }

    /// Precision and signedness of output channel `channel`: the palette's
    /// when cmap routes the channel through pclr, else its source component's.
    private static func channelFormat(_ channel: Int, image: ComponentImage, mapping: [ComponentMapping]?,
                                      palette: PaletteBox?) throws(JP2KError) -> (precision: Int, signed: Bool) {
        let source = try sourceComponent(channel, mapping: mapping)
        guard image.info.components.indices.contains(source) else {
            throw .invalidContainer(.badComponentMapping)
        }
        if let mapping, let palette, channel < mapping.count {
            return (palette.bitDepths[channel], palette.signed[channel])
        }
        let descriptor = image.info.components[source]
        return (descriptor.precision, descriptor.isSigned)
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

    /// Codestream component feeding output channel `channel` (through cmap
    /// when present); out-of-range channels are rejected instead of trapping.
    static func sourceComponent(_ channel: Int, mapping: [ComponentMapping]?) throws(JP2KError) -> Int {
        guard let mapping else { return channel }
        guard channel >= 0 && channel < mapping.count else { throw .invalidContainer(.badComponentMapping) }
        return mapping[channel].cmp
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
