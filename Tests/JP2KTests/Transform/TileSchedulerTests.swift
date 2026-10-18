import Foundation
import Testing
@testable import JP2K

struct TileSchedulerTests {
    private func limits(threads: Int) -> Limits {
        var limits = Limits()
        limits.maxThreads = threads
        // Small fixtures stay serial by default; force the tile scheduler.
        limits.parallelSampleThreshold = 0
        limits.maxPixels = 1 << 16
        limits.maxCodingPasses = 1 << 16
        limits.maxPacketIterations = 1 << 16
        return limits
    }

    private func outcome(_ bytes: [UInt8], threads: Int) async -> (Result<[[Int32]], JP2KError>, Int) {
        do {
            let (image, metrics) = try await JP2KDecoder(limits: limits(threads: threads))
                .decodeComponentsWithMetrics(bytes)
            return (.success(image.components), metrics.parallelRuns)
        } catch {
            return (.failure(error), 0)
        }
    }

    @Test(arguments: ["tiles-127x61.j2k", "two-tiles-127x61.j2k"])
    func damagedTilesFailTheSameWayOnAnyThreadCount(name: String) async throws {
        // A flipped byte can break Tier-2 of one tile and Tier-1 of another;
        // the serial loop reports whichever tile comes first, and so must the
        // concurrent path, whichever child finishes first.
        let bytes = Array(try Data(contentsOf: #require(Fixtures.url(name))))
        var parallelDecodes = 0
        var failures = 0
        for position in stride(from: 60, to: bytes.count, by: 113) {
            var input = bytes
            input[position] ^= 0x5A
            let serial = await outcome(input, threads: 1)
            for threads in [2, 5] {
                let concurrent = await outcome(input, threads: threads)
                #expect(concurrent.0 == serial.0, "flip at \(position), \(threads) threads")
                if concurrent.1 > 0 { parallelDecodes += 1 }
            }
            if case .failure = serial.0 { failures += 1 }
        }
        // Both outcomes must be exercised on the concurrent path.
        #expect(parallelDecodes > 0)
        #expect(failures > 0)
    }

    @Test func tightBudgetRestartsSeriallyWithTheSameResult() async throws {
        let bytes = Array(try Data(contentsOf: #require(Fixtures.url("tiles-127x61.j2k"))))
        let measured = try await JP2KDecoder(limits: limits(threads: 1)).decodeComponentsWithMetrics(bytes)
        #expect(measured.1.parallelRuns == 0)
        // At the serial peak (plus allocator slack) the per-tile shares do
        // not fit, so the decode must restart serially and still succeed.
        var tight = limits(threads: 8)
        tight.maxMemoryBytes = measured.1.peakMemoryBytes + 256
        let restarted = try await JP2KDecoder(limits: tight).decodeComponentsWithMetrics(bytes)
        #expect(restarted.0.components == measured.0.components)
        #expect(restarted.1.parallelRuns == 0)
        var roomy = limits(threads: 8)
        roomy.maxMemoryBytes = measured.1.peakMemoryBytes * 4
        let concurrent = try await JP2KDecoder(limits: roomy).decodeComponentsWithMetrics(bytes)
        #expect(concurrent.0.components == measured.0.components)
        #expect(concurrent.1.parallelRuns > 0)
    }

    @Test func largeTilesUseTheSchedulerWithDefaultLimits() async throws {
        // 128 × 128 tile planes are 64 KiB, where allocators round coarsely;
        // the per-tile shares must still cover them, or every decode would
        // quietly restart serially.
        guard let root = Conformance.root() else { return }
        let url = root.appendingPathComponent("input/conformance/p0_07.j2k")
        let bytes = Array(try Data(contentsOf: url))
        #expect(try await JP2KDecoder().decodeComponentsWithMetrics(bytes).1.parallelRuns > 0)
    }

    @Test func roundingAllowanceCoversCoarseAllocatorQuanta() throws {
        // macOS's medium zone rounds to 32 KiB (a 64 KiB plane plus its array
        // header becomes 96 KiB) and some Linux arm64 kernels map 64 KiB
        // pages. The test runner's allocator does not always show this, so
        // the allowance itself is pinned.
        let header = 32
        for bytes in stride(from: 24_576, through: 8 << 20, by: 4_093) {
            let allowance = try CodeBlockScheduler.rounded(bytes)
            let roundedTo64K = (bytes + header + 65_535) / 65_536 * 65_536
            #expect(allowance >= roundedTo64K - header, "\(bytes) bytes")
        }
        for bytes in stride(from: 0, to: 24_576, by: 97) {
            // Small size classes are at most 1/8 apart.
            #expect(try CodeBlockScheduler.rounded(bytes) >= bytes + bytes / 8)
        }
    }

    @Test func memoryLimitBoundaryDoesNotDependOnThreads() async throws {
        // Limits clearly below the serial minimum must fail and limits
        // clearly above it must succeed with any thread count: any memory
        // doubt sends the concurrent path back to the serial loop. (glibc's
        // allocation rounding varies between runs, so the exact boundary is
        // a little fuzzy and is avoided.)
        let bytes = Array(try Data(contentsOf: #require(Fixtures.url("two-tiles-127x61.j2k"))))
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
            #expect(await succeeds(lower + offset, threads: 4) == false, "\(offset) below the minimum")
        }
        for offset in [4_096, 8_192] {
            #expect(await succeeds(lower + offset, threads: 4), "\(offset) above the minimum")
        }
    }

    // MARK: - Error order across tiles

    enum Damage: Sendable { case tier1, tier2 }

    /// Tier-1 fails on a reserved code-block style bit; Tier-2 fails on a
    /// truncated packet body.
    private func damaged(_ damage: [Int: Damage]) throws -> (MainHeader, [TileData]) {
        let bytes = Array(try Data(contentsOf: #require(Fixtures.url("tiles-127x61.j2k"))))
        var context = DecodeContext(limits: Limits())
        let header = try MainHeaderParser.parse(bytes, range: 0..<bytes.count, context: &context)
        var tiles = try TilePartParser.parse(bytes, header: header, context: &context)
        for (index, kind) in damage {
            switch kind {
            case .tier1: tiles[index].parameters.cod.component.codeBlockStyle |= 0x40
            case .tier2: tiles[index].body.removeLast(tiles[index].body.count / 2)
            }
        }
        return (header, tiles)
    }

    private func serialError(_ header: MainHeader, _ tiles: [TileData]) async -> JP2KError? {
        var context = DecodeContext(limits: limits(threads: 1))
        do {
            for tile in tiles { _ = try await TileDecoder.decode(tile, header: header, context: &context) }
            return nil
        } catch {
            return error
        }
    }

    @Test(arguments: [
        [5: Damage.tier1, 9: .tier2],
        [5: Damage.tier2, 9: .tier1],
        [2: Damage.tier1, 3: .tier1, 14: .tier2],
        [0: Damage.tier2, 1: .tier1],
        [15: Damage.tier1],
    ])
    func lowestFailingTileWins(damage: [Int: Damage]) async throws {
        // Whichever child finishes first, the error is the one the serial
        // loop meets first: Tier-1 of an earlier tile before Tier-2 of a
        // later one, and Tier-2 of an earlier tile before anything later.
        let (header, tiles) = try damaged(damage)
        let expected = await serialError(header, tiles)
        let first = try #require(damage.keys.min())
        #expect(expected == (damage[first] == .tier1 ? .invalidCodestream(.badCodeBlock)
                                                      : .invalidCodestream(.badPacketHeader)))
        for threads in [2, 4, 16] {
            var context = DecodeContext(limits: limits(threads: threads))
            do {
                let result = try await TileScheduler.decode(tiles, header: header, context: &context)
                Issue.record("expected \(String(describing: expected)), got \(result == nil ? "a restart" : "success")")
            } catch {
                #expect(error == expected, "\(threads) threads")
            }
        }
    }
}
