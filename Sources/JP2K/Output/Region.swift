enum RegionResolver {
    static func resolve(_ region: Region?, width: Int, height: Int) throws(JP2KError) -> (Int, Int, Int, Int) {
        guard let region else { return (0, 0, width, height) }
        switch region {
        case .pixels(let x, let y, let w, let h):
            if x < 0 || y < 0 || w < 1 || h < 1 || x > width || y > height ||
                w > width - x || h > height - y { throw .regionOutOfBounds }
            return (x, y, w, h)
        case .fraction(let l, let t, let r, let b):
            if !l.isFinite || !t.isFinite || !r.isFinite || !b.isFinite ||
                l < 0 || t < 0 || r > 1 || b > 1 || l >= r || t >= b { throw .regionOutOfBounds }
            let x = Int((l * Double(width)).rounded(.down))
            let y = Int((t * Double(height)).rounded(.down))
            let right = Int((r * Double(width)).rounded(.up))
            let bottom = Int((b * Double(height)).rounded(.up))
            if x >= right || y >= bottom { throw .regionOutOfBounds }
            return (x, y, right - x, bottom - y)
        }
    }
}
