import Testing
@testable import JP2K

@Test func inverse53RoundTrip() {
    let original: [Int32] = [10, -3, 22, 17, -9, 40, 5, -12, 31]
    var forward = original
    for index in forward.indices where index & 1 == 1 {
        let right = min(index + 1, forward.count - 1)
        forward[index] -= (original[index - 1] + original[right]) >> 1
    }
    for index in forward.indices where index & 1 == 0 {
        let left = max(index - 1, 1)
        let right = min(index + 1, forward.count - 2)
        forward[index] += (forward[left] + forward[right] + 2) >> 2
    }
    var packed = forward.indices.filter { $0 & 1 == 0 }.map { forward[$0] }
    packed += forward.indices.filter { $0 & 1 == 1 }.map { forward[$0] }
    var work = [Int32](repeating: 0, count: original.count)
    InverseDWT.inverse53(&packed, work: &work, lowCount: 5, count: original.count, parity: 0)
    #expect(packed == original)
}

@Test func inverse97RoundTrip() {
    let original: [Float] = [1, 2, -3, 4, 5, -2, 7, 8, 9]
    var forward = original
    func lift(_ parity: Int, _ factor: Float) {
        for index in forward.indices where index & 1 == parity {
            let left = index > 0 ? index - 1 : index + 1
            let right = index + 1 < forward.count ? index + 1 : index - 1
            forward[index] += (forward[left] + forward[right]) * factor
        }
    }
    lift(1, -1.586134342)
    lift(0, -0.052980118)
    lift(1, 0.882911075)
    lift(0, 0.443506852)
    for index in forward.indices { forward[index] /= index & 1 == 0 ? 1.230174105 : 1.625732422 }
    var packed = forward.indices.filter { $0 & 1 == 0 }.map { Int32(bitPattern: forward[$0].bitPattern) }
    packed += forward.indices.filter { $0 & 1 == 1 }.map { Int32(bitPattern: forward[$0].bitPattern) }
    var work = [Float](repeating: 0, count: original.count)
    InverseDWT.inverse97(&packed, work: &work, lowCount: 5, count: original.count, parity: 0)
    for index in original.indices {
        let value = Float(bitPattern: UInt32(bitPattern: packed[index]))
        #expect(abs(value - original[index]) < 0.001)
    }
}

@Test func inverseDWTRejectsInvalidResolutionGeometry() throws {
    let low = Resolution(x0: 0, y0: 0, x1: 1, y1: 1, precinctsWide: 0, precinctsHigh: 0, bands: [])
    let high = Resolution(x0: 0, y0: 0, x1: 3, y1: 1, precinctsWide: 0, precinctsHigh: 0, bands: [])
    var coefficients: [Int32] = [0, 0, 0]
    var budget = MemoryBudget(limit: 1024)
    #expect(throws: JP2KError.invalidCodestream(.badCodeBlock)) {
        try InverseDWT.decode(&coefficients, resolutions: [low, high], reversible: true, budget: &budget)
    }
}

@Test func inverseDWTScratchRespectsBudget() throws {
    // One resolution needs no transform and therefore no scratch at all;
    // two resolutions need line scratch, which a zero budget refuses.
    let low = Resolution(x0: 0, y0: 0, x1: 1, y1: 1, precinctsWide: 0, precinctsHigh: 0, bands: [])
    let high = Resolution(x0: 0, y0: 0, x1: 2, y1: 1, precinctsWide: 0, precinctsHigh: 0, bands: [])
    var coefficients: [Int32] = [7]
    var budget = MemoryBudget(limit: 0)
    try InverseDWT.decode(&coefficients, resolutions: [low], reversible: true, budget: &budget)
    #expect(coefficients == [7])
    var pair: [Int32] = [0, 0]
    #expect(throws: JP2KError.limitExceeded(.memory)) {
        try InverseDWT.decode(&pair, resolutions: [low, high], reversible: true, budget: &budget)
    }
    #expect(budget.used == 0)
}

@Test func irreversibleLevelShiftRoundsHalfToEven() throws {
    // OpenJPEG rounds with lrintf / cvtss2si: ties go to the even integer.
    let reals: [Float] = [0.5, 1.5, 2.5, -0.5, -1.5, 0.49999997]
    var values = reals.map { Int32(bitPattern: $0.bitPattern) }
    try InverseMCT.levelShift(&values, precision: 8, signed: true, reversible: false)
    #expect(values == [0, 2, 2, 0, -2, 0])
}
