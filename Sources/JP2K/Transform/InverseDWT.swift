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
 * Copyright (c) 2007, Jonathan Ballard <dzonatas@dzonux.net>
 * Copyright (c) 2007, Callum Lerwick <seg@haxxed.com>
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
// Ported from OpenJPEG v2.5.4: dwt.c: opj_dwt_decode, opj_idwt53_h, opj_idwt53_v, opj_dwt_decode_real, opj_v8dwt_decode
/// In-place inverse wavelet transform of a full tile component.
enum InverseDWT {
    /// Rows and columns are transformed 16 at a time, one SIMD lane each, so
    /// the vertical pass reads whole row segments instead of striding through
    /// memory, and every lifting step is a vector operation. Lanes are
    /// independent and use the same scalar operations (no fused multiply-add),
    /// so results match a one-signal-at-a-time transform bit for bit.
    static let lanes = 16
    typealias IntegerLanes = SIMD16<Int32>
    typealias WideLanes = SIMD16<Int64>
    typealias FloatLanes = SIMD16<Float>

    static func decode(_ values: inout [Int32], resolutions: [Resolution], reversible: Bool,
                       budget: inout MemoryBudget) throws(JP2KError) {
        guard let last = resolutions.last else { throw .invalidCodestream(.badCOD) }
        let stride = try Checked.sub(last.x1, last.x0)
        let maxLength = max(stride, try Checked.sub(last.y1, last.y0))
        // A single resolution needs no transform; otherwise only the work
        // array of the selected filter is allocated (and charged).
        if resolutions.count < 2 { return }
        var integerWork = try budget.array(repeating: IntegerLanes(), count: reversible ? maxLength : 0)
        var floatWork: [FloatLanes]
        do {
            floatWork = try budget.array(repeating: FloatLanes(), count: reversible ? 0 : maxLength)
        } catch {
            budget.release(bytes: integerWork.capacity * MemoryLayout<IntegerLanes>.stride)
            throw error
        }
        defer {
            budget.release(bytes: integerWork.capacity * MemoryLayout<IntegerLanes>.stride)
            budget.release(bytes: floatWork.capacity * MemoryLayout<FloatLanes>.stride)
        }
        for level in 1..<resolutions.count {
            let previous = resolutions[level - 1]
            let current = resolutions[level]
            let width = try Checked.sub(current.x1, current.x0)
            let height = try Checked.sub(current.y1, current.y0)
            let lowWidth = try Checked.sub(previous.x1, previous.x0)
            let lowHeight = try Checked.sub(previous.y1, previous.y0)
            let expectedLowWidth = current.x0 & 1 == 0 ? try Checked.ceilDiv(width, 2) : width / 2
            let expectedLowHeight = current.y0 & 1 == 0 ? try Checked.ceilDiv(height, 2) : height / 2
            guard width >= 0, height >= 0, width <= stride, height <= maxLength,
                  lowWidth == expectedLowWidth, lowHeight == expectedLowHeight,
                  try Checked.mul(stride, height) <= values.count else { throw .invalidCodestream(.badCodeBlock) }
            // The checks above keep every index below in range: rows start at
            // row * stride with width <= stride, and columns stay below width.
            var row = 0
            while row < height {
                let line = Line(base: row * stride, step: 1, lanes: min(lanes, height - row),
                                laneStep: stride, lowCount: lowWidth, count: width, parity: current.x0 & 1)
                if reversible { inverse53(&values, line, work: &integerWork) } else { inverse97(&values, line, work: &floatWork) }
                row += lanes
            }
            var column = 0
            while column < width {
                let line = Line(base: column, step: stride, lanes: min(lanes, width - column),
                                laneStep: 1, lowCount: lowHeight, count: height, parity: current.y0 & 1)
                if reversible { inverse53(&values, line, work: &integerWork) } else { inverse97(&values, line, work: &floatWork) }
                column += lanes
            }
        }
    }

    /// Up to 16 parallel 1-D signals of `count` samples: sample i of lane k
    /// is at base + i * step + k * laneStep. The first `lowCount` samples are
    /// the low band.
    struct Line {
        let base: Int
        let step: Int
        let lanes: Int
        let laneStep: Int
        let lowCount: Int
        let count: Int
        let parity: Int
    }

    /// Interleaves the low and high bands into `work`: low sample r goes to
    /// position 2r + parity, high r to the other parity, as
    /// opj_dwt_interleave_h/v do. Unused lanes stay zero.
    @inline(__always)
    private static func interleave<V: SIMD>(_ values: [Int32], _ line: Line, into work: inout [V],
                                            _ convert: (Int32) -> V.Scalar) {
        for index in 0..<line.count {
            let position = index < line.lowCount ? 2 * index + line.parity
                : 2 * (index - line.lowCount) + 1 - line.parity
            let source = line.base + index * line.step
            var vector = V()
            for lane in 0..<line.lanes { vector[lane] = convert(values[source + lane * line.laneStep]) }
            work[position] = vector
        }
    }

