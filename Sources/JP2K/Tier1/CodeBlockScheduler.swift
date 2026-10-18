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
// Ported from OpenJPEG v2.5.4: t1.c: opj_t1_decode_cblks, opj_t1_clbl_decode_processor
import Dispatch
import Synchronization

/// One code-block to decode. Placement is validated by TileDecoder; an
/// error found while listing the block is kept and raised when the block is
/// reached, before or after decoding it as the original loop did.
struct CodeBlockJob: Sendable {
    let component: Int
    let block: CodeBlock
    let orientation: Int
    let roiShift: Int
    let codeBlockStyle: UInt8
    var numBitPlanes = 0
    let reversible: Bool
    let stepSize: Float
    /// Nominal code-block size from COD/COC (2^xcb × 2^ycb).
    let maxWidth: Int
    let maxHeight: Int
    var offsetX = 0
    var offsetY = 0
    var width = 0
    var height = 0
    /// Width of the component's coefficient grid.
    let rowStride: Int
    var errorBeforeDecode: JP2KError?
    var errorAfterDecode: JP2KError?

    init(component: Int, block: CodeBlock, orientation: Int, roiShift: Int, codeBlockStyle: UInt8,
         reversible: Bool, stepSize: Float, maxWidth: Int, maxHeight: Int, rowStride: Int) {
        self.component = component
        self.block = block
        self.orientation = orientation
        self.roiShift = roiShift
        self.codeBlockStyle = codeBlockStyle
        self.reversible = reversible
        self.stepSize = stepSize
        self.maxWidth = maxWidth
        self.maxHeight = maxHeight
        self.rowStride = rowStride
    }
}

