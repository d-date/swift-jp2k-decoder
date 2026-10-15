/*
 * The copyright in this software is being made available under the 2-clauses
 * BSD License, included below. This software may be subject to other third
 * party and contributor rights, including patent rights, and no such rights
 * are granted under this license.
 *
 * Copyright (c) 2002-2014, Universite catholique de Louvain (UCL), Belgium
 * Copyright (c) 2002-2014, Professor Benoit Macq
 * Copyright (c) 2001-2003, David Janssens
 * Copyright (c) 2002-2003, Yannick Verschueren
 * Copyright (c) 2003-2007, Francois-Olivier Devaux
 * Copyright (c) 2003-2014, Antonin Descampe
 * Copyright (c) 2005, Herve Drolon, FreeImage Team
 * All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions
 * are met:
 * 1. Redistributions of source code must retain the above copyright
 *    notice, this list of conditions and the following disclaimer.
 * 2. Redistributions in binary form must reproduce the above copyright
 *    notice, this list of conditions and the following disclaimer in the
 *    documentation and/or other materials provided with the distribution.
 *
 * THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS `AS IS'
 * AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
 * IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
 * ARE DISCLAIMED.  IN NO EVENT SHALL THE COPYRIGHT OWNER OR CONTRIBUTORS BE
 * LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
 * CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
 * SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
 * INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
 * CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
 * ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
 * POSSIBILITY OF SUCH DAMAGE.
 */
// Ported from OpenJPEG v2.5.4: bio.c: opj_bio_init_dec, opj_bio_bytein, opj_bio_getbit, opj_bio_read, opj_bio_inalign
/// Reads a bounded packet header with JPEG 2000 byte stuffing.
struct PacketBitReader {
    let bytes: [UInt8]
    let range: Range<Int>
    private(set) var offset: Int
    private var bit = 8
    private var previousWasFF = false

    init(_ bytes: [UInt8], range: Range<Int>) {
        self.bytes = bytes
        self.range = range
        offset = range.lowerBound
    }

    init(_ bytes: [UInt8]) {
        self.init(bytes, range: 0..<bytes.count)
    }

    mutating func readBit() throws(JP2KError) -> Int {
        if offset < 0 || offset >= range.upperBound || offset >= bytes.count || range.lowerBound < 0 {
            throw .invalidCodestream(.badPacketHeader)
        }
        if bit == 8 { bit = previousWasFF ? 6 : 7 }
        let value = Int((bytes[offset] >> bit) & 1)
        if bit == 0 {
            previousWasFF = bytes[offset] == 0xFF
            offset = try Checked.add(offset, 1)
            bit = 8
        } else { bit -= 1 }
        return value
    }

    mutating func read(bits count: Int) throws(JP2KError) -> Int {
        if count < 1 || count > 32 { throw .invalidCodestream(.badPacketHeader) }
        var result = 0
        for _ in 0..<count { result = (result << 1) | (try readBit()) }
        return result
    }

    mutating func alignAndFinish() throws(JP2KError) -> Int {
        if bit != 8 {
            if offset < 0 || offset >= range.upperBound || offset >= bytes.count {
                throw .invalidCodestream(.badPacketHeader)
            }
            previousWasFF = bytes[offset] == 0xFF
            offset = try Checked.add(offset, 1)
            bit = 8
        }
        // bio_inalign consumes the stuffed byte after a terminal 0xFF.
        if previousWasFF {
            if offset < 0 || offset >= range.upperBound || offset >= bytes.count {
                throw .invalidCodestream(.badPacketHeader)
            }
            offset = try Checked.add(offset, 1)
            previousWasFF = false
        }
        return try Checked.sub(offset, range.lowerBound)
    }
}
