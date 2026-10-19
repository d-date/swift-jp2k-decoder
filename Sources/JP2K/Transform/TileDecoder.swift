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
/// Decodes one tile: Tier-2 into the tile geometry (`prepare`), then Tier-1,
/// the inverse DWT, MCT and level shift into separate coefficient planes
/// (`reconstruct`). The split lets tiles be reconstructed concurrently
/// while reading geometry that no one mutates.
enum TileDecoder {
    static func decode(_ tile: TileData, header: MainHeader,
                       context: inout DecodeContext) async throws(JP2KError) -> TileGeometry {
        var geometry = try prepare(tile, header: header, context: &context)
        // The planes are moved out, not copied, so reconstruction can write
        // them while the geometry is read; they are moved back afterwards.
        var planes = try context.budget.array(repeating: [Int32](), count: geometry.components.count)
        let listBytes = planes.capacity * MemoryLayout<[Int32]>.stride
        defer { context.budget.release(bytes: listBytes) }
        for component in planes.indices {
            swap(&planes[component], &geometry.components[component].coefficients)
        }
        try await reconstruct(tile, header: header, geometry: geometry, planes: &planes, context: &context)
        for component in planes.indices {
            swap(&planes[component], &geometry.components[component].coefficients)
        }
        return geometry
    }

    static func prepare(_ tile: TileData, header: MainHeader,
                        context: inout DecodeContext) throws(JP2KError) -> TileGeometry {
        var geometry = try TileGeometryBuilder.build(tile: tile, header: header, context: &context)
        let positions = try PacketIterator.positions(geometry: geometry, parameters: tile.parameters,
                                                     header: header, tileIndex: tile.index, context: &context)
        try PacketDecoder.decodeTile(tile, geometry: &geometry, positions: positions, context: &context)
        return geometry
    }

    /// `planes[c]` is component c's coefficient plane, the size the geometry
    /// gave it; on return it holds the tile's reconstructed samples.
    static func reconstruct(_ tile: TileData, header: MainHeader, geometry: TileGeometry,
                            planes: inout [[Int32]], context: inout DecodeContext) async throws(JP2KError) {
        guard planes.count == geometry.components.count else { throw .invalidCodestream(.badSIZ) }
        let concurrent = await decodeCodeBlocksConcurrently(tile, geometry: geometry, planes: &planes,
                                                            context: &context)
        for component in geometry.components.indices {
            let coding = tile.parameters.coc[component] ?? tile.parameters.cod.component
            if !concurrent {
                try decodeCodeBlocks(tile, component: component, geometry: geometry, planes: &planes,
                                     context: &context)
            }
            try InverseDWT.decode(&planes[component], resolutions: geometry.components[component].resolutions,
                                  reversible: coding.reversible, budget: &context.budget)
        }
        if tile.parameters.cod.mct {
            try InverseMCT.decode(&planes, reversible: tile.parameters.cod.component.reversible)
        }
        for component in geometry.components.indices {
            let descriptor = header.geometry.components[component]
            let coding = tile.parameters.coc[component] ?? tile.parameters.cod.component
            try InverseMCT.levelShift(&planes[component], precision: descriptor.precision,
                                      signed: descriptor.isSigned, reversible: coding.reversible)
        }
    }

    /// An upper bound on what `reconstruct` charges with code-blocks decoded
    /// on one thread, plus fresh planes and the list holding them: the
    /// budget one concurrently reconstructed tile needs.
    static func reconstructionBytes(_ tile: TileData, geometry: TileGeometry) throws(JP2KError) -> Int {
        var planes = try CodeBlockScheduler.rounded(
            Checked.mul(geometry.components.count, MemoryLayout<[Int32]>.stride))
        var transient = 0
        for component in geometry.components.indices {
            let coding = tile.parameters.coc[component] ?? tile.parameters.cod.component
            let componentGeometry = geometry.components[component]
            planes = try Checked.add(planes, CodeBlockScheduler.rounded(
                Checked.mul(componentGeometry.coefficients.count, MemoryLayout<Int32>.stride)))
            var blocks = 0
            var maxData = 0
            for resolution in componentGeometry.resolutions {
                for band in resolution.bands {
                    for precinct in band.precincts {
                        for block in precinct.codeBlocks where block.totalPasses > 0 {
                            blocks = try Checked.add(blocks, 1)
                            maxData = max(maxData, block.data.count)
                        }
                    }
                }
            }
            let list = try CodeBlockScheduler.rounded(Checked.mul(blocks, MemoryLayout<CodeBlockJob>.stride))
            let scratch = try CodeBlockScheduler.scratchBytes(
                width: Checked.shiftLeft(1, coding.codeBlockWidthExp),
                height: Checked.shiftLeft(1, coding.codeBlockHeightExp), maxData: maxData)
            let dwt = try CodeBlockScheduler.rounded(
                InverseDWT.workBytes(resolutions: componentGeometry.resolutions, reversible: coding.reversible))
            transient = max(transient, try Checked.add(list, Checked.add(scratch, dwt)))
        }
        return try Checked.add(planes, transient)
    }

