/// Decoded codestream components at their native precision.
public struct ComponentImage: Sendable {
    public let info: ImageInfo
    public let components: [[Int32]]
    public let iccProfile: [UInt8]?
}
