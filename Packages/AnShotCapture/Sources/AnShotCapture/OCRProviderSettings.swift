//
//  OCRProviderSettings.swift
//  AnShotCapture
//
//  识别 provider 的配置与密钥存储
//  （契约见 docs/model-providers/model.md §2.1 / §4 / §6.2）。
//
//  ── 密钥存在哪里，以及为什么 ──────────────────────────────
//
//  endpoint 与 model 走 UserDefaults：它们不是秘密。
//
//  **API Key 存本地文件**（`~/Library/Application Support/anShot/secrets.json`，
//  权限 0600）。这是用户明确要求的取舍，不是随手的决定：
//
//  * Keychain 在安全性上更好，但对**自签名应用**有实际代价——访问时可能弹出
//    「anShot 想要使用您存储在钥匙串中的机密信息」的授权框。对「截图后顺手
//    贴个密钥」这个场景，弹框的干扰大于它带来的收益。
//  * 之所以不用 UserDefaults 存密钥：那是 plist，窗口位置这类非敏感数据也混在
//    同一份偏好里，导出/备份偏好会一并带走密钥；独立文件可以单独排除。
//  * 文件权限显式设为 0600 且不依赖 umask；目录在应用自己的子目录下（0700）。
//
//  安全边界要说清楚：**本机同一用户下的任何进程都能读到这个文件**。
//  它挡的是「其它用户 / 其它机器 / 误备份」，不挡本机上的恶意程序。
//
//  ── 为什么留一个协议口子 ──────────────────────────────────
//
//  把存储抽象成 `SecretStoring` 之后，测试与诊断可以注入内存实现：
//  既能验证「配置往返」，又不必依赖真实文件的读写与权限设置。
//

import AnShotCore
import Foundation

// MARK: - 配置

/// 某个 provider 的一份配置。
///
/// `apiKey` 只在内存里存在，不随另外两个字段落盘（见 `OCRProviderSettings`）。
public struct OCRProviderConfig: Equatable, Sendable {

    /// 请求地址。空串表示用 provider 的默认地址。
    public var endpoint: String

    /// 模型名。空串表示用 provider 的默认模型。
    public var model: String

    /// API Key。Apple Vision 不使用该字段。
    public var apiKey: String

    /// 第二个凭据：只有百度 OCR 这类用「Key + Secret」换 token 的服务才用。
    /// 与 `apiKey` 一样只在内存里存在，不随另外两个字段落盘。
    public var secretKey: String

    public init(
        endpoint: String = "",
        model: String = "",
        apiKey: String = "",
        secretKey: String = ""
    ) {
        self.endpoint = endpoint
        self.model = model
        self.apiKey = apiKey
        self.secretKey = secretKey
    }

    /// 实际会使用的地址：填了就用填的，否则回落到默认值。
    public func resolvedEndpoint(for kind: OCRProviderKind) -> String {
        let trimmed = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? kind.defaultEndpoint : trimmed
    }

    /// 实际会使用的模型：填了就用填的，否则回落到默认值。
    public func resolvedModel(for kind: OCRProviderKind) -> String {
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? kind.defaultModel : trimmed
    }
}

// MARK: - 密钥存储

/// 密钥存储抽象。
public protocol SecretStoring: Sendable {

    /// 读取密钥；不存在时返回 nil。
    func secret(for account: String) -> String?

    /// 写入密钥；传 nil 或空串表示删除。
    func setSecret(_ value: String?, for account: String) throws

    /// 删除密钥；不存在时不算失败。
    func removeSecret(for account: String) throws
}

/// 本地文件实现。
///
/// 一处一文件、整体读写：密钥条目本来就只有个位数，
/// 增量更新带来的复杂度远大于它省下的那点 IO。
public struct LocalFileSecretStore: SecretStoring {

    private let fileURL: URL

