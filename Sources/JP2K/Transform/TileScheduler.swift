/// Decodes the tiles of a multi-tile image concurrently. Tier-2 runs first
/// for every tile, in order, on the decode budget exactly as the serial loop
/// runs it; reconstruction, which dominates the cost, then runs as one child
/// task per tile, at most `workers` at once, started in tile order. Each
/// child writes fresh coefficient planes inside a budget share reserved up
/// front, and the planes are moved into the geometry as children finish.
///
/// The serial loop never charges more than all tiles' geometry plus one
/// tile's reconstruction, which is below what this path holds while its
/// shares are reserved, so once they are reserved the serial loop could not
/// have run out of memory either. Whenever that argument does not cover an
/// outcome (the shares do not fit, a child outgrows its share, or a plane
/// cannot be moved onto the decode budget) `decode` returns nil and the
/// caller restarts the tile loop serially from its saved state. Success and
/// the reported error therefore never depend on the thread count.
enum TileScheduler {
    private struct TileResult: Sendable {
        let tile: Int
        var planes: [[Int32]] = []
        var error: JP2KError?
    }

    static func decode(_ tileParts: [TileData], header: MainHeader,
                       context: inout DecodeContext) async throws(JP2KError) -> [TileGeometry]? {
        var tiles: [TileGeometry] = []
        tiles.reserveCapacity(tileParts.count)
        // The serial loop would reach a Tier-2 failure only after
        // reconstructing every earlier tile; it is raised after those.
        var prepareFailure: JP2KError?
        for tile in tileParts {
            do {
                tiles.append(try TileDecoder.prepare(tile, header: header, context: &context))
            } catch {
                prepareFailure = error
                break
            }
        }
        if tiles.isEmpty, let prepareFailure { throw prepareFailure }
        let workers = min(context.limits.maxThreads, tiles.count)
        guard workers > 1 else { return nil }

        var largest = 0
        for index in tiles.indices {
            let bytes = try Checked.add(TileDecoder.reconstructionBytes(tileParts[index], geometry: tiles[index]),
                                        viewBytes(components: tiles[index].components.count))
            largest = max(largest, bytes)
        }
        let share = largest
        let pool = try Checked.mul(share, workers)
        do {
            try context.budget.reserve(bytes: pool)
        } catch {
            return nil
        }
        defer { context.budget.release(bytes: pool) }

        // One level of fan-out: a reconstructed tile decodes its code-blocks
        // on its own thread.
        var childLimits = context.limits
        childLimits.maxThreads = 1
        let limits = childLimits
        var failure: (tile: Int, error: JP2KError)?
        var memoryTile: Int?
        await withTaskGroup(of: TileResult.self) { group in
            var next = 0
            func start(_ index: Int) {
                let tile = tileParts[index]
                // The child reads the geometry but never its planes; it gets a
                // copy without them so the planes stay uniquely owned here.
                // The copied component list and the sizes are charged to the
                // child's share (viewBytes).
                var view = tiles[index]
                var counts: [Int] = []
                counts.reserveCapacity(view.components.count)
                for component in view.components.indices {
                    counts.append(view.components[component].coefficients.count)
                    view.components[component].coefficients = []
                }
                let geometry = view
                let sizes = counts
                group.addTask {
                    await reconstruct(tile, index: index, header: header, geometry: geometry,
                                      sizes: sizes, limits: limits, share: share)
                }
            }
            while next < workers {
                start(next)
                next += 1
            }
            for await result in group {
                if let error = result.error {
                    if error == .limitExceeded(.memory) {
                        memoryTile = min(memoryTile ?? Int.max, result.tile)
                    } else if result.tile < (failure?.tile ?? Int.max) {
                        failure = (result.tile, error)
                    }
                } else if !install(result.planes, into: &tiles[result.tile], budget: &context.budget) {
                    memoryTile = min(memoryTile ?? Int.max, result.tile)
                }
                // Tiles start in order and a failure stops new starts, so
                // every tile below the lowest failure has been reconstructed.
                if failure == nil && memoryTile == nil && next < tiles.count {
                    start(next)
                    next += 1
                }
            }
        }
        if let memoryTile, memoryTile < (failure?.tile ?? Int.max) { return nil }
        if let failure { throw failure.error }
        if let prepareFailure { throw prepareFailure }
        context.countParallelRun()
        return tiles
    }

    /// Body of one child task.
    private static func reconstruct(_ tile: TileData, index: Int, header: MainHeader, geometry: TileGeometry,
                                    sizes: [Int], limits: Limits, share: Int) async -> TileResult {
        var context = DecodeContext(limits: limits)
        context.budget = MemoryBudget(limit: share)
        do throws(JP2KError) {
            try context.budget.reserve(bytes: viewBytes(components: sizes.count))
            var planes = try context.budget.array(repeating: [Int32](), count: sizes.count)
            for component in sizes.indices {
                planes[component] = try context.budget.array(repeating: Int32.zero, count: sizes[component])
            }
            try await TileDecoder.reconstruct(tile, header: header, geometry: geometry,
                                              planes: &planes, context: &context)
            return TileResult(tile: index, planes: planes)
        } catch {
            return TileResult(tile: index, error: error)
        }
    }

    /// What a child's geometry copy adds: its own component list (stripping
    /// the planes copies the shared one) and the list of plane sizes.
    private static func viewBytes(components: Int) throws(JP2KError) -> Int {
        try Checked.add(CodeBlockScheduler.rounded(Checked.mul(components, MemoryLayout<TileComponent>.stride)),
                        CodeBlockScheduler.rounded(Checked.mul(components, MemoryLayout<Int>.stride)))
    }

    /// Moves a child's planes into the tile, moving their charge from the
    /// child's share onto the decode budget in place of the planes they
    /// replace. False when the budget cannot take them (allocator rounding
    /// can differ between the two allocations).
    private static func install(_ planes: [[Int32]], into geometry: inout TileGeometry,
                                budget: inout MemoryBudget) -> Bool {
        guard planes.count == geometry.components.count else { return false }
        for component in planes.indices {
            let old = geometry.components[component].coefficients.capacity * MemoryLayout<Int32>.stride
            let new = planes[component].capacity * MemoryLayout<Int32>.stride
            geometry.components[component].coefficients = planes[component]
            budget.release(bytes: old)
            do {
                try budget.reserve(bytes: new)
            } catch {
                return false
            }
        }
        return true
    }
}
