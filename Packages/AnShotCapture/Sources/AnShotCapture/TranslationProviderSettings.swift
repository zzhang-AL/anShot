//
//  TranslationProviderSettings.swift
//  AnShotCapture
//
//  翻译 provider 的持久化设置（契约见 docs/model-providers/model.md §7.3）。
//
//  与 `OCRProviderSettings` 是同构的：endpoint / model 落 UserDefaults，
//  密钥落本地密钥文件，两处分开的理由也一样——见 §4 的说明。
//

import AnShotCore
import Foundation

/// 某个翻译 provider 的一份配置。
///
/// `apiKey` 只在内存里存在，不随另外两个字段落盘。
public struct TranslationProviderConfig: Equatable, Sendable {

    /// 请求地址。空串表示用 provider 的默认地址。
    public var endpoint: String

    /// 模型名。空串表示用 provider 的默认模型。
    public var model: String

    /// API Key。Apple 翻译不使用该字段。
    public var apiKey: String

    public init(endpoint: String = "", model: String = "", apiKey: String = "") {
        self.endpoint = endpoint
        self.model = model
        self.apiKey = apiKey
    }

    /// 实际会使用的地址：填了就用填的，否则回落到默认值。
    public func resolvedEndpoint(for kind: TranslationProviderKind) -> String {
        let trimmed = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? kind.defaultEndpoint : trimmed
    }

    /// 实际会使用的模型：填了就用填的，否则回落到默认值。
    public func resolvedModel(for kind: TranslationProviderKind) -> String {
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? kind.defaultModel : trimmed
    }
}

/// 翻译 provider 设置的读写。
///
/// `@unchecked Sendable` 的理由与 `OCRProviderSettings` 相同：UserDefaults
/// 跨线程可访问，两种 `SecretStoring` 实现都有同步保护，类内没有可变存储属性。
public final class TranslationProviderSettings: @unchecked Sendable {

    /// 当前生效的选用策略。
    ///
    /// **键名未变**：策略的 rawValue 与旧 provider 的 rawValue 同名
    /// （`appleTranslation` / `openAICompatible` / `claude`），旧配置能直接
    /// 解析成对应的显式策略，不需要迁移。唯一变化是键缺失时的默认值：
    /// 以前是「Apple 翻译」，现在是「自动」。
    public static let selectedStrategyKey = "translation.provider.selected"

    /// 自动模式的云端首选。
    public static let preferredCloudKey = "translation.cloud.primary"

    /// 某个 provider 的 endpoint / model 键。
    public static func configKey(for kind: TranslationProviderKind) -> String {
        "translation.provider.\(kind.rawValue).config"
    }

    /// 某个 provider 的密钥账号名。
    public static func secretAccount(for kind: TranslationProviderKind) -> String {
        "translation.\(kind.rawValue).apiKey"
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

    /// 当前生效的选用策略。
    ///
    /// 缺省是 **自动（云端优先，本机兜底）**：自动模式要先外发，所以默认值
    /// 不是无害的，必须说清楚它为什么可以当默认——云端的可用前提是用户
    /// **自己配了密钥**，没配则永远走本机，因此这个默认值不会偷偷外发。
    public var selectedStrategy: TranslationStrategy {
        get {
            guard let raw = defaults.string(forKey: Self.selectedStrategyKey),
                  let strategy = TranslationStrategy(rawValue: raw) else {
                return .automatic
            }
            return strategy
        }
        set {
            defaults.set(newValue.rawValue, forKey: Self.selectedStrategyKey)
        }
    }

    /// 自动模式下的云端首选 provider。
    ///
    /// 只接受云端 kind：本机不该被用作「云端首选」，写坏的值一律回落，
    /// 免得自动模式走进一条「首选本身是本机」的死路。
    public var preferredCloudKind: TranslationProviderKind {
        get {
            guard let raw = defaults.string(forKey: Self.preferredCloudKey),
                  let kind = TranslationProviderKind(rawValue: raw),
                  TranslationStrategy.cloudKinds.contains(kind) else {
                return TranslationStrategy.defaultCloudKind
            }
            return kind
        }
        set {
            defaults.set(newValue.rawValue, forKey: Self.preferredCloudKey)
        }
    }

    /// 读取某个 provider 的完整配置。
    public func config(for kind: TranslationProviderKind) -> TranslationProviderConfig {
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
        return TranslationProviderConfig(endpoint: endpoint, model: model, apiKey: apiKey)
    }

    /// 保存配置。endpoint / model 落 UserDefaults，密钥落密钥存储。
    public func save(_ config: TranslationProviderConfig, for kind: TranslationProviderKind) throws {
        let dict = [
            "endpoint": config.endpoint.trimmingCharacters(in: .whitespacesAndNewlines),
            "model": config.model.trimmingCharacters(in: .whitespacesAndNewlines),
        ]
        if let data = try? JSONEncoder().encode(dict) {
            defaults.set(data, forKey: Self.configKey(for: kind))
        }
        guard kind.requiresAPIKey else { return }
        try secrets.setSecret(config.apiKey, for: Self.secretAccount(for: kind))
    }

    /// 清除配置：两处都要清，只清一处会留下「以为删掉了」的密钥。
    public func clear(_ kind: TranslationProviderKind) throws {
        defaults.removeObject(forKey: Self.configKey(for: kind))
        try secrets.removeSecret(for: Self.secretAccount(for: kind))
    }

    /// 该 provider 是否已具备发请求所需的全部字段。
    public func isConfigured(_ kind: TranslationProviderKind) -> Bool {
        // 不需要密钥的本机 provider 直接算配置完毕。
        guard kind.requiresAPIKey else { return true }
        let key = secrets.secret(for: Self.secretAccount(for: kind)) ?? ""
        return !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// 读取密钥存储里的任意条目（供 provider 缓存派生凭据）。
    public func storedSecret(for account: String) -> String? {
        secrets.secret(for: account)
    }

    /// 写入密钥存储里的任意条目；传 `nil` 表示删除。
    public func storeSecret(_ value: String?, for account: String) throws {
        try secrets.setSecret(value, for: account)
    }
}
