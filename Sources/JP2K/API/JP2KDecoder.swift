/// A decoder entry point.
public struct JP2KDecoder: Sendable {
    public var limits: Limits

    public init(limits: Limits = Limits()) { self.limits = limits }

    public func readInfo(_ bytes: Span<UInt8>) throws(JP2KError) -> ImageInfo {
        if bytes.count < 12 { throw .inputSize }
        if bytes.count > limits.maxInputBytes { throw .limitExceeded(.inputBytes) }
        var context = DecodeContext(limits: limits)
        try context.budget.reserve(bytes: bytes.count)
        var input: [UInt8] = []
        input.reserveCapacity(bytes.count)
        for index in 0..<bytes.count { input.append(bytes[index]) }
        return try readInfoArray(input, context: &context)
    }

    private func readInfoArray(_ input: [UInt8], context: inout DecodeContext) throws(JP2KError) -> ImageInfo {
        try parseInfoArray(input, context: &context).0
    }

    private func parseInfoArray(_ input: [UInt8], context: inout DecodeContext) throws(JP2KError) -> (ImageInfo, MainHeader, JP2File?) {
        let format = try FormatDetector.detect(input)
        let file: JP2File?
        let range: Range<Int>
        switch format {
        case .jp2:
            let parsed = try JP2Parser.parse(input, context: &context)
            file = parsed
            range = parsed.codestream
        case .codestream:
            file = nil
            range = 0..<input.count
        }
        let header = try MainHeaderParser.parse(input, range: range, context: &context)
        let geometry = header.geometry
        let width = try Checked.sub(geometry.x1, geometry.x0)
        let height = try Checked.sub(geometry.y1, geometry.y0)
        if let file {
            let image = file.header.imageHeader
            if image.width != width || image.height != height || image.nc != geometry.components.count {
                throw .invalidContainer(.headerMismatch)
            }
            for index in geometry.components.indices {
                let component = geometry.components[index]
                let descriptor = UInt8(component.precision - 1) | (component.isSigned ? 0x80 : 0)
                if image.bpc == 255 {
                    guard let bpcc = file.header.bitsPerComponent, index < bpcc.count, bpcc[index] == descriptor else {
                        throw .invalidContainer(.headerMismatch)
                    }
                } else if image.bpc != descriptor { throw .invalidContainer(.headerMismatch) }
            }
        }
        try context.budget.reserve(bytes: try Checked.mul(geometry.components.count, MemoryLayout<ComponentInfo>.stride))
        var components: [ComponentInfo] = []
        components.reserveCapacity(geometry.components.count)
        for component in geometry.components {
            let x0 = try Checked.ceilDiv(geometry.x0, component.dx)
            let y0 = try Checked.ceilDiv(geometry.y0, component.dy)
            let x1 = try Checked.ceilDiv(geometry.x1, component.dx)
            let y1 = try Checked.ceilDiv(geometry.y1, component.dy)
            components.append(ComponentInfo(x0: x0, y0: y0, width: try Checked.sub(x1, x0),
                                            height: try Checked.sub(y1, y0), dx: component.dx,
                                            dy: component.dy, precision: component.precision,
                                            isSigned: component.isSigned))
        }
        let color: ColorSpace
        if let file {
            switch file.header.colour {
            case .enumerated(16): color = .sRGB
            case .enumerated(17): color = .grayscale
            case .enumerated(18): color = .sYCC
            case .enumerated(let value): color = .other(value)
            case .restrictedICC: color = .icc
            case .other: color = .unspecified
            }
        } else { color = .unspecified }
        let info = ImageInfo(width: width, height: height, components: components,
                             colorSpace: color, isJP2Container: file != nil)
        return (info, header, file)
    }

    public func readInfo(_ bytes: [UInt8]) throws(JP2KError) -> ImageInfo {
        if bytes.count < 12 { throw .inputSize }
        if bytes.count > limits.maxInputBytes { throw .limitExceeded(.inputBytes) }
        var context = DecodeContext(limits: limits)
        try context.budget.reserve(bytes: bytes.count)
        return try readInfoArray(bytes, context: &context)
    }

    /// Decodes every codestream component at its native precision.
    @concurrent
    public func decodeComponents(_ bytes: Span<UInt8>) async throws(JP2KError) -> ComponentImage {
        if bytes.count < 12 { throw .inputSize }
        if bytes.count > limits.maxInputBytes { throw .limitExceeded(.inputBytes) }
        var context = DecodeContext(limits: limits)
        try context.budget.reserve(bytes: bytes.count)
        var input: [UInt8] = []
        input.reserveCapacity(bytes.count)
        for index in 0..<bytes.count { input.append(bytes[index]) }
        return try await decodeComponentsArray(input, context: &context)
    }

