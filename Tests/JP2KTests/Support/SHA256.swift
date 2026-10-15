// A small SHA-256 implementation for platforms without CryptoKit.
import Foundation
enum SHA256 {
    private static let constants: [UInt32] = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
        0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
        0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
        0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
        0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
    ]

    private static func rotate(_ value: UInt32, _ amount: UInt32) -> UInt32 {
        (value >> amount) | (value << (32 - amount))
    }

    static func hex(_ input: [UInt8]) -> String {
        var data = input
        let bitCount = UInt64(data.count) &* 8
        data.append(0x80)
        while data.count % 64 != 56 { data.append(0) }
        for shift in stride(from: 56, through: 0, by: -8) {
            data.append(UInt8(truncatingIfNeeded: bitCount >> shift))
        }
        var hash: [UInt32] = [
            0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
            0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
        ]
        for start in stride(from: 0, to: data.count, by: 64) {
            var words = [UInt32](repeating: 0, count: 64)
            for index in 0..<16 {
                let offset = start + index * 4
                words[index] = UInt32(data[offset]) << 24 | UInt32(data[offset + 1]) << 16
                    | UInt32(data[offset + 2]) << 8 | UInt32(data[offset + 3])
            }
            for index in 16..<64 {
                let a = words[index - 15]
                let b = words[index - 2]
                let s0 = rotate(a, 7) ^ rotate(a, 18) ^ (a >> 3)
                let s1 = rotate(b, 17) ^ rotate(b, 19) ^ (b >> 10)
                words[index] = words[index - 16] &+ s0 &+ words[index - 7] &+ s1
            }
            var state = hash
            for index in 0..<64 {
                let s1 = rotate(state[4], 6) ^ rotate(state[4], 11) ^ rotate(state[4], 25)
                let choice = (state[4] & state[5]) ^ (~state[4] & state[6])
                let t1 = state[7] &+ s1 &+ choice &+ constants[index] &+ words[index]
                let s0 = rotate(state[0], 2) ^ rotate(state[0], 13) ^ rotate(state[0], 22)
                let majority = (state[0] & state[1]) ^ (state[0] & state[2]) ^ (state[1] & state[2])
                let t2 = s0 &+ majority
                state = [t1 &+ t2, state[0], state[1], state[2], state[3] &+ t1, state[4], state[5], state[6]]
            }
            for index in 0..<8 { hash[index] = hash[index] &+ state[index] }
        }
        return hash.map { String(format: "%08x", $0) }.joined()
    }
}
