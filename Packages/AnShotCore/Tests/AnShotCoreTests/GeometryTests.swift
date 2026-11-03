import Foundation
import Testing
@testable import AnShotCore

@Suite("几何类型契约")
struct GeometryTests {

    @Test("PixelRect 非空判定")
    func nonEmpty() {
        let zero = PixelRect(origin: PixelPoint(x: 0, y: 0),
                             size: PixelSize(width: 0, height: 10))
        #expect(!zero.isNonEmpty)

        let normal = PixelRect(origin: PixelPoint(x: 1, y: 2),
                               size: PixelSize(width: 3, height: 4))
        #expect(normal.isNonEmpty)
    }

    @Test("Codable 往返后相等")
    func codableRoundTrip() throws {
        let original = PixelRect(origin: PixelPoint(x: 1.5, y: 2.5),
                                 size: PixelSize(width: 300, height: 200))
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(PixelRect.self, from: data)
        #expect(decoded == original)
    }
}
