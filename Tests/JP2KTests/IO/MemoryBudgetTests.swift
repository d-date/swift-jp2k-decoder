import Testing
@testable import JP2K

@Test func budgetRejectsBeforeAllocating() throws {
    var budget = MemoryBudget(limit: 100)
    #expect(throws: JP2KError.limitExceeded(.memory)) {
        _ = try budget.array(repeating: Int32(0), count: 26)
    }
    #expect(budget.used == 0)
    #expect(throws: JP2KError.limitExceeded(.memory)) {
        _ = try budget.array(repeating: UInt8(0), count: Int.max)
    }
    #expect(budget.used == 0)
    let values = try budget.array(repeating: UInt8(7), count: 100)
    #expect(values.count == 100)
    #expect(budget.used == 100)
    budget.release(bytes: 150)
    #expect(budget.used == 0)
}

@Test func budgetRejectsInvalidReservations() {
    var budget = MemoryBudget(limit: 1)
    #expect(throws: JP2KError.limitExceeded(.memory)) { try budget.reserve(bytes: -1) }
    #expect(throws: JP2KError.limitExceeded(.memory)) {
        _ = try budget.array(repeating: UInt8(0), count: -1)
    }
    #expect(budget.used == 0)
}

@Test func contextCountsAndBoundaries() throws {
    var limits = Limits()
    limits.maxPackets = 2
    limits.maxCodingPasses = 3
    limits.maxMarkerDataBytes = 4
    var context = DecodeContext(limits: limits)
    try context.countPacket()
    try context.countPacket()
    #expect(context.packets == 2)
    #expect(throws: JP2KError.limitExceeded(.packets)) { try context.countPacket() }
    #expect(context.packets == 2)
    try context.countCodingPasses(3)
    #expect(throws: JP2KError.limitExceeded(.codingPasses)) {
        try context.countCodingPasses(1)
    }
    try context.countMarkerData(4)
    #expect(throws: JP2KError.limitExceeded(.markerData)) {
        try context.countMarkerData(Int.max)
    }
    #expect(context.markerDataBytes == 4)
}

@Test func publicDefaultsAndErrorDetails() {
    let limits = Limits()
    #expect(limits.maxInputBytes == 32 << 20)
    #expect(limits.maxPixels == 16_000_000)
    #expect(limits.maxComponents == 4)
    #expect(limits.maxBitDepth == 16)
    #expect(limits.maxTiles == 4_096)
    #expect(limits.maxTileParts == 16_384)
    #expect(limits.maxLayers == 64)
    #expect(limits.maxMemoryBytes == 512 << 20)
    #expect(limits.maxPackets == 1_000_000)
    #expect(limits.maxCodingPasses == 4_000_000)
    #expect(limits.maxMarkerDataBytes == 8 << 20)
    #expect(JP2KError.Reason(rawValue: "truncated") == .truncated)
    #expect(JP2KError.Limit(rawValue: "memory") == .memory)
    #expect(JP2KError.Feature(rawValue: "htj2k") == .htj2k)
}

@Test func bitDepthLimitClampsToSupportedPrecision() {
    var limits = Limits()
    limits.maxBitDepth = 32
    #expect(limits.maxBitDepth == 16)
    limits.maxBitDepth = 8
    #expect(limits.maxBitDepth == 8)
}
