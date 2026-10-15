/// Caller-configurable resource limits applied during decoding.
public struct Limits: Sendable, Equatable {
    public var maxInputBytes: Int = 32 << 20
    public var maxPixels: Int = 16_000_000
    public var maxComponents: Int = 4
    /// Precision above 16 remains unsupported.
    public var maxBitDepth: Int = 16 {
        didSet {
            if maxBitDepth > 16 { maxBitDepth = 16 }
        }
    }
    public var maxTiles: Int = 4_096
    public var maxTileParts: Int = 16_384
    public var maxLayers: Int = 64
    public var maxMemoryBytes: Int = 512 << 20
    public var maxPackets: Int = 1_000_000
    public var maxCodingPasses: Int = 4_000_000
    public var maxMarkerDataBytes: Int = 8 << 20

    public init() {}
}
