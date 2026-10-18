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
/// large components are split across child tasks; each worker owns its
/// scratch and a private budget carved out of the decode budget beforehand.
/// Results are merged in job order, so output and errors match the serial
/// path exactly.
enum CodeBlockScheduler {
    static func run(_ jobs: [CodeBlockJob], geometry: inout TileGeometry,
                    context: inout DecodeContext) async throws(JP2KError) {
        guard !jobs.isEmpty else { return }
        let workers = try workerCount(for: jobs, limit: context.limits.maxThreads,
                                      threshold: context.limits.parallelSampleThreshold)
        if workers > 1, try await runParallel(jobs, workers: workers, geometry: &geometry, context: &context) {
            return
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

    /// What one worker hands back: the coefficients of its jobs in order,
    /// and the first of its jobs that failed.
    private struct WorkerResult: Sendable {
        let worker: Int
        var outputs: [[Int32]] = []
        var failure: (job: Int, error: JP2KError)?
    }

    /// Allocator rounding is covered by 512 bytes plus 1/8 per allocation,
    /// which bounds malloc rounding on every supported platform. It only
    /// sizes the reservation; each worker's budget still checks every
    /// allocation against its share.
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

    /// Worker `w` decodes jobs w, w + workers, w + 2·workers, … Its share
    /// covers its scratch, the coefficient array of each of its jobs and the
    /// list holding them, so workers never contend for a budget.
    private static func shares(_ jobs: [CodeBlockJob], workers: Int, scratch: Int) throws(JP2KError) -> [Int] {
        var shares = [Int](repeating: scratch, count: workers)
        for index in jobs.indices {
            let bytes = try rounded(Checked.mul(Checked.mul(jobs[index].width, jobs[index].height), 4))
            shares[index % workers] = try Checked.add(shares[index % workers], bytes)
        }
        for worker in 0..<workers {
            let list = try rounded(Checked.mul(strideCount(jobs.count, worker: worker, workers: workers),
                                               MemoryLayout<[Int32]>.stride))
            shares[worker] = try Checked.add(shares[worker], list)
        }
        return shares
    }

    private static func strideCount(_ jobCount: Int, worker: Int, workers: Int) throws(JP2KError) -> Int {
        try Checked.ceilDiv(Checked.sub(jobCount, worker), workers)
    }

    /// Returns false when the worker budgets cannot be reserved or a worker
    /// ran out of its share; the caller then decodes serially, which charges
    /// exactly what it uses.
    private static func runParallel(_ jobs: [CodeBlockJob], workers: Int, geometry: inout TileGeometry,
                                    context: inout DecodeContext) async throws(JP2KError) -> Bool {
        let limits = scratchLimits(jobs)
        var maxData = 0
        for job in jobs { maxData = max(maxData, job.block.data.count) }
        let scratch = try scratchBytes(width: limits.width, height: limits.height, maxData: maxData)
        // The share list and the result list live until the merge ends, so
        // they are reserved before the shares are computed.
        var reserved = try Checked.add(rounded(Checked.mul(workers, MemoryLayout<Int>.stride)),
                                       rounded(Checked.mul(workers, MemoryLayout<WorkerResult?>.stride)))
        do {
            try context.budget.reserve(bytes: reserved)
        } catch {
            return false
        }
        defer { context.budget.release(bytes: reserved) }
        let shares = try Self.shares(jobs, workers: workers, scratch: scratch)
        var total = 0
        for share in shares { total = try Checked.add(total, share) }
        let withShares = try Checked.add(reserved, total)
        do {
            try context.budget.reserve(bytes: total)
        } catch {
            return false
        }
        reserved = withShares

        // Indexed by worker, so the merge can find each job's output.
        let results = await withTaskGroup(of: WorkerResult.self, returning: [WorkerResult?].self) { group in
            for worker in 0..<workers {
                let share = shares[worker]
                group.addTask {
                    decodeStride(jobs, worker: worker, workers: workers, limits: limits, share: share)
                }
            }
            var results = [WorkerResult?](repeating: nil, count: workers)
            for await result in group { results[result.worker] = result }
            return results
        }

        // Each worker stops at its first failure and walks its jobs in
        // increasing order, so its failure is the lowest failing job of its
        // stride, and the lowest over all workers is the one the serial path
        // would report: every job below it was decoded by some worker.
        var failure: (job: Int, error: JP2KError)?
        for case let result? in results {
            if let found = result.failure, found.job < (failure?.job ?? Int.max) { failure = found }
        }
        if let failure {
            // A worker that outgrew its share says nothing about the input;
            // let the serial path decide.
            if failure.error == .limitExceeded(.memory) { return false }
            throw failure.error
        }
        // Merged in job order, as the serial path writes them.
        for index in jobs.indices {
            let job = jobs[index]
            guard let outputs = results[index % workers]?.outputs else { throw .invalidCodestream(.badCodeBlock) }
            let slot = index / workers
            guard slot < outputs.count, outputs[slot].count == (try Checked.mul(job.width, job.height)) else {
                throw .invalidCodestream(.badCodeBlock)
            }
            let values = outputs[slot]
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

    /// Body of one child task: decodes the worker's stride with its own
    /// scratch and budget.
    private static func decodeStride(_ jobs: [CodeBlockJob], worker: Int, workers: Int,
                                     limits: (width: Int, height: Int), share: Int) -> WorkerResult {
        var budget = MemoryBudget(limit: share)
        var result = WorkerResult(worker: worker)
        var index = worker
        do throws(JP2KError) {
            // Failing to set up counts as failing the worker's first job.
            let count = try strideCount(jobs.count, worker: worker, workers: workers)
            result.outputs = try budget.array(repeating: [], count: count)
            var decoder = try CodeBlockDecoder(maxWidth: limits.width, maxHeight: limits.height, budget: &budget)
            var slot = 0
            while index < jobs.count {
                let job = jobs[index]
                try decode(job, with: &decoder, budget: &budget)
                var values = try budget.array(repeating: Int32(0), count: Checked.mul(job.width, job.height))
                for sample in values.indices { values[sample] = coefficient(job, decoder, sample) }
                result.outputs[slot] = values
                slot += 1
                index = try Checked.add(index, workers)
            }
        } catch {
            result.failure = (min(index, jobs.count - 1), error)
        }
        return result
    }
}