    /// - Parameter fileURL: 存储文件位置；nil 表示用默认位置
    ///   （`~/Library/Application Support/anShot/secrets.json`）。
    public init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? Self.defaultFileURL()
    }

    /// 默认存储位置。
    public static func defaultFileURL() -> URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first
            ?? URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        return base
            .appendingPathComponent("anShot", isDirectory: true)
            .appendingPathComponent("secrets.json", isDirectory: false)
    }

    public func secret(for account: String) -> String? {
        readAll()[account]
    }

    public func setSecret(_ value: String?, for account: String) throws {
        // 「读全部 → 改一条 → 写全部」必须整体互斥：设置页保存密钥与识别任务
        // 刷新 token 缓存可能同时发生，不加锁时后写的一方会带着旧快照覆盖
        // 先写的那一条（例如刚保存的密钥被 token 写入悄悄抹掉）。
        try Self.writeLock.withLock {
            var all = readAll()
            let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let trimmed, !trimmed.isEmpty {
                all[account] = trimmed
            } else {
                all[account] = nil
            }
            try writeAll(all)
        }
    }

    /// 进程内所有实例共用一把锁：它们指向的通常是同一个默认文件。
    private static let writeLock = NSLock()

    public func removeSecret(for account: String) throws {
        try setSecret(nil, for: account)
    }

    private func readAll() -> [String: String] {
        guard let data = try? Data(contentsOf: fileURL),
              let dictionary = try? JSONDecoder().decode([String: String].self, from: data) else {
            return [:]
        }
        return dictionary
    }

    private func writeAll(_ dictionary: [String: String]) throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )

        let data = try JSONEncoder().encode(dictionary)
        // 原子写：先写临时文件再替换。中途失败若留下半截 JSON，
        // 读回来就是空字典——所有密钥一起消失，而不是坏掉一条。
        try data.write(to: fileURL, options: [.atomic])
        // 显式收权。不依赖 umask，也不怕「文件已存在且权限更宽」的情况：
        // atomic 写在某些情况下会保留目标文件的原有权限。
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: fileURL.path
        )
    }
}

/// 内存实现：测试与诊断使用，不做任何持久化。
public final class InMemorySecretStore: SecretStoring, @unchecked Sendable {

    private var storage: [String: String] = [:]
    private let lock = NSLock()

    public init() {}

    public func secret(for account: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return storage[account]
    }

    public func setSecret(_ value: String?, for account: String) throws {
        lock.lock()
        defer { lock.unlock() }
        guard let value, !value.isEmpty else {
            storage[account] = nil
            return
        }
        storage[account] = value
    }

    public func removeSecret(for account: String) throws {
        lock.lock()
        defer { lock.unlock() }
        storage[account] = nil
    }
}

// MARK: - 配置读写

/// 配置的持久化入口：endpoint / model 走 UserDefaults，API Key 走密钥存储。
///
/// `@unchecked Sendable` 的依据：三个存储面都是线程安全的——
/// `UserDefaults` 本身可跨线程访问，`SecretStoring` 的两个实现
///（本地文件 / 内存）各自同步，且属性全是 `let`，
/// 没有任何可变共享状态需要额外保护。
/// 不标它的话 `OCRService` 就无法在 `Task` 里使用：编译器会把
/// 「把 service 送出去」判为数据竞争。
public final class OCRProviderSettings: @unchecked Sendable {

    /// 当前生效的 provider。
    public static let selectedKindKey = "ocr.provider.selected"

    /// 某个 provider 的 endpoint / model 键。
    public static func configKey(for kind: OCRProviderKind) -> String {
        "ocr.provider.\(kind.rawValue).config"
    }

    /// 某个 provider 的密钥账号名。
    public static func secretAccount(for kind: OCRProviderKind) -> String {
        "ocr.\(kind.rawValue).apiKey"
    }

    /// 某个 provider 的第二个凭据账号名（百度 OCR 的 Secret Key）。
    public static func secretKeyAccount(for kind: OCRProviderKind) -> String {
        "ocr.\(kind.rawValue).secretKey"
    }

    private let defaults: UserDefaults
    private let secrets: SecretStoring

    public init(
        defaults: UserDefaults = .standard,
        secrets: SecretStoring = LocalFileSecretStore()
    ) {
        self.defaults = defaults
        self.secrets = secrets
    }

