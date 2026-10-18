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
// Ported from OpenJPEG v2.5.4: j2k.c: opj_j2k_update_image_data
/// Copies decoded tile components into their image component planes.
enum ComponentAssembler {
    static func assemble(_ tiles: [TileGeometry], info: ImageInfo,
                         context: inout DecodeContext) throws(JP2KError) -> [[Int32]] {
        try context.budget.reserve(bytes: try Checked.mul(info.components.count, MemoryLayout<[Int32]>.stride))
        var output: [[Int32]] = []
        output.reserveCapacity(info.components.count)
        for descriptor in info.components {
            output.append(try context.budget.array(repeating: Int32.zero,
                                                   count: Checked.mul(descriptor.width, descriptor.height)))
        }
        for tile in tiles {
            guard tile.components.count == output.count else { throw .invalidCodestream(.badSIZ) }
            for component in tile.components.indices {
                let source = tile.components[component]
                let destination = info.components[component]
                let width = try Checked.sub(source.x1, source.x0)
                let height = try Checked.sub(source.y1, source.y0)
                let startX = try Checked.sub(source.x0, destination.x0)
                let startY = try Checked.sub(source.y0, destination.y0)
                guard startX >= 0, startY >= 0,
                      try Checked.add(startX, width) <= destination.width,
                      try Checked.add(startY, height) <= destination.height,
                      try Checked.mul(width, height) == source.coefficients.count else {
                    throw .invalidCodestream(.badSIZ)
                }
                // The guard bounds every row below, so copy whole rows.
                var src = 0
                var dst = startY * destination.width + startX
                for _ in 0..<height {
                    output[component].replaceSubrange(dst..<(dst + width),
                                                      with: source.coefficients[src..<(src + width)])
                    src += width
                    dst += destination.width
                }
            }
        }
        return output
    }
}
