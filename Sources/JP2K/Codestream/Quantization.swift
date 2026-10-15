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
// Ported from OpenJPEG v2.5.4: j2k.c: opj_j2k_read_qcd, opj_j2k_read_qcc, opj_j2k_read_SQcd_SQcc
struct QuantizationStyle: Sendable {
    var style: UInt8
    var guardBits: Int
    var stepSizes: [(exponent: Int, mantissa: Int)]

    static func parse(_ payload: ByteReader, context: inout DecodeContext) throws(JP2KError) -> Self {
        var reader = payload
        if reader.remaining < 2 { throw .invalidCodestream(.badQCD) }
        let descriptor = try reader.u8()
        let style = descriptor & 31
        if style > 2 { throw .invalidCodestream(.badQCD) }
        let guardBits = Int(descriptor >> 5)
        let bytesPerStep = style == 0 ? 1 : 2
        if reader.remaining % bytesPerStep != 0 || (style == 1 && reader.remaining != 2) {
            throw .invalidCodestream(.badQCD)
        }
        let count = reader.remaining / bytesPerStep
        if count == 0 || count > 97 { throw .invalidCodestream(.badQCD) }
        try context.budget.reserve(bytes: try Checked.mul(count, MemoryLayout<(exponent: Int, mantissa: Int)>.stride))
        var steps: [(exponent: Int, mantissa: Int)] = []
        steps.reserveCapacity(count)
        for _ in 0..<count {
            if style == 0 {
                steps.append((Int(try reader.u8() >> 3), 0))
            } else {
                let value = try reader.u16()
                steps.append((Int(value >> 11), Int(value & 0x7FF)))
            }
        }
        return Self(style: style, guardBits: guardBits, stepSizes: steps)
    }

    static func parseQCC(_ payload: ByteReader, count: Int,
                         context: inout DecodeContext) throws(JP2KError) -> (Int, Self) {
        var reader = payload
        let component = count <= 256 ? try Checked.int(reader.u8()) : try Checked.int(reader.u16())
        if component >= count { throw .invalidCodestream(.badQCC) }
        return (component, try parse(reader, context: &context))
    }
}
