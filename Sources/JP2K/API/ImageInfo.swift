public enum ColorSpace: Sendable, Equatable {
    case sRGB, grayscale, sYCC, icc, other(UInt32), unspecified
}

public struct ComponentInfo: Sendable, Equatable {
    public let x0, y0: Int
    public let width, height: Int
    public let dx, dy: Int
    public let precision: Int
    public let isSigned: Bool
}

public struct ImageInfo: Sendable {
    public let width, height: Int
    public let components: [ComponentInfo]
    public let colorSpace: ColorSpace
    public let isJP2Container: Bool
}
