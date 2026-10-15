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

// Ported from OpenJPEG v2.5.4: pi.c: opj_pi_create_decode, opj_get_all_encoding_parameters, opj_pi_update_decode_poc, opj_pi_update_decode_not_poc, opj_pi_next_lrcp, opj_pi_next_rlcp, opj_pi_next_rpcl, opj_pi_next_pcrl, opj_pi_next_cprl, opj_pi_next
struct PacketPosition: Equatable {
    var layer, resolution, component, precinct: Int
}

private struct PacketWindow {
    var resolutionStart, resolutionEnd: Int
    var componentStart, componentEnd: Int
    var layerEnd: Int
    var order: ProgressionOrder
}

private struct PacketGrid {
    var dx, dy: Int
    var levels: Int
    var sizes: [(x: Int, y: Int)]
}

enum PacketIterator {
    static func positions(geometry: TileGeometry, parameters: TileCodingParameters,
                          header: MainHeader, tileIndex: Int,
                          context: inout DecodeContext) throws(JP2KError) -> [PacketPosition] {
        let image = header.geometry
        let tileCount = try Checked.mul(image.tilesAcross, image.tilesDown)
        if tileIndex < 0 || tileIndex >= tileCount || geometry.components.count != image.components.count {
            throw .invalidCodestream(.badSOT)
        }
        let layers = parameters.cod.layers
        if layers < 1 { throw .invalidCodestream(.badCOD) }
        var grids: [PacketGrid] = []
        try context.budget.reserve(bytes: try Checked.mul(image.components.count, MemoryLayout<PacketGrid>.stride))
        grids.reserveCapacity(image.components.count)
        var maxResolution = 0
        var maxPrecinct = 0
        for component in image.components.indices {
            let descriptor = image.components[component]
            let coding = parameters.coc[component] ?? parameters.cod.component
            let count = try Checked.add(coding.decompositionLevels, 1)
            if count != geometry.components[component].resolutions.count || coding.precinctSizes.count < count {
                throw .invalidCodestream(.badCOD)
            }
            maxResolution = max(maxResolution, count)
            try context.budget.reserve(bytes: try Checked.mul(count, MemoryLayout<(x: Int, y: Int)>.stride))
            var sizes: [(x: Int, y: Int)] = []
            sizes.reserveCapacity(count)
            for resolution in 0..<count {
                let cell = geometry.components[component].resolutions[resolution]
                let precincts = try Checked.mul(cell.precinctsWide, cell.precinctsHigh)
                maxPrecinct = max(maxPrecinct, precincts)
                let exponent = coding.precinctSizes[resolution]
                sizes.append((exponent.ppx, exponent.ppy))
            }
            grids.append(PacketGrid(dx: descriptor.dx, dy: descriptor.dy, levels: count, sizes: sizes))
        }
        if maxResolution == 0 || maxPrecinct == 0 { return [] }
        let stepComponent = maxPrecinct
        let stepResolution = try Checked.mul(grids.count, stepComponent)
        let stepLayer = try Checked.mul(maxResolution, stepResolution)
        let includeCount = try Checked.mul(layers, stepLayer)
        // Each included packet has an output position. Reject an oversized full
        // iterator before allocating its index, while partial POC windows may fit.
        var state = PacketState(geometry: geometry, grids: grids,
                                include: try context.budget.array(repeating: UInt8.zero, count: includeCount),
                                stepComponent: stepComponent, stepResolution: stepResolution,
                                stepLayer: stepLayer, context: context)
        let windows: [PacketWindow]
        if parameters.poc.isEmpty {
            windows = [PacketWindow(resolutionStart: 0, resolutionEnd: maxResolution,
                                    componentStart: 0, componentEnd: grids.count,
                                    layerEnd: layers, order: parameters.cod.progression)]
        } else {
            try context.budget.reserve(bytes: try Checked.mul(parameters.poc.count, MemoryLayout<PacketWindow>.stride))
            windows = parameters.poc.map {
                PacketWindow(resolutionStart: min($0.resStart, maxResolution), resolutionEnd: min($0.resEnd, maxResolution),
                             componentStart: $0.compStart, componentEnd: $0.compEnd,
                             layerEnd: min($0.layerEnd, layers), order: $0.order)
            }
        }
        for window in windows {
            try state.walk(window)
        }
        context = state.context
        return state.result
    }
}

