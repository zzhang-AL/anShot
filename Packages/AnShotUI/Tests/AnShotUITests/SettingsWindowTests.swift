import AnShotCore
import AppKit
import Testing

@testable import AnShotUI

@Suite("设置窗口 · 页面初始化")
@MainActor
struct SettingsWindowTests {
    @Test("首次构建所有页面及关闭后重建均能完成")
    func constructsAllPagesAndReopens() throws {
        _ = NSApplication.shared
        let suiteName = "com.anshot.test.settings-window.\(UUID().uuidString)"
        let store = try #require(UserDefaults(suiteName: suiteName))
        defer { store.removePersistentDomain(forName: suiteName) }
        let settings = AppSettings(store: store)
        let host = SettingsShortcutHost()

        for _ in 0..<2 {
            // 构造会加载全部设置页；遗漏任何初始化都会在这里重现打开即崩溃。
            let controller = SettingsWindowController(settings: settings, shortcutHost: host)
            let window = try #require(controller.window)
            #expect(controller.currentPageForDiagnostics == .general)
            for page in SettingsPage.allCases {
                controller.showPageForDiagnostics(page)
                #expect(controller.currentPageForDiagnostics == page)
            }
            controller.reloadFromSettings()
            controller.showPageForDiagnostics(.translation)
            #expect(window.contentView != nil)
            #expect(window.title == "anShot 设置")
            window.close()
        }
    }
}

/// 只提供界面依赖，测试不注册或改动系统全局快捷键。
@MainActor
private final class SettingsShortcutHost: ShortcutHosting {
    func applyCaptureShortcut(_ shortcut: Shortcut) -> String? { nil }
    func suspendCaptureShortcut() -> Bool { true }
    func resumeCaptureShortcut() -> String? { nil }
    func applyPinToggleShortcut(_ shortcut: Shortcut) -> String? { nil }
    func suspendPinToggleShortcut() -> Bool { true }
    func resumePinToggleShortcut() -> String? { nil }
}
