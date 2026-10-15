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
// Ported from OpenJPEG v2.5.4: j2k.c: opj_j2k_read_header_procedure, opj_j2k_read_ppm, opj_j2k_read_tlm, opj_j2k_read_plm, opj_j2k_read_crg, opj_j2k_read_com
struct MainHeader: Sendable {
    var geometry: ImageGeometry
    var cod: CodingStyle
    var coc: [Int: ComponentCodingStyle]
    var qcd: QuantizationStyle
    var qcc: [Int: QuantizationStyle]
    var rgn: [Int: Int]
    var poc: [ProgressionChange]
    var ppm: [[UInt8]]
    var firstTilePartOffset: Int
}

enum MainHeaderParser {
    static func parse(_ bytes: [UInt8], range: Range<Int>, context: inout DecodeContext) throws(JP2KError) -> MainHeader {
        var reader = ByteReader(bytes, range: range, truncationError: .invalidCodestream(.truncated))
        if try reader.u16() != Marker.soc { throw .invalidCodestream(.missingSOC) }
        var geometry: ImageGeometry?
        var cod: CodingStyle?
        var qcd: QuantizationStyle?
        var coc: [Int: ComponentCodingStyle] = [:]
        var qcc: [Int: QuantizationStyle] = [:]
        var rgn: [Int: Int] = [:]
        var poc: [ProgressionChange] = []
        var ppmParts: [Int: [UInt8]] = [:]
        while reader.remaining >= 2 {
            let markerOffset = reader.offset
            let marker = try reader.u16()
            if Marker.isReservedDelimiter(marker) { continue }
            if marker == Marker.sot {
                guard let geometry, let cod, let qcd else { throw .invalidCodestream(.unexpectedMarker) }
                try geometry.reservePlaneEstimate(context: &context)
                // Zppm orders the parts; they may arrive in any order (as in
                // conformance file g3), matching OpenJPEG's indexed merge.
                let ppm = ppmParts.keys.sorted().compactMap { ppmParts[$0] }
                return MainHeader(geometry: geometry, cod: cod, coc: coc, qcd: qcd, qcc: qcc,
                                  rgn: rgn, poc: poc, ppm: ppm, firstTilePartOffset: markerOffset)
            }
            if geometry == nil && marker != Marker.siz { throw .invalidCodestream(.missingSIZ) }
            if marker == 0xFF50 { throw .unsupported(.htj2k) }
            if Marker.isPart2(marker) { throw .unsupported(.part2) }
            let known = [Marker.siz, Marker.cod, Marker.coc, Marker.qcd, Marker.qcc, Marker.rgn,
                         Marker.poc, Marker.ppm, Marker.tlm, Marker.plm, Marker.crg, Marker.com]
            if !known.contains(marker) { throw .invalidCodestream(.badMarker) }
            if reader.remaining < 2 { throw .invalidCodestream(.badMarkerLength) }
            let length = try Checked.int(reader.u16())
            if length < 2 || length - 2 > reader.remaining { throw .invalidCodestream(.badMarkerLength) }
            try context.countMarkerData(length - 2)
            let segment = try reader.subReader(length: length - 2)
            switch marker {
            case Marker.siz:
                if geometry != nil { throw .invalidCodestream(.unexpectedMarker) }
                geometry = try ImageGeometry.parse(segment, context: &context)
            case Marker.cod: cod = try CodingStyle.parse(segment, context: &context)
            case Marker.coc:
                guard let geometry else { throw .invalidCodestream(.missingSIZ) }
                let (index, style) = try CodingStyle.parseCOC(segment, count: geometry.components.count, context: &context)
                try reserveEntry(index, in: &coc, context: &context)
                coc[index] = style
            case Marker.qcd: qcd = try QuantizationStyle.parse(segment, context: &context)
            case Marker.qcc:
                guard let geometry else { throw .invalidCodestream(.missingSIZ) }
                let (index, style) = try QuantizationStyle.parseQCC(segment, count: geometry.components.count, context: &context)
                try reserveEntry(index, in: &qcc, context: &context)
                qcc[index] = style
            case Marker.rgn:
                guard let geometry else { throw .invalidCodestream(.missingSIZ) }
                let (index, shift) = try ROI.parse(segment, count: geometry.components.count)
                try reserveEntry(index, in: &rgn, context: &context)
                rgn[index] = shift
            case Marker.poc:
                guard let geometry, let cod else { throw .invalidCodestream(.unexpectedMarker) }
                let changes = try Progression.parse(segment, count: geometry.components.count,
                                                    layers: cod.layers, context: &context)
                let newCount = try Checked.add(poc.count, changes.count)
                // Like opj_j2k_read_poc, the 32-record cap applies to the total
                // across all POC markers, not to each marker separately.
                if newCount >= 32 { throw .invalidCodestream(.badPOC) }
                let bytes = try Checked.mul(changes.count, MemoryLayout<ProgressionChange>.stride)
                try context.budget.reserve(bytes: bytes)
                poc.reserveCapacity(newCount)
                poc.append(contentsOf: changes)
                context.budget.release(bytes: bytes)
            case Marker.ppm:
                var body = segment
                if body.remaining < 2 { throw .invalidCodestream(.badPPM) }
                let index = try Checked.int(body.u8())
                if ppmParts[index] != nil { throw .invalidCodestream(.badPPM) }
                let dataSize = body.remaining
                // Entry bytes include the key and the dictionary slot overhead.
                let entryBytes = MemoryLayout<Int>.stride + 2 * MemoryLayout<[UInt8]>.stride
                try context.budget.reserve(bytes: try Checked.add(dataSize, entryBytes))
                ppmParts.reserveCapacity(try Checked.add(ppmParts.count, 1))
                ppmParts[index] = Array(try body.bytes(count: dataSize))
            case Marker.tlm:
                if segment.remaining < 2 { throw .invalidCodestream(.badMarkerLength) }
            case Marker.plm:
                if segment.remaining < 1 { throw .invalidCodestream(.badMarkerLength) }
            case Marker.crg:
                guard let geometry else { throw .invalidCodestream(.missingSIZ) }
                if segment.remaining != (try Checked.mul(geometry.components.count, 4)) { throw .invalidCodestream(.badMarkerLength) }
            case Marker.com:
                if segment.remaining < 2 { throw .invalidCodestream(.badMarkerLength) }
            default: break
            }
        }
        throw .invalidCodestream(geometry == nil ? .missingSIZ : .truncated)
    }

    private static func reserveEntry<Value>(_ key: Int, in dictionary: inout [Int: Value],
                                            context: inout DecodeContext) throws(JP2KError) {
        if dictionary[key] == nil {
            try context.budget.reserve(bytes: MemoryLayout<(Int, Value)>.stride)
            dictionary.reserveCapacity(try Checked.add(dictionary.count, 1))
        }
    }
}
