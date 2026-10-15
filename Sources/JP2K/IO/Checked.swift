/// Arithmetic and conversions for values derived from input data.
enum Checked {
    private static let overflow = JP2KError.invalidCodestream(.arithmeticOverflow)

    static func add(_ a: Int, _ b: Int) throws(JP2KError) -> Int {
        let (result, didOverflow) = a.addingReportingOverflow(b)
        if didOverflow { throw overflow }
        return result
    }

    static func sub(_ a: Int, _ b: Int) throws(JP2KError) -> Int {
        let (result, didOverflow) = a.subtractingReportingOverflow(b)
        if didOverflow { throw overflow }
        return result
    }

    static func mul(_ a: Int, _ b: Int) throws(JP2KError) -> Int {
        let (result, didOverflow) = a.multipliedReportingOverflow(by: b)
        if didOverflow { throw overflow }
        return result
    }

    static func ceilDiv(_ a: Int, _ b: Int) throws(JP2KError) -> Int {
        if b <= 0 { throw overflow }
        let quotient = a / b
        if a > 0 && a % b != 0 { return try add(quotient, 1) }
        return quotient
    }

    static func ceilDivPow2(_ a: Int, _ shift: Int) throws(JP2KError) -> Int {
        if shift < 0 || shift >= Int.bitWidth { throw overflow }
        if shift == Int.bitWidth - 1 {
            if a == Int.min { return -1 }
            return a > 0 ? 1 : 0
        }
        return try ceilDiv(a, 1 << shift)
    }

    static func floorDivPow2(_ a: Int, _ shift: Int) throws(JP2KError) -> Int {
        if shift < 0 || shift >= Int.bitWidth { throw overflow }
        return a >> shift
    }

    static func shiftLeft(_ a: Int, _ shift: Int) throws(JP2KError) -> Int {
        if shift < 0 || shift >= Int.bitWidth { throw overflow }
        if shift == Int.bitWidth - 1 {
            if a == 0 { return 0 }
            if a == -1 { return Int.min }
            throw overflow
        }
        return try mul(a, 1 << shift)
    }

    static func int<T: BinaryInteger>(_ value: T) throws(JP2KError) -> Int {
        guard let result = Int(exactly: value) else { throw overflow }
        return result
    }

    static func int32<T: BinaryInteger>(_ value: T) throws(JP2KError) -> Int32 {
        guard let result = Int32(exactly: value) else { throw overflow }
        return result
    }
}
