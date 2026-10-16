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
 * Copyright (c) 2007, Callum Lerwick <seg@haxxed.com>
 * Copyright (c) 2012, Carl Hetherington
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
// Ported from OpenJPEG v2.5.4: t1.c: opj_t1_allocate_buffers, opj_t1_decode_cblk, opj_t1_dec_sigpass_raw, opj_t1_dec_sigpass_mqc, opj_t1_dec_refpass_raw, opj_t1_dec_refpass_mqc, opj_t1_dec_clnpass, opj_t1_dec_clnpass_check_segsym, opj_t1_dec_clnpass_step, opj_t1_update_flags, opj_t1_getctxtno_sc_or_spb_index
/// Noncopyable so its budget-charged scratch buffers can never be duplicated
/// by an uncharged copy-on-write.
struct CodeBlockDecoder: ~Copyable {
    private static let sigma = UInt32(1 << 4)
    private static let neighbours = UInt32(0x1EF)
    private static let pi = UInt32(1 << 21)
    private static let mu = UInt32(1 << 20)
    private static let piAll = UInt32((1 << 21) | (1 << 24) | (1 << 27) | (1 << 30))
    private let maxWidth: Int
    private let maxHeight: Int
    private var flags: [UInt32]
    private var data: [Int32] = []
    private var decodedCount = 0
    private var mqInput: [UInt8] = []

    init(maxWidth: Int, maxHeight: Int, budget: inout MemoryBudget) throws(JP2KError) {
        guard (1...1024).contains(maxWidth), (1...1024).contains(maxHeight),
              try Checked.mul(maxWidth, maxHeight) <= 4096 else { throw .invalidCodestream(.badCodeBlock) }
        self.maxWidth = maxWidth
        self.maxHeight = maxHeight
        flags = []
    }

    mutating func decode(_ block: CodeBlock, orientation: Int, roiShift: Int,
                         codeBlockStyle: UInt8, numBitPlanes: Int,
                         budget: inout MemoryBudget) throws(JP2KError) {
        decodedCount = 0
        let width = try Checked.sub(block.x1, block.x0)
        let height = try Checked.sub(block.y1, block.y0)
        guard width > 0, height > 0, width <= maxWidth, height <= maxHeight,
              (0...3).contains(orientation), roiShift >= 0,
              codeBlockStyle & 0xC0 == 0 else { throw .invalidCodestream(.badCodeBlock) }
        let planes: Int
        do {
            planes = try Checked.add(numBitPlanes, roiShift)
        } catch {
            throw .invalidCodestream(.badCodeBlock)
        }
        guard planes >= 0, planes < 31 else {
            throw .invalidCodestream(.badCodeBlock)
        }
        let count = try Checked.mul(width, height)
        let stride = try Checked.add(width, 2)
        let flagRows = try Checked.add(try Checked.ceilDiv(height, 4), 2)
        let activeFlags = try Checked.mul(stride, flagRows)
        if activeFlags > flags.count {
            try budget.append(contentsOf: repeatElement(UInt32.zero, count: activeFlags - flags.count), to: &flags)
        }
        if count > data.count {
            try budget.append(contentsOf: repeatElement(Int32.zero, count: count - data.count), to: &data)
        }
        for segment in block.segments where segment.length < 0 || segment.passes < 0 {
            throw .invalidCodestream(.badCodeBlock)
        }
        let paddedCount = try Checked.add(block.data.count, 2)
        mqInput.removeAll(keepingCapacity: true)
        if paddedCount > mqInput.capacity {
            // The helper charges both old and new storage during growth.
            try budget.append(contentsOf: repeatElement(UInt8.zero, count: paddedCount), to: &mqInput)
            mqInput.removeAll(keepingCapacity: true)
        }
        mqInput.append(contentsOf: block.data)
        mqInput.append(0xFF)
        mqInput.append(0xFF)
        for index in 0..<count { data[index] = 0 }
        for index in 0..<activeFlags { flags[index] = 0 }
        for x in 0..<stride {
            flags[x] = Self.piAll
            flags[(flagRows - 1) * stride + x] = Self.piAll
        }
        if height % 4 != 0 {
            let row = (height + 3) / 4
            // Set the unused row positions in the final stripe.
            let unused = (height % 4..<4).reduce(UInt32(0)) { $0 | (Self.pi << (3 * $1)) }
            for x in 0..<stride { flags[row * stride + x] = unused }
        }
        var working: [Int32] = []
        swap(&working, &data)
        var workingFlags: [UInt32] = []
        swap(&workingFlags, &flags)
        var mq = MQDecoder(paddedData: mqInput, dataCount: block.data.count, segments: block.segments)
        mq.resetStates()
        mq.setState(context: 18, msb: 0, prob: 46)
        mq.setState(context: 17, msb: 0, prob: 3)
        mq.setState(context: 0, msb: 0, prob: 4)
        var plane = planes
        var passType = 2
        let bypass = codeBlockStyle & 0x01 != 0
        let reset = codeBlockStyle & 0x02 != 0
        let vcausal = codeBlockStyle & 0x08 != 0
        let segsym = codeBlockStyle & 0x20 != 0
        for segmentIndex in block.segments.indices {
            let segment = block.segments[segmentIndex]
            let raw = bypass && plane <= numBitPlanes - 4 && passType < 2
            mq.startSegment(segmentIndex, raw: raw)
            for _ in 0..<segment.passes where plane >= 1 {
                switch passType {
                case 0:
                    Self.significancePass(width: width, height: height, stride: stride, plane: plane,
                                     orientation: orientation, raw: raw, vcausal: vcausal,
                                     mq: &mq, samples: &working, flags: &workingFlags)
                case 1:
                    Self.refinementPass(width: width, height: height, stride: stride, plane: plane,
                                        raw: raw, mq: &mq, samples: &working, flags: &workingFlags)
                default:
                    Self.cleanupPass(width: width, height: height, stride: stride, plane: plane,
                                     orientation: orientation, vcausal: vcausal, mq: &mq,
                                     samples: &working, flags: &workingFlags)
                    if segsym {
                        // OpenJPEG consumes all four symbols and only warns on a mismatch.
                        for _ in 0..<4 { _ = mq.decode(context: 18) }
                    }
                }
                if reset && !raw {
                    mq.resetStates()
                    mq.setState(context: 18, msb: 0, prob: 46)
                    mq.setState(context: 17, msb: 0, prob: 3)
                    mq.setState(context: 0, msb: 0, prob: 4)
                }
                passType += 1
                if passType == 3 { passType = 0; plane -= 1 }
            }
        }
        swap(&working, &data)
        swap(&workingFlags, &flags)
        decodedCount = count
    }

