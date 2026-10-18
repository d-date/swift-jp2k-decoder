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
 * Copyright (c) 2007, Callum Lerwick <seg@haxxed.com>
 * Copyright (c) 2012, Carl Hetherington
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
// Ported from OpenJPEG v2.5.4: tcd.c: opj_tcd_decode_tile, opj_tcd_t1_decode, opj_tcd_dwt_decode, opj_tcd_mct_decode, opj_tcd_dc_level_shift_decode; t1.c: opj_t1_clbl_decode_processor
/// Decodes one tile with a reusable Tier 1 scratch decoder.
enum TileDecoder {
    static func decode(_ tile: TileData, header: MainHeader,
                       context: inout DecodeContext) async throws(JP2KError) -> TileGeometry {
        var geometry = try TileGeometryBuilder.build(tile: tile, header: header, context: &context)
        let positions = try PacketIterator.positions(geometry: geometry, parameters: tile.parameters,
                                                     header: header, tileIndex: tile.index, context: &context)
        try PacketDecoder.decodeTile(tile, geometry: &geometry, positions: positions, context: &context)
        for component in geometry.components.indices {
            let coding = tile.parameters.coc[component] ?? tile.parameters.cod.component
            try await decodeCodeBlocks(tile, component: component, geometry: &geometry, context: &context)
            try InverseDWT.decode(&geometry.components[component].coefficients,
                                  resolutions: geometry.components[component].resolutions,
                                  reversible: coding.reversible, budget: &context.budget)
        }
        if tile.parameters.cod.mct {
            try InverseMCT.decode(&geometry, reversible: tile.parameters.cod.component.reversible)
        }
        for component in geometry.components.indices {
            let descriptor = header.geometry.components[component]
            let coding = tile.parameters.coc[component] ?? tile.parameters.cod.component
            try InverseMCT.levelShift(&geometry.components[component].coefficients,
                                      precision: descriptor.precision, signed: descriptor.isSigned,
                                      reversible: coding.reversible)
        }
        return geometry
    }

    /// Runs Tier-1 for one component. The job list is built from a borrowed
    /// view of the component, so nothing else holds its coefficient plane
    /// when the scheduler writes into it (a live copy would force a full
    /// copy-on-write of the plane), and it is charged to the budget while it
    /// exists.
    private static func decodeCodeBlocks(_ tile: TileData, component: Int, geometry: inout TileGeometry,
                                         context: inout DecodeContext) async throws(JP2KError) {
        var listBytes = 0
        defer { context.budget.release(bytes: listBytes) }
        let jobs = try codeBlockJobs(tile, component: component, geometry.components[component],
                                     listBytes: &listBytes, budget: &context.budget)
        if jobs.isEmpty { return }
        try await CodeBlockScheduler.run(jobs, geometry: &geometry, context: &context)
    }

    /// Lists the component's code-blocks with coded passes in OpenJPEG's
    /// decode order. Errors the serial loop used to raise before or after
    /// decoding a block are attached to that block's job, so they surface in
    /// the same order whichever path decodes it. `listBytes` records what was
    /// charged for the list, including any capacity rounding.
    private static func codeBlockJobs(_ tile: TileData, component: Int, _ componentGeometry: borrowing TileComponent,
                                      listBytes: inout Int, budget: inout MemoryBudget) throws(JP2KError) -> [CodeBlockJob] {
        let coding = tile.parameters.coc[component] ?? tile.parameters.cod.component
        let roi = tile.parameters.rgn[component] ?? 0
        let width = try Checked.sub(componentGeometry.x1, componentGeometry.x0)
        let height = try Checked.sub(componentGeometry.y1, componentGeometry.y0)
        let maxWidth = try Checked.shiftLeft(1, coding.codeBlockWidthExp)
        let maxHeight = try Checked.shiftLeft(1, coding.codeBlockHeightExp)
        var count = 0
        for resolution in componentGeometry.resolutions {
            for band in resolution.bands {
                for precinct in band.precincts {
                    for block in precinct.codeBlocks where block.totalPasses > 0 { count = try Checked.add(count, 1) }
                }
            }
        }
        if count == 0 { return [] }
        let requested = try Checked.mul(count, MemoryLayout<CodeBlockJob>.stride)
        try budget.reserve(bytes: requested)
        listBytes = requested
        var jobs: [CodeBlockJob] = []
        jobs.reserveCapacity(count)
        let actual = try Checked.mul(jobs.capacity, MemoryLayout<CodeBlockJob>.stride)
        if actual > requested {
            try budget.reserve(bytes: actual - requested)
            listBytes = actual
        }
        for resolution in componentGeometry.resolutions.indices {
            let bands = componentGeometry.resolutions[resolution].bands
            for band in bands {
                for precinct in band.precincts {
                    for block in precinct.codeBlocks where block.totalPasses > 0 {
                        var job = CodeBlockJob(component: component, block: block, orientation: band.orientation,
                                               roiShift: roi, codeBlockStyle: coding.codeBlockStyle,
                                               reversible: coding.reversible, stepSize: band.stepSize,
                                               maxWidth: maxWidth, maxHeight: maxHeight, rowStride: width)
                        do {
                            job.numBitPlanes = try Checked.sub(try Checked.add(band.numBitPlanes, 1), block.zeroBitPlanes)
                        } catch {
                            job.errorBeforeDecode = error
                        }
                        do {
                            try place(&job, block: block, band: band, resolution: resolution,
                                      component: componentGeometry, width: width, height: height)
                        } catch {
                            job.errorAfterDecode = error
                        }
                        jobs.append(job)
                    }
                }
            }
        }
        return jobs
    }

    /// Validates that the block lands inside the component's coefficient grid,
    /// so the copy loops need no per-sample checks.
    private static func place(_ job: inout CodeBlockJob, block: CodeBlock, band: Band, resolution: Int,
                              component: borrowing TileComponent, width: Int, height: Int) throws(JP2KError) {
        let blockWidth = try Checked.sub(block.x1, block.x0)
        let blockHeight = try Checked.sub(block.y1, block.y0)
        var offsetX = try Checked.sub(block.x0, band.x0)
        var offsetY = try Checked.sub(block.y0, band.y0)
        if resolution > 0 {
            let previous = component.resolutions[resolution - 1]
            if band.orientation & 1 != 0 { offsetX = try Checked.add(offsetX, Checked.sub(previous.x1, previous.x0)) }
            if band.orientation & 2 != 0 { offsetY = try Checked.add(offsetY, Checked.sub(previous.y1, previous.y0)) }
        }
        guard blockWidth > 0, blockHeight > 0, offsetX >= 0, offsetY >= 0,
              try Checked.add(offsetX, blockWidth) <= width,
              try Checked.add(offsetY, blockHeight) <= height,
              try Checked.mul(Checked.add(offsetY, blockHeight), width) <= component.coefficients.count else {
            throw .invalidCodestream(.badCodeBlock)
        }
        job.offsetX = offsetX
        job.offsetY = offsetY
        job.width = blockWidth
        job.height = blockHeight
    }
}
