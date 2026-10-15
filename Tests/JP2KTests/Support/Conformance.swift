import Foundation

struct ConformanceCase: Equatable {
    let name: String
    let referenceStem: String
    let componentCount: Int
    let resFactor: Int
    let peak: [Double]
    let mse: [Double]
}

enum Conformance {
    static let class1 = ConformanceTable.class1

    static func root(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL? {
        guard let path = environment["JP2K_CONFORMANCE_DIR"], !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    static func sourceURL(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL? {
        if let path = environment["OPJ_SRC"], !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true)
                .appendingPathComponent("tests/conformance/CMakeLists.txt")
        }
        #if os(Android)
        return nil
        #else
        return URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".reference/openjpeg/tests/conformance/CMakeLists.txt")
        #endif
    }

    static func availableCases(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [ConformanceCase] {
        guard root(environment: environment) != nil else { return [] }
        return class1
    }

    static func inputURL(_ item: ConformanceCase, root: URL) -> URL {
        root.appendingPathComponent("input/conformance").appendingPathComponent(item.name)
    }

    static func referenceURL(_ item: ConformanceCase, component: Int, root: URL) -> URL {
        root.appendingPathComponent("baseline/conformance")
            .appendingPathComponent("\(item.referenceStem)_\(component).pgx")
    }

    static func skippedReducedResolution(_ cases: [ConformanceCase]) -> [String] {
        cases.filter { $0.resFactor != 0 }.map(\.name)
    }

    struct MissingFile: Error {
        let path: String
    }

    static func requireFiles(root: URL, cases: [ConformanceCase]) throws {
        for item in cases where item.resFactor == 0 {
            let input = inputURL(item, root: root)
            guard FileManager.default.fileExists(atPath: input.path) else {
                throw MissingFile(path: input.path)
            }
            for component in 0..<item.componentCount {
                let reference = referenceURL(item, component: component, root: root)
                guard FileManager.default.fileExists(atPath: reference.path) else {
                    throw MissingFile(path: reference.path)
                }
            }
        }
    }

    static func parse(_ cmake: String) throws -> [ConformanceCase] {
        var tables: [String: [String]] = [:]
        for line in cmake.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("set("), let close = trimmed.firstIndex(of: ")"),
                  let quote = trimmed.firstIndex(of: "\"") else { continue }
            let key = trimmed[trimmed.index(trimmed.startIndex, offsetBy: 4)..<quote]
                .trimmingCharacters(in: .whitespaces)
            let value = trimmed[trimmed.index(after: quote)..<close].replacingOccurrences(of: "\"", with: "")
            tables[key] = value.split(separator: ";").map(String.init)
        }
        func table(_ key: String, _ index: Int) throws -> String {
            guard let values = tables[key], values.indices.contains(index) else { throw ParseError.missingTable(key) }
            return values[index]
        }
        func doubles(_ value: String) throws -> [Double] {
            let values = value.split(separator: ":").compactMap { Double($0) }
            guard !values.isEmpty else { throw ParseError.invalidValue(value) }
            return values
        }
        var result: [ConformanceCase] = []
        for profile in 0...1 {
            for index in 1...(profile == 0 ? 16 : 7) {
                let prefix = profile == 0 ? "C1P0" : "C1P1"
                let number = String(format: "%02d", index)
                let count = try Int(table(profile == 0 ? "CP0_nbC_list" : "CP1_nbC_list", index))
                let resFactor = profile == 0 ? try Int(table("C1P0_ResFactor_list", index)) : 0
                guard let count, let resFactor else { throw ParseError.invalidValue(number) }
                result.append(ConformanceCase(
                    name: "p\(profile)_\(number).j2k",
                    referenceStem: "c1p\(profile)_\(number)",
                    componentCount: count, resFactor: resFactor,
                    peak: try doubles(table("\(prefix)_PEAK_list", index)),
                    mse: try doubles(table("\(prefix)_MSE_list", index))
                ))
            }
        }
        return result
    }

    enum ParseError: Error { case missingTable(String), invalidValue(String) }
}
