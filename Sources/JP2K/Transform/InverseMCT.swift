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
 * Copyright (c) 2008, 2011-2012, Centre National d'Etudes Spatiales (CNES), FR
 * Copyright (c) 2012, CS Systemes d'Information, France
 * Copyright (c) 2006-2007, Parvatha Elangovan
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
// Ported from OpenJPEG v2.5.4: mct.c: opj_mct_decode, opj_mct_decode_real; tcd.c: opj_tcd_dc_level_shift_decode
/// Inverse colour transform and final precision adjustment.
enum InverseMCT {
    static func decode(_ tile: inout TileGeometry, reversible: Bool) throws(JP2KError) {
        guard tile.components.count >= 3 else { throw .invalidCodestream(.badCOD) }
        let count = tile.components[0].coefficients.count
        guard tile.components[1].coefficients.count == count,
              tile.components[2].coefficients.count == count else { throw .invalidCodestream(.badCOD) }
        for index in 0..<count {
            let y = tile.components[0].coefficients[index]
            let u = tile.components[1].coefficients[index]
            let v = tile.components[2].coefficients[index]
            if reversible {
                let green = Int64(y) - ((Int64(u) + Int64(v)) >> 2)
                tile.components[0].coefficients[index] = Int32(clamping: green + Int64(v))
                tile.components[1].coefficients[index] = Int32(clamping: green)
                tile.components[2].coefficients[index] = Int32(clamping: green + Int64(u))
            } else {
                let yf = Float(bitPattern: UInt32(bitPattern: y))
                let uf = Float(bitPattern: UInt32(bitPattern: u))
                let vf = Float(bitPattern: UInt32(bitPattern: v))
                let redTerm = vf * 1.402
                let greenUTerm = uf * 0.34413
                let greenVTerm = vf * 0.71414
                let blueTerm = uf * 1.772
                tile.components[0].coefficients[index] = Int32(bitPattern: (yf + redTerm).bitPattern)
                tile.components[1].coefficients[index] = Int32(bitPattern: (yf - greenUTerm - greenVTerm).bitPattern)
                tile.components[2].coefficients[index] = Int32(bitPattern: (yf + blueTerm).bitPattern)
            }
        }
    }

    static func levelShift(_ values: inout [Int32], precision: Int, signed: Bool,
                           reversible: Bool) throws(JP2KError) {
        guard (1...16).contains(precision) else { throw .invalidCodestream(.specRange) }
        let offset = signed ? 0 : 1 << (precision - 1)
        let minimum = signed ? -(1 << (precision - 1)) : 0
        let maximum = signed ? (1 << (precision - 1)) - 1 : (1 << precision) - 1
        let low = Int64(minimum), high = Int64(maximum), shift = Int64(offset)
        if reversible {
            for index in values.indices {
                values[index] = Int32(clamping: min(high, max(low, Int64(values[index]) + shift)))
            }
            return
        }
        for index in values.indices {
            let real = Float(bitPattern: UInt32(bitPattern: values[index]))
            if real.isNaN { throw .invalidCodestream(.badCodeBlock) }
            let value: Int64
            if real >= Float(Int32.max) { value = Int64(Int32.max) } else if real <= Float(Int32.min) { value = Int64(Int32.min) } else { value = Int64(real.rounded(.toNearestOrEven)) }
            values[index] = Int32(clamping: min(high, max(low, value + shift)))
        }
    }
}
