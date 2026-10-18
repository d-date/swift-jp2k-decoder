import Foundation
import Testing
@testable import JP2K

struct CodeBlockSchedulerTests {
    private static let fixtureNames = [
        "cblk-8x8.j2k", "gray-378x472-53.jp2", "gray-378x472-97.jp2", "gray16-40x30.jp2",
        "layers.j2k", "levels-max.j2k", "modes-all.j2k", "modes-bypass.j2k", "modes-pterm.j2k",
        "modes-reset.j2k", "modes-segsym.j2k", "modes-termall.j2k", "modes-vcausal.j2k",
        "origin.j2k", "poc.j2k", "precincts.j2k", "rgb-64-53-mct.jp2", "rgb-64-97.jp2",
        "rgba-33x17.jp2", "roi.j2k", "signed12-31x19.j2k", "subsampled-rgb.j2k",
        "tiles-127x61.j2k", "two-tiles-127x61.j2k"
    ]

    private func limits(threads: Int, threshold: Int = 0) -> Limits {
        var limits = Limits()
        limits.maxThreads = threads
        limits.parallelSampleThreshold = threshold
        return limits
    }

    private func outcome(_ bytes: [UInt8], _ base: Limits) async -> Result<[[Int32]], JP2KError> {
        // Bit flips can inflate the declared size or work; keep each decode small.
        var limits = base
        limits.maxPixels = 1 << 16
        limits.maxCodingPasses = 1 << 16
        limits.maxPacketIterations = 1 << 16
        do {
            return .success(try await JP2KDecoder(limits: limits).decodeComponents(bytes).components)
        } catch {
            return .failure(error)
        }
    }