/// Runs Tier-1 for one tile component. Code-blocks are independent, so
/// large components are split across threads; each worker owns its scratch and a
/// private budget carved out of the decode budget beforehand. Results are
/// merged in job order, so output and errors match the serial path exactly.
enum CodeBlockScheduler {
    static func run(_ jobs: [CodeBlockJob], geometry: inout TileGeometry,
                    context: inout DecodeContext) throws(JP2KError) {
        guard !jobs.isEmpty else { return }
        let workers = try workerCount(for: jobs, limit: context.limits.maxThreads,
                                      threshold: context.limits.parallelSampleThreshold)
        if workers > 1, #available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *) {
            if try runParallel(jobs, workers: workers, geometry: &geometry, context: &context) { return }
        }
        try runSerial(jobs, geometry: &geometry, budget: &context.budget)
    }

    private static func workerCount(for jobs: [CodeBlockJob], limit: Int, threshold: Int) throws(JP2KError) -> Int {
        var samples = 0
        for job in jobs { samples = try Checked.add(samples, Checked.mul(job.width, job.height)) }
        guard samples >= threshold else { return 1 }
        return max(1, min(limit, jobs.count))
    }

    private static func scratchLimits(_ jobs: [CodeBlockJob]) -> (width: Int, height: Int) {
        var width = 1, height = 1
        for job in jobs {
            width = max(width, job.maxWidth)
            height = max(height, job.maxHeight)
        }
        return (width, height)
    }

    private static func runSerial(_ jobs: [CodeBlockJob], geometry: inout TileGeometry,
                                  budget: inout MemoryBudget) throws(JP2KError) {
        let limits = scratchLimits(jobs)
        var decoder = try CodeBlockDecoder(maxWidth: limits.width, maxHeight: limits.height, budget: &budget)
        do {
            for job in jobs {
                try decode(job, with: &decoder, budget: &budget)
                try store(job, from: decoder, into: &geometry)
            }
        } catch {
            decoder.release(from: &budget)
            throw error
        }
        decoder.release(from: &budget)
    }

    private static func decode(_ job: CodeBlockJob, with decoder: inout CodeBlockDecoder,
                               budget: inout MemoryBudget) throws(JP2KError) {
        if let error = job.errorBeforeDecode { throw error }
        try decoder.decode(job.block, orientation: job.orientation, roiShift: job.roiShift,
                           codeBlockStyle: job.codeBlockStyle, numBitPlanes: job.numBitPlanes,
                           budget: &budget)
        if let error = job.errorAfterDecode { throw error }
        guard decoder.outputCount >= (try Checked.mul(job.width, job.height)) else {
            throw .invalidCodestream(.badCodeBlock)
        }
    }

    /// Index of the block's first coefficient, after checking with Checked
    /// arithmetic that every row it writes lies inside the component plane.
    private static func firstTarget(_ job: CodeBlockJob, in geometry: borrowing TileGeometry) throws(JP2KError) -> Int {
        guard geometry.components.indices.contains(job.component),
              job.width >= 0, job.height >= 0, job.offsetX >= 0, job.offsetY >= 0,
              try Checked.add(job.offsetX, job.width) <= job.rowStride,
              try Checked.mul(Checked.add(job.offsetY, job.height), job.rowStride)
                <= geometry.components[job.component].coefficients.count else {
            throw .invalidCodestream(.badCodeBlock)
        }
        return try Checked.add(Checked.mul(job.offsetY, job.rowStride), job.offsetX)
    }

    private static func store(_ job: CodeBlockJob, from decoder: borrowing CodeBlockDecoder,
                              into geometry: inout TileGeometry) throws(JP2KError) {
        var source = 0
        var row = try firstTarget(job, in: geometry)
        for _ in 0..<job.height {
            for x in 0..<job.width {
                geometry.components[job.component].coefficients[row + x] = coefficient(job, decoder, source)
                source += 1
            }
            row += job.rowStride
        }
    }

    @inline(__always)
    private static func coefficient(_ job: CodeBlockJob, _ decoder: borrowing CodeBlockDecoder,
                                    _ index: Int) -> Int32 {
        Dequantize.sample(decoder.output(at: index), roiShift: job.roiShift, reversible: job.reversible,
                          stepSize: job.stepSize)
    }

    // MARK: - Parallel path

    /// What the workers hand back: one output slot per job, and the lowest
    /// failing job seen so far.
    private struct SharedResults: Sendable {
        var outputs: [[Int32]]
        var error: (job: Int, error: JP2KError)?
    }

    /// A budget the workers draw output arrays from concurrently. Like
    /// MemoryBudget, it checks the requested bytes before an allocation and
    /// the allocator's rounding right after it, so `used` never exceeds
    /// `limit`; the limit itself was reserved from the decode budget.
    @available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
    private struct SharedBudget: ~Copyable {
        let limit: Int
        let used = Atomic<Int>(0)

        init(limit: Int) { self.limit = limit }

        func reserve(bytes: Int) throws(JP2KError) {
            if bytes < 0 { throw .limitExceeded(.memory) }
            var current = used.load(ordering: .relaxed)
            while true {
                if bytes > limit - current { throw .limitExceeded(.memory) }
                let (exchanged, original) = used.compareExchange(
                    expected: current, desired: current + bytes, ordering: .relaxed)
                if exchanged { return }
                current = original
            }
        }
    }

    /// Allocator rounding is covered by 512 bytes plus 1/8 per allocation,
    /// which bounds malloc rounding on every supported platform. It only
    /// sizes the reservation; actual allocations are still checked.
    private static func rounded(_ bytes: Int) throws(JP2KError) -> Int {
        try Checked.add(Checked.add(bytes, bytes / 8), 512)
    }

    /// Scratch one worker may need at the largest nominal block size. Flags
    /// and samples may each be grown once while the old buffer is still live,
    /// and the MQ input doubles; three times the final size covers both.
    private static func scratchBytes(width: Int, height: Int, maxData: Int) throws(JP2KError) -> Int {
        let stride = try Checked.add(width, 2)
        let flagRows = try Checked.add(Checked.ceilDiv(height, 4), 2)
        let flags = try rounded(Checked.mul(Checked.mul(stride, flagRows), 4 * 3))
        let samples = try rounded(Checked.mul(Checked.mul(width, height), 4 * 3))
        let mq = try rounded(Checked.mul(Checked.add(maxData, 2), 3))
        return try Checked.add(flags, Checked.add(samples, mq))
    }

    /// Returns false when the worker budgets cannot be reserved or a worker
    /// ran out of its share; the caller then decodes serially, which charges
    /// exactly what it uses.
    @available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
    private static func runParallel(_ jobs: [CodeBlockJob], workers: Int, geometry: inout TileGeometry,
                                    context: inout DecodeContext) throws(JP2KError) -> Bool {
        let limits = scratchLimits(jobs)
        var maxData = 0
        var outputBytes = 0
        for job in jobs {
            maxData = max(maxData, job.block.data.count)
            outputBytes = try Checked.add(outputBytes, rounded(Checked.mul(Checked.mul(job.width, job.height), 4)))
        }
        let scratch = try scratchBytes(width: limits.width, height: limits.height, maxData: maxData)
        let reserved = try Checked.add(outputBytes, Checked.mul(scratch, workers))
        // The slot array is charged exactly; the workers' output arrays and
        // scratch come out of `reserved`.
        let slots: [[Int32]]
        do {
            try context.budget.reserve(bytes: reserved)
            do {
                slots = try context.budget.array(repeating: [], count: jobs.count)
            } catch {
                context.budget.release(bytes: reserved)
                throw error
            }
        } catch {
            return false
        }
        let slotBytes = slots.capacity * MemoryLayout<[Int32]>.stride
        defer {
            context.budget.release(bytes: reserved)
            context.budget.release(bytes: slotBytes)
        }

        // Workers claim jobs in increasing order from a shared counter, so
        // none sits idle while another works through a long list.
        let next = Atomic<Int>(0)
        let shared = SharedBudget(limit: outputBytes)
        // `consume` hands the only reference to the Mutex, so filling a slot
        // never triggers a copy-on-write of the whole slot array.
        let results = Mutex(SharedResults(outputs: consume slots, error: nil))
        DispatchQueue.concurrentPerform(iterations: workers) { _ in
            var budget = MemoryBudget(limit: scratch)
            var claimed = 0
            do throws(JP2KError) {
                var decoder = try CodeBlockDecoder(maxWidth: limits.width, maxHeight: limits.height, budget: &budget)
                while true {
                    claimed = next.wrappingAdd(1, ordering: .relaxed).oldValue
                    if claimed >= jobs.count { break }
                    let job = jobs[claimed]
                    try decode(job, with: &decoder, budget: &budget)
                    let count = try Checked.mul(job.width, job.height)
                    let requested = try Checked.mul(count, MemoryLayout<Int32>.stride)
                    try shared.reserve(bytes: requested)
                    var values = [Int32](repeating: 0, count: count)
                    let actual = try Checked.mul(values.capacity, MemoryLayout<Int32>.stride)
                    if actual > requested { try shared.reserve(bytes: actual - requested) }
                    for sample in values.indices { values[sample] = coefficient(job, decoder, sample) }
                    let index = claimed
                    results.withLock { $0.outputs[index] = values }
                }
            } catch {
                // A worker stops at its first failure; scratch setup failing
                // before any claim counts as job 0.
                let index = min(claimed, jobs.count - 1)
                results.withLock { state in
                    if index < (state.error?.job ?? Int.max) { state.error = (index, error) }
                }
            }
        }
        let state = results.withLock { $0 }

        // The lowest failing job is the one the serial path would report:
        // jobs are claimed in increasing order and a worker stops only after
        // a failure, so every job below the lowest failure was decoded.
        if let failure = state.error {
            // A worker that outgrew its share says nothing about the input;
            // let the serial path decide.
            if failure.error == .limitExceeded(.memory) { return false }
            throw failure.error
        }
        guard state.outputs.count == jobs.count else { throw .invalidCodestream(.badCodeBlock) }
        for index in jobs.indices {
            let job = jobs[index]
            let values = state.outputs[index]
            guard values.count == (try Checked.mul(job.width, job.height)) else {
                throw .invalidCodestream(.badCodeBlock)
            }
            var row = try firstTarget(job, in: geometry)
            for source in stride(from: 0, to: values.count, by: max(job.width, 1)) {
                let rowEnd = try Checked.add(row, job.width)
                let sourceEnd = try Checked.add(source, job.width)
                geometry.components[job.component].coefficients
                    .replaceSubrange(row..<rowEnd, with: values[source..<sourceEnd])
                row = try Checked.add(row, job.rowStride)
            }
        }
        context.countParallelRun()
        return true
    }
}
