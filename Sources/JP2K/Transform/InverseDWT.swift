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
    static func decode(_ values: inout [Int32], resolutions: [Resolution], reversible: Bool,
                       budget: inout MemoryBudget) throws(JP2KError) {
        guard let last = resolutions.last else { throw .invalidCodestream(.badCOD) }
        let stride = try Checked.sub(last.x1, last.x0)
        let maxLength = max(stride, try Checked.sub(last.y1, last.y0))
        // A single resolution needs no transform; otherwise only the work
        // array of the selected filter is allocated (and charged).
        if resolutions.count < 2 { return }
        let lineBytes = try Checked.mul(maxLength, MemoryLayout<Int32>.stride)
        let integerCount = reversible ? maxLength : 0
        let floatCount = reversible ? 0 : maxLength
        var scratch = try budget.array(repeating: Int32.zero, count: maxLength)
        var integerWork: [Int32]
        var floatWork: [Float]
        do {
            integerWork = try budget.array(repeating: Int32.zero, count: integerCount)
            floatWork = try budget.array(repeating: Float.zero, count: floatCount)
        } catch {
            budget.release(bytes: lineBytes)
            throw error
        }
        defer {
            budget.release(bytes: lineBytes)
            budget.release(bytes: integerCount * MemoryLayout<Int32>.stride)
            budget.release(bytes: floatCount * MemoryLayout<Float>.stride)
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
            guard width >= 0, height >= 0, width <= stride,
                  lowWidth == expectedLowWidth, lowHeight == expectedLowHeight,
                  try Checked.mul(stride, height) <= values.count else { throw .invalidCodestream(.badCodeBlock) }
            for row in 0..<height {
                let start = try Checked.mul(row, stride)
                for index in 0..<width { scratch[index] = values[start + index] }
                if reversible { inverse53(&scratch, work: &integerWork, lowCount: lowWidth, count: width, parity: current.x0 & 1) } else { inverse97(&scratch, work: &floatWork, lowCount: lowWidth, count: width, parity: current.x0 & 1) }
                for index in 0..<width { values[start + index] = scratch[index] }
            }
            for column in 0..<width {
                for index in 0..<height { scratch[index] = values[index * stride + column] }
                if reversible { inverse53(&scratch, work: &integerWork, lowCount: lowHeight, count: height, parity: current.y0 & 1) } else { inverse97(&scratch, work: &floatWork, lowCount: lowHeight, count: height, parity: current.y0 & 1) }
                for index in 0..<height { values[index * stride + column] = scratch[index] }
            }
        }
    }

    static func inverse53(_ line: inout [Int32], work: inout [Int32], lowCount: Int, count: Int, parity: Int) {
        if count == 0 { return }
        if count == 1 {
            if parity == 1 { line[0] /= 2 }
            return
        }
        var low = 0, high = lowCount
        for index in 0..<count {
            if index & 1 == parity { work[index] = line[low]; low += 1 } else { work[index] = line[high]; high += 1 }
        }
        // Undo update on the low samples, extending the high sequence symmetrically.
        for index in 0..<count where index & 1 == parity {
            let left = index > 0 ? index - 1 : index + 1
            let right = index + 1 < count ? index + 1 : index - 1
            let sum = Int64(work[left]) + Int64(work[right]) + 2
            work[index] = Int32(clamping: Int64(work[index]) - (sum >> 2))
        }
        // Undo prediction on the high samples.
        for index in 0..<count where index & 1 != parity {
            let left = index > 0 ? index - 1 : index + 1
            let right = index + 1 < count ? index + 1 : index - 1
            let sum = Int64(work[left]) + Int64(work[right])
            work[index] = Int32(clamping: Int64(work[index]) + (sum >> 1))
        }
        for index in 0..<count { line[index] = work[index] }
    }

    static func inverse97(_ line: inout [Int32], work: inout [Float], lowCount: Int, count: Int, parity: Int) {
        if count < 2 { return }
        var low = 0, high = lowCount
        for index in 0..<count {
            if index & 1 == parity { work[index] = Float(bitPattern: UInt32(bitPattern: line[low])); low += 1 } else { work[index] = Float(bitPattern: UInt32(bitPattern: line[high])); high += 1 }
        }
        for index in 0..<count {
            work[index] *= index & 1 == parity ? 1.230174105 : 1.625732422
        }
        lift(&work, count: count, parity: parity, factor: -0.443506852)
        lift(&work, count: count, parity: 1 - parity, factor: -0.882911075)
        lift(&work, count: count, parity: parity, factor: 0.052980118)
        lift(&work, count: count, parity: 1 - parity, factor: 1.586134342)
        for index in 0..<count { line[index] = Int32(bitPattern: work[index].bitPattern) }
    }

    private static func lift(_ samples: inout [Float], count: Int, parity: Int, factor: Float) {
        for index in 0..<count where index & 1 == parity {
            let left = index > 0 ? index - 1 : index + 1
            let right = index + 1 < count ? index + 1 : index - 1
            let neighbours = samples[left] + samples[right]
            let change = neighbours * factor
            samples[index] += change
        }
    }
}
