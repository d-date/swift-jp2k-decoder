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
    // Measured across 36 generated fixtures and 43 OpenJPEG conformance streams:
    // at most 257 tile-parts, 20 layers, 26,472 packets, 50,784 packet
    // iterations, 214,473 coding passes, and 99,793 retained marker bytes.
    // Each default is at least four times its observed maximum, rounded up
    // to a power of two. Tile-parts also cover 4,096 tiles x 8 layers =
    // 32,768 parts. The observed memory peak was 195,855,892 bytes.
    // For a 4,000x4,000, four-component, eight-layer, five-level image with
    // 64x64 precincts and code blocks, the six resolution grids have
    // 4 + 16 + 64 + 256 + 1,024 + 3,969 = 5,333 precincts per component.
    // Packets: 5,333 x 4 x 8 = 170,656, rounded up to 262,144.
    // Code blocks per component: 4 LL + 3 x (16 + 64 + 256 + 1,024 +
    // 3,969) high-band blocks = 15,991. At 109 passes per block, the
    // worst case is 15,991 x 4 x 109 = 6,972,076 passes, rounded up to
    // 8,388,608. Packet iterations allow 16 x 262,144 = 4,194,304.
    public var maxTileParts: Int = 32_768
    public var maxLayers: Int = 128
    public var maxMemoryBytes: Int = 512 << 20
    public var maxPackets: Int = 262_144
    // Scan steps are cheap but can far exceed emitted packets in spatial
    // orders with subsampled components, so this is 16 x maxPackets.
    public var maxPacketIterations: Int = 4_194_304
    public var maxCodingPasses: Int = 8_388_608
    public var maxMarkerDataBytes: Int = 8 << 20
    /// Upper bound on workers used for Tier-1 decoding of one tile component;
    /// 1 decodes serially. Output and errors are identical for every value.
    /// Workers run through Dispatch, which runs no more of them at once than
    /// there are available cores. Worker scratch comes out of
    /// `maxMemoryBytes`; when it does not fit, decoding falls back to one
    /// thread instead of failing.
    public var maxThreads: Int = 8
    /// Tiles with fewer coded samples stay on one thread, where start-up
    /// would cost more than it saves. Internal so tests can force either path.
    var parallelSampleThreshold = 32_768

    public init() {}
}
