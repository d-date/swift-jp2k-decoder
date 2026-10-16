import Foundation
import Testing
@testable import JP2K

@Test(arguments: ["bypass", "reset", "termall", "vcausal", "pterm", "segsym", "all"])
func codeBlockModePixels(_ mode: String) throws {
    let stem = "modes-\(mode)"
    let input = Array(try Data(contentsOf: #require(Fixtures.url("\(stem).j2k"))))
    let pgx = try PGX.parse(Array(Data(contentsOf: #require(Fixtures.url("\(stem)_0.pgx")))))
    let image = try JP2KDecoder().decodeComponents(input)
    #expect(image.components.count == 1)
    #expect(image.components[0] == pgx.samples)
}

@Test(.enabled(if: Conformance.root() != nil),
      arguments: ["p0_02.j2k", "p1_01.j2k", "p1_02.j2k", "p1_03.j2k",
                  "p1_05.j2k", "c2_mono.j2c"])
func codeBlockModeConformance(_ name: String) throws {
    let root = try #require(Conformance.root())
    let url = root.appendingPathComponent("input/conformance").appendingPathComponent(name)
    let bytes = Array(try Data(contentsOf: url))
    var limits = Limits()
    limits.maxComponents = 16_384
    limits.maxPixels = 1 << 26
    limits.maxMemoryBytes = 2 << 30
    let image = try JP2KDecoder(limits: limits).decodeComponents(bytes)
    #expect(!image.components.isEmpty)
}
