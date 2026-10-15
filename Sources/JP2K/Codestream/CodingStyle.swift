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
// Ported from OpenJPEG v2.5.4: j2k.c: opj_j2k_read_cod, opj_j2k_read_coc, opj_j2k_read_SPCod_SPCoc
enum ProgressionOrder: UInt8, Sendable { case lrcp, rlcp, rpcl, pcrl, cprl }

struct ComponentCodingStyle: Sendable {
    var decompositionLevels: Int
    var codeBlockWidthExp: Int
    var codeBlockHeightExp: Int
    var codeBlockStyle: UInt8
    var reversible: Bool
    var precinctSizes: [(ppx: Int, ppy: Int)]

    static func parse(_ reader: inout ByteReader, precincts: Bool,
                      context: inout DecodeContext) throws(JP2KError) -> Self {
        if reader.remaining < 5 { throw .invalidCodestream(.badCOD) }
        let levels = try Checked.int(reader.u8())
        let width = try Checked.add(Checked.int(reader.u8()), 2)
        let height = try Checked.add(Checked.int(reader.u8()), 2)
        let style = try reader.u8()
        let transform = try reader.u8()
        let exponentSum = try Checked.add(width, height)
        if levels > 32 || width > 10 || height > 10 || exponentSum > 12 || transform > 1 {
            throw .invalidCodestream(.specRange)
        }
        if style & 0x40 != 0 { throw .unsupported(.htj2k) }
        if style & 0x80 != 0 { throw .invalidCodestream(.badCOD) }
        let count = try Checked.add(levels, 1)
        if reader.remaining != (precincts ? count : 0) { throw .invalidCodestream(.badCOD) }
        try context.budget.reserve(bytes: try Checked.mul(count, MemoryLayout<(ppx: Int, ppy: Int)>.stride))
        var sizes: [(ppx: Int, ppy: Int)] = []
        sizes.reserveCapacity(count)
        for index in 0..<count {
            if precincts {
                let byte = try reader.u8()
                let ppx = Int(byte & 15), ppy = Int(byte >> 4)
                if index > 0 && (ppx == 0 || ppy == 0) { throw .invalidCodestream(.specRange) }
                sizes.append((ppx, ppy))
            } else { sizes.append((15, 15)) }
        }
        return Self(decompositionLevels: levels, codeBlockWidthExp: width, codeBlockHeightExp: height,
                    codeBlockStyle: style, reversible: transform == 1, precinctSizes: sizes)
    }
}

struct CodingStyle: Sendable {
    var usesPrecincts: Bool
    var usesSOP: Bool
    var usesEPH: Bool
    var progression: ProgressionOrder
    var layers: Int
    var mct: Bool
    var component: ComponentCodingStyle

    static func parse(_ payload: ByteReader, context: inout DecodeContext) throws(JP2KError) -> Self {
        var reader = payload
        if reader.remaining < 10 { throw .invalidCodestream(.badCOD) }
        let flags = try reader.u8()
        let rawOrder = try reader.u8()
        guard let order = ProgressionOrder(rawValue: rawOrder) else { throw .invalidCodestream(.badCOD) }
        let layers = try Checked.int(reader.u16())
        let mct = try reader.u8()
        if flags & 0xF8 != 0 || layers == 0 || mct > 1 { throw .invalidCodestream(.badCOD) }
        if layers > context.limits.maxLayers { throw .limitExceeded(.layers) }
        let component = try ComponentCodingStyle.parse(&reader, precincts: flags & 1 != 0, context: &context)
        return Self(usesPrecincts: flags & 1 != 0, usesSOP: flags & 2 != 0,
                    usesEPH: flags & 4 != 0, progression: order, layers: layers,
                    mct: mct == 1, component: component)
    }

    static func parseCOC(_ payload: ByteReader, count: Int,
                         context: inout DecodeContext) throws(JP2KError) -> (Int, ComponentCodingStyle) {
        var reader = payload
        let component = count <= 256 ? try Checked.int(reader.u8()) : try Checked.int(reader.u16())
        let flag = try reader.u8()
        if component >= count || flag & 0xFE != 0 { throw .invalidCodestream(.badCOC) }
        return (component, try ComponentCodingStyle.parse(&reader, precincts: flag & 1 != 0, context: &context))
    }
}
