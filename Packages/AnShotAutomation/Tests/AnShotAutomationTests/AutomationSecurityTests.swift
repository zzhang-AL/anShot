//
//  AutomationSecurityTests.swift
//  AnShotAutomationTests
//
//  覆盖 MCP 与自动化后台通道的四层安全防线单元测试：
//  1. Socket 内核级对端代码签名门禁；
//  2. 总开关 + 常量时间访问令牌（ANSHOT_MCP_TOKEN）及 Socket 实时联动；
//  3. IPC 中转输出路径沙箱校验；
//  4. 敏感隐私应用窗口拦截与硬件级隐私排除清单。
//

import AnShotCapture
import Darwin
import Foundation
import Testing

@testable import AnShotAutomation

/// 测试用线程安全内存密钥存储，避免读写宿主真实的 `secrets.json`。
private final class InMemorySecretStore: SecretStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: String] = [:]

    func secret(for account: String) -> String? {
        lock.withLock { storage[account] }
    }

    func setSecret(_ value: String?, for account: String) throws {
        lock.withLock {
            if let value, !value.isEmpty {
                storage[account] = value
            } else {
                storage.removeValue(forKey: account)
            }
        }
    }

    func removeSecret(for account: String) throws {
        lock.withLock {
            _ = storage.removeValue(forKey: account)
        }
    }
}

private func makeIsolatedSecuritySettings() -> (AutomationSecuritySettings, String) {
    let suite = "com.anshot.tests.security.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    let settings = AutomationSecuritySettings(store: defaults, secrets: InMemorySecretStore())
    return (settings, suite)
}

@Suite("MCP 与自动化四层安全防线")
struct AutomationSecurityTests {

    // MARK: - 防线 1：Socket 对端代码签名校验

    @Test("防线 1：Socket 对端代码签名校验不通过时立即拒绝连接且绝不执行业务处理")
    func socketRejectsUntrustedPeerSignature() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("anshot-sec-sock-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let socketPath = tempDir.appendingPathComponent("auto.sock").path
        let handlerCalled = LockedFlag()

        let server = AutomationDaemonServer(
            socketPath: socketPath,
            peerVerifier: { _ in false },
            handler: { _ in
                handlerCalled.mark()
                return (CommandReport(ok: true, windows: []), nil)
            }
        )
        #expect(server.start())
        defer { server.stop() }

        do {
            _ = try await AutomationDaemonClient.send(
                action: .listWindows,
                timeout: 5,
                socketPath: socketPath
            )
            Issue.record("未通过签名校验的对端连接必须失败，不得返回成功响应")
        } catch {
            // 连接被服务端立即关闭，触发传输层错误
        }

        #expect(!handlerCalled.value, "签名校验失败时绝不能调用业务 handler")
    }

    // MARK: - 防线 2：总开关 + 访问令牌 + Socket 实时同步

    @Test("防线 2：总开关关闭时拒绝所有自动化请求，且 Socket 服务端同步停止监听并清理文件")
    func masterSwitchBlocksRequestsAndStopsSocket() throws {
        let (settings, suite) = makeIsolatedSecuritySettings()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("anshot-sec-sync-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let socketPath = tempDir.appendingPathComponent("auto.sock").path
        let server = AutomationDaemonServer(
            socketPath: socketPath,
            peerVerifier: { _ in true },
            handler: { _ in (CommandReport(ok: true), nil) }
        )
        defer { server.stop() }

        // 默认开启：允许授权，sync 后开始监听
        #expect(settings.isAutomationEnabled == true)
        try AutomationSecurityGate.authorize(providedToken: nil, settings: settings)
        server.syncWithSecuritySettings(settings)
        #expect(FileManager.default.fileExists(atPath: socketPath))

        // 关闭总开关：立即拒绝请求，且 sync 后停止监听并删除 socket 文件
        settings.setAutomationEnabled(false)
        #expect(throws: AutomationError.self) {
            try AutomationSecurityGate.authorize(providedToken: nil, settings: settings)
        }
        server.syncWithSecuritySettings(settings)
        #expect(!FileManager.default.fileExists(atPath: socketPath))
    }

