//
//  DesktopCatalogTests.swift
//  AnShotAutomationTests
//

import Foundation
import Testing
@testable import AnShotAutomation

@Suite("多显示器桌面枚举")
struct DesktopCatalogTests {
    private let displays: [(id: UInt32, uuid: String)] = [(1, "AAA"), (2, "BBB")]

    @Test("区分普通桌面和全屏空间，记录当前状态与显示器")
    func distinctDisplays() throws {
        let records: [[String: Any]] = [
            record("aaa", current: 20, spaces: [(10, 0), (20, 4), (30, 0)]),
            record("BBB", current: 40, spaces: [(40, 0)])
        ]
        let result = try DesktopCatalog.describe(records: records, displays: displays)
        #expect(result.map(\.id) == [10, 20, 30, 40])
        #expect(result.map(\.position) == [1, 2, 3, 1])
        #expect(result.map(\.desktopNumber) == [1, nil, 2, 1])
        #expect(result.map(\.isCurrent) == [false, true, false, true])
        #expect(result.map(\.displayID) == [1, 1, 1, 2])
    }

    @Test("共享桌面映射到所有显示器")
    func sharedSpacesAreAvailableOnAllDisplays() throws {
        let result = try DesktopCatalog.describe(
            records: [record("Main", current: 10, spaces: [(10, 0), (20, 0)])],
            displays: displays
        )
        #expect(result.count == 4)
        #expect(result.filter { $0.id == 10 }.map(\.displayID) == [1, 2])
        #expect(result.filter(\.isCurrent).count == 2)
    }

    @Test("无法映射显示器时拒绝返回误导结果")
    func unknownDisplayFails() {
        #expect(throws: AutomationError.self) {
            _ = try DesktopCatalog.describe(
                records: [record("unknown", current: 10, spaces: [(10, 0)])],
                displays: displays
            )
        }
    }

    private func record(_ display: String, current: UInt64, spaces: [(UInt64, Int)]) -> [String: Any] {
        [
            "Display Identifier": display,
            "Current Space": ["ManagedSpaceID": NSNumber(value: current)],
            "Spaces": spaces.map { ["ManagedSpaceID": NSNumber(value: $0.0), "type": NSNumber(value: $0.1)] }
        ]
    }
}
