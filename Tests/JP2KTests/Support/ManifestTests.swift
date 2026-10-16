import Foundation
import Testing

struct ManifestTests {
    @Test func matchesEveryFixture() throws {
        guard let manifestURL = Fixtures.url("MANIFEST.sha256") else {
            Issue.record("Fixture directory unavailable")
            return
        }
        let manifest = try String(contentsOf: manifestURL, encoding: .utf8)
        var listed: Set<String> = []
        for line in manifest.split(separator: "\n") {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            try #require(parts.count == 2)
            let name = String(parts[1])
            listed.insert(name)
            let url = try #require(Fixtures.url(name))
            let actual = SHA256.hex(Array(try Data(contentsOf: url)))
            #expect(actual == parts[0], "Checksum mismatch: \(name)")
        }
        let directory = manifestURL.deletingLastPathComponent()
        let entries = try #require(FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey]))
        var files: Set<String> = []
        for case let url as URL in entries {
            guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { continue }
            let name = String(url.path.dropFirst(directory.path.count + 1))
            if name != "MANIFEST.sha256" { files.insert(name) }
        }
        #expect(listed == files)
        #expect(!listed.isEmpty)
    }
}
