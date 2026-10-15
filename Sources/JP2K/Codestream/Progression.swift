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
 * Copyright (c) 2006-2007, Parvatha Elangovan
 * Copyright (c) 2010-2011, Kaori Hagihara
 * Copyright (c) 2011-2012, Centre National d'Etudes Spatiales (CNES), France
 * Copyright (c) 2012, CS Systemes d'Information, France
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
// Ported from OpenJPEG v2.5.4: j2k.c: opj_j2k_read_poc
struct ProgressionChange: Sendable {
    var resStart, compStart, layerEnd, resEnd, compEnd: Int
    var order: ProgressionOrder
}

enum Progression {
    static func parse(_ payload: ByteReader, count: Int, layers: Int,
                      context: inout DecodeContext) throws(JP2KError) -> [ProgressionChange] {
        var reader = payload
        let wide = count > 256
        let recordLength = wide ? 9 : 7
        if reader.remaining == 0 || reader.remaining % recordLength != 0 { throw .invalidCodestream(.badPOC) }
        let recordCount = reader.remaining / recordLength
        if recordCount >= 32 { throw .invalidCodestream(.badPOC) }
        try context.budget.reserve(bytes: try Checked.mul(recordCount, MemoryLayout<ProgressionChange>.stride))
        var changes: [ProgressionChange] = []
        changes.reserveCapacity(recordCount)
        while reader.remaining > 0 {
            let rs = try Checked.int(reader.u8())
            let cs = wide ? try Checked.int(reader.u16()) : try Checked.int(reader.u8())
            let layer = try Checked.int(reader.u16())
            let re = try Checked.int(reader.u8())
            let ce = wide ? try Checked.int(reader.u16()) : try Checked.int(reader.u8())
            guard let order = ProgressionOrder(rawValue: try reader.u8()) else { throw .invalidCodestream(.badPOC) }
            if rs >= re || cs >= ce || cs >= count || layer == 0 { throw .invalidCodestream(.badPOC) }
            changes.append(ProgressionChange(resStart: rs, compStart: cs, layerEnd: min(layer, layers),
                                             resEnd: re, compEnd: min(ce, count), order: order))
        }
        return changes
    }
}
