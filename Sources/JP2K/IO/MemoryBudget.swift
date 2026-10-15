/// Tracks reserved bytes before creating buffers.
struct MemoryBudget {
    let limit: Int
    private(set) var used: Int = 0

    init(limit: Int) { self.limit = limit }

    mutating func reserve(bytes: Int) throws(JP2KError) {
        if bytes < 0 || limit < 0 || used > limit || bytes > limit - used {
            throw .limitExceeded(.memory)
        }
        used += bytes
    }

    mutating func release(bytes: Int) {
        if bytes > 0 { used -= min(bytes, used) }
    }

    mutating func array<T>(repeating value: T, count: Int) throws(JP2KError) -> [T] {
        if count < 0 { throw .limitExceeded(.memory) }
        let (size, didOverflow) = count.multipliedReportingOverflow(by: MemoryLayout<T>.stride)
        if didOverflow { throw .limitExceeded(.memory) }
        try reserve(bytes: size)
        return [T](repeating: value, count: count)
    }
}
