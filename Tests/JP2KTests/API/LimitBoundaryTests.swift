import Foundation
import Testing
@testable import JP2K

struct LimitBoundaryTests {
    private func fixture(_ name: String) throws -> [UInt8] {
        Array(try Data(contentsOf: #require(Fixtures.url(name))))
    }

    @Test func inputBytes() throws {
        let bytes = try fixture("levels-0.j2k")
        var limits = Limits()
        limits.maxInputBytes = bytes.count
        _ = try JP2KDecoder(limits: limits).readInfo(bytes)
        limits.maxInputBytes = bytes.count - 1
        #expect(throws: JP2KError.limitExceeded(.inputBytes)) {
            _ = try JP2KDecoder(limits: limits).readInfo(bytes)
        }
    }

    @Test func headerLimits() throws {
        let bytes = try fixture("rgb-64-53-mct.jp2")
        let info = try JP2KDecoder().readInfo(bytes)
        let cases: [(JP2KError.Limit, Int, (inout Limits, Int) -> Void)] = [
            (.pixels, info.width * info.height, { $0.maxPixels = $1 }),
            (.components, info.components.count, { $0.maxComponents = $1 }),
            (.bitDepth, info.components.map(\.precision).max() ?? 0, { $0.maxBitDepth = $1 })
        ]
        for (kind, value, set) in cases {
            var limits = Limits()
            set(&limits, value)
            _ = try JP2KDecoder(limits: limits).readInfo(bytes)
            set(&limits, value - 1)
            #expect(throws: JP2KError.limitExceeded(kind)) {
                _ = try JP2KDecoder(limits: limits).readInfo(bytes)
            }
        }
    }