    @Test(arguments: fixtureNames)
    func parallelOutputMatchesSerial(name: String) async throws {
        let bytes = Array(try Data(contentsOf: #require(Fixtures.url(name))))
        let serial = try await JP2KDecoder(limits: limits(threads: 1)).decodeComponentsWithMetrics(bytes)
        #expect(serial.1.parallelRuns == 0)
        for threads in [2, 8] {
            let parallel = try await JP2KDecoder(limits: limits(threads: threads)).decodeComponentsWithMetrics(bytes)
            #expect(parallel.0.components == serial.0.components, "\(name) with \(threads) threads")
            #expect(parallel.1.parallelRuns > 0, "\(name) with \(threads) threads took the serial path")
        }
    }

    @Test func corruptInputsFailTheSameWayOnAnyThreadCount() async throws {
        // Bit flips must give the same result (same pixels or the same error)
        // whether code-blocks are decoded serially or not. (Truncations almost
        // always fail while parsing, before Tier-1, so they add little here.)
        // limits(threads:) sets the parallel threshold to 0, so the 4-thread
        // decode really takes the parallel path for this small image.
        let bytes = Array(try Data(contentsOf: #require(Fixtures.url("modes-all.j2k"))))
        var mismatches = 0
        var parallelDecodes = 0
        func compare(_ input: [UInt8]) async {
            let serial = await outcome(input, limits(threads: 1))
            if await outcome(input, limits(threads: 4)) != serial { mismatches += 1 }
            var parallel = limits(threads: 4)
            parallel.maxPixels = 1 << 16
            if let runs = try? await JP2KDecoder(limits: parallel).decodeComponentsWithMetrics(input).1.parallelRuns,
               runs > 0 { parallelDecodes += 1 }
        }
        for position in stride(from: 40, to: bytes.count, by: 89) {
            var input = bytes
            input[position] ^= 0x5A
            await compare(input)
        }
        #expect(mismatches == 0)
        // Some damaged inputs must still reach (and finish) the parallel
        // path; failures inside it are pinned by the synthetic-job tests.
        #expect(parallelDecodes > 0)
    }

    @Test func tightBudgetFallsBackToSerialInsteadOfFailing() async throws {
        let bytes = Array(try Data(contentsOf: #require(Fixtures.url("gray-378x472-53.jp2"))))
        let measured = try await JP2KDecoder(limits: limits(threads: 1)).decodeComponentsWithMetrics(bytes)
        // The serial peak plus 16 KiB (allocator rounding varies between runs
        // on glibc) leaves no room for eight workers' output and scratch
        // shares, so the parallel request must quietly decode on one thread.
        var tight = limits(threads: 8)
        tight.maxMemoryBytes = measured.1.peakMemoryBytes + 16_384
        let image = try await JP2KDecoder(limits: tight).decodeComponentsWithMetrics(bytes)
        #expect(image.0.components == measured.0.components)
        #expect(image.1.parallelRuns == 0)
        // With room to spare the same request does run in parallel.
        var roomy = limits(threads: 8)
        roomy.maxMemoryBytes = measured.1.peakMemoryBytes * 2
        #expect(try await JP2KDecoder(limits: roomy).decodeComponentsWithMetrics(bytes).1.parallelRuns > 0)
    }

    // MARK: - Error order on synthetic jobs

    /// A one-component 32x8 grid holding four 8x8 blocks side by side.
    private func grid() -> TileGeometry {
        TileGeometry(x0: 0, y0: 0, x1: 32, y1: 8, components: [
            TileComponent(x0: 0, y0: 0, x1: 32, y1: 8, resolutions: [],
                          coefficients: [Int32](repeating: 0, count: 32 * 8))
        ])
    }

    enum Fault: Sendable { case none, decode, before, after }

    /// `.decode` uses a reserved code-block style bit, which CodeBlockDecoder
    /// rejects; `.before` / `.after` carry distinct marker errors.
    private func job(_ index: Int, _ fault: Fault) -> CodeBlockJob {
        let block = CodeBlock(x0: 0, y0: 0, x1: 8, y1: 8, segments: [CodeBlockSegment(passes: 1, length: 2)],
                              data: [0x12, 0x34], totalPasses: 1)
        var job = CodeBlockJob(component: 0, block: block, orientation: 0, roiShift: 0,
                               codeBlockStyle: fault == .decode ? 0x40 : 0, reversible: true, stepSize: 1,
                               maxWidth: 8, maxHeight: 8, rowStride: 32)
        job.numBitPlanes = 4
        job.offsetX = index * 8
        job.width = 8
        job.height = 8
        if fault == .before { job.errorBeforeDecode = .limitExceeded(.packets) }
        if fault == .after { job.errorAfterDecode = .limitExceeded(.layers) }
        return job
    }

    private func schedule(_ faults: [Fault], threads: Int) async -> JP2KError? {
        var geometry = grid()
        var context = DecodeContext(limits: limits(threads: threads))
        let jobs = faults.enumerated().map { job($0.offset, $0.element) }
        do {
            try await CodeBlockScheduler.run(jobs, geometry: &geometry, context: &context)
            return nil
        } catch {
            return error
        }
    }

    @Test(arguments: [
        ([Fault.none, .decode, .before, .after], JP2KError.invalidCodestream(.badCodeBlock)),
        ([Fault.none, .before, .decode, .after], JP2KError.limitExceeded(.packets)),
        ([Fault.none, .after, .before, .decode], JP2KError.limitExceeded(.layers)),
        ([Fault.none, .none, .none, .after], JP2KError.limitExceeded(.layers))
    ])
    func lowestFailingBlockWinsOnEveryPath(faults: [Fault], expected: JP2KError) async {
        // The serial loop stops at the first failing block; the parallel path
        // must report that same block's error even when later blocks fail
        // first on other threads.
        for threads in [1, 2, 4] {
            let error = await schedule(faults, threads: threads)
            #expect(error == expected, "\(threads) threads")
        }
    }

    @Test func errorBeforeDecodeSkipsTheDecodeAndAfterStillDecodes() async {
        // A block whose listing failed before decoding reports that error even
        // if decoding it would also fail; a placement error comes after a
        // successful decode, so a decode failure in the same block wins.
        var both = job(0, .decode)
        both.errorBeforeDecode = .limitExceeded(.packets)
        var decodeThenPlace = job(0, .decode)
        decodeThenPlace.errorAfterDecode = .limitExceeded(.layers)
        for threads in [1, 3] {
            for (candidate, expected) in [(both, JP2KError.limitExceeded(.packets)),
                                          (decodeThenPlace, JP2KError.invalidCodestream(.badCodeBlock))] {
                var geometry = grid()
                var context = DecodeContext(limits: limits(threads: threads))
                do {
                    try await CodeBlockScheduler.run([candidate, job(1, .none)], geometry: &geometry, context: &context)
                    Issue.record("expected \(expected) with \(threads) threads")
                } catch {
                    #expect(error == expected, "\(threads) threads")
                }
            }
        }
    }
}