    /// Runs Tier-1 for one component on this thread. The job list is
    /// charged to the budget while it exists.
    private static func decodeCodeBlocks(_ tile: TileData, component: Int, geometry: TileGeometry,
                                         planes: inout [[Int32]], context: inout DecodeContext) throws(JP2KError) {
        var listBytes = 0
        defer { context.budget.release(bytes: listBytes) }
        let jobs = try codeBlockJobs(tile, components: CollectionOfOne(component), geometry: geometry,
                                     planes: planes, listBytes: &listBytes, budget: &context.budget)
        try CodeBlockScheduler.decode(jobs, into: &planes[component], budget: &context.budget)
    }

    /// Runs Tier-1 for every component of the tile in one fan-out, when the
    /// tile is large enough for it to pay off. False leaves the planes as
    /// they were, for the serial loop: that includes any error, which the
    /// serial loop then raises in its own order.
    private static func decodeCodeBlocksConcurrently(_ tile: TileData, geometry: TileGeometry,
                                                     planes: inout [[Int32]],
                                                     context: inout DecodeContext) async -> Bool {
        guard context.limits.maxThreads > 1,
              (try? warrantsFanOut(tile, planes: planes, limits: context.limits)) == true else { return false }
        var listBytes = 0
        defer { context.budget.release(bytes: listBytes) }
        if let jobs = try? codeBlockJobs(tile, components: geometry.components.indices, geometry: geometry,
                                         planes: planes, listBytes: &listBytes, budget: &context.budget),
           await CodeBlockScheduler.decodeConcurrently(jobs, into: &planes, context: &context) {
            return true
        }
        context.countParallelFallback()
        return false
    }

    private static func warrantsFanOut(_ tile: TileData, planes: [[Int32]],
                                       limits: Limits) throws(JP2KError) -> Bool {
        var samples = 0
        for plane in planes { samples = try Checked.add(samples, plane.count) }
        return try limits.warrantsFanOut(codedBytes: tile.body.count, samples: samples)
    }

    /// Lists the components' code-blocks with coded passes in OpenJPEG's
    /// decode order, component by component. Errors the serial loop used to
    /// raise before or after decoding a block are attached to that block's
    /// job, so they surface in the same order whichever path decodes it.
    /// `listBytes` records what was charged for the list, including any
    /// capacity rounding.
    private static func codeBlockJobs(_ tile: TileData, components: some Collection<Int>,
                                      geometry: borrowing TileGeometry,
                                      planes: borrowing [[Int32]], listBytes: inout Int,
                                      budget: inout MemoryBudget) throws(JP2KError) -> [CodeBlockJob] {
        var count = 0
        for component in components {
            for resolution in geometry.components[component].resolutions {
                for band in resolution.bands {
                    for precinct in band.precincts {
                        for block in precinct.codeBlocks where block.totalPasses > 0 {
                            count = try Checked.add(count, 1)
                        }
                    }
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
        for component in components {
            try appendJobs(tile, component: component, geometry.components[component],
                           planeCount: planes[component].count, to: &jobs)
        }
        return jobs
    }

    private static func appendJobs(_ tile: TileData, component: Int, _ componentGeometry: borrowing TileComponent,
                                   planeCount: Int, to jobs: inout [CodeBlockJob]) throws(JP2KError) {
        let coding = tile.parameters.coc[component] ?? tile.parameters.cod.component
        let roi = tile.parameters.rgn[component] ?? 0
        let width = try Checked.sub(componentGeometry.x1, componentGeometry.x0)
        let height = try Checked.sub(componentGeometry.y1, componentGeometry.y0)
        let maxWidth = try Checked.shiftLeft(1, coding.codeBlockWidthExp)
        let maxHeight = try Checked.shiftLeft(1, coding.codeBlockHeightExp)
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
                                      component: componentGeometry, planeCount: planeCount,
                                      width: width, height: height)
                        } catch {
                            job.errorAfterDecode = error
                        }
                        jobs.append(job)
                    }
                }
            }
        }
    }

    /// Validates that the block lands inside the component's coefficient grid,
    /// so the copy loops need no per-sample checks.
    private static func place(_ job: inout CodeBlockJob, block: CodeBlock, band: Band, resolution: Int,
                              component: borrowing TileComponent, planeCount: Int,
                              width: Int, height: Int) throws(JP2KError) {
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
              try Checked.mul(Checked.add(offsetY, blockHeight), width) <= planeCount else {
            throw .invalidCodestream(.badCodeBlock)
        }
        job.offsetX = offsetX
        job.offsetY = offsetY
        job.width = blockWidth
        job.height = blockHeight
    }
}
