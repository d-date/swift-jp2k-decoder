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
 * Copyright (c) 2008, Jerome Fimes, Communications & Systemes <jerome.fimes@c-s.fr>
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
// Ported from OpenJPEG v2.5.4: mqc.c: opj_mqc_init_enc, opj_mqc_flush, opj_mqc_byteout; mqc_inl.h: opj_mqc_encode
@testable import JP2K

struct MQEncoder {
    private var a: UInt32 = 0x8000
    private var c: UInt32 = 0
    private var ct = 12
    private var previous: UInt8 = 0
    private var output: [UInt8] = []
    private var states = [Int](repeating: 0, count: 19)

    mutating func setState(context: Int, msb: Int, prob: Int) {
        states[context] = msb + 2 * prob
    }

    mutating func encode(_ bit: Int, context: Int) {
        let state = T1Tables.states[states[context]]
        a -= state.qeval
        if bit == state.mps {
            if a & 0x8000 == 0 {
                if a < state.qeval { a = state.qeval } else { c &+= state.qeval }
                states[context] = state.nmps
                renormalize()
            } else {
                c &+= state.qeval
            }
        } else {
            if a < state.qeval { c &+= state.qeval } else { a = state.qeval }
            states[context] = state.nlps
            renormalize()
        }
    }

    mutating func flush() -> [UInt8] {
        let temporary = c &+ a
        c |= 0xFFFF
        if c >= temporary { c &-= 0x8000 }
        c <<= ct
        byteOut()
        c <<= ct
        byteOut()
        return output
    }

    private mutating func renormalize() {
        repeat {
            a <<= 1
            c <<= 1
            ct -= 1
            if ct == 0 { byteOut() }
        } while a & 0x8000 == 0
    }

    private mutating func byteOut() {
        if previous == 0xFF {
            previous = UInt8(truncatingIfNeeded: c >> 20)
            output.append(previous)
            c &= 0xFFFFF
            ct = 7
        } else if c & 0x8000000 == 0 {
            previous = UInt8(truncatingIfNeeded: c >> 19)
            output.append(previous)
            c &= 0x7FFFF
            ct = 8
        } else {
            previous &+= 1
            if !output.isEmpty { output[output.count - 1] = previous }
            if previous == 0xFF {
                c &= 0x7FFFFFF
                previous = UInt8(truncatingIfNeeded: c >> 20)
                output.append(previous)
                c &= 0xFFFFF
                ct = 7
            } else {
                previous = UInt8(truncatingIfNeeded: c >> 19)
                output.append(previous)
                c &= 0x7FFFF
                ct = 8
            }
        }
    }
}

extension MQDecoder {
    /// Test-only convenience: a decoder with an ample budget.
    static func testing(data: [UInt8], segmentLengths: [Int]) -> MQDecoder {
        var budget = MemoryBudget(limit: Int.max)
        // A 2-byte padded copy of a test vector always fits an Int.max budget.
        guard let decoder = try? MQDecoder(data: data, segmentLengths: segmentLengths, budget: &budget) else {
            return MQDecoder.testing(data: [], segmentLengths: [0])
        }
        return decoder
    }
}
