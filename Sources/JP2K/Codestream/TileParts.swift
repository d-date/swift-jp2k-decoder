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
 * Copyright (c) 2008, Jerome Fimes, Communications & Systemes <jerome.fimes@c-s.fr>
 * Copyright (c) 2006-2007, Parvatha Elangovan
 * Copyright (c) 2010-2011, Kaori Hagihara
 * Copyright (c) 2011-2012, Centre National d'Etudes Spatiales (CNES), France
 * Copyright (c) 2012, CS Systemes d'Information, France
 * Copyright (c) 2017, IntoPIX SA <support@intopix.com>
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
// Ported from OpenJPEG v2.5.4: j2k.c: opj_j2k_get_sot_values, opj_j2k_read_sot, opj_j2k_read_sod, opj_j2k_read_ppm, opj_j2k_merge_ppm, opj_j2k_read_ppt, opj_j2k_merge_ppt, opj_j2k_read_plt
struct TileCodingParameters {
    var cod: CodingStyle
    var coc: [Int: ComponentCodingStyle]
    var qcd: QuantizationStyle
    var qcc: [Int: QuantizationStyle]
    var rgn: [Int: Int]
    var poc: [ProgressionChange]
}

struct TileData {
    var index: Int
    var parameters: TileCodingParameters
    var body: [UInt8]
    var packedPacketHeaders: [UInt8]?
    var tilePartCount: Int
}

private struct TileState {
    var data: TileData
    var expectedParts: Int
    var ppt: [Int: [UInt8]] = [:]
}

