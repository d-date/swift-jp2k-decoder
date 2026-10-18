import Foundation
import Testing
@testable import JP2K

@Test func mqTablesHaveReferenceSizes() {
    #expect(T1Tables.zeroCoding.count == 2048)
    #expect(T1Tables.signCoding.count == 256)
    #expect(T1Tables.signPrediction.count == 256)
    #expect(T1Tables.states.count == 94)
}

@Test func mqEmptyInputUsesSyntheticMarker() {
    var decoder = MQDecoder.testing(data: [], segmentLengths: [0])
    decoder.setState(context: 0, msb: 0, prob: 0)
    for _ in 0..<32 { #expect(decoder.decode(context: 0) == 1) }
}

@Test func mqTenThousandSymbolRoundTrip() {
    var encoder = MQEncoder()
    var seed: UInt32 = 0x1234_5678
    var symbols: [(Int, Int)] = []
    for index in 0..<10_000 {
        seed = seed &* 1_664_525 &+ 1_013_904_223
        let context = index % 19
        let bit = Int((seed >> 29) & 1)
        encoder.encode(bit, context: context)
        symbols.append((context, bit))
    }
    let bytes = encoder.flush()
    var decoder = MQDecoder.testing(data: bytes, segmentLengths: [bytes.count])
    for (context, bit) in symbols {
        #expect(decoder.decode(context: context) == bit)
    }
}

@Test func mqRawModeStuffingAndMarker() {
    var decoder = MQDecoder.testing(data: [0xFF, 0x7F, 0xAB], segmentLengths: [3])
    decoder.rawInitDec()
    let bits = (0..<23).map { _ in decoder.rawDecode() }
    let expected = Array(repeating: 1, count: 8) + Array(repeating: 1, count: 7)
        + [1, 0, 1, 0, 1, 0, 1, 1]
    #expect(bits == expected)
    for _ in 0..<32 { #expect(decoder.rawDecode() == 1) }
}

#if !os(Android)
@Test func mqMatchesInstrumentedOpenJPEGCodeBlock() throws {
    let url = try #require(Fixtures.url("mq-trace-gray-53.txt"))
    let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n")
    let hex = try #require(lines.first { $0.hasPrefix("B ") }).dropFirst(2)
    var bytes: [UInt8] = []
    var cursor = hex.startIndex
    while cursor < hex.endIndex {
        let next = hex.index(cursor, offsetBy: 2)
        bytes.append(try #require(UInt8(hex[cursor..<next], radix: 16)))
        cursor = next
    }
    var decoder = MQDecoder.testing(data: bytes, segmentLengths: [bytes.count])
    decoder.setState(context: 18, msb: 0, prob: 46)
    decoder.setState(context: 17, msb: 0, prob: 3)
    decoder.setState(context: 0, msb: 0, prob: 4)
    var count = 0
    for line in lines where line.hasPrefix("S ") {
        let fields = line.split(separator: " ")
        let context = try #require(Int(fields[1]))
        let expected = try #require(Int(fields[2]))
        #expect(decoder.decode(context: context) == expected)
        count += 1
    }
    #expect(count == 128)
}
#endif

@Test func mqTableReferenceEntriesAndMaskedLookups() {
    #expect(T1Tables.zeroCoding[0] == 0)
    #expect(T1Tables.zeroCoding[1] == 1)
    #expect(T1Tables.zeroCoding[2047] == 8)
    #expect(T1Tables.signCoding[0] == 9)
    #expect(T1Tables.signCoding[255] == 13)
    #expect(T1Tables.signPrediction[0] == 0)
    #expect(T1Tables.signPrediction[255] == 1)
    #expect(T1Tables.zeroContext(orientation: 0, flags: 0x210) == 0)
    #expect(T1Tables.signContext(256) == 9)
    #expect(T1Tables.predictedSign(256) == 0)
    #expect(T1Tables.magnitudeContext(flags: 0) == 14)
    #expect(T1Tables.magnitudeContext(flags: 1) == 15)
    #expect(T1Tables.magnitudeContext(flags: 1 << 20) == 16)
}

@Test func mqCanSelectLaterSegments() {
    var decoder = MQDecoder.testing(data: [0, 0xAA, 0x55], segmentLengths: [1, 2])
    decoder.startSegment(1, raw: true)
    let bits = (0..<16).map { _ in decoder.rawDecode() }
    #expect(bits == [1, 0, 1, 0, 1, 0, 1, 0,
                     0, 1, 0, 1, 0, 1, 0, 1])
}

@Test func mqCanRevisitSegmentsAfterSequentialDecode() {
    var decoder = MQDecoder.testing(data: [0x11, 0xAA, 0x55], segmentLengths: [1, 1, 1])
    decoder.startSegment(0, raw: true)
    #expect((0..<8).map { _ in decoder.rawDecode() } == [0, 0, 0, 1, 0, 0, 0, 1])
    decoder.startSegment(1, raw: true)
    #expect((0..<8).map { _ in decoder.rawDecode() } == [1, 0, 1, 0, 1, 0, 1, 0])
    decoder.startSegment(2, raw: true)
    #expect((0..<8).map { _ in decoder.rawDecode() } == [0, 1, 0, 1, 0, 1, 0, 1])
    decoder.startSegment(1, raw: true)
    #expect((0..<8).map { _ in decoder.rawDecode() } == [1, 0, 1, 0, 1, 0, 1, 0])
}

@Test func mqBudgetChargesCopyBeforeAllocation() throws {
    var budget = MemoryBudget(limit: 5)
    let decoder = try MQDecoder(data: [0, 1, 2], segmentLengths: [3], budget: &budget)
    #expect(budget.used == 5)
    _ = decoder
    #expect(throws: JP2KError.limitExceeded(.memory)) {
        _ = try MQDecoder(data: [0, 1, 2, 3], segmentLengths: [4], budget: &budget)
    }
    #expect(budget.used == 5)
}

