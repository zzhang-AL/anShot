//
//  CaptureDiagnostics+LaunchAtLogin.swift
//  AnShotUI
//
//  「登录时自动启动」诊断。
//
//  存在的理由与其它诊断相同：设置窗口里的开关无法脚本化点击。
//
//  比别的诊断多做一步——**真的注册一次，再注销回初始状态**。
//  理由：`SMAppService` 能否成功完全取决于系统的判定（应用所在位置、
//  是否存在多个副本、用户是否拒绝过），这些都不是读代码能确定的。
//  只做只读断言会给出一个「看起来没问题」的结论，而用户在真机上点开关仍然失败。
//
//  恢复靠 `defer`：即使中途断言失败或提前返回，也一定回到初始状态。
//  一个会把用户系统状态改掉的诊断，比没有诊断更糟。
//

#if DEBUG

import AppKit
import Foundation
import ServiceManagement

extension CaptureDiagnostics {

    /// 登录项诊断：状态读取、界面同步、注册往返。
    static func runLaunchAtLoginDiagnostic() async {
        var failures: [String] = []
        func check(_ label: String, _ passed: Bool, detail: String? = nil) {
            let suffix = detail.map { "（\($0)）" } ?? ""
            logger.notice("\(passed ? "✅" : "❌", privacy: .public) \(label, privacy: .public)\(suffix, privacy: .public)")
            if !passed { failures.append(label) }
        }

        // ── 1）状态读取 ──

        let statusText = LaunchAtLogin.describeStatus()
        check(
            "状态应落在已知取值内",
            ["notRegistered", "enabled", "requiresApproval", "notFound"].contains(statusText),
            detail: statusText
        )
        // 这条守卫的是开关会不会骗人：`.requiresApproval` 虽然登记了，
        // 但用户没批准之前并不会真的启动，把它算成「开」就是显示一个假状态。
        check(
            "isEnabled 必须只认 enabled",
            LaunchAtLogin.isEnabled == (statusText == "enabled"),
            detail: "status=\(statusText) isEnabled=\(LaunchAtLogin.isEnabled)"
        )
        if statusText == "requiresApproval" {
            check(
                "待批准时必须提示去哪里允许",
                LaunchAtLogin.notice?.contains("登录项") == true,
                detail: LaunchAtLogin.notice ?? "nil"
            )
        } else {
            check(
                "非待批准状态不应冒出审批提示",
                LaunchAtLogin.notice?.contains("允许") != true,
                detail: LaunchAtLogin.notice ?? "无提示"
            )
        }

        // ── 2）界面同步 ──
        //
        // 开关必须反映系统状态。反了的话，用户会照着界面把真实状态改坏。

        let suiteName = "com.anshot.app.diagnostic.launchAtLogin.\(UUID().uuidString)"
        guard let store = UserDefaults(suiteName: suiteName) else {
            logger.error("launchAtLogin diag: 无法创建测试 suite")
            return
        }
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }

        let controller = SettingsWindowController(
            settings: AppSettings(store: store),
            shortcutHost: DiagnosticShortcutHost(initial: AppSettings.defaultCaptureShortcut)
        )
        controller.show()
        // 真实建窗不是「调用完就完成了」的同步操作，给激活与布局留时间。
        try? await Task.sleep(for: .milliseconds(800))

        let ui = controller.launchAtLoginControlsState
        check(
            "开关初始状态应与系统一致",
            ui.isOn == LaunchAtLogin.isEnabled,
            detail: "ui=\(ui.isOn) system=\(LaunchAtLogin.isEnabled)"
        )
        check(
            "开关下方提示与状态自洽",
            ui.noticeText.isEmpty || statusText == "requiresApproval" || statusText == "notFound",
            detail: "notice=\(ui.noticeText.isEmpty ? "无" : ui.noticeText)"
        )
        // 通用页同时承载「截图快捷键」与「启动」两张卡片；
        // 少一张就说明新增的卡片没有进 buildPage。
        check("当前应停在通用页", controller.currentPageForDiagnostics == .general)

        controller.window?.close()

        // ── 3）注册往返 ──
        //
        // 真正调一次系统 API。失败信息原样打印——它就是用户点开关时会看到的东西。
        //
        // 恢复**不用 `defer`**：`exit()` 是 C 函数，不会触发 Swift 的 `defer`
        //（栈不展开）。放进去等于永远不执行——实测会在系统里留下一个指向
        // 临时构建路径的登录项。所以恢复必须写在 `exit` 之前。

        let wasEnabled = LaunchAtLogin.isEnabled

        if let failure = LaunchAtLogin.setEnabled(!wasEnabled) {
            // 开发机上失败很常见（应用不在「应用程序」文件夹、或有多个副本），
            // 所以这里**不判失败**，只如实记录：它决定了用户会在开关下看到什么。
            logger.notice("⚠️ 切换登录项未成功（取决于应用位置，属预期内）：\(failure, privacy: .public)")
        } else {
            check(
                "切换后系统状态应随之变化",
                LaunchAtLogin.isEnabled == !wasEnabled,
                detail: "was=\(wasEnabled) now=\(LaunchAtLogin.isEnabled) status=\(LaunchAtLogin.describeStatus())"
            )
        }

        // 回到初始状态。注册失败时 `wasEnabled` 就是当前值，
        // 这里的调用是个幂等的无害操作。
        if let restoreFailure = LaunchAtLogin.setEnabled(wasEnabled) {
            check("应能恢复初始状态", false, detail: restoreFailure)
        } else {
            check(
                "恢复后系统状态应与初始一致",
                LaunchAtLogin.isEnabled == wasEnabled,
                detail: "was=\(wasEnabled) now=\(LaunchAtLogin.isEnabled)"
            )
        }

        logger.notice("[launchAtLogin] 汇总: \(failures.isEmpty ? "全部通过" : "\(failures.count) 项失败", privacy: .public) exitCode=\(failures.isEmpty ? 0 : 1, privacy: .public)")
        exit(failures.isEmpty ? 0 : 1)
    }
}

#endif
