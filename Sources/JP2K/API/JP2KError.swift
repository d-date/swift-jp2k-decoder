/// Errors returned by decoding and output operations.
public enum JP2KError: Error, Sendable, Equatable {
    case inputSize
    case invalidContainer(Reason)
    case invalidCodestream(Reason)
    case limitExceeded(Limit)
    case unsupported(Feature)
    case regionOutOfBounds

    public struct Reason: RawRepresentable, Hashable, Sendable {
        public let rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }

        public static let truncated = Self(rawValue: "truncated")
        public static let arithmeticOverflow = Self(rawValue: "arithmeticOverflow")
        public static let badSignature = Self(rawValue: "badSignature")
        public static let badFileType = Self(rawValue: "badFileType")
        public static let badBoxLength = Self(rawValue: "badBoxLength")
        public static let missingHeaderBox = Self(rawValue: "missingHeaderBox")
        public static let missingImageHeader = Self(rawValue: "missingImageHeader")
        public static let missingCodestream = Self(rawValue: "missingCodestream")
        public static let duplicateBox = Self(rawValue: "duplicateBox")
        public static let headerMismatch = Self(rawValue: "headerMismatch")
        public static let badColourSpecification = Self(rawValue: "badColourSpecification")
        public static let badPalette = Self(rawValue: "badPalette")
        public static let badComponentMapping = Self(rawValue: "badComponentMapping")
        public static let badChannelDefinition = Self(rawValue: "badChannelDefinition")
        public static let missingSOC = Self(rawValue: "missingSOC")
        public static let missingSIZ = Self(rawValue: "missingSIZ")
        public static let badMarker = Self(rawValue: "badMarker")
        public static let unexpectedMarker = Self(rawValue: "unexpectedMarker")
        public static let badMarkerLength = Self(rawValue: "badMarkerLength")
        public static let badSIZ = Self(rawValue: "badSIZ")
        public static let badCOD = Self(rawValue: "badCOD")
        public static let badCOC = Self(rawValue: "badCOC")
        public static let badQCD = Self(rawValue: "badQCD")
        public static let badQCC = Self(rawValue: "badQCC")
        public static let badRGN = Self(rawValue: "badRGN")
        public static let badPOC = Self(rawValue: "badPOC")
        public static let badSOT = Self(rawValue: "badSOT")
        public static let badTilePart = Self(rawValue: "badTilePart")
        public static let badPPM = Self(rawValue: "badPPM")
        public static let badPPT = Self(rawValue: "badPPT")
        public static let badPacketHeader = Self(rawValue: "badPacketHeader")
        public static let badCodeBlock = Self(rawValue: "badCodeBlock")
        public static let missingEOC = Self(rawValue: "missingEOC")
        public static let specRange = Self(rawValue: "specRange")
    }

    public struct Limit: RawRepresentable, Hashable, Sendable {
        public let rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }

        public static let inputBytes = Self(rawValue: "inputBytes")
        public static let pixels = Self(rawValue: "pixels")
        public static let components = Self(rawValue: "components")
        public static let bitDepth = Self(rawValue: "bitDepth")
        public static let tiles = Self(rawValue: "tiles")
        public static let tileParts = Self(rawValue: "tileParts")
        public static let layers = Self(rawValue: "layers")
        public static let memory = Self(rawValue: "memory")
        public static let packets = Self(rawValue: "packets")
        public static let packetIteration = Self(rawValue: "packetIteration")
        public static let codingPasses = Self(rawValue: "codingPasses")
        public static let markerData = Self(rawValue: "markerData")
    }

    public struct Feature: RawRepresentable, Hashable, Sendable {
        public let rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }

        public static let part2 = Self(rawValue: "part2")
        public static let htj2k = Self(rawValue: "htj2k")
        public static let bitDepthAbove16 = Self(rawValue: "bitDepthAbove16")
        public static let colourSpace = Self(rawValue: "colourSpace")
        public static let iccProfile = Self(rawValue: "iccProfile")
        public static let unspecifiedColour = Self(rawValue: "unspecifiedColour")
        public static let componentCount = Self(rawValue: "componentCount")
    }
}
