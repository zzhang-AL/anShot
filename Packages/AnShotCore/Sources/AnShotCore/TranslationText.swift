//
//  TranslationText.swift
//  AnShotCore
//
//  翻译结果模型（M3-3）。
//
//  ── 契约（m3-advanced/model.md §5.2）──────────────────────
//
//  * `segments` 与 OCR 的 `lines` **顺序与数量一一对应**——这是硬约束，
//    不是实现细节：译文要能原位替换到图上对应的文字框里，一旦错位，
//    显示出来的就是「这句话的译文配那张图的位置」这种最糟的错误。
//  * **单行失败不导致整体失败**：该行标记为未翻译并保留原文。
//  * 按行而非按段：不做段落合并（那需要版面分析，属非目标）。
//
//  ── 为什么这里不 import Translation ──────────────────────
//
//  `Translation` 框架是 macOS 15.0+ 且 Swift-only，而本项目部署基线是 13.0。
//  模型与「按行对齐 + 失败降级」的规则是纯数据逻辑，放在 AnShotCore 后
//  既能被单测覆盖，又不把 15.0 的可用性要求传染给整个核心模块。
//  真正的框架调用隔离在 AnShotCapture 的一个 `@available` 封装里。
//

import Foundation

/// 一行译文。
public struct TranslationSegment: Codable, Equatable, Sendable {

    /// 原文（来自对应 OCR 行）。
    public let sourceText: String

    /// 译文；未翻译时为 nil。
    public let translatedText: String?

    /// 这一行是否真的翻译成功。
    public var isTranslated: Bool { translatedText != nil }

    /// 界面上应当显示的文字：翻译成功用译文，失败保留原文。
    ///
    /// 把这条规则放在模型上而不是各调用点，是为了让「失败就显示原文」
    /// 只有一处实现——否则按钮、面板、导出三处会各写一遍并逐渐不一致。
    public var displayText: String { translatedText ?? sourceText }

    public init(sourceText: String, translatedText: String?) {
        self.sourceText = sourceText
        self.translatedText = translatedText
    }
}

/// 一次翻译的结果。
public struct TranslationResult: Codable, Equatable, Sendable {

    /// 源语言标识（优先取自 OCR 的语言检测结果，避免二次检测产生分歧）。
    public let sourceLanguage: String?

    /// 目标语言标识。
    public let targetLanguage: String

    /// 按行译文，**顺序与数量与 OCR 的 lines 一一对应**。
    public let segments: [TranslationSegment]

    public init(sourceLanguage: String?, targetLanguage: String, segments: [TranslationSegment]) {
        self.sourceLanguage = sourceLanguage
        self.targetLanguage = targetLanguage
        self.segments = segments
    }

    /// 成功翻译的行数。
    public var translatedCount: Int { segments.filter(\.isTranslated).count }

    /// 是否全部行都没翻出来（界面据此提示「翻译不可用」而不是逐行报错）。
    public var isEntirelyUntranslated: Bool { translatedCount == 0 && !segments.isEmpty }

    /// 是否部分成功。
    public var isPartiallyTranslated: Bool { translatedCount > 0 && translatedCount < segments.count }
}

/// 翻译的可用性。
///
/// 部署基线是 macOS 13.0，而系统翻译框架要求 15.0，所以「不可用」是
/// 一个**正常状态**而不是错误：界面需要能明确区分「系统不支持」与
/// 「翻译调用失败」，前者应当把入口置灰并说明原因。
public enum TranslationAvailability: Equatable, Sendable {

    /// 可用。
    case available

    /// 当前系统版本低于框架要求。
    case requiresNewerSystem(required: String)

    /// 语言对不受支持。
    case unsupportedLanguagePair(source: String?, target: String)

    /// 尚未确定（异步查询中）。
    case unknown

    /// 选中的云端 provider 还缺配置（密钥等）。
    case notConfigured(provider: String)

    /// 源语言与目标语言是同一个语言：不是「不支持」，而是**不需要翻**。
    ///
    /// 单独表达的理由：系统对 `en` → `en-US` 返回 `.unsupported`，若照搬就会
    /// 显示成「不支持这个语言对」，用户看到的信息是错的。
    case sameAsTarget(language: String)

    /// 系统支持该语言对，但本机还没下载对应的语言包。
    ///
    /// 与 `unsupportedLanguagePair` 分开：这一条是**可行动**的
    /// （去系统设置里下载即可），前者不是。实测 `installedSource` 会话在
    /// 这种语言对上会直接抛 `Unable to Translate`。
    case languagePackNotInstalled(source: String, target: String)

    /// 能否尝试翻译。
    public var isAvailable: Bool { self == .available }

    /// 面向用户的说明。
    ///
    /// 措词不再写死「系统本地翻译」：翻译现在可以是本机或云端两种来源，
    /// 一句话说死会让云端用户对着「系统本地翻译不可用」发懵。
    public var explanation: String {
        switch self {
        case .available:
            return "翻译可用"
        case .requiresNewerSystem(let required):
            return "本机翻译需要 \(required) 或更新版本；可在设置中改用云端翻译服务"
        case .unsupportedLanguagePair(let source, let target):
            let from = source ?? "自动检测"
            return "不支持 \(from) → \(target) 这个语言对"
        case .unknown:
            return "正在检查翻译可用性…"
        case .notConfigured(let provider):
            return "「\(provider)」还没配置完成，请到设置里填写密钥"
        case .sameAsTarget(let language):
            return "原文已经是\(TranslationLanguage.displayName(of: language))，无需翻译"
        case .languagePackNotInstalled(let source, let target):
            let from = TranslationLanguage.displayName(of: source)
            let to = TranslationLanguage.displayName(of: target)
            return "本机缺少 \(from) → \(to) 的语言包，请在「系统设置 › 通用 › 语言与地区」中下载"
        }
    }
}

/// 把 OCR 行与译文对齐成结果。
///
/// 单独抽出来是因为「一一对应」这条契约需要一个**唯一**的实现：
/// 任何调用点自己拼 `segments` 都可能漏掉一行或错开一位，
/// 而这种错误在界面上只表现为译文错位，不会被任何断言自然发现。
public enum TranslationAligner {

    /// 按行对齐。
    ///
    /// - Parameters:
    ///   - lines: OCR 行（顺序即契约顺序）。
    ///   - translations: 逐行译文；**短于 lines 或含 nil 都按未翻译处理**，
    ///     不抛错、不截断——契约要求单行失败不导致整体失败。
    ///   - sourceLanguage: 源语言标识。
    ///   - targetLanguage: 目标语言标识。
    public static func align(
        lines: [OCRTextLine],
        translations: [String?],
        sourceLanguage: String?,
        targetLanguage: String
    ) -> TranslationResult {
        let segments = lines.enumerated().map { index, line -> TranslationSegment in
            let candidate = index < translations.count ? translations[index] : nil
            // 空白译文等同于没翻出来：系统在无法翻译时可能返回空串，
            // 若把它当作成功，界面上会出现一整行空白。
            let cleaned = candidate?.trimmingCharacters(in: .whitespacesAndNewlines)
            let text = (cleaned?.isEmpty ?? true) ? nil : cleaned
            return TranslationSegment(sourceText: line.text, translatedText: text)
        }
        return TranslationResult(
            sourceLanguage: sourceLanguage,
            targetLanguage: targetLanguage,
            segments: segments
        )
    }
}
