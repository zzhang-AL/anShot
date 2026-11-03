//
//  TranslationProviderContract.swift
//  AnShotCore
//
//  翻译的提供者身份（契约见 docs/model-providers/model.md §7）。
//
//  ⚠️ 文件名带 `Contract` 后缀是刻意的：本文件只定义**契约**，不含实现。
//  实现（协议与 Apple 适配器）在 `AnShotCapture/TranslationProvider.swift`。
//  两者曾**同名**，从路径上无法区分二者。
//
//  ── 为什么翻译也需要 provider 化 ─────────────────────────────
//
//  改造前只有一条路：macOS 26.0 的系统 Translation 框架。它有两个硬约束——
//  系统版本（26.0 起）与语言包（需用户自行下载）。两条都不满足时，
//  翻译按钮只是个灰掉的图标，用户没有任何替代路径。
//
//  把提供者抽象出来，云端 API 就是第二条路：**低版本系统也能翻译**。
//  代价是文本会离开本机，所以 `sendsTextOffDevice` 必须显式暴露、
//  由界面持续提示；默认仍然是本机（与 OCR 侧的取舍一致）。
//

import Foundation

/// 翻译的提供者。
public enum TranslationProviderKind: String, Codable, CaseIterable, Sendable {

    /// Apple 系统 Translation 框架（本机，需 macOS 26.0 与语言包）。
    case appleTranslation

    /// 任何 OpenAI chat-completions 兼容的服务。
    case openAICompatible

    /// Anthropic Claude Messages API。
    case claude

    /// 界面展示名。
    public var displayName: String {
        switch self {
        case .appleTranslation: return "Apple 翻译（本机）"
        case .openAICompatible: return "OpenAI 兼容"
        case .claude: return "Claude"
        }
    }

    /// 默认请求地址；空串表示该 provider 不需要地址。
    public var defaultEndpoint: String {
        switch self {
        case .appleTranslation: return ""
        case .openAICompatible: return "https://api.openai.com/v1/chat/completions"
        case .claude: return "https://api.anthropic.com/v1/messages"
        }
    }

    /// 默认模型名；空串表示该 provider 不需要模型。
    public var defaultModel: String {
        switch self {
        case .appleTranslation: return ""
        case .openAICompatible: return "gpt-4o-mini"
        case .claude: return "claude-3-5-haiku-latest"
        }
    }

    /// 是否需要 API Key。Apple 翻译不需要。
    public var requiresAPIKey: Bool { self != .appleTranslation }

    /// 是否需要模型名。Apple 翻译没有模型可选。
    public var requiresModel: Bool { self != .appleTranslation }

    /// 是否会把**文本**发送到本机之外。
    ///
    /// 与 OCR 的「图像外发」分开记：翻译只发文字，但这些文字同样来自用户的截图。
    /// 界面据此给出对应的提示，而不是笼统复用一句「会上传截图」。
    public var sendsTextOffDevice: Bool { self != .appleTranslation }

    /// 本机 provider 的系统版本要求，用于向用户解释为什么不可用。
    ///
    /// 云端 provider 返回 `nil`——它们不受系统版本限制，这正是它们的意义：
    /// 系统不够新时，翻译功能仍然可用。
    public var requiredSystemVersion: String? {
        switch self {
        case .appleTranslation: return "macOS 26.0"
        case .openAICompatible, .claude: return nil
        }
    }
}
