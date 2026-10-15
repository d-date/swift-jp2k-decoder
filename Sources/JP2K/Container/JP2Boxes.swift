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
 * Copyright (c) 2010-2011, Kaori Hagihara
 * Copyright (c) 2008, 2011-2012, Centre National d'Etudes Spatiales (CNES), FR
 * Copyright (c) 2012, CS Systemes d'Information, France
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
// Ported from OpenJPEG v2.5.4: jp2.c: opj_jp2_read_boxhdr, opj_jp2_read_boxhdr_char, opj_jp2_read_header
struct JP2File {
    var header: JP2Header
    var codestream: Range<Int>
}

private struct Box {
    let type: UInt32
    let payload: ByteReader
    let range: Range<Int>
    let extendsToEnd: Bool
}

enum JP2Parser {
    private static let signature: UInt32 = 0x6A50_2020
    private static let fileType: UInt32 = 0x6674_7970
    private static let headerType: UInt32 = 0x6A70_3268
    private static let codestreamType: UInt32 = 0x6A70_3263
    private static let brand: UInt32 = 0x6A70_3220

    static func parse(_ bytes: [UInt8], context: inout DecodeContext) throws(JP2KError) -> JP2File {
        if bytes.count > context.limits.maxInputBytes { throw .limitExceeded(.inputBytes) }
        guard bytes.starts(with: [0, 0, 0, 12, 0x6A, 0x50, 0x20, 0x20, 0x0D, 0x0A, 0x87, 0x0A]) else {
            throw .invalidContainer(.badSignature)
        }
        var reader = ByteReader(bytes, range: 0..<bytes.count, truncationError: .invalidContainer(.badBoxLength))
        let first = try next(&reader)
        if first.type != signature || first.range.count != 4 { throw .invalidContainer(.badSignature) }
        if reader.remaining == 0 { throw .invalidContainer(.badFileType) }
        let second = try next(&reader)
        if second.type != fileType { throw .invalidContainer(.badFileType) }
        try validateFileType(second.payload)
        var header: JP2Header?
        var stream: Range<Int>?
        while reader.remaining > 0 {
            let box = try next(&reader)
            if box.extendsToEnd && box.type != codestreamType && stream == nil {
                throw .invalidContainer(.badBoxLength)
            }
            switch box.type {
            case signature, fileType:
                throw .invalidContainer(.duplicateBox)
            case headerType:
                if header != nil { throw .invalidContainer(.duplicateBox) }
                if stream != nil { throw .invalidContainer(.missingHeaderBox) }
                header = try JP2Header.parse(box.payload, context: &context)
            case codestreamType:
                if header == nil { throw .invalidContainer(.missingHeaderBox) }
                if stream != nil { throw .invalidContainer(.duplicateBox) }
                stream = box.range
            default: break
            }
        }
        guard let header else { throw .invalidContainer(.missingHeaderBox) }
        guard let stream else { throw .invalidContainer(.missingCodestream) }
        return JP2File(header: header, codestream: stream)
    }

    private static func validateFileType(_ payload: ByteReader) throws(JP2KError) {
        var reader = payload
        if reader.remaining < 8 || reader.remaining % 4 != 0 { throw .invalidContainer(.badFileType) }
        _ = try reader.u32()
        _ = try reader.u32()
        var found = false
        while reader.remaining > 0 {
            if try reader.u32() == brand { found = true }
        }
        if !found { throw .invalidContainer(.badFileType) }
    }

    static func nextBox(_ reader: inout ByteReader) throws(JP2KError) -> (UInt32, ByteReader, Range<Int>) {
        let box = try next(&reader)
        return (box.type, box.payload, box.range)
    }

    private static func next(_ reader: inout ByteReader) throws(JP2KError) -> Box {
        if reader.remaining < 8 { throw .invalidContainer(.badBoxLength) }
        let declared = try reader.u32()
        let type = try reader.u32()
        var headerSize = 8
        let length: Int
        if declared == 1 {
            if reader.remaining < 8 { throw .invalidContainer(.badBoxLength) }
            headerSize = 16
            let wide = try reader.u64()
            guard wide >= 16, let converted = Int(exactly: wide) else {
                throw .invalidContainer(.badBoxLength)
            }
            length = converted
        } else if declared == 0 {
            length = try Checked.add(headerSize, reader.remaining)
        } else {
            if declared < 8 { throw .invalidContainer(.badBoxLength) }
            length = try Checked.int(declared)
        }
        let bodySize = try Checked.sub(length, headerSize)
        if bodySize > reader.remaining { throw .invalidContainer(.badBoxLength) }
        let bodyStart = reader.offset
        let payload = try reader.subReader(length: bodySize)
        return Box(type: type, payload: payload, range: bodyStart..<reader.offset,
                   extendsToEnd: declared == 0)
    }
}
