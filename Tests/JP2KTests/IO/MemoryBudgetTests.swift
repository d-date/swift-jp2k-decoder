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
    // Allocator rounding is charged too, so allocate well inside the limit.
    let values = try budget.array(repeating: UInt8(7), count: 50)
    #expect(values.count == 50)
    #expect(budget.used == values.capacity)
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

@Test func budgetAppendChargesLiveCapacity() throws {
    var budget = MemoryBudget(limit: 1_000)
    var values: [UInt16] = []
    try budget.append(contentsOf: [UInt16(1), 2, 3], to: &values)
    #expect(budget.used == values.capacity * MemoryLayout<UInt16>.stride)
    try budget.append(UInt16(4), to: &values)
    #expect(budget.used == values.capacity * MemoryLayout<UInt16>.stride)
    try budget.append(contentsOf: [UInt16](repeating: 5, count: 20), to: &values)
    #expect(budget.used == values.capacity * MemoryLayout<UInt16>.stride)
}

@Test func budgetAppendChecksTransientPeakAndPreservesState() throws {
    // Growing from capacity c to the requested target t needs c + t bytes at
    // once; a limit one byte below that must fail without changing state.
    var limited = MemoryBudget(limit: 1_000)
    var candidate: [UInt8] = []
    try limited.append(contentsOf: [UInt8](repeating: 1, count: 8), to: &candidate)
    let oldCapacity = candidate.capacity
    let required = candidate.count + oldCapacity + 1
    let target = max(required, oldCapacity * 2)
    let before = limited.used
    #expect(before == oldCapacity)
    limited = MemoryBudget(limit: before + target - 1)
    try limited.reserve(bytes: before)
    #expect(throws: JP2KError.limitExceeded(.memory)) {
        try limited.append(contentsOf: [UInt8](repeating: 2, count: oldCapacity + 1), to: &candidate)
    }
    #expect(limited.used == before)
    #expect(candidate.count == 8)
    #expect(candidate.capacity == oldCapacity)

    var enough = MemoryBudget(limit: before + target)
    try enough.reserve(bytes: before)
    try enough.append(contentsOf: [UInt8](repeating: 2, count: oldCapacity + 1), to: &candidate)
    #expect(enough.used == candidate.capacity)
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
    #expect(limits.maxTileParts == 32_768)
    #expect(limits.maxLayers == 128)
    #expect(limits.maxMemoryBytes == 512 << 20)
    #expect(limits.maxPackets == 262_144)
    #expect(limits.maxPacketIterations == 4_194_304)
    #expect(limits.maxCodingPasses == 8_388_608)
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

@Test func budgetNeverRecordsMoreThanItsLimit() throws {
    // Allocators may round a request up; that slack must still respect the
    // limit, so every successful charge leaves `used` within it.
    for limit in 1...96 {
        for count in 1...64 {
            var budget = MemoryBudget(limit: limit)
            var values: [UInt8] = []
            if (try? budget.append(contentsOf: repeatElement(UInt8(1), count: count), to: &values)) != nil {
                #expect(budget.used <= limit)
                #expect(budget.used == values.capacity)
            }
            var other = MemoryBudget(limit: limit)
            if let array = try? other.array(repeating: UInt8(0), count: count) {
                #expect(other.used <= limit)
                #expect(other.used == array.capacity)
            }
        }
    }
}
