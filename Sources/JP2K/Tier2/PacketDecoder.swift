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
 * Copyright (c) 2008, 2011-2012, Centre National d'Etudes Spatiales (CNES), FR
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
// Ported from OpenJPEG v2.5.4: t2.c: opj_t2_decode_packets, opj_t2_decode_packet, opj_t2_read_packet_header, opj_t2_read_packet_data, opj_t2_init_seg, opj_t2_getcommacode, opj_t2_getnumpasses
/// Reads packet headers and distributes packet body segments to code blocks.
enum PacketDecoder {
    static func commaCode(_ bits: inout PacketBitReader) throws(JP2KError) -> Int {
        var count = 0
        while try bits.read(bits: 1) == 1 {
            count = try Checked.add(count, 1)
            if count > 32 { throw .invalidCodestream(.badPacketHeader) }
        }
        return count
    }

    static func numberOfPasses(_ bits: inout PacketBitReader) throws(JP2KError) -> Int {
        if try bits.read(bits: 1) == 0 { return 1 }
        if try bits.read(bits: 1) == 0 { return 2 }
        let small = try bits.read(bits: 2)
        if small != 3 { return try Checked.add(3, small) }
        let medium = try bits.read(bits: 5)
        if medium != 31 { return try Checked.add(6, medium) }
        return try Checked.add(37, bits.read(bits: 7))
    }

    static func segmentLengthBitCount(_ numLenBits: Int, passes: Int) throws(JP2KError) -> Int {
        if numLenBits < 1 || passes < 1 { throw .invalidCodestream(.badPacketHeader) }
        let width = try Checked.add(numLenBits, Int.bitWidth - 1 - passes.leadingZeroBitCount)
        if width > 32 { throw .invalidCodestream(.badPacketHeader) }
        return width
    }

