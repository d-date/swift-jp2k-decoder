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
// Ported from OpenJPEG v2.5.4: mqc.c: opj_mqc_init_dec, opj_mqc_raw_init_dec, opj_mqc_resetstates, opj_mqc_setstate; mqc_inl.h: opj_mqc_bytein, opj_mqc_decode, opj_mqc_raw_decode
struct MQDecoder {
    private let data: [UInt8]
    private let segmentLengths: [Int]
    private let segments: [CodeBlockSegment]
    private var position = 0
    private var segmentStart = 0
    private var end = 0
    private var a: UInt32 = 0x8000
    private var c: UInt32 = 0
    private var ct = 0
    private var states = [Int](repeating: 0, count: 19)
    private(set) var endOfByteStreamCounter = 0

    /// The decoder keeps a padded copy of the code-block data (two 0xFF bytes
    /// past the end, as opj_mqc_init_dec arranges), so the copy is charged to
    /// the budget; there is deliberately no unbudgeted initializer.
    init(data: [UInt8], segmentLengths: [Int], budget: inout MemoryBudget) throws(JP2KError) {
        let length = try Checked.add(data.count, 2)
        try budget.reserve(bytes: length)
        self.data = data + [0xFF, 0xFF]
        self.segmentLengths = segmentLengths
        self.segments = []
        let first = segmentLengths.first ?? data.count
        end = min(data.count, max(0, first))
        initializeMQ()
    }

    /// Borrows the code-block decoder's already budgeted, padded scratch.
    init(paddedData: [UInt8], dataCount: Int, segments: [CodeBlockSegment]) {
        self.data = paddedData
        self.segmentLengths = []
        self.segments = segments
        let first = segments.first?.length ?? dataCount
        end = min(dataCount, max(0, first))
        initializeMQ()
    }

    mutating func resetStates() {
        for index in states.indices { states[index] = 0 }
    }

    mutating func setState(context: Int, msb: Int, prob: Int) {
        guard (0..<19).contains(context), (0...1).contains(msb), (0..<47).contains(prob) else { return }
        states[context] = msb + 2 * prob
    }

    mutating func startSegment(_ index: Int, raw: Bool = false) {
        let segmentCount = segments.isEmpty ? segmentLengths.count : segments.count
        guard (0..<segmentCount).contains(index) else { return }
        var start = 0
        for previous in 0..<index {
            let length = segments.isEmpty ? segmentLengths[previous] : segments[previous].length
            let (sum, overflow) = start.addingReportingOverflow(max(0, length))
            start = overflow ? data.count - 2 : min(data.count - 2, sum)
        }
        position = start
        segmentStart = start
        let length = segments.isEmpty ? segmentLengths[index] : segments[index].length
        let (finish, overflow) = start.addingReportingOverflow(max(0, length))
        end = overflow ? data.count - 2 : min(data.count - 2, finish)
        if raw { rawInitDec() } else { initializeMQ() }
    }

    mutating func rawInitDec() {
        position = segmentStart
        c = 0
        ct = 0
    }

    mutating func rawDecode() -> Int {
        if ct == 0 {
            if c == 0xFF {
                if byte(at: position) > 0x8F {
                    c = 0xFF
                    ct = 8
                } else {
                    c = UInt32(byte(at: position))
                    position += 1
                    ct = 7
                }
            } else {
                c = UInt32(byte(at: position))
                position += 1
                ct = 8
            }
        }
        ct -= 1
        return Int((c >> ct) & 1)
    }

    /// `context` comes from the T1 context tables, whose values are all in
    /// 0..<19 (pinned by a test); the guard only keeps a caller bug from trapping.
    mutating func decode(context: Int) -> Int {
        guard states.indices.contains(context) else { return 0 }
        let state = T1Tables.states[states[context]]
        a -= state.qeval
        let decision: Int
        if c >> 16 < state.qeval {
            if a < state.qeval {
                a = state.qeval
                decision = state.mps
                states[context] = state.nmps
            } else {
                a = state.qeval
                decision = 1 - state.mps
                states[context] = state.nlps
            }
            renormalize()
        } else {
            c -= state.qeval << 16
            if a & 0x8000 == 0 {
                if a < state.qeval {
                    decision = 1 - state.mps
                    states[context] = state.nlps
                } else {
                    decision = state.mps
                    states[context] = state.nmps
                }
                renormalize()
            } else {
                decision = state.mps
            }
        }
        return decision
    }

    private func byte(at index: Int) -> UInt8 {
        if index >= end { return 0xFF }
        if data.indices.contains(index) { return data[index] }
        return 0xFF
    }

    private mutating func byteIn() {
        let next = UInt32(byte(at: position + 1))
        if byte(at: position) == 0xFF {
            if next > 0x8F {
                c &+= 0xFF00
                ct = 8
                endOfByteStreamCounter += 1
            } else {
                position += 1
                c &+= next << 9
                ct = 7
            }
        } else {
            position += 1
            c &+= next << 8
            ct = 8
        }
    }

    private mutating func initializeMQ() {
        endOfByteStreamCounter = 0
        c = UInt32(byte(at: position)) << 16
        byteIn()
        c <<= 7
        ct -= 7
        a = 0x8000
    }

    private mutating func renormalize() {
        repeat {
            if ct == 0 { byteIn() }
            a <<= 1
            c <<= 1
            ct -= 1
        } while a < 0x8000
    }
}