    @Test func tileLayerAndMarkerLimits() throws {
        let bytes = try fixture("tileparts.j2k")
        var context = DecodeContext(limits: Limits())
        let header = try MainHeaderParser.parse(bytes, range: 0..<bytes.count, context: &context)
        let tiles = try TilePartParser.parse(bytes, header: header, context: &context)
        let tileCount = header.geometry.tilesAcross * header.geometry.tilesDown
        let partCount = tiles.reduce(0) { $0 + $1.tilePartCount }
        let cases: [(JP2KError.Limit, Int, (inout Limits, Int) -> Void)] = [
            (.tiles, tileCount, { $0.maxTiles = $1 }),
            (.tileParts, partCount, { $0.maxTileParts = $1 }),
            (.layers, header.cod.layers, { $0.maxLayers = $1 })
        ]
        for (kind, value, set) in cases {
            #expect(value > 0)
            var limits = Limits()
            set(&limits, value)
            _ = try JP2KDecoder(limits: limits).decodeComponents(bytes)
            set(&limits, value - 1)
            #expect(throws: JP2KError.limitExceeded(kind)) {
                _ = try JP2KDecoder(limits: limits).decodeComponents(bytes)
            }
        }
    }

    @Test func retainedMarkerDataBoundary() throws {
        let bytes = try fixture("corrupt/ppm-flood.j2k")
        var context = DecodeContext(limits: Limits())
        _ = try MainHeaderParser.parse(bytes, range: 0..<bytes.count, context: &context)
        let retained = context.markerDataBytes
        #expect(retained > 0)
        var limits = Limits()
        limits.maxMarkerDataBytes = retained
        _ = try JP2KDecoder(limits: limits).readInfo(bytes)
        limits.maxMarkerDataBytes = retained - 1
        #expect(throws: JP2KError.limitExceeded(.markerData)) {
            _ = try JP2KDecoder(limits: limits).readInfo(bytes)
        }
    }

    @Test func skippedMarkerPayloadDoesNotConsumeRetainedBudget() throws {
        let chunk = [UInt8](repeating: 0, count: 60_000)
        var bytes = CodestreamWriter.soc() + CodestreamWriter.siz()
            + CodestreamWriter.cod() + CodestreamWriter.qcd()
        let baseline = bytes + [0xFF, 0x90]
        var baselineContext = DecodeContext(limits: Limits())
        _ = try MainHeaderParser.parse(baseline, range: 0..<baseline.count, context: &baselineContext)
        for _ in 0..<6 { bytes += CodestreamWriter.marker(0xFF55, [0, 0x40] + chunk) }
        for _ in 0..<6 { bytes += CodestreamWriter.marker(0xFF57, [0] + chunk) }
        for _ in 0..<6 { bytes += CodestreamWriter.marker(0xFF64, [0, 0] + chunk) }
        bytes += [0xFF, 0x90]
        #expect(bytes.count > 1 << 20)
        var limits = Limits()
        limits.maxMarkerDataBytes = baselineContext.markerDataBytes
        _ = try JP2KDecoder(limits: limits).readInfo(bytes)
    }

    @Test func skippedPLTDoesNotConsumeRetainedBudget() throws {
        let baseline = try fixture("levels-0.j2k")
        let sot = try #require(baseline.indices.dropLast().first {
            baseline[$0] == 0xFF && baseline[$0 + 1] == 0x90
        })
        let sod = try #require(baseline.indices.dropLast().first {
            baseline[$0] == 0xFF && baseline[$0 + 1] == 0x93
        })
        let payload = [UInt8](repeating: 0, count: 60_001)
        let markers = (0..<18).flatMap { index in
            CodestreamWriter.marker(0xFF58, [UInt8(index)] + payload)
        }
        var bytes = baseline
        bytes.insert(contentsOf: markers, at: sod)
        let originalLength = baseline[(sot + 6)..<(sot + 10)].reduce(0) { ($0 << 8) | Int($1) }
        bytes.replaceSubrange((sot + 6)..<(sot + 10), with: CodestreamWriter.u32(originalLength + markers.count))
        #expect(markers.count > 1 << 20)
        var limits = Limits()
        limits.maxMarkerDataBytes = 100
        var context = DecodeContext(limits: limits)
        let header = try MainHeaderParser.parse(bytes, range: 0..<bytes.count, context: &context)
        _ = try TilePartParser.parse(bytes, header: header, context: &context)
        #expect(context.markerDataBytes < limits.maxMarkerDataBytes)
    }

    @Test func defaultLimitsCoverDenseSixResolutionImage() {
        // Mock the internal resolution and band grids for a 4,000-square
        // component. At each high resolution, a 64-wide precinct covers a
        // 32-wide band, so it holds one nominal 64-wide code block per band.
        let resolutionSides = (0...5).reversed().map { level in
            (4_000 + (1 << level) - 1) >> level
        }
        let precincts = resolutionSides.map { side in
            let across = (side + 63) / 64
            return across * across
        }
        let llBlocksAcross = (resolutionSides[0] + 63) / 64
        let highBlocks = resolutionSides.dropFirst().map { side in
            let bandSide = (side + 1) / 2
            let across = (bandSide + 31) / 32
            return across * across
        }
        let packets = precincts.reduce(0, +) * 4 * 8
        let blocksPerComponent = llBlocksAcross * llBlocksAcross + 3 * highBlocks.reduce(0, +)
        #expect(precincts == [4, 16, 64, 256, 1_024, 3_969])
        let passes = blocksPerComponent * 4 * 109
        #expect(packets == 170_656)
        #expect(blocksPerComponent == 15_991)
        #expect(passes == 6_972_076)
        let limits = Limits()
        #expect(packets <= limits.maxPackets)
        #expect(16 * packets <= limits.maxPacketIterations)
        #expect(passes <= limits.maxCodingPasses)
    }

    @Test func workLimits() throws {
        let bytes = try fixture("levels-0.j2k")
        let measured = try JP2KDecoder().decodeComponentsWithMetrics(bytes)
        // Memory: the recorded peak includes allocator rounding, which varies
        // by platform, so the exact one-byte boundary is not portable. Pin it
        // with a margin instead: the measured peak passes and 90% of it fails
        // with .memory.
        var memoryLimits = Limits()
        memoryLimits.maxMemoryBytes = measured.1.peakMemoryBytes
        _ = try JP2KDecoder(limits: memoryLimits).decodeComponents(bytes)
        memoryLimits.maxMemoryBytes = measured.1.peakMemoryBytes / 10 * 9
        #expect(throws: JP2KError.limitExceeded(.memory)) {
            _ = try JP2KDecoder(limits: memoryLimits).decodeComponents(bytes)
        }
        let cases: [(JP2KError.Limit, Int, (inout Limits, Int) -> Void)] = [
            (.packets, measured.1.packets, { $0.maxPackets = $1 }),
            (.packetIteration, measured.1.packetWork, { $0.maxPacketIterations = $1 }),
            (.codingPasses, measured.1.codingPasses, { $0.maxCodingPasses = $1 })
        ]
        for (kind, value, set) in cases {
            #expect(value > 0)
            var limits = Limits()
            set(&limits, value)
            _ = try JP2KDecoder(limits: limits).decodeComponents(bytes)
            set(&limits, value - 1)
            #expect(throws: JP2KError.limitExceeded(kind)) {
                _ = try JP2KDecoder(limits: limits).decodeComponents(bytes)
            }
        }
    }

    @Test func measureFixtureAndConformanceCounters() throws {
        guard ProcessInfo.processInfo.environment["JP2K_MEASURE_LIMITS"] == "1" else { return }
        let manifestURL = try #require(Fixtures.url("MANIFEST.sha256"))
        let manifest = try String(contentsOf: manifestURL, encoding: .utf8)
        let fixtureNames = manifest.split(separator: "\n").compactMap { line -> String? in
            guard let last = line.split(separator: " ").last else { return nil }
            let name = String(last)
            return (name.hasSuffix(".j2k") || name.hasSuffix(".jp2")) && !name.hasPrefix("corrupt/") ? name : nil
        }
        var sources = try fixtureNames.map { ($0, Array(try Data(contentsOf: #require(Fixtures.url($0))))) }
        if let root = Conformance.root() {
            let names = Conformance.class1.filter { $0.resFactor == 0 }.map(\.name)
                + ["a1_mono", "a2_colr", "a3_mono", "a4_colr", "a5_mono", "a6_mono_colr",
                   "b1_mono", "b2_mono", "b3_mono", "c1_mono", "c2_mono", "d1_colr",
                   "d2_colr", "e1_colr", "e2_colr", "f1_mono", "f2_mono", "g1_colr",
                   "g2_colr", "g3_colr", "g4_colr"].map { "\($0).j2c" }
            for name in names {
                let url = root.appendingPathComponent("input/conformance/\(name)")
                sources.append((name, Array(try Data(contentsOf: url))))
            }
        }
        var limits = Limits()
        limits.maxInputBytes = 256 << 20
        limits.maxPixels = 1 << 26
        limits.maxComponents = 16_384
        limits.maxMemoryBytes = 2 << 30
        limits.maxPackets = Int.max
        limits.maxPacketIterations = Int.max
        limits.maxCodingPasses = Int.max
        limits.maxMarkerDataBytes = Int.max
        let decoder = JP2KDecoder(limits: limits)
        for (name, bytes) in sources {
            let measured = try decoder.decodeComponentsWithMetrics(bytes).1
            var context = DecodeContext(limits: limits)
            let range: Range<Int>
            if name.hasSuffix(".jp2") { range = try JP2Parser.parse(bytes, context: &context).codestream }
            else { range = 0..<bytes.count }
            let header = try MainHeaderParser.parse(bytes, range: range, context: &context)
            let tiles = try TilePartParser.parse(bytes, header: header, context: &context)
            let tileParts = tiles.reduce(0) { $0 + $1.tilePartCount }
            print("LIMIT_METRICS \(name) packets=\(measured.packets) iterations=\(measured.packetWork) passes=\(measured.codingPasses) markers=\(measured.markerDataBytes) tileparts=\(tileParts) layers=\(header.cod.layers) peak=\(measured.peakMemoryBytes)")
        }
    }
}