    @inline(__always)
    private static func store<V: SIMD>(_ work: [V], _ line: Line, into values: inout [Int32],
                                       _ convert: (V.Scalar) -> Int32) {
        for index in 0..<line.count {
            let target = line.base + index * line.step
            let vector = work[index]
            for lane in 0..<line.lanes { values[target + lane * line.laneStep] = convert(vector[lane]) }
        }
    }

    static func inverse53(_ values: inout [Int32], _ line: Line, work: inout [IntegerLanes]) {
        let count = line.count
        if count == 0 { return }
        if count == 1 {
            if line.parity == 1 {
                for lane in 0..<line.lanes { values[line.base + lane * line.laneStep] /= 2 }
            }
            return
        }
        // Sums are formed in 64 bits and each step saturates to Int32, as the
        // scalar transform does with hostile coefficients. SIMD integers only
        // offer wrapping operators, but no wrap can happen: every operand is
        // an Int32 value, so |a + b + 2| < 2^33 and the result of each step
        // is below 2^34 in magnitude before it is clamped.
        let low = WideLanes(repeating: Int64(Int32.min))
        let high = WideLanes(repeating: Int64(Int32.max))
        interleave(values, line, into: &work) { $0 }
        // Undo update on the low samples, extending the high sequence symmetrically.
        var index = line.parity
        while index < count {
            let left = index > 0 ? index - 1 : index + 1
            let right = index + 1 < count ? index + 1 : index - 1
            let sum = WideLanes(truncatingIfNeeded: work[left]) &+ WideLanes(truncatingIfNeeded: work[right]) &+ 2
            let updated = WideLanes(truncatingIfNeeded: work[index]) &- (sum &>> 2)
            work[index] = IntegerLanes(truncatingIfNeeded: updated.clamped(lowerBound: low, upperBound: high))
            index += 2
        }
        // Undo prediction on the high samples.
        index = 1 - line.parity
        while index < count {
            let left = index > 0 ? index - 1 : index + 1
            let right = index + 1 < count ? index + 1 : index - 1
            let sum = WideLanes(truncatingIfNeeded: work[left]) &+ WideLanes(truncatingIfNeeded: work[right])
            let updated = WideLanes(truncatingIfNeeded: work[index]) &+ (sum &>> 1)
            work[index] = IntegerLanes(truncatingIfNeeded: updated.clamped(lowerBound: low, upperBound: high))
            index += 2
        }
        store(work, line, into: &values) { $0 }
    }

    static func inverse97(_ values: inout [Int32], _ line: Line, work: inout [FloatLanes]) {
        let count = line.count
        if count < 2 { return }
        interleave(values, line, into: &work) { Float(bitPattern: UInt32(bitPattern: $0)) }
        for index in 0..<count {
            let factor: Float = index & 1 == line.parity ? 1.230174105 : 1.625732422
            work[index] *= factor
        }
        lift(&work, count: count, parity: line.parity, factor: -0.443506852)
        lift(&work, count: count, parity: 1 - line.parity, factor: -0.882911075)
        lift(&work, count: count, parity: line.parity, factor: 0.052980118)
        lift(&work, count: count, parity: 1 - line.parity, factor: 1.586134342)
        store(work, line, into: &values) { Int32(bitPattern: $0.bitPattern) }
    }

    @inline(__always)
    private static func lift(_ work: inout [FloatLanes], count: Int, parity: Int, factor: Float) {
        var index = parity
        while index < count {
            let left = index > 0 ? index - 1 : index + 1
            let right = index + 1 < count ? index + 1 : index - 1
            let neighbours = work[left] + work[right]
            let change = neighbours * factor
            work[index] += change
            index += 2
        }
    }

    /// Single-signal forms (one lane, packed low band first) used by tests.
    static func inverse53(_ line: inout [Int32], lowCount: Int, count: Int, parity: Int) {
        var work = [IntegerLanes](repeating: IntegerLanes(), count: count)
        inverse53(&line, Line(base: 0, step: 1, lanes: 1, laneStep: 0, lowCount: lowCount, count: count, parity: parity),
                  work: &work)
    }

    static func inverse97(_ line: inout [Int32], lowCount: Int, count: Int, parity: Int) {
        var work = [FloatLanes](repeating: FloatLanes(), count: count)
        inverse97(&line, Line(base: 0, step: 1, lanes: 1, laneStep: 0, lowCount: lowCount, count: count, parity: parity),
                  work: &work)
    }
}