private struct PacketState {
    let geometry: TileGeometry
    let grids: [PacketGrid]
    var include: [UInt8]
    let stepComponent, stepResolution, stepLayer: Int
    var context: DecodeContext
    var result: [PacketPosition] = []
    mutating func emit(layer: Int, resolution: Int, component: Int, precinct: Int) throws(JP2KError) {
        if component < 0 || component >= grids.count { throw .invalidCodestream(.badPOC) }
        let resolutions = geometry.components[component].resolutions
        if resolution < 0 || resolution >= resolutions.count { return }
        let cell = resolutions[resolution]
        let count = try Checked.mul(cell.precinctsWide, cell.precinctsHigh)
        if precinct < 0 || precinct >= count { return }
        let index = try Checked.add(Checked.add(Checked.mul(layer, stepLayer), Checked.mul(resolution, stepResolution)),
                                    Checked.add(Checked.mul(component, stepComponent), precinct))
        if index < 0 || index >= include.count { throw .invalidCodestream(.badPOC) }
        if include[index] != 0 { return }
        try context.countPacket()
        if result.count == result.capacity {
            let oldCapacity = result.capacity
            let nextCapacity = try Checked.mul(max(1, oldCapacity), 2)
            try context.budget.reserve(bytes: try Checked.mul(nextCapacity, MemoryLayout<PacketPosition>.stride))
            result.reserveCapacity(nextCapacity)
            context.budget.release(bytes: try Checked.mul(oldCapacity, MemoryLayout<PacketPosition>.stride))
        }
        include[index] = 1
        result.append(PacketPosition(layer: layer, resolution: resolution, component: component, precinct: precinct))
    }

    mutating func walk(_ window: PacketWindow) throws(JP2KError) {
        if window.resolutionStart < 0 || window.resolutionEnd < window.resolutionStart ||
            window.componentStart < 0 || window.componentEnd > grids.count ||
            window.componentStart >= window.componentEnd || window.layerEnd < 0 {
            throw .invalidCodestream(.badPOC)
        }
        if window.resolutionStart == window.resolutionEnd || window.layerEnd == 0 { return }
        switch window.order {
        case .lrcp:
            for layer in 0..<window.layerEnd {
                for resolution in window.resolutionStart..<window.resolutionEnd {
                    for component in window.componentStart..<window.componentEnd {
                        try emitPrecincts(layer: layer, resolution: resolution, component: component)
                    }
                }
            }
        case .rlcp:
            for resolution in window.resolutionStart..<window.resolutionEnd {
                for layer in 0..<window.layerEnd {
                    for component in window.componentStart..<window.componentEnd {
                        try emitPrecincts(layer: layer, resolution: resolution, component: component)
                    }
                }
            }
        case .rpcl, .pcrl, .cprl:
            try walkSpatial(window)
        }
    }

    mutating func emitPrecincts(layer: Int, resolution: Int, component: Int) throws(JP2KError) {
        if resolution >= geometry.components[component].resolutions.count { return }
        let cell = geometry.components[component].resolutions[resolution]
        let count = try Checked.mul(cell.precinctsWide, cell.precinctsHigh)
        for precinct in 0..<count {
            try context.countPacketWork()
            try emit(layer: layer, resolution: resolution, component: component, precinct: precinct)
        }
    }

    private func steps(component: Int) throws(JP2KError) -> (Int, Int) {
        let grid = grids[component]
        var minimumX = 0
        var minimumY = 0
        for resolution in 0..<grid.levels {
            let level = try Checked.sub(try Checked.sub(grid.levels, 1), resolution)
            let sizes = grid.sizes[resolution]
            let xShift = try Checked.add(sizes.x, level)
            let yShift = try Checked.add(sizes.y, level)
            if xShift < 32 && grid.dx <= Int(UInt32.max) >> xShift {
                let step = try Checked.shiftLeft(grid.dx, xShift)
                minimumX = minimumX == 0 ? step : min(minimumX, step)
            }
            if yShift < 32 && grid.dy <= Int(UInt32.max) >> yShift {
                let step = try Checked.shiftLeft(grid.dy, yShift)
                minimumY = minimumY == 0 ? step : min(minimumY, step)
            }
        }
        return (minimumX, minimumY)
    }

