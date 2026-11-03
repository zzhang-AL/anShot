//
//  TranslationStrategy.swift
//  AnShotCore
//
//  翻译的选用策略与语言标识比较（契约见 docs/model-providers/model.md §7.6）。
//
//  ── 为什么与 TranslationProviderKind 分开 ─────────────────────
//
//  `TranslationProviderKind` 回答的是「用谁翻」，是一份**身份**；
//  「翻不出来时要不要换一个」回答的是**行为**，两者不是一回事。
//  把 `automatic` 塞进 provider 枚举，它就得回答 `defaultEndpoint`、
//  `requiresAPIKey` 这些它根本不存在的问题——那不是抽象，是污染。
//
//  ── 允许降级的方向只有一条 ───────────────────────────────────
//
//  `.automatic` 是**云端优先、本机兜底**：先外发，拿不到译文才回到本机。
//  这个方向是安全的——它不会把用户想留在本机的文字发出去。
//
//  反过来（本机优先、失败自动上传）无论怎么解释都不该做：用户选本机就是
//  不想外发，因为云端更「好用」而替他改主意，是对该选择的直接背叛。
//  所以显式选中某个 provider 时，**绝不降级**。
//

import Foundation

/// 翻译的选用策略。
public enum TranslationStrategy: String, Codable, CaseIterable, Sendable {

    /// 先用已配置的云端 provider，拿不到译文再回到本机。
    case automatic

    /// 只用 Apple 系统翻译（本机）；失败就如实失败，绝不外发。
    case appleTranslation

    /// 只用 OpenAI 兼容的云端服务。
    case openAICompatible

    /// 只用 Anthropic Claude。
    case claude

    /// 设置界面的展示名。
    public var displayName: String {
        switch self {
        case .automatic: return "自动（云端优先，本机兜底）"
        case .appleTranslation: return TranslationProviderKind.appleTranslation.displayName
        case .openAICompatible: return TranslationProviderKind.openAICompatible.displayName
        case .claude: return TranslationProviderKind.claude.displayName
        }
    }

    /// 显式指定的 provider；`automatic` 返回 nil——它本身不是一个 provider。
    public var explicitKind: TranslationProviderKind? {
        switch self {
        case .automatic: return nil
        case .appleTranslation: return .appleTranslation
        case .openAICompatible: return .openAICompatible
        case .claude: return .claude
        }
    }

    /// 是否允许在拿不到译文时换另一个 provider。
    public var allowsFallback: Bool { self == .automatic }

    /// 是否是自动策略（调用方据此决定要不要读「首选云端」）。
    public var isAutomatic: Bool { self == .automatic }

    /// 自动模式的**云端首选**候选。
    ///
    /// 只有云端：本机不能充当「云端首选」，那是另一条 case 的事。
    /// 不按「已配置的云端全试一遍」也是有意的——用户配过的服务不一定都想
    /// 被隐式使用，把文本发给一个界面上没被选中的第三方，比少翻一次糟得多。
    public static let cloudKinds: [TranslationProviderKind] = [defaultCloudKind, .claude]

    /// 自动模式的默认云端首选。
    public static let defaultCloudKind: TranslationProviderKind = .openAICompatible
}

/// 语言标识的规范化与比较。
///
/// 存在的理由是一个实测出来的坑：`LanguageAvailability` 把 `en` → `en-US`
/// 判为 **unsupported**（同一语言，没什么可翻），于是「英文截图 + 目标选
/// 译成英文」会被判成「语言对不支持」，用户点了按钮只听到一声响。
///
/// 同一个语言不是错误，也不是「不支持」，而是一件应当**说清楚**的事。
public enum TranslationLanguage {

    /// 规范化成「语言 + 脚本」，用于判断是否同一语言。
    ///
    /// 只保留主语言码与脚本，丢掉区域与变体：`en`、`en-US`、`en-GB` 是同一
    /// 语言；而 `zh-Hans` 与 `zh-Hant` 不是——那是简繁转换，用户确实可能要。
    public static func normalized(_ identifier: String) -> String {
        let unified = identifier
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "_", with: "-")
            .lowercased()
        let subtags = unified.split(separator: "-").map(String.init)
        guard let language = subtags.first, !language.isEmpty else { return "" }
        // 脚本子标签固定四字母（Hans / Hant / Latn…），其余（US / 419 / 变体）都丢掉。
        let script = subtags.dropFirst().first { $0.count == 4 && $0.allSatisfy { $0.isLetter } }
        guard let script else { return language }
        return "\(language)-\(script)"
    }

    /// 两个标识是否指同一语言；任一为空或无法判定时返回 false（宁可放行）。
    public static func isSameLanguage(_ lhs: String?, _ rhs: String?) -> Bool {
        guard let lhs, let rhs else { return false }
        let left = normalized(lhs)
        let right = normalized(rhs)
        guard !left.isEmpty, !right.isEmpty else { return false }
        return left == right
    }

    /// 面向用户的语言名。
    ///
    /// 认不出来就原样回传标识：编一个错的名字比给出 `xx-YY` 更难排查。
    public static func displayName(of identifier: String) -> String {
        switch normalized(identifier) {
        case "en": return "英文"
        case "zh-hans": return "简体中文"
        case "zh-hant": return "繁体中文"
        case "ja": return "日文"
        case "ko": return "韩文"
        case "fr": return "法文"
        case "de": return "德文"
        case "es": return "西班牙文"
        case "pt": return "葡萄牙文"
        case "ru": return "俄文"
        case "it": return "意大利文"
        case "ar": return "阿拉伯文"
        case "th": return "泰文"
        case "vi": return "越南文"
        default: return identifier
        }
    }
}
