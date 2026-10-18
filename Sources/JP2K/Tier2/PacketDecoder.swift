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
            try validate(position, in: geometry)
            let (c, r, p) = (position.component, position.resolution, position.precinct)
            if tile.parameters.cod.usesSOP && bodyOffset <= tile.body.count - 6 &&
                tile.body[bodyOffset] == 0xFF && tile.body[bodyOffset + 1] == 0x91 {
                bodyOffset = try Checked.add(bodyOffset, 6)
            }
            let headerBytes = packed ?? tile.body
            let start = packed == nil ? bodyOffset : headerOffset
            if start < 0 || start >= headerBytes.count { throw .invalidCodestream(.badPacketHeader) }
            var bits = PacketBitReader(headerBytes, range: start..<headerBytes.count)
            let present = try bits.read(bits: 1) == 1
            let style = (tile.parameters.coc[c] ?? tile.parameters.cod.component).codeBlockStyle
            // Precincts are mutated in place through the geometry so no
            // code-block or tag-tree storage is ever copied.
            let bands = geometry.components[c].resolutions[r].bands.indices
            if position.layer == 0 {
                for band in bands { reset(&geometry.components[c].resolutions[r].bands[band].precincts[p]) }
            }
            if present {
                for band in bands where geometry.components[c].resolutions[r].bands[band].hasArea {
                    try readHeader(&geometry.components[c].resolutions[r].bands[band].precincts[p],
                                   layer: position.layer, codeBlockStyle: style, bits: &bits, context: &context)
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
            for band in bands where geometry.components[c].resolutions[r].bands[band].hasArea {
                for block in geometry.components[c].resolutions[r].bands[band].precincts[p].codeBlocks.indices {
                    try readBody(&geometry.components[c].resolutions[r].bands[band].precincts[p].codeBlocks[block],
                                 layer: position.layer, body: tile.body, offset: &bodyOffset,
                                 budget: &context.budget)
                }
            }
        }
        if bodyOffset != tile.body.count { throw .invalidCodestream(.badPacketHeader) }
        if let packed, headerOffset != packed.count { throw .invalidCodestream(.badPacketHeader) }
    }

    private static func validate(_ position: PacketPosition, in geometry: borrowing TileGeometry) throws(JP2KError) {
        guard geometry.components.indices.contains(position.component),
              geometry.components[position.component].resolutions.indices.contains(position.resolution) else {
            throw .invalidCodestream(.badPacketHeader)
        }
        let precinctCount = try Checked.mul(
            geometry.components[position.component].resolutions[position.resolution].precinctsWide,
            geometry.components[position.component].resolutions[position.resolution].precinctsHigh)
        if position.precinct < 0 || position.precinct >= precinctCount {
            throw .invalidCodestream(.badPacketHeader)
        }
    }

    /// Clears what earlier tiles' packets left behind before layer 0.
    private static func reset(_ precinct: inout Precinct) {
        precinct.inclusionTree.reset()
        precinct.zeroBitPlaneTree.reset()
        for index in precinct.codeBlocks.indices {
            precinct.codeBlocks[index].segments.removeAll(keepingCapacity: true)
            precinct.codeBlocks[index].included = false
            precinct.codeBlocks[index].totalPasses = 0
            precinct.codeBlocks[index].packetSegments.removeAll(keepingCapacity: true)
        }
    }

    /// Reads one band's share of a packet header: inclusion, zero bitplanes,
    /// pass counts and segment lengths for every code-block of the precinct.
    private static func readHeader(_ precinct: inout Precinct, layer: Int, codeBlockStyle: UInt8,
                                   bits: inout PacketBitReader, context: inout DecodeContext) throws(JP2KError) {
        for index in precinct.codeBlocks.indices {
            let firstInclusion = precinct.codeBlocks[index].segments.isEmpty
            let included: Bool
            if firstInclusion {
                included = try precinct.inclusionTree.decode(&bits, leaf: index, threshold: Checked.add(layer, 1))
            } else {
                included = try bits.read(bits: 1) == 1
            }
            if !included { continue }
            if firstInclusion {
                var zero = 0
                while !(try precinct.zeroBitPlaneTree.decode(&bits, leaf: index, threshold: zero)) {
                    zero = try Checked.add(zero, 1)
                    if zero > 109 { throw .invalidCodestream(.badPacketHeader) }
                }
                precinct.codeBlocks[index].zeroBitPlanes = zero
                precinct.codeBlocks[index].numLenBits = 3
                precinct.codeBlocks[index].included = true
            }
            try readPasses(&precinct.codeBlocks[index], codeBlockStyle: codeBlockStyle,
                           bits: &bits, context: &context)
        }
    }

    /// Reads the new pass count and the length of each segment those passes
    /// fall into, opening segments as the code-block style requires.
    private static func readPasses(_ block: inout CodeBlock, codeBlockStyle: UInt8,
                                   bits: inout PacketBitReader, context: inout DecodeContext) throws(JP2KError) {
        let passes = try numberOfPasses(&bits)
        let newTotal = try Checked.add(block.totalPasses, passes)
        // ROI can make the zero-bitplane count exceed the band's nominal bitplanes.
        // OpenJPEG accepts those packets; the fixed Part 1 pass ceiling still applies.
        if newTotal > 109 { throw .invalidCodestream(.badPacketHeader) }
        try context.countCodingPasses(passes)
        let increment = try commaCode(&bits)
        block.numLenBits = try Checked.add(block.numLenBits, increment)
        if block.numLenBits > 32 { throw .invalidCodestream(.badPacketHeader) }
        var remaining = passes
        while remaining > 0 {
            let index: Int
            if let last = block.segments.indices.last,
               block.segments[last].passes + block.segments[last].pendingPasses < block.segments[last].maxPasses {
                index = last
            } else {
                index = block.segments.count
                if index >= 109 { throw .invalidCodestream(.badPacketHeader) }
                let segment = CodeBlockSegment(maxPasses: maxPasses(style: codeBlockStyle,
                                                                    previous: block.segments.last?.maxPasses))
                try context.budget.append(segment, to: &block.segments)
            }
            let segment = block.segments[index]
            let available = try Checked.sub(segment.maxPasses, Checked.add(segment.passes, segment.pendingPasses))
            if available < 1 { throw .invalidCodestream(.badPacketHeader) }
            let segmentPasses = min(remaining, available)
            let width = try segmentLengthBitCount(block.numLenBits, passes: segmentPasses)
            block.segments[index].pendingPasses = segmentPasses
            block.segments[index].pendingLength = try bits.read(bits: width)
            remaining = try Checked.sub(remaining, segmentPasses)
        }
    }

    /// Moves the bytes announced by the packet header from the body into
    /// the code-block and commits the pending passes.
    private static func readBody(_ block: inout CodeBlock, layer: Int, body: [UInt8], offset: inout Int,
                                 budget: inout MemoryBudget) throws(JP2KError) {
        for index in block.segments.indices where block.segments[index].pendingPasses > 0 {
            let segment = block.segments[index]
            let length = segment.pendingLength
            if length < 0 || offset > body.count || length > body.count - offset {
                throw .invalidCodestream(.badPacketHeader)
            }
            let end = try Checked.add(offset, length)
            try budget.append(contentsOf: body[offset..<end], to: &block.data)
            offset = end
            try budget.append(CodeBlockPacketSegment(layer: layer, passes: segment.pendingPasses, length: length),
                              to: &block.packetSegments)
            block.segments[index].length = try Checked.add(segment.length, length)
            block.segments[index].dataLength = try Checked.add(segment.dataLength, length)
            block.totalPasses = try Checked.add(block.totalPasses, segment.pendingPasses)
            block.segments[index].passes = try Checked.add(segment.passes, segment.pendingPasses)
            block.segments[index].pendingPasses = 0
            block.segments[index].pendingLength = 0
        }
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

private extension Band {
    var hasArea: Bool { x0 < x1 && y0 < y1 }
}
