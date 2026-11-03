//
//  LaunchAtLogin.swift
//  AnShotUI
//
//  「登录时自动启动」开关。
//
//  ── 为什么状态不落 UserDefaults ──────────────────────────────
//
//  系统的登录项注册状态就是**唯一真相**。自己再存一份会立刻产生分叉：
//  用户在「系统设置 › 通用 › 登录项」里关掉之后，我们存的那份仍然说「开着」，
//  界面就会显示一个与系统相反的开关——而且用户没有任何办法在我们这边纠正它。
//
//  ── 为什么状态有四种而开关只有两态 ───────────────────────────
//
//  `SMAppService` 除了「登记了」和「没登记」，还会返回 `.requiresApproval`：
//  已经登记，但需要用户到系统设置里手动允许。此时开关应当是**关**的（确实还没生效），
//  但界面必须把「去哪打开」讲出来——否则用户点开关、开关自己弹回去、
//  全程没有任何解释，看起来就像开关坏了。
//
//  ── 一句提醒 ────────────────────────────────────────────────
//
//  注册能否成功取决于系统的判定，不取决于我们。失败时**把系统的原话转给用户**，
//  而不是吞掉或换成一句笼统的「设置失败」——那句话对用户毫无用处。
//

import AnShotCore
import Foundation
import ServiceManagement

private let launchAtLoginLogger = AnShotLog.launchAtLogin
/// 登录时自动启动。
///
/// 无状态：所有查询与变更都直接问系统，因此不存在「缓存与系统不一致」的可能。
@MainActor
enum LaunchAtLogin {

    /// 当前是否**已生效**。
    ///
    /// 只有 `.enabled` 算数。`.requiresApproval` 虽然登记了，但用户没批准之前
    /// 并不会真的启动，把它当成「开」会让开关骗人。
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// 供界面显示的一行提示；不需要额外提示时返回 nil。
    ///
    /// `.notFound` **刻意不给提示**：实测它在全新环境第一次查询时就会出现
    /// （此时登录项尚未创建），注册成功后即变成 `.enabled`。把它当错误去提示
    /// 「应用装错了地方」，只会让刚装好的用户白白怀疑自己的安装位置。
    static var notice: String? {
        switch SMAppService.mainApp.status {
        case .requiresApproval:
            return "已在系统中登记，但需要到「系统设置 › 通用 › 登录项」允许后才会生效"
        default:
            return nil
        }
    }

    /// 打开/关闭登录项。
    ///
    /// - Parameter enabled: 期望的状态。
    /// - Returns: 失败原因（已本地化，可直接显示给用户）；成功返回 nil。
    ///
    /// **永远不抛**：调用方是界面动作，抛出去只会变成崩溃。失败信息一律作为返回值
    /// 交给界面显示。
    @discardableResult
    static func setEnabled(_ enabled: Bool) -> String? {
        let service = SMAppService.mainApp
        do {
            if enabled {
                try service.register()
            } else {
                try service.unregister()
            }
            launchAtLoginLogger.notice("""
                launch at login \(enabled ? "on" : "off", privacy: .public); \
                status=\(String(describing: service.status), privacy: .public)
                """)
            return nil
        } catch {
            // 原样转达系统给的原因：它通常已经指出了真正的症结
            // （例如应用不在「应用程序」文件夹、或存在多个副本）。
            launchAtLoginLogger.error("""
                launch at login \(enabled ? "on" : "off", privacy: .public) failed; \
                status=\(String(describing: service.status), privacy: .public) \
                error=\(String(describing: error), privacy: .public)
                """)
            return error.localizedDescription
        }
    }

    /// 把当前状态整理成一行供诊断使用的文字。
    static func describeStatus() -> String {
        switch SMAppService.mainApp.status {
        case .notRegistered: return "notRegistered"
        case .enabled: return "enabled"
        case .requiresApproval: return "requiresApproval"
        case .notFound: return "notFound"
        @unknown default: return "unknown"
        }
    }
}
