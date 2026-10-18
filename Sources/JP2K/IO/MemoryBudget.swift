/// Tracks reserved bytes before creating buffers.
struct MemoryBudget {
    let limit: Int
    private(set) var used: Int = 0
    private(set) var peak: Int = 0

    init(limit: Int) { self.limit = limit }

    mutating func reserve(bytes: Int) throws(JP2KError) {
        if bytes < 0 || limit < 0 || used > limit || bytes > limit - used {
            throw .limitExceeded(.memory)
        }
        used += bytes
        peak = max(peak, used)
    }

    mutating func release(bytes: Int) {
        if bytes > 0 { used -= min(bytes, used) }
    }

    mutating func array<T>(repeating value: T, count: Int) throws(JP2KError) -> [T] {
        if count < 0 { throw .limitExceeded(.memory) }
        let (size, didOverflow) = count.multipliedReportingOverflow(by: MemoryLayout<T>.stride)
        if didOverflow { throw .limitExceeded(.memory) }
        try reserve(bytes: size)
        let array = [T](repeating: value, count: count)
        do {
            try chargeSlack(actualBytes: array.capacity &* MemoryLayout<T>.stride, requestedBytes: size)
        } catch {
            release(bytes: size)
            throw error
        }
        return array
    }

    /// Allocators may round a request up (e.g. malloc_size, glibc usable size).
    /// The rounding is charged like any other byte so `used` never exceeds
    /// `limit`; an unused part of the request is released.
    private mutating func chargeSlack(actualBytes: Int, requestedBytes: Int) throws(JP2KError) {
        if actualBytes > requestedBytes {
            try reserve(bytes: actualBytes - requestedBytes)
        } else if actualBytes < requestedBytes {
            release(bytes: requestedBytes - actualBytes)
        }
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
            var grown = array
            grown.reserveCapacity(target)
            do {
                try chargeSlack(actualBytes: grown.capacity &* stride, requestedBytes: newBytes)
            } catch {
                // Dropping `grown` frees the new storage; `array` is untouched.
                release(bytes: newBytes)
                throw error
            }
            array = grown
            release(bytes: oldBytes)
        }
        array.append(contentsOf: elements)
    }

    mutating func append<T>(_ element: T, to array: inout [T]) throws(JP2KError) {
        try append(contentsOf: CollectionOfOne(element), to: &array)
    }
}
