import Testing
@testable import JP2K

@Test func checkedArithmetic() throws {
    #expect(try Checked.add(2, 3) == 5)
    #expect(try Checked.sub(2, 3) == -1)
    #expect(try Checked.mul(-3, 4) == -12)
    #expect(throws: JP2KError.invalidCodestream(.arithmeticOverflow)) {
        _ = try Checked.add(Int.max, 1)
    }
    #expect(throws: JP2KError.invalidCodestream(.arithmeticOverflow)) {
        _ = try Checked.sub(Int.min, 1)
    }
    #expect(throws: JP2KError.invalidCodestream(.arithmeticOverflow)) {
        _ = try Checked.mul(Int.max, 2)
    }
}

@Test func checkedDivisionAndShifts() throws {
    #expect(try Checked.ceilDiv(5, 2) == 3)
    #expect(try Checked.ceilDiv(-5, 2) == -2)
    #expect(try Checked.ceilDivPow2(5, 1) == 3)
    #expect(try Checked.ceilDivPow2(-5, 1) == -2)
    #expect(try Checked.floorDivPow2(-5, 1) == -3)
    #expect(try Checked.ceilDivPow2(Int.max, 63) == 1)
    #expect(try Checked.floorDivPow2(Int.min, 63) == -1)
    #expect(try Checked.shiftLeft(-1, 63) == Int.min)
    #expect(throws: JP2KError.invalidCodestream(.arithmeticOverflow)) {
        _ = try Checked.ceilDiv(1, 0)
    }
    #expect(throws: JP2KError.invalidCodestream(.arithmeticOverflow)) {
        _ = try Checked.shiftLeft(1, 64)
    }
    #expect(throws: JP2KError.invalidCodestream(.arithmeticOverflow)) {
        _ = try Checked.floorDivPow2(1, -1)
    }
}

@Test func checkedConversions() throws {
    #expect(try Checked.int(UInt32.max) == Int(UInt32.max))
    #expect(try Checked.int32(Int32.min) == Int32.min)
    #expect(throws: JP2KError.invalidCodestream(.arithmeticOverflow)) {
        _ = try Checked.int(UInt64.max)
    }
    #expect(throws: JP2KError.invalidCodestream(.arithmeticOverflow)) {
        _ = try Checked.int32(Int64.max)
    }
}