    /// The last decoded block is read element by element from the budgeted
    /// scratch buffer (row-major, width × height), so the decoder never writes
    /// into a caller-owned array that might share copy-on-write storage.
    var outputCount: Int { min(decodedCount, data.count) }

    func output(at index: Int) -> Int32 {
        index >= 0 && index < outputCount ? data[index] : 0
    }

    @inline(__always) private static func signIndex(_ word: UInt32, _ west: UInt32, _ east: UInt32,
                                                    _ row: Int) -> Int {
        let shift = row * 3
        var index = Int((word >> shift) & 0xAA)
        index |= Int((west >> (19 + shift)) & 1)
        index |= Int((east >> (17 + shift)) & 4)
        index |= Int((word >> (row == 0 ? 14 : 12 + shift)) & 16)
        index |= Int((word >> (16 + shift)) & 64)
        return index
    }

    @inline(__always) private static func mark(_ index: Int, row: Int, negative: Int, stride: Int,
                                               vcausal: Bool = false, flags: inout [UInt32]) {
        let shift = row * 3
        flags[index - 1] |= UInt32(1 << (5 + shift))
        flags[index] |= UInt32((1 << 4) | (negative << 19)) << shift
        flags[index + 1] |= UInt32(1 << (3 + shift))
        if row == 0 && !vcausal {
            let north = index - stride
            flags[north] |= UInt32((1 << 16) | (negative << 31))
            flags[north - 1] |= UInt32(1 << 17)
            flags[north + 1] |= UInt32(1 << 15)
        }
        if row == 3 {
            let south = index + stride
            flags[south] |= UInt32((1 << 1) | (negative << 18))
            flags[south - 1] |= UInt32(1 << 2)
            flags[south + 1] |= 1
        }
    }

