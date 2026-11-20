//
//  AutomationSecuritySettings.swift
//  AnShotCapture
//
//  MCP 与自动化后台服务的安全策略配置：
//  - 总开关（随时一键关闭自动化与 Socket 监听）
//  - 访问令牌（`ANSHOT_MCP_TOKEN` 常量时间比对，防未授权脚本借壳调用）
//  - 敏感应用隐私保护（密码管理器/钥匙串等窗口单窗拦截 + 全屏硬件级自动剔除）
//

import Foundation
import Security

/// 捕获时的敏感应用隐私排除清单（用于全屏/区域捕获通过 `SCContentFilter` 底层剔除密码库等窗口）。
public struct CapturePrivacyExclusion: Sendable, Equatable {
    public let bundleIdentifiers: Set<String>
    public let applicationNames: Set<String>

    public static let none = CapturePrivacyExclusion(bundleIdentifiers: [], applicationNames: [])

    public var isEmpty: Bool {
        bundleIdentifiers.isEmpty && applicationNames.isEmpty
    }

    public init(bundleIdentifiers: Set<String>, applicationNames: Set<String>) {
        self.bundleIdentifiers = Set(bundleIdentifiers.map { $0.lowercased() })
        self.applicationNames = Set(applicationNames.map { $0.lowercased() })
    }

    /// 判定给定窗口是否命中隐私排除规则（大小写不敏感）。
    public func matches(bundleIdentifier: String?, applicationName: String?) -> Bool {
        if let bid = bundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
           !bid.isEmpty,
           bundleIdentifiers.contains(bid) {
            return true
        }
        if let name = applicationName?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
           !name.isEmpty,
           applicationNames.contains(name) {
            return true
        }
        return false
    }
}

/// MCP 与自动化安全策略（由 `AnShotCapture` 提供单一事实来源，供 `AnShotAutomation`、`AnShotUI`、`App` 共享）。
public final class AutomationSecuritySettings: @unchecked Sendable {

    /// 设置发生变更时在进程内广播（常驻 Socket 服务端据此实时启停监听）。
    public static let didChangeNotification = Notification.Name("com.anshot.automationSecuritySettingsDidChange")

    /// 跨进程与测试可复用的共享默认实例。
    public static let shared = AutomationSecuritySettings()

    /// 环境变量名称：AI 客户端配置 MCP 时通过该环境变量传递访问令牌。
    public static let tokenEnvironmentVariable = "ANSHOT_MCP_TOKEN"

    /// 在 `LocalFileSecretStore` 中存储访问令牌的账号键名。
    public static let tokenSecretAccount = "automation.mcp.accessToken"

    private enum Key {
        static let enabled = "automation.security.enabled"
        static let requireToken = "automation.security.requireToken"
        static let protectSensitiveWindows = "automation.security.protectSensitiveWindows"
    }

    /// 默认受保护的敏感隐私应用 Bundle ID 黑名单（密码管理器、系统钥匙串与系统设置）。
    public static let defaultProtectedBundleIdentifiers: Set<String> = [
        "com.1password.1password",
        "com.agilebits.onepassword7",
        "2bua8c4s2c.com.agilebits.onepassword4",
        "com.bitwarden.desktop",
        "org.keepassxc.keepassxc",
        "com.apple.passwords",
        "com.apple.keychainaccess",
        "com.apple.systempreferences",
        "in.sinew.enpass-desktop",
        "com.dashlane.dashlanephonefinal",
        "com.lastpass.lastpass",
        "com.strongboxsafe.strongbox.macos",
        "com.hicknhacksoftware.macpass"
    ]

    /// 默认受保护的敏感隐私应用名黑名单（兜底匹配无法通过 PID 取到 Bundle ID 的情形）。
    public static let defaultProtectedApplicationNames: Set<String> = [
        "1password",
        "1password 7",
        "bitwarden",
        "keepassxc",
        "passwords",
        "密码",
        "keychain access",
        "钥匙串访问",
        "system settings",
        "系统设置",
        "enpass",
        "dashlane",
        "lastpass",
        "strongbox",
        "macpass"
    ]

    private let store: UserDefaults
    private let secrets: SecretStoring

    public init(
        store: UserDefaults = .standard,
        secrets: SecretStoring = LocalFileSecretStore()
    ) {
        self.store = store
        self.secrets = secrets
    }

    // MARK: - 读写属性

