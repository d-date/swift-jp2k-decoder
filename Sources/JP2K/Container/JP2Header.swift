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
// Ported from OpenJPEG v2.5.4: jp2.c: opj_jp2_read_ihdr, opj_jp2_read_bpcc, opj_jp2_read_colr, opj_jp2_read_pclr, opj_jp2_read_cmap, opj_jp2_read_cdef, opj_jp2_check_color
struct ImageHeaderBox: Sendable, Equatable {
    var height: Int
    var width: Int
    var nc: Int
    var bpc: UInt8
    var c: UInt8
    var unkC: UInt8
    var ipr: UInt8
}

enum ColourSpecification: Sendable, Equatable {
    case enumerated(UInt32)
    case restrictedICC([UInt8])
    case other(method: UInt8)
}

struct PaletteBox: Sendable, Equatable {
    var entries: [[Int32]]
    var bitDepths: [Int]
    var signed: [Bool]
}

struct ComponentMapping: Sendable, Equatable {
    var cmp: Int
    var mtyp: UInt8
    var pcol: Int
}

struct ChannelDefinition: Sendable, Equatable {
    var cn: Int
    var typ: Int
    var asoc: Int
}

struct JP2Header: Sendable, Equatable {
    var imageHeader: ImageHeaderBox
    var bitsPerComponent: [UInt8]?
    var colour: ColourSpecification
    var palette: PaletteBox?
    var componentMapping: [ComponentMapping]?
    var channelDefinitions: [ChannelDefinition]?

    static func parse(_ payload: ByteReader, context: inout DecodeContext) throws(JP2KError) -> Self {
        var reader = payload
        if reader.remaining == 0 { throw .invalidContainer(.missingImageHeader) }
        let (firstType, firstPayload, _) = try JP2Parser.nextBox(&reader)
        if firstType != 0x6968_6472 { throw .invalidContainer(.missingImageHeader) }
        let image = try readImageHeader(firstPayload)
        var result = Self(imageHeader: image, bitsPerComponent: nil, colour: .other(method: 0),
                          palette: nil, componentMapping: nil, channelDefinitions: nil)
        var hasColour = false
        while reader.remaining > 0 {
            let (type, body, _) = try JP2Parser.nextBox(&reader)
            switch type {
            case 0x6968_6472: throw .invalidContainer(.duplicateBox)
            case 0x6270_6363:
                if result.bitsPerComponent != nil { throw .invalidContainer(.duplicateBox) }
                if body.remaining != image.nc { throw .invalidContainer(.badBoxLength) }
                var part = body
                try context.budget.reserve(bytes: image.nc)
                result.bitsPerComponent = Array(try part.bytes(count: image.nc))
            case 0x636F_6C72:
                if !hasColour {
                    result.colour = try readColour(body, context: &context)
                    hasColour = true
                }
            case 0x7063_6C72:
                if result.palette != nil { throw .invalidContainer(.duplicateBox) }
                result.palette = try readPalette(body, context: &context)
            case 0x636D_6170:
                if result.componentMapping != nil { throw .invalidContainer(.duplicateBox) }
                guard let palette = result.palette else { throw .invalidContainer(.badComponentMapping) }
                result.componentMapping = try readMapping(body, columns: palette.bitDepths.count,
                                                          components: image.nc, context: &context)
            case 0x6364_6566:
                if result.channelDefinitions != nil { throw .invalidContainer(.duplicateBox) }
                result.channelDefinitions = try readDefinitions(body, context: &context)
            default: break
            }
        }
        try validate(&result)
        return result
    }

    private static func readImageHeader(_ payload: ByteReader) throws(JP2KError) -> ImageHeaderBox {
        if payload.remaining != 14 { throw .invalidContainer(.badBoxLength) }
        var reader = payload
        let height = try Checked.int(reader.u32())
        let width = try Checked.int(reader.u32())
        let count = try Checked.int(reader.u16())
        if height == 0 || width == 0 || count == 0 || count > 16_384 {
            throw .invalidContainer(.missingImageHeader)
        }
        let bpc = try reader.u8()
        let c = try reader.u8()
        let unkC = try reader.u8()
        let ipr = try reader.u8()
        return ImageHeaderBox(height: height, width: width, nc: count, bpc: bpc, c: c, unkC: unkC, ipr: ipr)
    }

    private static func readColour(_ payload: ByteReader, context: inout DecodeContext) throws(JP2KError) -> ColourSpecification {
        var reader = payload
        if reader.remaining < 3 { throw .invalidContainer(.badColourSpecification) }
        let method = try reader.u8()
        _ = try reader.u8()
        _ = try reader.u8()
        switch method {
        case 1:
            if reader.remaining < 4 { throw .invalidContainer(.badColourSpecification) }
            return .enumerated(try reader.u32())
        case 2:
            try context.budget.reserve(bytes: reader.remaining)
            return .restrictedICC(Array(try reader.bytes(count: reader.remaining)))
        default: return .other(method: method)
        }
    }