    mutating func walkSpatial(_ window: PacketWindow) throws(JP2KError) {
        if window.order == .cprl {
            for component in window.componentStart..<window.componentEnd {
                let (dx, dy) = try steps(component: component)
                try scan(window, dx: dx, dy: dy, fixedComponent: component, fixedResolution: nil)
            }
        } else {
            var dx = 0
            var dy = 0
            for component in grids.indices {
                let step = try steps(component: component)
                if step.0 > 0 { dx = dx == 0 ? step.0 : min(dx, step.0) }
                if step.1 > 0 { dy = dy == 0 ? step.1 : min(dy, step.1) }
            }
            if window.order == .rpcl {
                for resolution in window.resolutionStart..<window.resolutionEnd {
                    try scan(window, dx: dx, dy: dy, fixedComponent: nil, fixedResolution: resolution)
                }
            } else {
                try scan(window, dx: dx, dy: dy, fixedComponent: nil, fixedResolution: nil)
            }
        }
    }

    mutating func scan(_ window: PacketWindow, dx: Int, dy: Int,
                       fixedComponent: Int?, fixedResolution: Int?) throws(JP2KError) {
        if dx == 0 || dy == 0 { return }
        var y = geometry.y0
        while y < geometry.y1 {
            var x = geometry.x0
            while x < geometry.x1 {
                let components: Range<Int>
                if let fixedComponent {
                    components = fixedComponent..<(try Checked.add(fixedComponent, 1))
                } else {
                    components = window.componentStart..<window.componentEnd
                }
                for component in components {
                    let resolutions: Range<Int>
                    if let fixedResolution {
                        resolutions = fixedResolution..<(try Checked.add(fixedResolution, 1))
                    } else {
                        resolutions = window.resolutionStart..<window.resolutionEnd
                    }
                    for resolution in resolutions {
                        try context.countPacketWork()
                        if let precinct = try precinct(x: x, y: y, component: component, resolution: resolution) {
                            for layer in 0..<window.layerEnd {
                                try emit(layer: layer, resolution: resolution, component: component, precinct: precinct)
                            }
                        }
                    }
                }
                x = try Checked.add(x, try Checked.sub(dx, x % dx))
            }
            y = try Checked.add(y, try Checked.sub(dy, y % dy))
        }
    }

    private func precinct(x: Int, y: Int, component: Int,
                          resolution: Int) throws(JP2KError) -> Int? {
        let grid = grids[component]
        if resolution >= grid.levels { return nil }
        let level = try Checked.sub(try Checked.sub(grid.levels, 1), resolution)
        let cell = geometry.components[component].resolutions[resolution]
        if cell.precinctsWide == 0 || cell.precinctsHigh == 0 || cell.x0 == cell.x1 || cell.y0 == cell.y1 { return nil }
        let exponent = grid.sizes[resolution]
        let rpx = try Checked.add(exponent.x, level)
        let rpy = try Checked.add(exponent.y, level)
        if x < 0 || y < 0 { throw .invalidCodestream(.badSIZ) }
        // The scan step is bounded to UInt32, but these precinct alignment
        // expressions in OpenJPEG use UInt64 and may have shifts above 31.
        let sx = try shifted64(grid.dx, by: rpx)
        let sy = try shifted64(grid.dy, by: rpy)
        let rx0 = try Checked.ceilDiv(geometry.x0, Checked.shiftLeft(grid.dx, level))
        let ry0 = try Checked.ceilDiv(geometry.y0, Checked.shiftLeft(grid.dy, level))
        let firstX = try shifted64(rx0, by: level) % shifted64(1, by: rpx)
        let firstY = try shifted64(ry0, by: level) % shifted64(1, by: rpy)
        if UInt64(y) % sy != 0 && !(y == geometry.y0 && firstY != 0) { return nil }
        if UInt64(x) % sx != 0 && !(x == geometry.x0 && firstX != 0) { return nil }
        let px = try Checked.sub(Checked.floorDivPow2(Checked.ceilDiv(x, Checked.shiftLeft(grid.dx, level)), exponent.x),
                                 Checked.floorDivPow2(rx0, exponent.x))
        let py = try Checked.sub(Checked.floorDivPow2(Checked.ceilDiv(y, Checked.shiftLeft(grid.dy, level)), exponent.y),
                                 Checked.floorDivPow2(ry0, exponent.y))
        if px < 0 || py < 0 || px >= cell.precinctsWide || py >= cell.precinctsHigh { return nil }
        return try Checked.add(px, Checked.mul(py, cell.precinctsWide))
    }

    private func shifted64(_ value: Int, by shift: Int) throws(JP2KError) -> UInt64 {
        if value < 0 || shift < 0 || shift >= UInt64.bitWidth {
            throw .invalidCodestream(.arithmeticOverflow)
        }
        let (result, overflow) = UInt64(value).multipliedReportingOverflow(by: UInt64(1) << shift)
        if overflow { throw .invalidCodestream(.arithmeticOverflow) }
        return result
    }
}
