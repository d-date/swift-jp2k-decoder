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
 * Copyright (c) 2006-2007, Parvatha Elangovan
 * Copyright (c) 2008, 2011-2012, Centre National d'Etudes Spatiales (CNES), FR
 * Copyright (c) 2012, CS Systemes d'Information, France
 * Copyright (c) 2017, IntoPIX SA <support@intopix.com>
 * Copyright (c) 2007, Jonathan Ballard <dzonatas@dzonux.net>
 * Copyright (c) 2007, Callum Lerwick <seg@haxxed.com>
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
// Ported from OpenJPEG v2.5.4: tcd.c: opj_tcd_init_tile, opj_tcd_code_block_dec_allocate; dwt.c: opj_dwt_getgain, opj_dwt_calc_explicit_stepsizes
struct CodeBlockSegment {
    var passes = 0
    var maxPasses = 0
    var length = 0
    var dataLength = 0
}
struct CodeBlock {
    var x0, y0, x1, y1: Int
    var included = false
    var zeroBitPlanes = 0
    var numLenBits = 3
    var segments: [CodeBlockSegment] = []
    var data: [UInt8] = []
    var totalPasses = 0
}
struct Precinct {
    var x0, y0, x1, y1: Int
    var codeBlocksWide, codeBlocksHigh: Int
    var codeBlocks: [CodeBlock]
    var inclusionTree: TagTree
    var zeroBitPlaneTree: TagTree
}
struct Band {
    var orientation: Int
    var x0, y0, x1, y1: Int
    var precincts: [Precinct]
    var stepSize: Float
    var numBitPlanes: Int
}
struct Resolution {
    var x0, y0, x1, y1: Int
    var precinctsWide, precinctsHigh: Int
    var bands: [Band]
}
struct TileComponent {
    var x0, y0, x1, y1: Int
    var resolutions: [Resolution]
    var coefficients: [Int32]
}
struct TileGeometry {
    var x0, y0, x1, y1: Int
    var components: [TileComponent]
}

private struct Rectangle {
    var x0, y0, x1, y1: Int
}

private struct PrecinctPlan {
    var rect: Rectangle
    var blockOriginX, blockOriginY: Int
    var blocksWide, blocksHigh: Int
}

