import Foundation
import Testing
@testable import JP2K

struct DecodeComponentsTests {
    @Test(arguments: [
        ("gray-378x472-53.jp2", 1, 0),
        ("gray-378x472-53.j2k", 1, 0),
        ("gray-378x472-97.jp2", 1, 1),
        ("rgb-64-53-mct.jp2", 3, 0),
        ("rgb-64-97.jp2", 3, 1),
        ("gray16-40x30.jp2", 1, 0),
        ("cblk-8x8.j2k", 1, 0),
        ("rgba-33x17.jp2", 4, 0),
        ("signed12-31x19.j2k", 1, 0),
        ("levels-0.j2k", 1, 0),
        ("levels-max.j2k", 1, 0)
    ])
    func referencePixels(name: String, count: Int, tolerance: Int) throws {
        let url = try #require(Fixtures.url(name))
        let image = try JP2KDecoder().decodeComponents(Array(Data(contentsOf: url)))
        #expect(image.components.count == count)
        for index in 0..<count {
            let base = String(name.split(separator: ".").first ?? "")
            let pgx = try PGX.parse(Array(Data(contentsOf: try #require(Fixtures.url("\(base)_\(index).pgx")))))
            #expect(image.components[index].count == image.info.components[index].width * image.info.components[index].height)
            #expect(image.components[index].count == pgx.samples.count)
            let difference = zip(image.components[index], pgx.samples).map { abs(Int($0) - Int($1)) }.max() ?? 0
            #expect(difference <= tolerance)
        }
    }

    @Test func concurrentDecode() async throws {
        let bytes = Array(try Data(contentsOf: #require(Fixtures.url("gray-378x472-97.jp2"))))
        // One shared decoder value used from eight tasks at once (it is Sendable).
        let decoder = JP2KDecoder()
        let results = try await withThrowingTaskGroup(of: [Int32].self) { group in
            for _ in 0..<8 { group.addTask { try decoder.decodeComponents(bytes).components[0] } }
            var result: [[Int32]] = []
            for try await value in group { result.append(value) }
            return result
        }
        #expect(results.count == 8)
        for result in results { #expect(result == results[0]) }
    }
}