    private static func readPalette(_ payload: ByteReader, context: inout DecodeContext) throws(JP2KError) -> PaletteBox {
        var reader = payload
        if reader.remaining < 3 { throw .invalidContainer(.badPalette) }
        let count = try Checked.int(reader.u16())
        let columns = try Checked.int(reader.u8())
        if count == 0 || count > 1024 || columns == 0 || reader.remaining < columns {
            throw .invalidContainer(.badPalette)
        }
        let entryCount = try Checked.mul(count, columns)
        let valueBytes = try Checked.mul(entryCount, MemoryLayout<Int32>.stride)
        let metaBytes = try Checked.mul(columns, MemoryLayout<Int>.stride + MemoryLayout<Bool>.stride)
        let outerBytes = try Checked.mul(columns, MemoryLayout<[Int32]>.stride)
        try context.budget.reserve(bytes: try Checked.add(Checked.add(valueBytes, metaBytes), outerBytes))
        // Capacities are fixed up front so the reserved byte count is exact.
        var depths: [Int] = []
        var signs: [Bool] = []
        depths.reserveCapacity(columns)
        signs.reserveCapacity(columns)
        for _ in 0..<columns {
            let descriptor = try reader.u8()
            let depth = try Checked.add(Checked.int(descriptor & 0x7F), 1)
            if depth > 38 { throw .invalidContainer(.badPalette) }
            depths.append(depth)
            signs.append(descriptor & 0x80 != 0)
        }
        var entries = [[Int32]](repeating: [], count: columns)
        for column in 0..<columns { entries[column].reserveCapacity(count) }
        for _ in 0..<count {
            for column in 0..<columns {
                let depth = depths[column]
                let byteCount = try Checked.ceilDiv(depth, 8)
                if reader.remaining < byteCount { throw .invalidContainer(.badPalette) }
                var value = 0
                for _ in 0..<byteCount {
                    value = try Checked.add(Checked.shiftLeft(value, 8), Checked.int(reader.u8()))
                }
                if depth <= 16 {
                    let mask = try Checked.sub(Checked.shiftLeft(1, depth), 1)
                    value &= mask
                    let signBit = try Checked.shiftLeft(1, Checked.sub(depth, 1))
                    if signs[column] && value & signBit != 0 {
                        value = try Checked.sub(value, Checked.shiftLeft(1, depth))
                    }
                    entries[column].append(try Checked.int32(value))
                } else {
                    entries[column].append(0)
                }
            }
        }
        if reader.remaining != 0 { throw .invalidContainer(.badPalette) }
        return PaletteBox(entries: entries, bitDepths: depths, signed: signs)
    }

    private static func readMapping(_ payload: ByteReader, columns: Int, components: Int,
                                    context: inout DecodeContext) throws(JP2KError) -> [ComponentMapping] {
        var reader = payload
        if reader.remaining != (try Checked.mul(columns, 4)) { throw .invalidContainer(.badComponentMapping) }
        try context.budget.reserve(bytes: try Checked.mul(columns, MemoryLayout<ComponentMapping>.stride))
        var mappings: [ComponentMapping] = []
        mappings.reserveCapacity(columns)
        var usedColumns = try context.budget.array(repeating: false, count: columns)
        for _ in 0..<columns {
            let cmp = try Checked.int(reader.u16())
            let method = try reader.u8()
            let column = try Checked.int(reader.u8())
            if cmp >= components || method > 1 || (method == 0 && column != 0) ||
                (method == 1 && (column >= columns || usedColumns[column])) {
                throw .invalidContainer(.badComponentMapping)
            }
            if method == 1 { usedColumns[column] = true }
            mappings.append(ComponentMapping(cmp: cmp, mtyp: method, pcol: column))
        }
        return mappings
    }

    private static func readDefinitions(_ payload: ByteReader,
                                        context: inout DecodeContext) throws(JP2KError) -> [ChannelDefinition] {
        var reader = payload
        if reader.remaining < 2 { throw .invalidContainer(.badChannelDefinition) }
        let count = try Checked.int(reader.u16())
        let expectedSize = try Checked.mul(count, 6)
        if count == 0 || count > 16_384 || reader.remaining != expectedSize {
            throw .invalidContainer(.badChannelDefinition)
        }
        try context.budget.reserve(bytes: try Checked.mul(count, MemoryLayout<ChannelDefinition>.stride))
        var definitions: [ChannelDefinition] = []
        var seen = try context.budget.array(repeating: false, count: count)
        for _ in 0..<count {
            let channel = try Checked.int(reader.u16())
            let kind = try Checked.int(reader.u16())
            let association = try Checked.int(reader.u16())
            if channel >= count || seen[channel] { throw .invalidContainer(.badChannelDefinition) }
            seen[channel] = true
            definitions.append(ChannelDefinition(cn: channel, typ: kind, asoc: association))
        }
        context.budget.release(bytes: try Checked.mul(count, MemoryLayout<Bool>.stride))
        return definitions
    }

    private static func validate(_ header: inout JP2Header) throws(JP2KError) {
        // OpenJPEG discards an unpaired pclr; reject either unpaired box in strict mode.
        if header.palette != nil && header.componentMapping == nil {
            throw .invalidContainer(.badPalette)
        }
        if header.palette == nil && header.componentMapping != nil {
            throw .invalidContainer(.badComponentMapping)
        }
        let channels = header.componentMapping?.count ?? header.imageHeader.nc
        if let definitions = header.channelDefinitions {
            if definitions.count != channels { throw .invalidContainer(.badChannelDefinition) }
            for item in definitions {
                if item.cn >= channels || (item.asoc != 0 && item.asoc != 65_535 && item.asoc > channels) {
                    throw .invalidContainer(.badChannelDefinition)
                }
            }
        }
    }
}
