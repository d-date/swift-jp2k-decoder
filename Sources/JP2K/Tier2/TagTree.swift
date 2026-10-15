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
// Ported from OpenJPEG v2.5.4: tgt.c: opj_tgt_create, opj_tgt_reset, opj_tgt_decode
private struct TagNode {
    var parent: Int
    var value: Int = 999
    var low: Int = 0
}

struct TagTree {
    private var nodes: [TagNode]
    private let leafCount: Int

    init(leavesWide: Int, leavesHigh: Int, budget: inout MemoryBudget) throws(JP2KError) {
        if leavesWide <= 0 || leavesHigh <= 0 { throw .invalidCodestream(.badPacketHeader) }
        leafCount = try Checked.mul(leavesWide, leavesHigh)
        var levels: [(width: Int, height: Int, offset: Int)] = []
        var width = leavesWide, height = leavesHigh, total = 0
        while true {
            if levels.count >= 32 { throw .invalidCodestream(.badPacketHeader) }
            levels.append((width, height, total))
            let count = try Checked.mul(width, height)
            total = try Checked.add(total, count)
            if count == 1 { break }
            width = try Checked.ceilDiv(width, 2)
            height = try Checked.ceilDiv(height, 2)
        }
        try budget.reserve(bytes: try Checked.mul(total, MemoryLayout<TagNode>.stride))
        nodes = [TagNode](repeating: TagNode(parent: -1), count: total)
        for level in 0..<(levels.count - 1) {
            let current = levels[level], next = levels[level + 1]
            for y in 0..<current.height {
                for x in 0..<current.width {
                    let index = try Checked.add(current.offset, Checked.add(Checked.mul(y, current.width), x))
                    let parent = try Checked.add(next.offset, Checked.add(Checked.mul(y / 2, next.width), x / 2))
                    if index < 0 || index >= nodes.count || parent < 0 || parent >= nodes.count {
                        throw .invalidCodestream(.badPacketHeader)
                    }
                    nodes[index].parent = parent
                }
            }
        }
    }

    func storageBytes() throws(JP2KError) -> Int {
        try Checked.mul(nodes.count, MemoryLayout<TagNode>.stride)
    }

    mutating func reset() {
        for index in nodes.indices { nodes[index].value = 999; nodes[index].low = 0 }
    }

    mutating func decode(_ bits: inout PacketBitReader, leaf: Int, threshold: Int) throws(JP2KError) -> Bool {
        if leaf < 0 || leaf >= leafCount || threshold < 0 { throw .invalidCodestream(.badPacketHeader) }
        var path: [Int] = []
        path.reserveCapacity(32)
        var index = leaf
        while index >= 0 {
            if path.count >= 32 { throw .invalidCodestream(.badPacketHeader) }
            if index >= nodes.count { throw .invalidCodestream(.badPacketHeader) }
            path.append(index)
            index = nodes[index].parent
        }
        var low = 0
        for index in path.reversed() {
            low = max(low, nodes[index].low)
            while low < threshold && low < nodes[index].value {
                if try bits.readBit() == 1 { nodes[index].value = low } else { low = try Checked.add(low, 1) }
            }
            nodes[index].low = low
        }
        return nodes[leaf].value < threshold
    }

    func value(leaf: Int) -> Int {
        if leaf < 0 || leaf >= leafCount { return 999 }
        return nodes[leaf].value
    }
}