    @Test("防线 2：开启访问令牌后强制校验，重置令牌后旧令牌立即失效，且常量时间比对准确")
    func accessTokenLifecycleAndConstantTimeComparison() throws {
        let (settings, suite) = makeIsolatedSecuritySettings()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }

        // 默认不强制要求令牌
        #expect(settings.requireAccessToken == false)
        try AutomationSecurityGate.authorize(providedToken: nil, settings: settings)

        // 开启强制令牌时自动生成 anshot_<64hex>
        settings.setRequireAccessToken(true)
        let firstToken = try #require(settings.currentAccessToken())
        #expect(firstToken.hasPrefix("anshot_"))
        #expect(firstToken.count == 7 + 64)

        // 缺令牌 / 空串 / 错误令牌全部拦截
        #expect(throws: AutomationError.self) {
            try AutomationSecurityGate.authorize(providedToken: nil, settings: settings)
        }
        #expect(throws: AutomationError.self) {
            try AutomationSecurityGate.authorize(providedToken: "   ", settings: settings)
        }
        #expect(throws: AutomationError.self) {
            try AutomationSecurityGate.authorize(providedToken: firstToken + "x", settings: settings)
        }

        // 正确令牌（含首尾空白修剪）通过
        try AutomationSecurityGate.authorize(providedToken: " \(firstToken)\n", settings: settings)

        // 重置令牌后，旧令牌立即失效，新令牌通过
        let rotatedToken = try settings.regenerateAccessToken()
        #expect(rotatedToken != firstToken)
        #expect(throws: AutomationError.self) {
            try AutomationSecurityGate.authorize(providedToken: firstToken, settings: settings)
        }
        try AutomationSecurityGate.authorize(providedToken: rotatedToken, settings: settings)

        // 常量时间字符串比对边界校验
        #expect(AutomationSecuritySettings.constantTimeEquals("abc123", "abc123"))
        #expect(!AutomationSecuritySettings.constantTimeEquals("abc123", "abc124"))
        #expect(!AutomationSecuritySettings.constantTimeEquals("abc123", "abc12"))
        #expect(!AutomationSecuritySettings.constantTimeEquals("", "a"))
        #expect(AutomationSecuritySettings.constantTimeEquals("", ""))
    }

    // MARK: - 防线 3：IPC 中转输出路径沙箱

    @Test("防线 3：IPC 中转路径沙箱严格拦截目录穿越、越权目录、宽权限、软链与覆盖，放行 0700 私有临时文件")
    func ipcOutputPathSandboxEnforcement() throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("anshot-sandbox-root-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        // 1. 合法 0700 私有目录内新文件 → 放行
        let validDir = tempRoot.appendingPathComponent("anshot-ipc-valid", isDirectory: true)
        try FileManager.default.createDirectory(
            at: validDir,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let validOutput = validDir.appendingPathComponent("report.json")
        let verified = try AutomationPathSandbox.validateTransferOutputPath(
            validOutput.path,
            allowedTempRoot: tempRoot
        )
        #expect(verified.lastPathComponent == "report.json")

        // 2. 已存在目标文件 → 拒绝覆盖
        FileManager.default.createFile(atPath: validOutput.path, contents: Data("existing".utf8))
        #expect(throws: AutomationError.self) {
            _ = try AutomationPathSandbox.validateTransferOutputPath(
                validOutput.path,
                allowedTempRoot: tempRoot
            )
        }

        // 3. 相对路径、空路径、含 .. 遍历路径、任意用户敏感路径 → 全部拒绝
        let badPaths = [
            "",
            "relative/anshot-ipc-1/report.json",
            validDir.path + "/../escaped.json",
            NSHomeDirectory() + "/.zshrc",
            tempRoot.appendingPathComponent("other-dir/report.json").path,
        ]
        for path in badPaths {
            #expect(throws: AutomationError.self) {
                _ = try AutomationPathSandbox.validateTransferOutputPath(path, allowedTempRoot: tempRoot)
            }
        }

        // 4. 权限过宽（0755）的 anshot-ipc-* 目录 → 拒绝
        let looseDir = tempRoot.appendingPathComponent("anshot-ipc-loose", isDirectory: true)
        try FileManager.default.createDirectory(at: looseDir, withIntermediateDirectories: true)
        #expect(chmod(looseDir.path, 0o755) == 0)
        #expect(throws: AutomationError.self) {
            _ = try AutomationPathSandbox.validateTransferOutputPath(
                looseDir.appendingPathComponent("out.png").path,
                allowedTempRoot: tempRoot
            )
        }

        // 5. 软链接伪装的 anshot-ipc-* 目录 → 拒绝
        let symlinkDir = tempRoot.appendingPathComponent("anshot-ipc-link", isDirectory: false)
        try FileManager.default.createSymbolicLink(at: symlinkDir, withDestinationURL: validDir)
        #expect(throws: AutomationError.self) {
            _ = try AutomationPathSandbox.validateTransferOutputPath(
                symlinkDir.appendingPathComponent("new.png").path,
                allowedTempRoot: tempRoot
            )
        }

        // 6. 嵌套子目录中的 anshot-ipc-* → 拒绝（必须为 tempRoot 直接子目录）
        let nestedDir = tempRoot
            .appendingPathComponent("nested", isDirectory: true)
            .appendingPathComponent("anshot-ipc-sub", isDirectory: true)
        try FileManager.default.createDirectory(
            at: nestedDir,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        #expect(throws: AutomationError.self) {
            _ = try AutomationPathSandbox.validateTransferOutputPath(
                nestedDir.appendingPathComponent("out.png").path,
                allowedTempRoot: tempRoot
            )
        }
    }

    // MARK: - 防线 4：敏感隐私窗口保护

    @Test("防线 4：默认保护密码管理器/钥匙串/系统设置并放行常规应用，关闭开关后解除排除")
    func sensitiveWindowPrivacyProtection() throws {
        let (settings, suite) = makeIsolatedSecuritySettings()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }

        #expect(settings.protectSensitiveWindows == true)
        #expect(!settings.activePrivacyExclusion.isEmpty)

        // Bundle ID 与应用名命中（含大小写不敏感）
        #expect(settings.isProtectedWindow(bundleIdentifier: "com.1password.1password", applicationName: nil))
        #expect(settings.isProtectedWindow(bundleIdentifier: "COM.BITWARDEN.DESKTOP", applicationName: nil))
        #expect(settings.isProtectedWindow(bundleIdentifier: "org.keepassxc.keepassxc", applicationName: nil))
        #expect(settings.isProtectedWindow(bundleIdentifier: "com.apple.keychainaccess", applicationName: nil))
        #expect(settings.isProtectedWindow(bundleIdentifier: nil, applicationName: "钥匙串访问"))
        #expect(settings.isProtectedWindow(bundleIdentifier: nil, applicationName: "系统设置"))
        #expect(settings.isProtectedWindow(bundleIdentifier: nil, applicationName: "1Password"))

        // 常规应用不受影响
        #expect(!settings.isProtectedWindow(bundleIdentifier: "com.apple.Safari", applicationName: "Safari"))
        #expect(!settings.isProtectedWindow(bundleIdentifier: "com.apple.dt.Xcode", applicationName: "Xcode"))

        // AutomationSecurityGate 拦截敏感应用，放行普通应用
        #expect(throws: AutomationError.self) {
            try AutomationSecurityGate.validateTargetWindowAllowed(
                pid: 0,
                applicationName: "1Password",
                settings: settings
            )
        }
        try AutomationSecurityGate.validateTargetWindowAllowed(
            pid: 0,
            applicationName: "Safari",
            settings: settings
        )

        // 关闭开关后不再排除或拦截
        settings.setProtectSensitiveWindows(false)
        #expect(settings.activePrivacyExclusion == .none)
        #expect(!settings.isProtectedWindow(bundleIdentifier: "com.1password.1password", applicationName: "1Password"))
        try AutomationSecurityGate.validateTargetWindowAllowed(
            pid: 0,
            applicationName: "1Password",
            settings: settings
        )
    }
}

/// 线程安全布尔标记，用于并发测试断言。
private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var state = false

    var value: Bool { lock.withLock { state } }
    func mark() { lock.withLock { state = true } }
}
