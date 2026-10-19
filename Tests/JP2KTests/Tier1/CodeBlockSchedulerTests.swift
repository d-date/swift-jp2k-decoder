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
        limits.parallelWorkThreshold = threshold
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

    @Test func componentsOfATileFanOutOnce() async throws {
        // The three components' code-blocks share one concurrent run.
        let bytes = Array(try Data(contentsOf: #require(Fixtures.url("rgb-64-53-mct.jp2"))))
        let serial = try await JP2KDecoder(limits: limits(threads: 1)).decodeComponentsWithMetrics(bytes)
        let concurrent = try await JP2KDecoder(limits: limits(threads: 8)).decodeComponentsWithMetrics(bytes)
        #expect(concurrent.0.components == serial.0.components)
        #expect(concurrent.1.parallelRuns == 1)
    }

    @Test(arguments: [
        // Measured: below about 1 KiB of coded data a fan-out costs more than
        // it saves; from about 2.5 KiB it halves the decode time.
        ("rgb-64-97.jp2", false), ("signed12-31x19.j2k", false), ("layers.j2k", false),
        ("gray16-40x30.jp2", true), ("rgb-64-53-mct.jp2", true), ("tiles-127x61.j2k", true)
    ])
    func defaultThresholdFollowsTheCodedData(name: String, fansOut: Bool) async throws {
        let bytes = Array(try Data(contentsOf: #require(Fixtures.url(name))))
        var limits = Limits()
        limits.maxThreads = 8
        let runs = try await JP2KDecoder(limits: limits).decodeComponentsWithMetrics(bytes).1.parallelRuns
        #expect((runs > 0) == fansOut)
    }

    // MARK: - Falling back from a concurrent run

    /// The single tile of a three-component codestream, with a reserved
    /// code-block style bit (which Tier-1 rejects) set on `damaged`.
    private func tile(damaging damaged: [Int]) throws -> (MainHeader, TileData) {
        let bytes = Array(try Data(contentsOf: #require(Fixtures.url("subsampled-rgb.j2k"))))
        var context = DecodeContext(limits: Limits())
        let header = try MainHeaderParser.parse(bytes, range: 0..<bytes.count, context: &context)
        var tiles = try TilePartParser.parse(bytes, header: header, context: &context)
        #expect(tiles.count == 1 && header.geometry.components.count == 3)
        for component in damaged {
            var coding = tiles[0].parameters.coc[component] ?? tiles[0].parameters.cod.component
            coding.codeBlockStyle |= 0x40
            tiles[0].parameters.coc[component] = coding
        }
        return (header, tiles[0])
    }

    private func decode(_ tile: TileData, _ header: MainHeader,
                        _ limits: Limits) async -> (Result<[[Int32]], JP2KError>, DecodeContext) {
        var context = DecodeContext(limits: limits)
        do {
            let geometry = try await TileDecoder.decode(tile, header: header, context: &context)
            return (.success(geometry.components.map(\.coefficients)), context)
        } catch {
            return (.failure(error), context)
        }
    }

    @Test(arguments: [[Int](), [1], [2], [0, 2]])
    func damagedComponentFailsTheSameWayOnAnyThreadCount(damaged: [Int]) async throws {
        // A later component's Tier-1 failure makes the concurrent run give
        // way; the serial loop then reports it after reconstructing the
        // earlier components, as a one-thread decode does.
        let (header, tile) = try tile(damaging: damaged)
        let serial = await decode(tile, header, limits(threads: 1))
        if damaged.isEmpty {
            #expect((try? serial.0.get()) != nil)
        } else {
            #expect(serial.0 == .failure(.invalidCodestream(.badCodeBlock)))
        }
        for threads in [2, 8] {
            let concurrent = await decode(tile, header, limits(threads: threads))
            #expect(concurrent.0 == serial.0, "\(threads) threads")
            // The concurrent run was attempted and, on damage, gave way.
            #expect(concurrent.1.parallelRuns == (damaged.isEmpty ? 1 : 0))
            #expect(concurrent.1.parallelFallbacks == (damaged.isEmpty ? 0 : 1))
        }
    }

    @Test func damagedComponentUnderATightBudgetFailsTheSameWay() async throws {
        // Near the serial memory minimum of a damaged tile, a concurrent
        // request must report what one thread reports: .memory below it and
        // the Tier-1 error above it.
        let (header, tile) = try tile(damaging: [2])
        func outcome(_ limit: Int, threads: Int) async -> (Result<[[Int32]], JP2KError>, DecodeContext) {
            var limits = limits(threads: threads)
            limits.maxMemoryBytes = limit
            return await decode(tile, header, limits)
        }
        var lower = 0
        var upper = Limits().maxMemoryBytes
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if await outcome(middle, threads: 1).0 != .failure(.limitExceeded(.memory)) {
                upper = middle
            } else {
                lower = middle + 1
            }
        }
        for offset in [-8_192, -4_096] {
            #expect(await outcome(lower + offset, threads: 8).0 == .failure(.limitExceeded(.memory)))
        }
        for offset in [4_096, 8_192] {
            let concurrent = await outcome(lower + offset, threads: 8)
            #expect(concurrent.0 == .failure(.invalidCodestream(.badCodeBlock)), "\(offset) above the minimum")
            #expect(concurrent.1.parallelRuns == 0)
            #expect(concurrent.1.parallelFallbacks == 1)
        }
    }

    @Test func memoryLimitBoundaryDoesNotDependOnThreads() async throws {
        // Limits clearly below the serial minimum fail and limits clearly
        // above it succeed with any thread count: when the worker shares do
        // not fit, the tile decodes on one thread. (glibc's allocation
        // rounding varies between runs, so the exact boundary is avoided.)
        let bytes = Array(try Data(contentsOf: #require(Fixtures.url("subsampled-rgb.j2k"))))
        func succeeds(_ limit: Int, threads: Int) async -> Bool {
            var limits = limits(threads: threads)
            limits.maxMemoryBytes = limit
            return (try? await JP2KDecoder(limits: limits).decodeComponents(bytes)) != nil
        }
        var lower = 0
        var upper = Limits().maxMemoryBytes
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if await succeeds(middle, threads: 1) { upper = middle } else { lower = middle + 1 }
        }
        for offset in [-8_192, -4_096] {
            #expect(await succeeds(lower + offset, threads: 8) == false, "\(offset) below the minimum")
        }
        for offset in [4_096, 8_192] {
            #expect(await succeeds(lower + offset, threads: 8), "\(offset) above the minimum")
        }
    }

    // MARK: - Synthetic jobs

    /// A 32 × 8 coefficient plane holding four 8 × 8 blocks side by side.
    private func grid() -> [Int32] {
        [Int32](repeating: 0, count: 32 * 8)
    }

    enum Fault: Sendable { case none, decode, before, after }

    /// `.decode` uses a reserved code-block style bit, which CodeBlockDecoder
    /// rejects; `.before` / `.after` carry distinct marker errors.
    private func job(_ index: Int, _ fault: Fault, component: Int = 0, data: [UInt8] = [0x12, 0x34]) -> CodeBlockJob {
        let block = CodeBlock(x0: 0, y0: 0, x1: 8, y1: 8,
                              segments: [CodeBlockSegment(passes: 1, length: data.count)],
                              data: data, totalPasses: 1)
        var job = CodeBlockJob(component: component, block: block, orientation: 0, roiShift: 0,
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

    private func serialError(_ jobs: [CodeBlockJob]) -> JP2KError? {
        var plane = grid()
        var budget = MemoryBudget(limit: Limits().maxMemoryBytes)
        do {
            try CodeBlockScheduler.decode(jobs, into: &plane, budget: &budget)
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
    func serialPathStopsAtTheFirstFailingBlock(faults: [Fault], expected: JP2KError) {
        #expect(serialError(faults.enumerated().map { job($0.offset, $0.element) }) == expected)
    }

    @Test func errorBeforeDecodeSkipsTheDecodeAndAfterStillDecodes() {
        // A block whose listing failed before decoding reports that error even
        // if decoding it would also fail; a placement error comes after a
        // successful decode, so a decode failure in the same block wins.
        var both = job(0, .decode)
        both.errorBeforeDecode = .limitExceeded(.packets)
        var decodeThenPlace = job(0, .decode)
        decodeThenPlace.errorAfterDecode = .limitExceeded(.layers)
        #expect(serialError([both, job(1, .none)]) == .limitExceeded(.packets))
        #expect(serialError([decodeThenPlace, job(1, .none)]) == .invalidCodestream(.badCodeBlock))
    }

    /// Four blocks with distinct data on each of two planes.
    private func twoComponentJobs() -> [CodeBlockJob] {
        (0..<2).flatMap { component in
            (0..<4).map { index in
                job(index, .none, component: component,
                    data: [UInt8(0x12 &+ index &* 0x31 &+ component &* 7), 0x34, UInt8(0x9B &- index), 0x5C])
            }
        }
    }

    @Test(arguments: [2, 3, 8])
    func concurrentRunWritesWhatTheSerialPathWrites(threads: Int) async throws {
        let jobs = twoComponentJobs()
        var expected = [grid(), grid()]
        var budget = MemoryBudget(limit: Limits().maxMemoryBytes)
        for component in 0..<2 {
            try CodeBlockScheduler.decode(jobs.filter { $0.component == component }, into: &expected[component],
                                          budget: &budget)
        }
        #expect(expected[0] != grid() && expected[1] != grid() && expected[0] != expected[1])
        var planes = [grid(), grid()]
        var context = DecodeContext(limits: limits(threads: threads))
        #expect(await CodeBlockScheduler.decodeConcurrently(jobs, into: &planes, context: &context))
        #expect(planes == expected)
        #expect(context.budget.used == 0)
        #expect(context.parallelRuns == 1)
    }

    @Test(arguments: [
        [Fault.none, .decode, .none, .none],
        [Fault.none, .none, .none, .before],
        [Fault.after, .none, .none, .none]
    ])
    func anyFailureLeavesTheErrorToTheSerialPath(faults: [Fault]) async {
        // Whichever worker fails, the concurrent run writes nothing and
        // reports no error: the serial path decides which error is first.
        var jobs = twoComponentJobs()
        for (index, fault) in faults.enumerated() {
            jobs[4 + index] = job(index, fault, component: 1)
        }
        for threads in [2, 4] {
            var planes = [grid(), grid()]
            var context = DecodeContext(limits: limits(threads: threads))
            #expect(await CodeBlockScheduler.decodeConcurrently(jobs, into: &planes, context: &context) == false)
            #expect(planes == [grid(), grid()], "\(threads) threads")
            #expect(context.budget.used == 0)
            #expect(context.parallelRuns == 0)
        }
    }

    @Test func concurrentRunGivesWayWhenItsSharesDoNotFit() async {
        var planes = [grid(), grid()]
        var context = DecodeContext(limits: limits(threads: 4))
        context.budget = MemoryBudget(limit: 4_096)
        #expect(await CodeBlockScheduler.decodeConcurrently(twoComponentJobs(), into: &planes, context: &context) == false)
        #expect(planes == [grid(), grid()])
        #expect(context.budget.used == 0)
    }
}
