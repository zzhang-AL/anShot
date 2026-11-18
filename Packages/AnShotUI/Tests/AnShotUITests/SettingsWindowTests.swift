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

    @Test("诊断启动参数判定统一入口与主菜单编辑通道校验")
    func diagnosticLaunchAndMainMenu() {
        _ = NSApplication.shared
        #expect(AppDelegate.isDiagnosticLaunch(arguments: ["anShot", "-checkUpdates"]))
        #expect(AppDelegate.isDiagnosticLaunch(arguments: ["anShot", "-diagnosePin"]))
        #expect(!AppDelegate.isDiagnosticLaunch(arguments: ["anShot"]))

        let menu = SettingsMainMenu.make()
        let editMenu = menu.item(withTitle: "编辑")?.submenu
        #expect(editMenu != nil)
        #expect(editMenu?.items.contains { $0.keyEquivalent == "c" } == true)
        #expect(editMenu?.items.contains { $0.keyEquivalent == "v" } == true)
        #expect(editMenu?.items.contains { $0.keyEquivalent == "a" } == true)
    }

    @Test("前台窗口激活策略协调器多窗口计数不提前退回 accessory")
    func foregroundPolicyCoordinatorReferenceCounting() {
        _ = NSApplication.shared
        ForegroundPolicyCoordinator.resetForTesting()
        defer { ForegroundPolicyCoordinator.resetForTesting() }

        ForegroundPolicyCoordinator.acquire("settings")
        #expect(ForegroundPolicyCoordinator.activeCount == 1)
        #expect(NSApp.activationPolicy() == .regular)

        ForegroundPolicyCoordinator.acquire("welcome")
        #expect(ForegroundPolicyCoordinator.activeCount == 2)

        ForegroundPolicyCoordinator.release("settings")
        #expect(ForegroundPolicyCoordinator.activeCount == 1)
        #expect(NSApp.activationPolicy() == .regular)

        ForegroundPolicyCoordinator.release("welcome")
        #expect(ForegroundPolicyCoordinator.activeCount == 0)
        #expect(NSApp.activationPolicy() == .accessory)
    }

    @Test("自定义控件焦点环与内部热键互撞检测")
    func focusRingAndShortcutInternalConflict() throws {
        _ = NSApplication.shared
        let push = SettingsPushButton(title: "测试", target: nil, action: nil)
        push.frame = NSRect(x: 0, y: 0, width: 80, height: 32)
        #expect(push.focusRingMaskBounds == push.bounds)

        let sidebarItem = SettingsSidebarItem(page: .general, target: nil, action: nil)
        sidebarItem.frame = NSRect(x: 0, y: 0, width: 160, height: 32)
        #expect(sidebarItem.focusRingMaskBounds == sidebarItem.bounds)

        let delegate = AppDelegate()
        let conflict = delegate.internalConflictMessage(
            for: AppSettings.defaultPinToggleShortcut,
            excluding: .capture
        )
        #expect(conflict?.contains("收起 / 展开全部固定截图") == true)
        #expect(delegate.internalConflictMessage(
            for: AppSettings.defaultCaptureShortcut,
            excluding: .capture
        ) == nil)
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