enum TileGeometryBuilder {
    static func build(tile: TileData, header: MainHeader,
                      context: inout DecodeContext) throws(JP2KError) -> TileGeometry {
        let image = header.geometry
        let count = try Checked.mul(image.tilesAcross, image.tilesDown)
        if tile.index < 0 || tile.index >= count { throw .invalidCodestream(.badSOT) }
        let tx = try Checked.add(image.tileX0, Checked.mul(tile.index % image.tilesAcross, image.tileWidth))
        let ty = try Checked.add(image.tileY0, Checked.mul(tile.index / image.tilesAcross, image.tileHeight))
        let rect = Rectangle(x0: max(tx, image.x0), y0: max(ty, image.y0),
                             x1: min(try Checked.add(tx, image.tileWidth), image.x1),
                             y1: min(try Checked.add(ty, image.tileHeight), image.y1))
        if rect.x0 >= rect.x1 || rect.y0 >= rect.y1 { throw .invalidCodestream(.badSIZ) }
        try context.budget.reserve(bytes: try Checked.mul(image.components.count, MemoryLayout<TileComponent>.stride))
        var components: [TileComponent] = []
        components.reserveCapacity(image.components.count)
        for componentIndex in image.components.indices {
            let descriptor = image.components[componentIndex]
            let coding = tile.parameters.coc[componentIndex] ?? tile.parameters.cod.component
            let quant = tile.parameters.qcc[componentIndex] ?? tile.parameters.qcd
            let componentRect = Rectangle(x0: try Checked.ceilDiv(rect.x0, descriptor.dx),
                                          y0: try Checked.ceilDiv(rect.y0, descriptor.dy),
                                          x1: try Checked.ceilDiv(rect.x1, descriptor.dx),
                                          y1: try Checked.ceilDiv(rect.y1, descriptor.dy))
            let resolutionCount = try Checked.add(coding.decompositionLevels, 1)
            if resolutionCount == 0 || coding.precinctSizes.count < resolutionCount {
                throw .invalidCodestream(.badCOD)
            }
            try context.budget.reserve(bytes: try Checked.mul(resolutionCount, MemoryLayout<Resolution>.stride))
            var resolutions: [Resolution] = []
            resolutions.reserveCapacity(resolutionCount)
            for resolutionIndex in 0..<resolutionCount {
                let level = try Checked.sub(coding.decompositionLevels, resolutionIndex)
                let resolutionRect = try downsample(componentRect, by: level)
                let precinctExponents = coding.precinctSizes[resolutionIndex]
                let px = precinctExponents.ppx, py = precinctExponents.ppy
                if px < 0 || py < 0 || px > 15 || py > 15 || (resolutionIndex > 0 && (px == 0 || py == 0)) {
                    throw .invalidCodestream(.specRange)
                }
                let originX = try floorGrid(resolutionRect.x0, exponent: px)
                let originY = try floorGrid(resolutionRect.y0, exponent: py)
                let endX = try ceilGrid(resolutionRect.x1, exponent: px)
                let endY = try ceilGrid(resolutionRect.y1, exponent: py)
                let precinctsWide = resolutionRect.x0 == resolutionRect.x1 ? 0 : try Checked.floorDivPow2(Checked.sub(endX, originX), px)
                let precinctsHigh = resolutionRect.y0 == resolutionRect.y1 ? 0 : try Checked.floorDivPow2(Checked.sub(endY, originY), py)
                let precinctCount = try Checked.mul(precinctsWide, precinctsHigh)
                let bandCount = resolutionIndex == 0 ? 1 : 3
                let allPrecincts = try Checked.mul(precinctCount, bandCount)
                try context.budget.reserve(bytes: try Checked.mul(bandCount, MemoryLayout<Band>.stride))
                try context.budget.reserve(bytes: try Checked.mul(allPrecincts, MemoryLayout<Precinct>.stride))
                var bands: [Band] = []
                bands.reserveCapacity(bandCount)
                for bandIndex in 0..<bandCount {
                    let orientation = resolutionIndex == 0 ? 0 : bandIndex + 1
                    let bandRect = try bandBounds(componentRect, level: level, orientation: orientation)
                    let gridX = resolutionIndex == 0 ? originX : try Checked.ceilDivPow2(originX, 1)
                    let gridY = resolutionIndex == 0 ? originY : try Checked.ceilDivPow2(originY, 1)
                    let blockGridX = resolutionIndex == 0 ? px : px - 1
                    let blockGridY = resolutionIndex == 0 ? py : py - 1
                    let bx = min(coding.codeBlockWidthExp, blockGridX)
                    let by = min(coding.codeBlockHeightExp, blockGridY)
                    if bx < 0 || by < 0 { throw .invalidCodestream(.specRange) }
                    let stepIndex = try Checked.add(try Checked.mul(max(0, resolutionIndex - 1), 3), orientation == 0 ? 0 : orientation)
                    let step = try quantStep(quant, index: stepIndex, level: level, precision: descriptor.precision,
                                             reversible: coding.reversible, orientation: orientation)
                    try context.budget.reserve(bytes: try Checked.mul(precinctCount, MemoryLayout<PrecinctPlan>.stride))
                    var plans: [PrecinctPlan] = []
                    plans.reserveCapacity(precinctCount)
                    var totalBlocks = 0
                    for precinctIndex in 0..<precinctCount {
                        let gx = try Checked.add(gridX, Checked.shiftLeft(precinctIndex % precinctsWide, blockGridX))
                        let gy = try Checked.add(gridY, Checked.shiftLeft(precinctIndex / precinctsWide, blockGridY))
                        let candidate = Rectangle(x0: gx, y0: gy,
                                                  x1: try Checked.add(gx, Checked.shiftLeft(1, blockGridX)),
                                                  y1: try Checked.add(gy, Checked.shiftLeft(1, blockGridY)))
                        let pr = Rectangle(x0: max(candidate.x0, bandRect.x0), y0: max(candidate.y0, bandRect.y0),
                                           x1: min(candidate.x1, bandRect.x1), y1: min(candidate.y1, bandRect.y1))
                        let blockX = try floorGrid(pr.x0, exponent: bx)
                        let blockY = try floorGrid(pr.y0, exponent: by)
                        let blockEndX = try ceilGrid(pr.x1, exponent: bx)
                        let blockEndY = try ceilGrid(pr.y1, exponent: by)
                        let wide = try Checked.floorDivPow2(Checked.sub(blockEndX, blockX), bx)
                        let high = try Checked.floorDivPow2(Checked.sub(blockEndY, blockY), by)
                        totalBlocks = try Checked.add(totalBlocks, Checked.mul(wide, high))
                        plans.append(PrecinctPlan(rect: pr, blockOriginX: blockX, blockOriginY: blockY,
                                                  blocksWide: wide, blocksHigh: high))
                    }
                    try context.budget.reserve(bytes: try Checked.mul(totalBlocks, MemoryLayout<CodeBlock>.stride))
                    try context.budget.reserve(bytes: try Checked.mul(
                        Checked.mul(totalBlocks, 10), MemoryLayout<CodeBlockSegment>.stride))
                    var precincts: [Precinct] = []
                    precincts.reserveCapacity(precinctCount)
                    for plan in plans {
                        let blockCount = try Checked.mul(plan.blocksWide, plan.blocksHigh)
                        var blocks: [CodeBlock] = []
                        blocks.reserveCapacity(blockCount)
                        for blockIndex in 0..<blockCount {
                            let x = try Checked.add(plan.blockOriginX, Checked.shiftLeft(blockIndex % plan.blocksWide, bx))
                            let y = try Checked.add(plan.blockOriginY, Checked.shiftLeft(blockIndex / plan.blocksWide, by))
                            var block = CodeBlock(x0: max(x, plan.rect.x0), y0: max(y, plan.rect.y0),
                                                  x1: min(try Checked.add(x, Checked.shiftLeft(1, bx)), plan.rect.x1),
                                                  y1: min(try Checked.add(y, Checked.shiftLeft(1, by)), plan.rect.y1))
                            block.segments.reserveCapacity(10)
                            blocks.append(block)
                        }
                        // Empty precincts have no packet-header tree leaves.
                        if blockCount == 0 {
                            // Use a one-node placeholder; no packet references it.
                            let inclusion = try TagTree(leavesWide: 1, leavesHigh: 1, budget: &context.budget)
                            let zero = try TagTree(leavesWide: 1, leavesHigh: 1, budget: &context.budget)
                            precincts.append(Precinct(x0: plan.rect.x0, y0: plan.rect.y0, x1: plan.rect.x1, y1: plan.rect.y1,
                                                      codeBlocksWide: 0, codeBlocksHigh: 0, codeBlocks: [],
                                                      inclusionTree: inclusion, zeroBitPlaneTree: zero))
                        } else {
                            let inclusion = try TagTree(leavesWide: plan.blocksWide, leavesHigh: plan.blocksHigh,
                                                        budget: &context.budget)
                            let zero = try TagTree(leavesWide: plan.blocksWide, leavesHigh: plan.blocksHigh,
                                                   budget: &context.budget)
                            precincts.append(Precinct(x0: plan.rect.x0, y0: plan.rect.y0, x1: plan.rect.x1, y1: plan.rect.y1,
                                                      codeBlocksWide: plan.blocksWide, codeBlocksHigh: plan.blocksHigh,
                                                      codeBlocks: blocks, inclusionTree: inclusion, zeroBitPlaneTree: zero))
                        }
                    }
                    let bitPlanes = try Checked.sub(Checked.add(step.exponent, quant.guardBits), 1)
                    bands.append(Band(orientation: orientation, x0: bandRect.x0, y0: bandRect.y0,
                                      x1: bandRect.x1, y1: bandRect.y1, precincts: precincts,
                                      stepSize: step.size, numBitPlanes: bitPlanes))
                    // Retain the plan charge for this geometry. Its storage may
                    // remain live across the next band's allocations.
                }
                resolutions.append(Resolution(x0: resolutionRect.x0, y0: resolutionRect.y0,
                                              x1: resolutionRect.x1, y1: resolutionRect.y1,
                                              precinctsWide: precinctsWide, precinctsHigh: precinctsHigh, bands: bands))
            }
            let width = try Checked.sub(componentRect.x1, componentRect.x0)
            let height = try Checked.sub(componentRect.y1, componentRect.y0)
            let coefficientCount = try Checked.mul(width, height)
            let coefficients = try context.budget.array(repeating: Int32.zero, count: coefficientCount)
            components.append(TileComponent(x0: componentRect.x0, y0: componentRect.y0,
                                            x1: componentRect.x1, y1: componentRect.y1,
                                            resolutions: resolutions, coefficients: coefficients))
        }
        return TileGeometry(x0: rect.x0, y0: rect.y0, x1: rect.x1, y1: rect.y1, components: components)
    }

