import Foundation
import Testing

struct FixturesTests {
    @Test func environmentOverride() {
        let directory = "/data/local/tmp/fixture-override"
        let url = Fixtures.url("sample.jp2", environment: ["JP2K_FIXTURES_DIR": directory])
        #expect(url == URL(fileURLWithPath: directory, isDirectory: true)
            .appendingPathComponent("sample.jp2"))
    }

    // Android runs have no resource bundle; they always use the override.
    #if !os(Android)
    @Test func bundledFixtureWhenOverrideUnset() {
        #expect(Fixtures.url("sample.jp2", environment: [:]) == Bundle.module.resourceURL?
            .appendingPathComponent("Fixtures", isDirectory: true)
            .appendingPathComponent("sample.jp2"))
    }
    #endif
}
