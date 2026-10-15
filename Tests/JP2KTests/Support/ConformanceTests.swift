import Foundation
import Testing

struct ConformanceTests {
    @Test func parsesOpenJPEGTables() throws {
        let url = Conformance.sourceURL(environment: [:])
        guard let url, FileManager.default.fileExists(atPath: url.path) else { return }
        let cases = try Conformance.parse(String(contentsOf: url, encoding: .utf8))
        #expect(cases.count == 23)
        #expect(Conformance.class1 == cases)
        #expect(cases.first?.name == "p0_01.j2k")
        #expect(cases.first?.resFactor == 0)
        #expect(cases.first?.peak == [0])
        #expect(cases.first?.mse == [0])
        #expect(cases.first(where: { $0.name == "p0_04.j2k" })?.peak == [5, 4, 6])
        #expect(cases.first(where: { $0.name == "p0_04.j2k" })?.mse == [0.776, 0.626, 1.070])
        #expect(cases.first(where: { $0.name == "p1_02.j2k" })?.peak == [5, 4, 6])
        #expect(cases.map(\.componentCount).prefix(4) == [1, 1, 1, 3])
        #expect(cases.filter { $0.resFactor != 0 }.map(\.name) == ["p0_08.j2k"])
    }

    @Test func availableDataHasClassOneInputsAndReferences() throws {
        let cases = Conformance.availableCases()
        guard let root = Conformance.root() else { return }
        #expect(cases.count == 23)
        try Conformance.requireFiles(root: root, cases: cases)
    }

    @Test func gatesDataAndReportsReducedResolutionSkips() throws {
        #expect(Conformance.root(environment: [:]) == nil)
        let root = Conformance.root(environment: ["JP2K_CONFORMANCE_DIR": "/tmp/openjpeg-data"])
        #expect(root?.path == "/tmp/openjpeg-data")
        #expect(Conformance.availableCases(environment: [:]).isEmpty)
        guard let source = Conformance.sourceURL(environment: [:]),
              FileManager.default.fileExists(atPath: source.path) else { return }
        let cases = try Conformance.parse(String(contentsOf: source, encoding: .utf8))
        let skipped = Conformance.skippedReducedResolution(cases)
        #expect(skipped == ["p0_08.j2k"])
        print("Skipped ResFactor != 0: \(skipped.joined(separator: ", "))")
    }

    @Test func classOneTableIsAvailableWithoutSourceTree() {
        let environment = ["JP2K_CONFORMANCE_DIR": "/tmp/openjpeg-data", "OPJ_SRC": "/missing/openjpeg"]
        #expect(Conformance.availableCases(environment: environment).count == 23)
    }

    @Test func missingConformanceFilesFailWhenEnabled() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let item = try #require(Conformance.class1.first)
        #expect(throws: Conformance.MissingFile.self) {
            try Conformance.requireFiles(root: root, cases: [item])
        }
        let input = Conformance.inputURL(item, root: root)
        try FileManager.default.createDirectory(at: input.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: input)
        #expect(throws: Conformance.MissingFile.self) {
            try Conformance.requireFiles(root: root, cases: [item])
        }
    }
}