    private static func significancePass(width: Int, height: Int, stride: Int, plane: Int,
                                         orientation: Int, raw: Bool = false, vcausal: Bool = false,
                                         mq: inout MQDecoder, samples: inout [Int32],
                                         flags: inout [UInt32]) {
        let magnitude = Int32((1 << plane) | (1 << (plane - 1)))
        for stripe in 0..<(height + 3) / 4 {
            let rows = min(4, height - stripe * 4)
            for x in 0..<width {
                let flagIndex = (stripe + 1) * stride + x + 1
                for row in 0..<rows {
                    let shift = row * 3
                    let word = flags[flagIndex]
                    if (word & ((Self.sigma | Self.pi) << shift)) != 0 ||
                        (word & (Self.neighbours << shift)) == 0 { continue }
                    let context = T1Tables.zeroContext(orientation: orientation, flags: Int(word >> shift))
                    if (raw ? mq.rawDecode() : mq.decode(context: context)) != 0 {
                        let sign = signIndex(word, flags[flagIndex - 1], flags[flagIndex + 1], row)
                        let negative = raw ? mq.rawDecode() :
                            mq.decode(context: T1Tables.signContext(sign)) ^ T1Tables.predictedSign(sign)
                        samples[(stripe * 4 + row) * width + x] = negative != 0 ? -magnitude : magnitude
                        mark(flagIndex, row: row, negative: negative, stride: stride,
                             vcausal: vcausal && row == 0, flags: &flags)
                    }
                    flags[flagIndex] |= Self.pi << shift
                }
            }
        }
    }

    private static func refinementPass(width: Int, height: Int, stride: Int, plane: Int,
                                       raw: Bool = false, mq: inout MQDecoder, samples: inout [Int32],
                                       flags: inout [UInt32]) {
        let half = Int32(1 << (plane - 1))
        for stripe in 0..<(height + 3) / 4 {
            let rows = min(4, height - stripe * 4)
            for x in 0..<width {
                let flagIndex = (stripe + 1) * stride + x + 1
                for row in 0..<rows {
                    let shift = row * 3
                    let word = flags[flagIndex]
                    if (word & ((Self.sigma | Self.pi) << shift)) != (Self.sigma << shift) { continue }
                    let offset = (stripe * 4 + row) * width + x
                    let bit = raw ? mq.rawDecode() :
                        mq.decode(context: T1Tables.magnitudeContext(flags: Int(word >> shift)))
                    samples[offset] += (bit ^ (samples[offset] < 0 ? 1 : 0)) != 0 ? half : -half
                    flags[flagIndex] |= Self.mu << shift
                }
            }
        }
    }

    private static func cleanupPass(width: Int, height: Int, stride: Int, plane: Int,
                                    orientation: Int, vcausal: Bool = false,
                                    mq: inout MQDecoder, samples: inout [Int32],
                                    flags: inout [UInt32]) {
        let magnitude = Int32((1 << plane) | (1 << (plane - 1)))
        for stripe in 0..<(height + 3) / 4 {
            let rows = min(4, height - stripe * 4)
            for x in 0..<width {
                let flagIndex = (stripe + 1) * stride + x + 1
                var start = 0
                var partial = false
                if rows == 4 && flags[flagIndex] == 0 {
                    if mq.decode(context: 17) == 0 { continue }
                    start = (mq.decode(context: 18) << 1) | mq.decode(context: 18)
                    partial = true
                }
                for row in start..<rows {
                    let shift = row * 3
                    let word = flags[flagIndex]
                    if (word & ((Self.sigma | Self.pi) << shift)) == 0 {
                        let significant: Bool
                        if partial { significant = true } else {
                            let context = T1Tables.zeroContext(orientation: orientation, flags: Int(word >> shift))
                            significant = mq.decode(context: context) != 0
                        }
                        if significant {
                            let sign = signIndex(word, flags[flagIndex - 1], flags[flagIndex + 1], row)
                            let negative = mq.decode(context: T1Tables.signContext(sign)) ^ T1Tables.predictedSign(sign)
                            samples[(stripe * 4 + row) * width + x] = negative != 0 ? -magnitude : magnitude
                            mark(flagIndex, row: row, negative: negative, stride: stride,
                                 vcausal: vcausal && row == 0, flags: &flags)
                        }
                    }
                    partial = false
                }
                flags[flagIndex] &= ~Self.piAll
            }
        }
    }
}
