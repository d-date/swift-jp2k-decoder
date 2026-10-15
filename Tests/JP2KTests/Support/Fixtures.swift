import Foundation

enum Fixtures {
    /// Locates a fixture file. `JP2K_FIXTURES_DIR` wins so that platforms
    /// without resource bundles (Android test runs on a device) can point at
    /// a pushed copy of `Tests/JP2KTests/Fixtures`.
    static func url(
        _ name: String,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL? {
        if let directory = environment["JP2K_FIXTURES_DIR"], !directory.isEmpty {
            return URL(fileURLWithPath: directory, isDirectory: true)
                .appendingPathComponent(name)
        }
        return Bundle.module.resourceURL?
            .appendingPathComponent("Fixtures", isDirectory: true)
            .appendingPathComponent(name)
    }
}
