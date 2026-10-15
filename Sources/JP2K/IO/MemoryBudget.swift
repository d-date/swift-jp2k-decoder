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

    /// The caller must pass uniquely owned storage. Charges both buffers while growing.
    mutating func append<T, C: Collection>(contentsOf elements: C, to array: inout [T]) throws(JP2KError)
    where C.Element == T {
        if elements.isEmpty { return }
        let (required, countOverflow) = array.count.addingReportingOverflow(elements.count)
        if countOverflow { throw .limitExceeded(.memory) }
        let oldCapacity = array.capacity
        if required > oldCapacity {
            let doubled = oldCapacity.multipliedReportingOverflow(by: 2)
            let target = max(required, doubled.overflow ? required : doubled.partialValue)
            let stride = MemoryLayout<T>.stride
            let (newBytes, overflow) = target.multipliedReportingOverflow(by: stride)
            if overflow { throw .limitExceeded(.memory) }
            let (oldBytes, oldOverflow) = oldCapacity.multipliedReportingOverflow(by: stride)
            if oldOverflow { throw .limitExceeded(.memory) }
            // The limit is enforced on the requested capacity before anything
            // changes, so a failure leaves both `used` and `array` untouched.
            try reserve(bytes: newBytes)
            array.reserveCapacity(target)
            // Allocators may round the capacity up (e.g. glibc usable size);
            // that slack is not input-amplifiable, so it is recorded without a
            // limit check to keep `used` equal to live capacity bytes.
            let actualBytes = array.capacity &* stride
            if actualBytes > newBytes {
                used = used.addingReportingOverflow(actualBytes - newBytes).overflow ? Int.max : used + (actualBytes - newBytes)
            } else if actualBytes < newBytes {
                release(bytes: newBytes - actualBytes)
            }
            release(bytes: oldBytes)
        }
        array.append(contentsOf: elements)
    }

    mutating func append<T>(_ element: T, to array: inout [T]) throws(JP2KError) {
        try append(contentsOf: CollectionOfOne(element), to: &array)
    }
}
