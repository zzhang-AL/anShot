//
//  KeyboardDesktopSwitcherTests.swift
//  AnShotAutomationTests
//

import CoreGraphics
import Testing
@testable import AnShotAutomation

@Suite("桌面切换快捷键")
struct KeyboardDesktopSwitcherTests {
    @Test("仅接受已启用的 Control 与目标方向键")
    func onlySupportedSystemShortcutsAreUsed() {
        let control = CGEventFlags.maskControl.rawValue | CGEventFlags.maskSecondaryFn.rawValue
        #expect(KeyboardDesktopSwitcher.isSupportedShortcut(enabled: true, keyCode: 123, flags: control, expectedKey: 123))
        #expect(!KeyboardDesktopSwitcher.isSupportedShortcut(enabled: false, keyCode: 123, flags: control, expectedKey: 123))
        #expect(!KeyboardDesktopSwitcher.isSupportedShortcut(enabled: true, keyCode: 124, flags: control, expectedKey: 123))
        #expect(!KeyboardDesktopSwitcher.isSupportedShortcut(enabled: true, keyCode: 123, flags: 0, expectedKey: 123))
        #expect(!KeyboardDesktopSwitcher.isSupportedShortcut(
            enabled: true, keyCode: 123, flags: control | CGEventFlags.maskCommand.rawValue, expectedKey: 123
        ))
    }
}
