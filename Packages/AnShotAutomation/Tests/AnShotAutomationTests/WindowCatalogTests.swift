//
//  WindowCatalogTests.swift
//  AnShotAutomationTests
//

import CoreGraphics
import Foundation
import Testing
@testable import AnShotAutomation

@Suite("跨桌面窗口解析")
struct WindowCatalogTests {

    @Test("系统省略在屏字段时，窗口不能被误判为在屏")
    func missingOnScreenFieldIsNotOnScreen() throws {
        var raw: [String: Any] = [
            kCGWindowNumber as String: NSNumber(value: 42),
            kCGWindowOwnerName as String: "Example",
            kCGWindowOwnerPID as String: NSNumber(value: 100),
            kCGWindowLayer as String: NSNumber(value: 0),
            kCGWindowBounds as String: [
                "X": NSNumber(value: 10), "Y": NSNumber(value: 20),
                "Width": NSNumber(value: 800), "Height": NSNumber(value: 600)
            ]
        ]
        let hidden = try #require(WindowCatalog.describe(raw, ownPID: 999))
        #expect(!hidden.isOnScreen)

        raw[kCGWindowIsOnscreen as String] = NSNumber(value: true)
        let visible = try #require(WindowCatalog.describe(raw, ownPID: 999))
        #expect(visible.isOnScreen)
    }

    @Test("应用名匹配优先当前桌面，只有后台窗口时也能选中")
    func applicationResolutionIncludesOtherDesktops() throws {
        let visible = window(id: 1, app: "Example", onScreen: true, width: 400)
        let background = window(id: 2, app: "Example", onScreen: false, width: 1000)
        let partial = window(id: 3, app: "Example Helper", onScreen: true, width: 1200)

        #expect(WindowCatalog.resolve(applicationName: "example", among: [background, visible])?.id == 1)
        #expect(WindowCatalog.resolve(applicationName: "example", among: [background, partial])?.id == 2)
        #expect(WindowCatalog.resolve(applicationName: "example", among: [background])?.id == 2)
    }

    private func window(id: UInt32, app: String, onScreen: Bool, width: Double) -> WindowInfo {
        WindowInfo(
            id: id,
            appName: app,
            title: nil,
            pid: 100,
            layer: 0,
            isOnScreen: onScreen,
            frame: WindowInfo.Rect(x: 0, y: 0, width: width, height: 600),
            displayID: nil,
            spaceIDs: nil
        )
    }
}
