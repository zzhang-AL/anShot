//
//  KeyboardDesktopSwitcher.swift
//  AnShotAutomation
//
//  可见桌面切换的快速路径：仅在系统启用 Control + 方向键且焦点在目标屏时使用。
//

import ApplicationServices
import CoreGraphics
import Foundation

enum KeyboardDesktopSwitcher {

    private struct Shortcut {
        let key: CGKeyCode
        let flags: CGEventFlags
    }

    /// 仅在用户显式允许切换时调用。不能可靠使用快捷键时拒绝切换。
    static func switchTo(spaceID: UInt64, displayID: UInt32) throws {
        guard AXIsProcessTrusted() else {
            throw AutomationError.captureFailed(
                "切换桌面需要辅助功能权限。请在「系统设置 → 隐私与安全性 → 辅助功能」"
                + "中为 anShot 授权；使用 --direct 时请以实际显示的进程条目为准。"
            )
        }
        let desktops = try DesktopCatalog.all().filter { $0.displayID == displayID }
        guard let target = desktops.first(where: { $0.id == spaceID }) else {
            throw AutomationError.invalidArgument("目标桌面已不存在或不属于该显示器，请重新调用 list_desktops。")
        }
        if target.isCurrent { return }
        guard try trySwitch(target: target, desktops: desktops) else {
            throw AutomationError.captureFailed(
                "无法使用 Control＋方向键切换目标桌面。请确认系统已启用左右切换空间快捷键，"
                + "且键盘焦点在目标显示器；也可使用 window_id 进行后台窗口截图。"
            )
        }
    }

    /// 快捷键不可用时返回 false；中途异常不猜测用户意图。
    static func trySwitch(target: DesktopInfo, desktops: [DesktopInfo]) throws -> Bool {
        let ordered = desktops.sorted { $0.position < $1.position }
        guard let original = ordered.first(where: \.isCurrent),
              DesktopCatalog.focusedSpaceID() == original.id,
              let start = ordered.firstIndex(where: { $0.id == original.id }),
              let end = ordered.firstIndex(where: { $0.id == target.id }),
              let left = shortcut(identifier: "79", expectedKey: 123),
              let right = shortcut(identifier: "81", expectedKey: 124) else { return false }
        guard start != end else { return true }

        let step = end > start ? 1 : -1
        let forward = step > 0 ? right : left
        let backward = step > 0 ? left : right
        var visited = [original.id]
        var index = start
        while index != end {
            let nextIndex = index + step
            let previous = visited[visited.count - 1]
            let next = ordered[nextIndex].id
            guard try activeSpace(displayID: target.displayID) == previous,
                  DesktopCatalog.focusedSpaceID() == previous else {
                throw AutomationError.captureFailed("桌面切换期间焦点发生变化，已停止自动切换。")
            }
            let sent = post(forward)
            let result = sent ? try waitForTransition(
                from: previous, to: next, displayID: target.displayID
            ) : false
            if !result {
                // 快捷键失效时先撤回本次已经完成的步骤。
                try restoreVisited(visited, shortcut: backward, displayID: target.displayID)
                return false
            }
            visited.append(next)
            index = nextIndex
        }

        // 空间 ID 往往先于显示动画更新，等待画面稳定再允许抓帧。
        Thread.sleep(forTimeInterval: 0.6)
        guard try activeSpace(displayID: target.displayID) == target.id else {
            throw AutomationError.captureFailed("桌面切换后状态发生变化，已取消截图。")
        }
        return true
    }

    private static func restoreVisited(
        _ visited: [UInt64],
        shortcut: Shortcut,
        displayID: UInt32
    ) throws {
        guard visited.count > 1 else { return }
        var current = visited[visited.count - 1]
        for previous in visited.dropLast().reversed() {
            guard try activeSpace(displayID: displayID) == current,
                  DesktopCatalog.focusedSpaceID() == current else {
                throw AutomationError.captureFailed("桌面已被用户或其他程序切换，未强行恢复。")
            }
            guard post(shortcut), try waitForTransition(from: current, to: previous, displayID: displayID) else {
                throw AutomationError.captureFailed("快捷键切换中断且无法自动恢复，请手动切回原桌面。")
            }
            current = previous
        }
    }

    /// 等待相邻空间生效；如果切到了意料之外的空间，视为用户操作并停止。
    private static func waitForTransition(from: UInt64, to: UInt64, displayID: UInt32) throws -> Bool {
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            let active = try activeSpace(displayID: displayID)
            if active == to { return true }
            guard active == from else {
                throw AutomationError.captureFailed("桌面被其他操作改变，已停止自动切换。")
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return false
    }

    private static func activeSpace(displayID: UInt32) throws -> UInt64 {
        guard let active = try DesktopCatalog.all().first(where: { $0.displayID == displayID && $0.isCurrent }) else {
            throw AutomationError.captureFailed("无法确认显示器当前桌面。")
        }
        return active.id
    }

    /// 只使用系统实际启用的 Control + 左右方向键，避免触发用户自定义快捷键。
    private static func shortcut(identifier: String, expectedKey: CGKeyCode) -> Shortcut? {
        guard let preferences = CFPreferencesCopyAppValue(
            "AppleSymbolicHotKeys" as CFString,
            "com.apple.symbolichotkeys" as CFString
        ) as? [String: Any],
        let entry = preferences[identifier] as? [String: Any],
        let value = entry["value"] as? [String: Any],
        let parameters = value["parameters"] as? [NSNumber], parameters.count >= 3 else { return nil }

        let flags = parameters[2].uint64Value
        guard isSupportedShortcut(
            enabled: (entry["enabled"] as? NSNumber)?.boolValue == true,
            keyCode: parameters[1].uint16Value,
            flags: flags,
            expectedKey: expectedKey
        ) else { return nil }
        return Shortcut(key: expectedKey, flags: CGEventFlags(rawValue: flags))
    }

    /// 避免把其他自定义快捷键当作桌面切换来投递。
    static func isSupportedShortcut(enabled: Bool, keyCode: UInt16, flags: UInt64, expectedKey: UInt16) -> Bool {
        let allowed = CGEventFlags.maskControl.rawValue | CGEventFlags.maskSecondaryFn.rawValue
        return enabled && keyCode == expectedKey
            && flags & CGEventFlags.maskControl.rawValue != 0 && flags & ~allowed == 0
    }

    private static func post(_ shortcut: Shortcut) -> Bool {
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: shortcut.key, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: shortcut.key, keyDown: false) else {
            return false
        }
        down.flags = shortcut.flags
        up.flags = shortcut.flags
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return true
    }
}
