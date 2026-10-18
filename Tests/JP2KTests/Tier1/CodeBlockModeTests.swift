import Foundation
import Testing
@testable import JP2K

@Test(.enabled(if: Conformance.root() != nil),
      arguments: ["p0_02.j2k", "p1_01.j2k", "p1_02.j2k", "p1_03.j2k",
                  "p1_05.j2k", "c2_mono.j2c"])
func codeBlockModeConformance(_ name: String) async throws {
    let root = try #require(Conformance.root())
    let url = root.appendingPathComponent("input/conformance").appendingPathComponent(name)
    let bytes = Array(try Data(contentsOf: url))
    var limits = Limits()
    limits.maxComponents = 16_384
    limits.maxPixels = 1 << 26
    limits.maxMemoryBytes = 2 << 30
    let image = try await JP2KDecoder(limits: limits).decodeComponents(bytes)
    #expect(!image.components.isEmpty)
}
