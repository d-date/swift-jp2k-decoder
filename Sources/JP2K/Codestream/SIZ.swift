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
// Ported from OpenJPEG v2.5.4: j2k.c: opj_j2k_read_siz
struct SIZComponent: Sendable {
    var precision: Int
    var isSigned: Bool
    var dx: Int
    var dy: Int
}

struct ImageGeometry: Sendable {
    var rsiz: UInt16
    var x1, y1, x0, y0: Int
    var tileWidth, tileHeight, tileX0, tileY0: Int
    var components: [SIZComponent]
    var tilesAcross, tilesDown: Int

    static func parse(_ payload: ByteReader, context: inout DecodeContext) throws(JP2KError) -> Self {
        var reader = payload
        if reader.remaining < 36 || (reader.remaining - 36) % 3 != 0 { throw .invalidCodestream(.badSIZ) }
        let rsiz = try reader.u16()
        if rsiz & 0x4000 != 0 { throw .unsupported(.htj2k) }
        if rsiz & 0x8000 != 0 { throw .unsupported(.part2) }
        let x1 = try Checked.int(reader.u32()), y1 = try Checked.int(reader.u32())
        let x0 = try Checked.int(reader.u32()), y0 = try Checked.int(reader.u32())
        let tw = try Checked.int(reader.u32()), th = try Checked.int(reader.u32())
        let tx = try Checked.int(reader.u32()), ty = try Checked.int(reader.u32())
        let count = try Checked.int(reader.u16())
        if count == 0 || count > 16_384 || count != reader.remaining / 3 { throw .invalidCodestream(.badSIZ) }
        let tx1 = try Checked.add(tx, tw)
        let ty1 = try Checked.add(ty, th)
        if x0 >= x1 || y0 >= y1 || tw == 0 || th == 0 || tx > x0 || ty > y0 || tx1 <= x0 || ty1 <= y0 {
            throw .invalidCodestream(.badSIZ)
        }
        let width = try Checked.sub(x1, x0), height = try Checked.sub(y1, y0)
        if try Checked.mul(width, height) > context.limits.maxPixels { throw .limitExceeded(.pixels) }
        if count > context.limits.maxComponents { throw .limitExceeded(.components) }
        let across = try Checked.ceilDiv(Checked.sub(x1, tx), tw)
        let down = try Checked.ceilDiv(Checked.sub(y1, ty), th)
        if try Checked.mul(across, down) > context.limits.maxTiles { throw .limitExceeded(.tiles) }
        try context.budget.reserve(bytes: try Checked.mul(count, MemoryLayout<SIZComponent>.stride))
        var components: [SIZComponent] = []
        components.reserveCapacity(count)
        for _ in 0..<count {
            let descriptor = try reader.u8()
            let precision = try Checked.add(Checked.int(descriptor & 0x7F), 1)
            let dx = try Checked.int(reader.u8()), dy = try Checked.int(reader.u8())
            if dx == 0 || dy == 0 || precision > 38 { throw .invalidCodestream(.specRange) }
            if precision > 16 { throw .unsupported(.bitDepthAbove16) }
            if precision > context.limits.maxBitDepth { throw .limitExceeded(.bitDepth) }
            components.append(SIZComponent(precision: precision, isSigned: descriptor & 0x80 != 0, dx: dx, dy: dy))
        }
        return Self(rsiz: rsiz, x1: x1, y1: y1, x0: x0, y0: y0,
                    tileWidth: tw, tileHeight: th, tileX0: tx, tileY0: ty,
                    components: components, tilesAcross: across, tilesDown: down)
    }

    func reservePlaneEstimate(context: inout DecodeContext) throws(JP2KError) {
        for component in components {
            let w = try Checked.sub(Checked.ceilDiv(x1, component.dx), Checked.ceilDiv(x0, component.dx))
            let h = try Checked.sub(Checked.ceilDiv(y1, component.dy), Checked.ceilDiv(y0, component.dy))
            try context.budget.reserve(bytes: try Checked.mul(Checked.mul(w, h), 4))
        }
    }
}