    private static func floorGrid(_ value: Int, exponent: Int) throws(JP2KError) -> Int {
        try Checked.shiftLeft(Checked.floorDivPow2(value, exponent), exponent)
    }
    private static func ceilGrid(_ value: Int, exponent: Int) throws(JP2KError) -> Int {
        try Checked.shiftLeft(Checked.ceilDivPow2(value, exponent), exponent)
    }
    private static func downsample(_ rect: Rectangle, by level: Int) throws(JP2KError) -> Rectangle {
        Rectangle(x0: try Checked.ceilDivPow2(rect.x0, level), y0: try Checked.ceilDivPow2(rect.y0, level),
                  x1: try Checked.ceilDivPow2(rect.x1, level), y1: try Checked.ceilDivPow2(rect.y1, level))
    }
    private static func bandBounds(_ rect: Rectangle, level: Int, orientation: Int) throws(JP2KError) -> Rectangle {
        if orientation == 0 { return try downsample(rect, by: level) }
        let offsetX = orientation & 1 == 0 ? 0 : try Checked.shiftLeft(1, level)
        let offsetY = orientation & 2 == 0 ? 0 : try Checked.shiftLeft(1, level)
        let shift = try Checked.add(level, 1)
        return Rectangle(x0: try Checked.ceilDivPow2(Checked.sub(rect.x0, offsetX), shift),
                         y0: try Checked.ceilDivPow2(Checked.sub(rect.y0, offsetY), shift),
                         x1: try Checked.ceilDivPow2(Checked.sub(rect.x1, offsetX), shift),
                         y1: try Checked.ceilDivPow2(Checked.sub(rect.y1, offsetY), shift))
    }
    private static func quantStep(_ quant: QuantizationStyle, index: Int, level: Int,
                                  precision: Int, reversible: Bool,
                                  orientation: Int) throws(JP2KError) -> (size: Float, exponent: Int) {
        let sourceIndex = quant.style == 1 ? 0 : index
        if sourceIndex < 0 || sourceIndex >= quant.stepSizes.count { throw .invalidCodestream(.badQCD) }
        let stored = quant.stepSizes[sourceIndex]
        let derivedLevel = index == 0 ? 0 : (index - 1) / 3
        let exponent = quant.style == 1 ? max(0, try Checked.sub(stored.exponent, derivedLevel)) : stored.exponent
        let gain = reversible ? (orientation == 3 ? 2 : orientation == 0 ? 0 : 1) : 0
        let range = try Checked.add(precision, gain)
        let power = try Checked.sub(range, exponent)
        let scale = Float(sign: .plus, exponent: power, significand: 1 + Float(stored.mantissa) / 2048)
        return (scale, exponent)
    }
}