    static func decodeTile(_ tile: TileData, geometry: inout TileGeometry,
                           positions: [PacketPosition], context: inout DecodeContext) throws(JP2KError) {
        var bodyOffset = 0
        var headerOffset = 0
        let packed = tile.packedPacketHeaders
        for position in positions {
            if position.component < 0 || position.component >= geometry.components.count ||
                position.resolution < 0 || position.resolution >= geometry.components[position.component].resolutions.count {
                throw .invalidCodestream(.badPacketHeader)
            }
            let precinctsWide = geometry.components[position.component].resolutions[position.resolution].precinctsWide
            let precinctsHigh = geometry.components[position.component].resolutions[position.resolution].precinctsHigh
            let precinctCount = try Checked.mul(precinctsWide, precinctsHigh)
            if position.precinct < 0 || position.precinct >= precinctCount {
                throw .invalidCodestream(.badPacketHeader)
            }
            if tile.parameters.cod.usesSOP && bodyOffset <= tile.body.count - 6 &&
                tile.body[bodyOffset] == 0xFF && tile.body[bodyOffset + 1] == 0x91 {
                bodyOffset = try Checked.add(bodyOffset, 6)
            }
            let headerBytes = packed ?? tile.body
            let start = packed == nil ? bodyOffset : headerOffset
            if start < 0 || start >= headerBytes.count { throw .invalidCodestream(.badPacketHeader) }
            var bits = PacketBitReader(headerBytes, range: start..<headerBytes.count)
            let present = try bits.read(bits: 1) == 1
            let coding = tile.parameters.coc[position.component] ?? tile.parameters.cod.component
            if position.layer == 0 {
                for bandIndex in geometry.components[position.component].resolutions[position.resolution].bands.indices {
                    let transient = try precinctCopyBytes(
                        geometry.components[position.component].resolutions[position.resolution]
                            .bands[bandIndex].precincts[position.precinct])
                    try context.budget.reserve(bytes: transient)
                    var blocks: [CodeBlock] = []
                    swap(&blocks, &geometry.components[position.component].resolutions[position.resolution]
                        .bands[bandIndex].precincts[position.precinct].codeBlocks)
                    var precinct = geometry.components[position.component].resolutions[position.resolution]
                        .bands[bandIndex].precincts[position.precinct]
                    swap(&blocks, &precinct.codeBlocks)
                    precinct.inclusionTree.reset()
                    precinct.zeroBitPlaneTree.reset()
                    for blockIndex in precinct.codeBlocks.indices {
                        precinct.codeBlocks[blockIndex].segments.removeAll(keepingCapacity: true)
                        precinct.codeBlocks[blockIndex].included = false
                        precinct.codeBlocks[blockIndex].totalPasses = 0
                        precinct.codeBlocks[blockIndex].packetSegments.removeAll(keepingCapacity: true)
                    }
                    geometry.components[position.component].resolutions[position.resolution].bands[bandIndex].precincts[position.precinct] = precinct
                    context.budget.release(bytes: transient)
                }
            }
            if present {
                for bandIndex in geometry.components[position.component].resolutions[position.resolution].bands.indices {
                    let bandX0 = geometry.components[position.component].resolutions[position.resolution].bands[bandIndex].x0
                    let bandX1 = geometry.components[position.component].resolutions[position.resolution].bands[bandIndex].x1
                    let bandY0 = geometry.components[position.component].resolutions[position.resolution].bands[bandIndex].y0
                    let bandY1 = geometry.components[position.component].resolutions[position.resolution].bands[bandIndex].y1
                    if bandX0 >= bandX1 || bandY0 >= bandY1 { continue }
                    let treeBytes = try Checked.add(
                        geometry.components[position.component].resolutions[position.resolution]
                            .bands[bandIndex].precincts[position.precinct].inclusionTree.storageBytes(),
                        geometry.components[position.component].resolutions[position.resolution]
                            .bands[bandIndex].precincts[position.precinct].zeroBitPlaneTree.storageBytes())
                    try context.budget.reserve(bytes: treeBytes)
                    var blocks: [CodeBlock] = []
                    swap(&blocks, &geometry.components[position.component].resolutions[position.resolution]
                        .bands[bandIndex].precincts[position.precinct].codeBlocks)
                    var precinct = geometry.components[position.component].resolutions[position.resolution]
                        .bands[bandIndex].precincts[position.precinct]
                    swap(&blocks, &precinct.codeBlocks)
                    for blockIndex in precinct.codeBlocks.indices {
                        let included: Bool
                        if precinct.codeBlocks[blockIndex].segments.isEmpty {
                            included = try precinct.inclusionTree.decode(&bits, leaf: blockIndex,
                                                                          threshold: Checked.add(position.layer, 1))
                        } else { included = try bits.read(bits: 1) == 1 }
                        if !included { continue }
                        if precinct.codeBlocks[blockIndex].segments.isEmpty {
                            var zero = 0
                            while !((try precinct.zeroBitPlaneTree.decode(&bits, leaf: blockIndex, threshold: zero))) {
                                zero = try Checked.add(zero, 1)
                                if zero > 109 { throw .invalidCodestream(.badPacketHeader) }
                            }
                            precinct.codeBlocks[blockIndex].zeroBitPlanes = zero
                            precinct.codeBlocks[blockIndex].numLenBits = 3
                            precinct.codeBlocks[blockIndex].included = true
                        }
                        let passes = try numberOfPasses(&bits)
                        let newTotal = try Checked.add(precinct.codeBlocks[blockIndex].totalPasses, passes)
                        // ROI can make the zero-bitplane count exceed the band's nominal bitplanes.
                        // OpenJPEG accepts those packets; the fixed Part 1 pass ceiling still applies.
                        if newTotal > 109 { throw .invalidCodestream(.badPacketHeader) }
                        try context.countCodingPasses(passes)
                        let increment = try commaCode(&bits)
                        precinct.codeBlocks[blockIndex].numLenBits = try Checked.add(precinct.codeBlocks[blockIndex].numLenBits, increment)
                        if precinct.codeBlocks[blockIndex].numLenBits > 32 { throw .invalidCodestream(.badPacketHeader) }
                        var remaining = passes
                        while remaining > 0 {
                            let index: Int
                            if let last = precinct.codeBlocks[blockIndex].segments.indices.last,
                               precinct.codeBlocks[blockIndex].segments[last].passes + precinct.codeBlocks[blockIndex].segments[last].pendingPasses < precinct.codeBlocks[blockIndex].segments[last].maxPasses {
                                index = last
                            } else {
                                index = precinct.codeBlocks[blockIndex].segments.count
                                if index >= 109 { throw .invalidCodestream(.badPacketHeader) }
                                try context.budget.append(CodeBlockSegment(maxPasses: maxPasses(style: coding.codeBlockStyle,
                                                                                          previous: precinct.codeBlocks[blockIndex].segments.last?.maxPasses)),
                                                          to: &precinct.codeBlocks[blockIndex].segments)
                            }
                            let available = try Checked.sub(precinct.codeBlocks[blockIndex].segments[index].maxPasses,
                                                            Checked.add(precinct.codeBlocks[blockIndex].segments[index].passes, precinct.codeBlocks[blockIndex].segments[index].pendingPasses))
                            if available < 1 { throw .invalidCodestream(.badPacketHeader) }
                            let segmentPasses = min(remaining, available)
                            let width = try segmentLengthBitCount(precinct.codeBlocks[blockIndex].numLenBits, passes: segmentPasses)
                            precinct.codeBlocks[blockIndex].segments[index].pendingPasses = segmentPasses
                            precinct.codeBlocks[blockIndex].segments[index].pendingLength = try bits.read(bits: width)
                            remaining = try Checked.sub(remaining, segmentPasses)
                        }
                    }
                    geometry.components[position.component].resolutions[position.resolution].bands[bandIndex].precincts[position.precinct] = precinct
                    context.budget.release(bytes: treeBytes)
                }
            }
            let consumed = try bits.alignAndFinish()
            let endHeader = try Checked.add(start, consumed)
            if endHeader > headerBytes.count { throw .invalidCodestream(.badPacketHeader) }
            var afterHeader = endHeader
            if tile.parameters.cod.usesEPH && afterHeader <= headerBytes.count - 2 &&
                headerBytes[afterHeader] == 0xFF && headerBytes[afterHeader + 1] == 0x92 {
                afterHeader = try Checked.add(afterHeader, 2)
            }
            if packed == nil { bodyOffset = afterHeader } else { headerOffset = afterHeader }
            if !present { continue }
            for bandIndex in geometry.components[position.component].resolutions[position.resolution].bands.indices {
                let bandX0 = geometry.components[position.component].resolutions[position.resolution].bands[bandIndex].x0
                let bandX1 = geometry.components[position.component].resolutions[position.resolution].bands[bandIndex].x1
                let bandY0 = geometry.components[position.component].resolutions[position.resolution].bands[bandIndex].y0
                let bandY1 = geometry.components[position.component].resolutions[position.resolution].bands[bandIndex].y1
                if bandX0 >= bandX1 || bandY0 >= bandY1 { continue }
                var blocks: [CodeBlock] = []
                swap(&blocks, &geometry.components[position.component].resolutions[position.resolution]
                    .bands[bandIndex].precincts[position.precinct].codeBlocks)
                var precinct = geometry.components[position.component].resolutions[position.resolution]
                    .bands[bandIndex].precincts[position.precinct]
                swap(&blocks, &precinct.codeBlocks)
                for blockIndex in precinct.codeBlocks.indices {
                    for segmentIndex in precinct.codeBlocks[blockIndex].segments.indices where precinct.codeBlocks[blockIndex].segments[segmentIndex].pendingPasses > 0 {
                        let length = precinct.codeBlocks[blockIndex].segments[segmentIndex].pendingLength
                        if length < 0 || bodyOffset > tile.body.count || length > tile.body.count - bodyOffset {
                            throw .invalidCodestream(.badPacketHeader)
                        }
                        let dataEnd = try Checked.add(bodyOffset, length)
                        try context.budget.append(contentsOf: tile.body[bodyOffset..<dataEnd],
                                                  to: &precinct.codeBlocks[blockIndex].data)
                        bodyOffset = try Checked.add(bodyOffset, length)
                        try context.budget.append(CodeBlockPacketSegment(layer: position.layer,
                                                                           passes: precinct.codeBlocks[blockIndex].segments[segmentIndex].pendingPasses,
                                                                           length: length),
                                                  to: &precinct.codeBlocks[blockIndex].packetSegments)
                        precinct.codeBlocks[blockIndex].segments[segmentIndex].length = try Checked.add(precinct.codeBlocks[blockIndex].segments[segmentIndex].length, length)
                        precinct.codeBlocks[blockIndex].segments[segmentIndex].dataLength = try Checked.add(precinct.codeBlocks[blockIndex].segments[segmentIndex].dataLength, length)
                        precinct.codeBlocks[blockIndex].totalPasses = try Checked.add(precinct.codeBlocks[blockIndex].totalPasses, precinct.codeBlocks[blockIndex].segments[segmentIndex].pendingPasses)
                        precinct.codeBlocks[blockIndex].segments[segmentIndex].passes = try Checked.add(precinct.codeBlocks[blockIndex].segments[segmentIndex].passes,
                                                                              precinct.codeBlocks[blockIndex].segments[segmentIndex].pendingPasses)
                        precinct.codeBlocks[blockIndex].segments[segmentIndex].pendingPasses = 0
                        precinct.codeBlocks[blockIndex].segments[segmentIndex].pendingLength = 0
                    }
                }
                geometry.components[position.component].resolutions[position.resolution].bands[bandIndex].precincts[position.precinct] = precinct
            }
        }
        if bodyOffset != tile.body.count { throw .invalidCodestream(.badPacketHeader) }
        if let packed, headerOffset != packed.count { throw .invalidCodestream(.badPacketHeader) }
    }

    private static func precinctCopyBytes(_ precinct: Precinct) throws(JP2KError) -> Int {
        let blocks = try Checked.mul(precinct.codeBlocks.count, MemoryLayout<CodeBlock>.stride)
        let inclusion = try precinct.inclusionTree.storageBytes()
        let zero = try precinct.zeroBitPlaneTree.storageBytes()
        return try Checked.add(blocks, Checked.add(inclusion, zero))
    }

    private static func maxPasses(style: UInt8, previous: Int?) -> Int {
        if style & 0x04 != 0 { return 1 }
        if style & 0x01 != 0 {
            guard let previous else { return 10 }
            return previous == 1 || previous == 10 ? 2 : 1
        }
        return 109
    }
}