enum TilePartParser {
    static func parse(_ bytes: [UInt8], header: MainHeader,
                      context: inout DecodeContext) throws(JP2KError) -> [TileData] {
        let tileCount = try Checked.mul(header.geometry.tilesAcross, header.geometry.tilesDown)
        if tileCount > context.limits.maxTiles { throw .limitExceeded(.tiles) }
        try context.budget.reserve(bytes: try Checked.mul(tileCount, MemoryLayout<TileState?>.stride))
        var states = [TileState?](repeating: nil, count: tileCount)
        var reader = ByteReader(bytes, range: header.firstTilePartOffset..<bytes.count,
                                truncationError: .invalidCodestream(.truncated))
        var partCount = 0
        let ppmChunks = try mergePPM(header.ppm, context: &context)
        var ppmPosition = 0
        while reader.remaining > 0 {
            if reader.remaining < 2 { throw .invalidCodestream(.badTilePart) }
            let start = reader.offset
            let marker = try reader.u16()
            if marker == Marker.eoc {
                if reader.remaining != 0 { throw .invalidCodestream(.badTilePart) }
                break
            }
            if marker != Marker.sot { throw .invalidCodestream(.badMarker) }
            if reader.remaining < 10 { throw .invalidCodestream(.badSOT) }
            if try reader.u16() != 10 { throw .invalidCodestream(.badSOT) }
            let index = try Checked.int(reader.u16())
            let psot = try Checked.int(reader.u32())
            let ordinal = try Checked.int(reader.u8())
            let declared = try Checked.int(reader.u8())
            if index >= tileCount || (psot != 0 && psot < 14) { throw .invalidCodestream(.badSOT) }
            if partCount >= context.limits.maxTileParts { throw .limitExceeded(.tileParts) }
            partCount = try Checked.add(partCount, 1)
            if states[index] == nil {
                if ordinal != 0 { throw .invalidCodestream(.badTilePart) }
                let parameters = TileCodingParameters(cod: header.cod, coc: header.coc, qcd: header.qcd,
                                                      qcc: header.qcc, rgn: header.rgn, poc: header.poc)
                let data = TileData(index: index, parameters: parameters, body: [],
                                    packedPacketHeaders: nil, tilePartCount: 0)
                states[index] = TileState(data: data, expectedParts: declared)
            }
            guard var state = states[index] else { throw .invalidCodestream(.badTilePart) }
            states[index] = nil
            if ordinal != state.data.tilePartCount || (declared != 0 && state.expectedParts != 0 && declared != state.expectedParts) ||
                (declared != 0 && ordinal >= declared) || (state.expectedParts != 0 && ordinal >= state.expectedParts) {
                throw .invalidCodestream(.badTilePart)
            }
            if declared != 0 { state.expectedParts = declared }
            let end: Int
            if psot == 0 {
                end = bytes.count >= 2 && bytes.suffix(2).elementsEqual([0xFF, 0xD9]) ? bytes.count - 2 : bytes.count
            } else {
                end = try Checked.add(start, psot)
                if end > bytes.count { throw .invalidCodestream(.badSOT) }
            }
            if end < reader.offset || end - reader.offset < 2 { throw .invalidCodestream(.badSOT) }
            while reader.offset < end {
                let code = try reader.u16()
                if Marker.isReservedDelimiter(code) { continue }
                if code == Marker.sod { break }
                if code == Marker.ppm { throw .invalidCodestream(.unexpectedMarker) }
                if code == 0xFF50 { throw .unsupported(.htj2k) }
                if Marker.isPart2(code) { throw .unsupported(.part2) }
                let allowed: [UInt16] = [Marker.cod, Marker.coc, Marker.qcd, Marker.qcc, Marker.rgn,
                                         Marker.poc, 0xFF61, 0xFF58, Marker.com]
                if !allowed.contains(code) { throw .invalidCodestream(.badMarker) }
                if ordinal != 0 && [Marker.cod, Marker.coc, Marker.qcd, Marker.qcc, Marker.rgn].contains(code) {
                    throw .invalidCodestream(.unexpectedMarker)
                }
                if end - reader.offset < 2 { throw .invalidCodestream(.badMarkerLength) }
                let length = try Checked.int(reader.u16())
                if length < 2 || length - 2 > end - reader.offset { throw .invalidCodestream(.badMarkerLength) }
                try context.countMarkerData(length - 2)
                let payload = try reader.subReader(length: length - 2)
                try apply(code, payload: payload, state: &state, header: header, context: &context)
            }
            if reader.offset > end || reader.offset < 2 || bytes[reader.offset - 2] != 0xFF || bytes[reader.offset - 1] != 0x93 {
                throw .invalidCodestream(.badTilePart)
            }
            var bodyEnd = end
            if psot == 0 {
                var position = reader.offset
                let lastByte = try Checked.sub(bytes.count, 1)
                while position < lastByte {
                    let next = try Checked.add(position, 1)
                    // SOP is FF91 Lsop(=4) Nsop; Nsop is a free 16-bit counter
                    // that may itself look like a marker, so step over it.
                    if bytes[position] == 0xFF && bytes[next] == 0x91 {
                        let sopEnd = try Checked.add(position, 6)
                        if sopEnd > bytes.count { throw .invalidCodestream(.badTilePart) }
                        position = sopEnd
                        continue
                    }
                    // Packet data never contains 0xFF followed by a byte above
                    // 0x8F except the in-stream SOP (FF91) and EPH (FF92)
                    // markers; anything else (another SOT, an early EOC) means
                    // this was not the last tile-part.
                    if bytes[position] == 0xFF && bytes[next] > 0x8F &&
                        bytes[next] != 0x91 && bytes[next] != 0x92 {
                        if bytes[next] != 0xD9 || next != lastByte {
                            throw .invalidCodestream(.badTilePart)
                        }
                        bodyEnd = position
                        break
                    }
                    position = next
                }
            }
            let bodyLength = try Checked.sub(bodyEnd, reader.offset)
            try context.budget.append(contentsOf: reader.bytes(count: bodyLength), to: &state.data.body)
            state.data.tilePartCount = try Checked.add(state.data.tilePartCount, 1)
            if !header.ppm.isEmpty {
                if ppmPosition >= ppmChunks.count { throw .invalidCodestream(.badPPM) }
                let chunk = ppmChunks[ppmPosition]
                ppmPosition = try Checked.add(ppmPosition, 1)
                var headers = state.data.packedPacketHeaders ?? []
                state.data.packedPacketHeaders = nil
                try context.budget.append(contentsOf: chunk, to: &headers)
                state.data.packedPacketHeaders = headers
            }
            states[index] = state
            if psot == 0 {
                if reader.remaining == 2 { try reader.skip(2) }
                if reader.remaining != 0 { throw .invalidCodestream(.badTilePart) }
                break
            }
        }
        if !header.ppm.isEmpty && ppmPosition != ppmChunks.count { throw .invalidCodestream(.badPPM) }
        var result: [TileData] = []
        try context.budget.reserve(bytes: try Checked.mul(tileCount, MemoryLayout<TileData>.stride))
        result.reserveCapacity(tileCount)
        for stateValue in states {
            guard var state = stateValue else { throw .invalidCodestream(.badTilePart) }
            if state.expectedParts != 0 && state.data.tilePartCount != state.expectedParts {
                throw .invalidCodestream(.badTilePart)
            }
            if !state.ppt.isEmpty {
                let parts = state.ppt.keys.sorted().compactMap { state.ppt[$0] }
                var count = 0
                for part in parts { count = try Checked.add(count, part.count) }
                try context.budget.reserve(bytes: count)
                var packed: [UInt8] = []
                packed.reserveCapacity(count)
                for part in parts { packed.append(contentsOf: part) }
                state.data.packedPacketHeaders = packed
            }
            result.append(state.data)
        }
        return result
    }

