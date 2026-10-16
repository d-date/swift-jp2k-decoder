/// Mutable resource accounting for one decode call.
struct DecodeContext {
    let limits: Limits
    var budget: MemoryBudget
    private(set) var packets: Int = 0
    private(set) var packetWork: Int = 0
    private(set) var codingPasses: Int = 0
    private(set) var markerDataBytes: Int = 0

    init(limits: Limits) {
        self.limits = limits
        budget = MemoryBudget(limit: limits.maxMemoryBytes)
    }

    mutating func countPacket() throws(JP2KError) {
        try count(1, current: &packets, maximum: limits.maxPackets, kind: .packets)
    }

    mutating func countPacketWork() throws(JP2KError) {
        try count(1, current: &packetWork, maximum: limits.maxPacketIterations, kind: .packetIteration)
    }

    mutating func countCodingPasses(_ n: Int) throws(JP2KError) {
        try count(n, current: &codingPasses, maximum: limits.maxCodingPasses, kind: .codingPasses)
    }

    mutating func countMarkerData(_ n: Int) throws(JP2KError) {
        try count(n, current: &markerDataBytes, maximum: limits.maxMarkerDataBytes, kind: .markerData)
    }

    private func count(
        _ amount: Int,
        current: inout Int,
        maximum: Int,
        kind: JP2KError.Limit
    ) throws(JP2KError) {
        if amount < 0 || maximum < 0 || current > maximum || amount > maximum - current {
            throw .limitExceeded(kind)
        }
        current += amount
    }
}
