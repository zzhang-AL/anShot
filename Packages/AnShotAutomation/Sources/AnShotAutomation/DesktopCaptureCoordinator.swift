//
//  DesktopCaptureCoordinator.swift
//  AnShotAutomation
//

import Darwin
import Foundation

/// 在所有 anShot 子进程之间协调屏幕抓帧与桌面切换。
enum DesktopCaptureCoordinator {

    static func capture<T: Sendable>(
        spaceID: UInt64?,
        displayID: UInt32,
        allowSwitch: Bool,
        operation: @Sendable () async throws -> T
    ) async throws -> T {
        // 非切换截图允许并发；切换期间独占锁，防止另一请求截到过渡桌面。
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("com.anshot.desktop-capture.lock").path
        let descriptor = open(path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, mode_t(0o600))
        guard descriptor >= 0 else {
            throw AutomationError.captureFailed("无法创建桌面截图协调锁（错误 \(errno)）。")
        }
        defer { close(descriptor) }

        let mode = (spaceID == nil ? LOCK_SH : LOCK_EX) | LOCK_NB
        let deadline = Date().addingTimeInterval(15)
        while flock(descriptor, mode) != 0 {
            guard errno == EWOULDBLOCK || errno == EAGAIN else {
                throw AutomationError.captureFailed("无法获取桌面截图协调锁（错误 \(errno)）。")
            }
            guard Date() < deadline else {
                throw AutomationError.captureFailed("等待其他桌面截图超时，请稍后重试。")
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        defer { flock(descriptor, LOCK_UN) }

        guard let spaceID else { return try await operation() }
        return try await DesktopTransaction.perform(
            target: spaceID,
            allowSwitch: allowSwitch,
            current: {
                guard let active = try DesktopCatalog.all().first(where: {
                    $0.displayID == displayID && $0.isCurrent
                }) else {
                    throw AutomationError.captureFailed("无法确认显示器当前桌面。")
                }
                return active.id
            },
            switchTo: { try KeyboardDesktopSwitcher.switchTo(spaceID: $0, displayID: displayID) },
            capture: operation
        )
    }
}

/// 桌面切换事务：确认目标、捕获、条件恢复。独立于系统 API，便于验证错误路径。
enum DesktopTransaction {

    static func perform<T>(
        target: UInt64,
        allowSwitch: Bool,
        current: () throws -> UInt64,
        switchTo: (UInt64) throws -> Void,
        capture: () async throws -> T
    ) async throws -> T {
        let original = try current()
        if original == target {
            let value = try await capture()
            guard try current() == target else {
                throw AutomationError.captureFailed("截图期间桌面发生变化，已丢弃结果。")
            }
            return value
        }

        guard allowSwitch else {
            throw AutomationError.invalidArgument(
                "目标桌面当前未显示；默认不会切换桌面。可先用 list_windows 选择该桌面的窗口进行后台截图，"
                + "如需完整桌面画面，须先取得用户对切换的明确同意，再传入 allow_switch: true"
                + "（CLI 使用 --switch-desktop）。"
            )
        }

        let captureResult: Result<T, Error>
        do {
            try switchTo(target)
            guard try current() == target else {
                throw AutomationError.captureFailed("未能确认目标桌面，已取消截图。")
            }
            let value = try await capture()
            guard try current() == target else {
                throw AutomationError.captureFailed("截图期间桌面发生变化，已丢弃结果。")
            }
            captureResult = .success(value)
        } catch {
            captureResult = .failure(error)
        }

        // 即使切换函数中途失败，也检查是否已经切换；用户切到第三个空间时不抢回。
        let active: UInt64
        do {
            active = try current()
        } catch {
            throw AutomationError.captureFailed("无法确认当前桌面，未执行自动恢复；请手动检查桌面。")
        }
        if active == target {
            do {
                try switchTo(original)
                guard try current() == original else {
                    throw AutomationError.captureFailed("系统未确认恢复原桌面。")
                }
            } catch {
                throw AutomationError.captureFailed("恢复原桌面失败，请手动切回：\(error.localizedDescription)")
            }
        } else if active != original {
            throw AutomationError.captureFailed("桌面已被用户或其他程序切换，未覆盖当前桌面状态。")
        }

        return try captureResult.get()
    }
}