    private static func apply(_ code: UInt16, payload: ByteReader, state: inout TileState,
                              header: MainHeader, context: inout DecodeContext) throws(JP2KError) {
        switch code {
        case Marker.cod: state.data.parameters.cod = try CodingStyle.parse(payload, context: &context)
        case Marker.coc:
            let (index, value) = try CodingStyle.parseCOC(payload, count: header.geometry.components.count, context: &context)
            try reserveEntry(index, in: &state.data.parameters.coc, context: &context)
            state.data.parameters.coc[index] = value
        case Marker.qcd: state.data.parameters.qcd = try QuantizationStyle.parse(payload, context: &context)
        case Marker.qcc:
            let (index, value) = try QuantizationStyle.parseQCC(payload, count: header.geometry.components.count, context: &context)
            try reserveEntry(index, in: &state.data.parameters.qcc, context: &context)
            state.data.parameters.qcc[index] = value
        case Marker.rgn:
            let (index, value) = try ROI.parse(payload, count: header.geometry.components.count)
            try reserveEntry(index, in: &state.data.parameters.rgn, context: &context)
            state.data.parameters.rgn[index] = value
        case Marker.poc:
            let changes = try Progression.parse(payload, count: header.geometry.components.count,
                                                layers: state.data.parameters.cod.layers, context: &context)
            let count = try Checked.add(state.data.parameters.poc.count, changes.count)
            if count >= 32 { throw .invalidCodestream(.badPOC) }
            state.data.parameters.poc.append(contentsOf: changes)
        case 0xFF61:
            var reader = payload
            if reader.remaining < 2 || !header.ppm.isEmpty { throw .invalidCodestream(.badPPT) }
            let sequence = try Checked.int(reader.u8())
            if state.ppt[sequence] != nil { throw .invalidCodestream(.badPPT) }
            let size = reader.remaining
            try context.budget.reserve(bytes: try Checked.add(size, MemoryLayout<(Int, [UInt8])>.stride))
            state.ppt[sequence] = Array(try reader.bytes(count: size))
        case 0xFF58:
            if payload.remaining < 1 { throw .invalidCodestream(.badMarkerLength) }
        case Marker.com:
            if payload.remaining < 2 { throw .invalidCodestream(.badMarkerLength) }
        default: break
        }
    }

    private static func reserveEntry<Value>(_ key: Int, in dictionary: inout [Int: Value],
                                            context: inout DecodeContext) throws(JP2KError) {
        if dictionary[key] == nil { try context.budget.reserve(bytes: MemoryLayout<(Int, Value)>.stride) }
    }

    private static func mergePPM(_ parts: [[UInt8]], context: inout DecodeContext) throws(JP2KError) -> [[UInt8]] {
        if parts.isEmpty { return [] }
        var total = 0
        for part in parts { total = try Checked.add(total, part.count) }
        try context.budget.reserve(bytes: total)
        var joined: [UInt8] = []
        joined.reserveCapacity(total)
        for part in parts { joined.append(contentsOf: part) }
        var reader = ByteReader(joined, range: 0..<joined.count, truncationError: .invalidCodestream(.badPPM))
        var chunks: [[UInt8]] = []
        while reader.remaining > 0 {
            if reader.remaining < 4 { throw .invalidCodestream(.badPPM) }
            let length = try Checked.int(reader.u32())
            if length > reader.remaining { throw .invalidCodestream(.badPPM) }
            try context.budget.reserve(bytes: try Checked.add(length, MemoryLayout<[UInt8]>.stride))
            chunks.append(Array(try reader.bytes(count: length)))
        }
        return chunks
    }
}