    /// Decodes every codestream component at its native precision.
    @concurrent
    public func decodeComponents(_ bytes: [UInt8]) async throws(JP2KError) -> ComponentImage {
        if bytes.count < 12 { throw .inputSize }
        if bytes.count > limits.maxInputBytes { throw .limitExceeded(.inputBytes) }
        var context = DecodeContext(limits: limits)
        try context.budget.reserve(bytes: bytes.count)
        return try await decodeComponentsArray(bytes, context: &context)
    }

    private func decodeComponentsArray(_ input: [UInt8], context: inout DecodeContext) async throws(JP2KError) -> ComponentImage {
        let (info, _, file, components) = try await decodeTileComponents(input, context: &context)
        let profile: [UInt8]?
        if let file, case .restrictedICC(let bytes) = file.header.colour { profile = bytes } else { profile = nil }
        return ComponentImage(info: info, components: components, iccProfile: profile)
    }

    func decodeComponentsWithMetrics(_ bytes: [UInt8]) async throws(JP2KError) -> (ComponentImage, DecodeMetrics) {
        if bytes.count < 12 { throw .inputSize }
        if bytes.count > limits.maxInputBytes { throw .limitExceeded(.inputBytes) }
        var context = DecodeContext(limits: limits)
        try context.budget.reserve(bytes: bytes.count)
        let image = try await decodeComponentsArray(bytes, context: &context)
        return (image, DecodeMetrics(packets: context.packets, packetWork: context.packetWork,
                                     codingPasses: context.codingPasses, markerDataBytes: context.markerDataBytes,
                                     peakMemoryBytes: context.budget.peak, parallelRuns: context.parallelRuns))
    }

    /// Decodes to eight-bit interleaved pixels.
    @concurrent
    public func decodePixels(_ bytes: Span<UInt8>, color: ColorInterpretation = .container,
                             region: Region? = nil) async throws(JP2KError) -> PixelImage {
        if bytes.count < 12 { throw .inputSize }
        if bytes.count > limits.maxInputBytes { throw .limitExceeded(.inputBytes) }
        var context = DecodeContext(limits: limits)
        try context.budget.reserve(bytes: bytes.count)
        var input: [UInt8] = []
        input.reserveCapacity(bytes.count)
        for index in 0..<bytes.count { input.append(bytes[index]) }
        return try await decodePixelsArray(input, color: color, region: region, context: &context)
    }

    /// Decodes to eight-bit interleaved pixels.
    @concurrent
    public func decodePixels(_ bytes: [UInt8], color: ColorInterpretation = .container,
                             region: Region? = nil) async throws(JP2KError) -> PixelImage {
        if bytes.count < 12 { throw .inputSize }
        if bytes.count > limits.maxInputBytes { throw .limitExceeded(.inputBytes) }
        var context = DecodeContext(limits: limits)
        try context.budget.reserve(bytes: bytes.count)
        return try await decodePixelsArray(bytes, color: color, region: region, context: &context)
    }

    private func decodePixelsArray(_ input: [UInt8], color: ColorInterpretation, region: Region?,
                                   context: inout DecodeContext) async throws(JP2KError) -> PixelImage {
        let (info, header, file, components) = try await decodeTileComponents(input, context: &context)
        let image = ComponentImage(info: info, components: components, iccProfile: nil)
        return try ColorConverter.convert(image, header: file?.header, color: color, region: region,
                                          referenceOrigin: (header.geometry.x0, header.geometry.y0), context: &context)
    }

    private func decodeTileComponents(_ input: [UInt8], context: inout DecodeContext)
        async throws(JP2KError) -> (ImageInfo, MainHeader, JP2File?, [[Int32]]) {
        let (info, header, file) = try parseInfoArray(input, context: &context)
        let tileParts = try TilePartParser.parse(input, header: header, context: &context)
        try context.budget.reserve(bytes: try Checked.mul(tileParts.count, MemoryLayout<TileGeometry>.stride))
        var tiles: [TileGeometry] = []
        tiles.reserveCapacity(tileParts.count)
        for tile in tileParts { tiles.append(try await TileDecoder.decode(tile, header: header, context: &context)) }
        let components = try ComponentAssembler.assemble(tiles, info: info, context: &context)
        return (info, header, file, components)
    }

}

struct DecodeMetrics {
    let packets: Int
    let packetWork: Int
    let codingPasses: Int
    let markerDataBytes: Int
    let peakMemoryBytes: Int
    let parallelRuns: Int
}