    /// 当前生效的 provider。没配置过时是 Apple Vision——**默认行为不能因为它
    /// 现在「可配置了」就变成需要网络的东西**。
    public var selectedKind: OCRProviderKind {
        get {
            guard let raw = defaults.string(forKey: Self.selectedKindKey),
                  let kind = OCRProviderKind(rawValue: raw) else {
                return .appleVision
            }
            return kind
        }
        set {
            defaults.set(newValue.rawValue, forKey: Self.selectedKindKey)
        }
    }

    /// 读取某个 provider 的完整配置（endpoint / model 来自 UserDefaults，密钥来自密钥存储）。
    public func config(for kind: OCRProviderKind) -> OCRProviderConfig {
        var endpoint = ""
        var model = ""
        if let data = defaults.data(forKey: Self.configKey(for: kind)),
           let dict = try? JSONDecoder().decode([String: String].self, from: data) {
            endpoint = dict["endpoint"] ?? ""
            model = dict["model"] ?? ""
        }
        // 不需要密钥的 provider 不去碰密钥存储：白读一次文件没有意义。
        let apiKey = kind.requiresAPIKey
            ? (secrets.secret(for: Self.secretAccount(for: kind)) ?? "")
            : ""
        let secretKey = kind.requiresSecretKey
            ? (secrets.secret(for: Self.secretKeyAccount(for: kind)) ?? "")
            : ""
        return OCRProviderConfig(
            endpoint: endpoint,
            model: model,
            apiKey: apiKey,
            secretKey: secretKey
        )
    }

    /// 保存配置。endpoint / model 落 UserDefaults，密钥落密钥存储。
    public func save(_ config: OCRProviderConfig, for kind: OCRProviderKind) throws {
        let dict = [
            "endpoint": config.endpoint.trimmingCharacters(in: .whitespacesAndNewlines),
            "model": config.model.trimmingCharacters(in: .whitespacesAndNewlines),
        ]
        if let data = try? JSONEncoder().encode(dict) {
            defaults.set(data, forKey: Self.configKey(for: kind))
        }
        guard kind.requiresAPIKey else { return }
        try secrets.setSecret(config.apiKey, for: Self.secretAccount(for: kind))
        guard kind.requiresSecretKey else { return }
        try secrets.setSecret(config.secretKey, for: Self.secretKeyAccount(for: kind))
    }

    /// 清除配置：两处都要清，只清一处会留下「以为删掉了」的密钥。
    public func clear(_ kind: OCRProviderKind) throws {
        defaults.removeObject(forKey: Self.configKey(for: kind))
        try secrets.removeSecret(for: Self.secretAccount(for: kind))
        try secrets.removeSecret(for: Self.secretKeyAccount(for: kind))
    }

    /// 读取密钥存储里的任意条目。
    ///
    /// 给 provider 缓存**派生凭据**用：百度用两个 Key 换来的 `access_token`
    /// 就是这种性质——它不是用户填的密钥，但和密钥一样不该散落在 UserDefaults 里。
    public func storedSecret(for account: String) -> String? {
        secrets.secret(for: account)
    }

    /// 写入密钥存储里的任意条目；传 `nil` 表示删除。
    public func storeSecret(_ value: String?, for account: String) throws {
        try secrets.setSecret(value, for: account)
    }

    /// 该 provider 是否已具备发请求所需的全部字段。
    public func isConfigured(_ kind: OCRProviderKind) -> Bool {
        // 不需要密钥的本机 provider（Apple Vision）直接算配置完毕。
        // 少了这一句，它会去查一个永远为空的密钥，把「本机可用」判成「未配置」。
        guard kind.requiresAPIKey else { return true }
        let isFilled = { (account: String) in
            !(self.secrets.secret(for: account) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty
        }
        guard isFilled(Self.secretAccount(for: kind)) else { return false }
        // 百度这类服务缺任何一个凭据都换不到 token，只查一半只会得到 401，
        // 而不是「还没配置好」这个用户能自己处理的提示。
        guard kind.requiresSecretKey else { return true }
        return isFilled(Self.secretKeyAccount(for: kind))
    }
}
