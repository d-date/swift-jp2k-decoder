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
                       context: inout DecodeContext) throws(JP2KError) -> TileGeometry {
        var geometry = try TileGeometryBuilder.build(tile: tile, header: header, context: &context)
        let positions = try PacketIterator.positions(geometry: geometry, parameters: tile.parameters,
                                                     header: header, tileIndex: tile.index, context: &context)
        try PacketDecoder.decodeTile(tile, geometry: &geometry, positions: positions, context: &context)
        var maxWidth = 1, maxHeight = 1
        for component in geometry.components.indices {
            let coding = tile.parameters.coc[component] ?? tile.parameters.cod.component
            maxWidth = max(maxWidth, try Checked.shiftLeft(1, coding.codeBlockWidthExp))
            maxHeight = max(maxHeight, try Checked.shiftLeft(1, coding.codeBlockHeightExp))
        }
        var decoder = try CodeBlockDecoder(maxWidth: maxWidth, maxHeight: maxHeight, budget: &context.budget)
        for component in geometry.components.indices {
            let coding = tile.parameters.coc[component] ?? tile.parameters.cod.component
            let roi = tile.parameters.rgn[component] ?? 0
            let width = try Checked.sub(geometry.components[component].x1, geometry.components[component].x0)
            for resolution in geometry.components[component].resolutions.indices {
                let bands = geometry.components[component].resolutions[resolution].bands
                for bandIndex in bands.indices {
                    let band = bands[bandIndex]
                    for precinct in band.precincts {
                        for block in precinct.codeBlocks where block.totalPasses > 0 {
                            let bitPlanes = try Checked.sub(try Checked.add(band.numBitPlanes, 1), block.zeroBitPlanes)
                            try decoder.decode(block, orientation: band.orientation, roiShift: roi,
                                               codeBlockStyle: coding.codeBlockStyle, numBitPlanes: bitPlanes,
                                               budget: &context.budget)
                            let blockWidth = try Checked.sub(block.x1, block.x0)
                            let blockHeight = try Checked.sub(block.y1, block.y0)
                            var offsetX = try Checked.sub(block.x0, band.x0)
                            var offsetY = try Checked.sub(block.y0, band.y0)
                            if resolution > 0 {
                                let previous = geometry.components[component].resolutions[resolution - 1]
                                if band.orientation & 1 != 0 { offsetX = try Checked.add(offsetX, Checked.sub(previous.x1, previous.x0)) }
                                if band.orientation & 2 != 0 { offsetY = try Checked.add(offsetY, Checked.sub(previous.y1, previous.y0)) }
                            }
                            for y in 0..<blockHeight {
                                for x in 0..<blockWidth {
                                    let source = try Checked.add(Checked.mul(y, blockWidth), x)
                                    let dest = try Checked.add(Checked.mul(try Checked.add(offsetY, y), width),
                                                               Checked.add(offsetX, x))
                                    guard source < decoder.outputCount, dest >= 0,
                                          dest < geometry.components[component].coefficients.count else {
                                        throw .invalidCodestream(.badCodeBlock)
                                    }
                                    geometry.components[component].coefficients[dest] = Dequantize.sample(
                                        decoder.output(at: source), roiShift: roi, reversible: coding.reversible,
                                        stepSize: band.stepSize)
                                }
                            }
                        }
                    }
                }
            }
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
}