@Test func mqRawMarkerStopsInput() {
    var decoder = MQDecoder.testing(data: [0xFF, 0x90], segmentLengths: [2])
    decoder.rawInitDec()
    for _ in 0..<40 { #expect(decoder.rawDecode() == 1) }
}

@Test func mqDecodesStandardTestSequence() {
    let encoded: [UInt8] = [
        0x84, 0xC7, 0x3B, 0xFC, 0xE1, 0xA1, 0x43, 0x04,
        0x02, 0x20, 0x00, 0x00, 0x41, 0x0D, 0xBB, 0x86,
        0xF4, 0x31, 0x7F, 0xFF, 0x88, 0xFF, 0x37, 0x47,
        0x1A, 0xDB, 0x6A, 0xDF, 0xFF, 0xAC
    ]
    let decoded: [UInt8] = [
        0x00, 0x02, 0x00, 0x51, 0x00, 0x00, 0x00, 0xC0,
        0x03, 0x52, 0x87, 0x2A, 0xAA, 0xAA, 0xAA, 0xAA,
        0x82, 0xC0, 0x20, 0x00, 0xFC, 0xD7, 0x9E, 0xF6,
        0xBF, 0x7F, 0xED, 0x90, 0x4F, 0x46, 0xA3, 0xBF
    ]
    let bits = decoded.flatMap { byte in (0..<8).reversed().map { Int((byte >> $0) & 1) } }
    // Test sequence from ITU-T T.88 Annex H.2 (same MQ coder as JPEG 2000),
    // single context starting at state 0. It pins both the decoder and the
    // test-only encoder used by the round-trip tests.
    var decoder = MQDecoder.testing(data: encoded, segmentLengths: [encoded.count])
    for bit in bits { #expect(decoder.decode(context: 0) == bit) }
    var encoder = MQEncoder()
    for bit in bits { encoder.encode(bit, context: 0) }
    // T.88's flush also emits the FF AC terminator, which the JPEG 2000
    // flush (opj_mqc_flush) leaves out; everything before it must match.
    let flushed = encoder.flush()
    #expect(flushed + [0xFF, 0xAC] == encoded)
}

@Test func t1ContextTablesStayWithinMQContexts() {
    // MQDecoder has 19 contexts; every context a table can yield must fit.
    #expect(T1Tables.zeroCoding.allSatisfy { $0 < 19 })
    #expect(T1Tables.signCoding.allSatisfy { $0 < 19 })
}

@Test func mqSkewedSourcesRoundTripThroughEveryState() {
    // Per-context probabilities from 1/2 down to 1/4096 walk the
    // probability states down to the smallest Qe and back on LPS hits.
    var encoder = MQEncoder()
    var seed: UInt32 = 0x9E37_79B9
    var symbols: [(Int, Int)] = []
    for index in 0..<60_000 {
        seed = seed &* 1_664_525 &+ 1_013_904_223
        let context = index % 19
        let skew = UInt32(1) << (context % 13)
        let bit = (seed >> 8) % (skew * 2) == 0 ? 1 : 0
        encoder.encode(bit, context: context)
        symbols.append((context, bit))
    }
    let bytes = encoder.flush()
    var decoder = MQDecoder.testing(data: bytes, segmentLengths: [bytes.count])
    var mismatches = 0
    for (context, bit) in symbols where decoder.decode(context: context) != bit { mismatches += 1 }
    #expect(mismatches == 0)
}

/// opj_mqc_decode / opj_mqc_renormd / opj_mqc_bytein written out literally,
/// with a bit-at-a-time renormalisation, as the reference for MQDecoder.
private struct ReferenceMQ {
    let data: [UInt8]
    var position = 0
    var a: UInt32 = 0x8000
    var c: UInt32 = 0
    var ct = 0
    var states = [Int](repeating: 0, count: 19)

    init(_ data: [UInt8]) {
        self.data = data
        states[18] = 46 * 2
        states[17] = 3 * 2
        states[0] = 4 * 2
        c = UInt32(byte(0)) << 16
        byteIn()
        c <<= 7
        ct -= 7
    }

    func byte(_ index: Int) -> UInt8 { index < data.count ? data[index] : 0xFF }

    mutating func byteIn() {
        if byte(position) == 0xFF {
            if byte(position + 1) > 0x8F {
                c &+= 0xFF00
                ct = 8
            } else {
                position += 1
                c &+= UInt32(byte(position)) << 9
                ct = 7
            }
        } else {
            position += 1
            c &+= UInt32(byte(position)) << 8
            ct = 8
        }
    }

    mutating func renormalize() {
        repeat {
            if ct == 0 { byteIn() }
            a <<= 1
            c <<= 1
            ct -= 1
        } while a < 0x8000
    }

    mutating func decode(_ context: Int) -> Int {
        let state = T1Tables.states[states[context]]
        let qeval = UInt32(state.qeval)
        a -= qeval
        let symbol: Int
        if c >> 16 < qeval {
            if a < qeval {
                a = qeval
                symbol = Int(state.mps)
                states[context] = Int(state.nmps)
            } else {
                a = qeval
                symbol = 1 - Int(state.mps)
                states[context] = Int(state.nlps)
            }
            renormalize()
        } else {
            c -= qeval << 16
            if a & 0x8000 == 0 {
                if a < qeval {
                    symbol = 1 - Int(state.mps)
                    states[context] = Int(state.nlps)
                } else {
                    symbol = Int(state.mps)
                    states[context] = Int(state.nmps)
                }
                renormalize()
            } else {
                symbol = Int(state.mps)
            }
        }
        return symbol
    }
}

@Test func mqMatchesReferenceOnArbitraryBytes() {
    // Random bytes, rich in 0xFF stuffing and markers, drive every branch:
    // LPS and MPS exchanges, renormalisation across byte boundaries (ct
    // reaching 0 mid-shift) and the synthetic 0xFF tail.
    var seed: UInt32 = 0xC0FF_EE11
    for trial in 0..<200 {
        var bytes: [UInt8] = []
        for _ in 0..<(16 + trial % 97) {
            seed = seed &* 1_664_525 &+ 1_013_904_223
            let roll = seed >> 24
            bytes.append(roll < 40 ? 0xFF : roll < 60 ? UInt8(0x80 + (seed >> 8) % 0x20) : UInt8(truncatingIfNeeded: seed >> 11))
        }
        var reference = ReferenceMQ(bytes)
        var decoder = MQDecoder.testing(data: bytes, segmentLengths: [bytes.count])
        decoder.setState(context: 18, msb: 0, prob: 46)
        decoder.setState(context: 17, msb: 0, prob: 3)
        decoder.setState(context: 0, msb: 0, prob: 4)
        var mismatch = false
        for index in 0..<2_000 {
            seed = seed &* 1_664_525 &+ 1_013_904_223
            let context = Int((seed >> 16) % 19)
            if decoder.decode(context: context) != reference.decode(context) {
                Issue.record("trial \(trial): first difference at symbol \(index)")
                mismatch = true
                break
            }
        }
        if mismatch { break }
    }
}