    /// 总开关：是否允许 MCP / CLI 通过常驻服务与跨进程通道执行后台自动化。
    public var isAutomationEnabled: Bool {
        if store.object(forKey: Key.enabled) == nil {
            return true
        }
        return store.bool(forKey: Key.enabled)
    }

    public func setAutomationEnabled(_ enabled: Bool) {
        store.set(enabled, forKey: Key.enabled)
        NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
    }

    /// 是否强制要求请求方在 `ANSHOT_MCP_TOKEN` 环境变量中携带有效访问令牌。
    public var requireAccessToken: Bool {
        store.bool(forKey: Key.requireToken)
    }

    public func setRequireAccessToken(_ required: Bool) {
        store.set(required, forKey: Key.requireToken)
        if required, currentAccessToken() == nil {
            _ = try? regenerateAccessToken()
        }
        NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
    }

    /// 是否开启敏感隐私窗口保护（密码管理器/钥匙串单窗拦截 + 全屏自动剔除）。默认开启。
    public var protectSensitiveWindows: Bool {
        if store.object(forKey: Key.protectSensitiveWindows) == nil {
            return true
        }
        return store.bool(forKey: Key.protectSensitiveWindows)
    }

    public func setProtectSensitiveWindows(_ enabled: Bool) {
        store.set(enabled, forKey: Key.protectSensitiveWindows)
        NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
    }

    /// 当前生效的隐私排除配置（关闭开关时返回 `.none`）。
    public var activePrivacyExclusion: CapturePrivacyExclusion {
        guard protectSensitiveWindows else { return .none }
        return CapturePrivacyExclusion(
            bundleIdentifiers: Self.defaultProtectedBundleIdentifiers,
            applicationNames: Self.defaultProtectedApplicationNames
        )
    }

    /// 判定目标窗口是否受隐私保护。
    public func isProtectedWindow(bundleIdentifier: String?, applicationName: String?) -> Bool {
        activePrivacyExclusion.matches(bundleIdentifier: bundleIdentifier, applicationName: applicationName)
    }

    // MARK: - 访问令牌管理与常量时间校验

    /// 读取当前已保存的访问令牌；未生成时为 `nil`。
    public func currentAccessToken() -> String? {
        guard let raw = secrets.secret(for: Self.tokenSecretAccount)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else {
            return nil
        }
        return raw
    }

    /// 若尚未存在访问令牌则生成并持久化一把，然后返回。
    @discardableResult
    public func ensureAccessToken() throws -> String {
        if let existing = currentAccessToken() {
            return existing
        }
        return try regenerateAccessToken()
    }

    /// 重新生成一把全新的 256-bit 随机访问令牌并覆盖存储（旧令牌立即失效）。
    @discardableResult
    public func regenerateAccessToken() throws -> String {
        let token = Self.generateSecureToken()
        try secrets.setSecret(token, for: Self.tokenSecretAccount)
        NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
        return token
    }

    /// 校验调用方提供的令牌是否合法（当 `requireAccessToken == false` 时放行）。
    public func validateAccessToken(_ providedToken: String?) -> Bool {
        guard requireAccessToken else { return true }
        guard let expected = currentAccessToken(),
              let provided = providedToken?.trimmingCharacters(in: .whitespacesAndNewlines),
              !provided.isEmpty else {
            return false
        }
        return Self.constantTimeEquals(expected, provided)
    }

    /// 生成 256-bit（32 字节）加密安全随机令牌（格式 `anshot_<64位小写hex>`）。
    public static func generateSecureToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        if status != errSecSuccess {
            for index in bytes.indices {
                bytes[index] = UInt8.random(in: 0...255)
            }
        }
        let hex = bytes.map { String(format: "%02x", $0) }.joined()
        return "anshot_\(hex)"
    }

    /// 常量时间字符串比对，避免通过响应耗时侧信道枚举令牌前缀。
    public static func constantTimeEquals(_ lhs: String, _ rhs: String) -> Bool {
        let leftBytes = Array(lhs.utf8)
        let rightBytes = Array(rhs.utf8)
        let maxLen = max(leftBytes.count, rightBytes.count)
        var diff: UInt8 = leftBytes.count == rightBytes.count ? 0 : 1
        for i in 0..<maxLen {
            let a = i < leftBytes.count ? leftBytes[i] : 0
            let b = i < rightBytes.count ? rightBytes[i] : 0
            diff |= (a ^ b)
        }
        return diff == 0
    }
}
