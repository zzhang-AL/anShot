//
//  TranslationService.swift
//  AnShotCapture
//
//  翻译的统一入口（契约见 docs/model-providers/model.md §7.5）。
//
//  ── 降级只发生在「自动」策略下，且只有一个方向 ────────────────
//
//  这里读一次设置，按策略决定要不要降级：
//
//  * `.automatic`：先云端，一行都没翻出来才回到本机。
//  * 显式选中某个 provider：**不降级**，绝不回退到别的 provider。
//
//  第二句尤其重要，而且它同时守住两个方向：用户选本机翻译，就是不想让文字
//  离开这台机器——因为「云端更好用」而自动上传，是对这个选择的直接背叛；
//  反过来，用户明确选了云端，我们也不该替他改成本机，他要的可能正是低版本
//  系统下仍然可用的翻译能力。一条规则同时兜住两边，不必写两句互相打架的话。
//

import AnShotCore
import Foundation

let translationServiceLogger = AnShotLog.translation
/// 翻译入口。
///
/// `Sendable`：只持有一份线程安全的配置读取器与一个不可变工厂，没有可变状态。
public final class TranslationService: Sendable {

    /// 构造 provider 的工厂。
    ///
    /// 抽成参数是为了让「自动降级」这条链可被单测：真去调网络或系统翻译的
    /// 测试既慢又不稳，而降级判断恰恰是最容易写错、也最需要被守住的部分。
    public typealias ProviderFactory = @Sendable (
        TranslationProviderKind,
        TranslationProviderConfig
    ) -> any TranslationProvider

    /// 默认工厂：本机与两个云端各一条实现。
    public static let defaultProviderFactory: ProviderFactory = { kind, config in
        switch kind {
        case .appleTranslation: return AppleTranslationProvider()
        case .openAICompatible: return OpenAICompatibleTranslationProvider(config: config)
        case .claude: return ClaudeTranslationProvider(config: config)
        }
    }

    private let settings: TranslationProviderSettings
    private let makeProvider: ProviderFactory

    public init(
        settings: TranslationProviderSettings = TranslationProviderSettings(),
        makeProvider: @escaping ProviderFactory = TranslationService.defaultProviderFactory
    ) {
        self.settings = settings
        self.makeProvider = makeProvider
    }

    /// 当前生效的选用策略。
    public var selectedStrategy: TranslationStrategy { settings.selectedStrategy }

    /// 自动模式的首选云端；显式选择本机时为 nil。
    public var preferredCloudKind: TranslationProviderKind { settings.preferredCloudKind }

    /// 当前策略下云端凭据是否就绪（同步、零网络）。
    ///
    /// 只回答「密钥填了没有」，不回答「能不能翻」——后者由 `availability` 统一给。
    /// 拆开是因为面板打开时要立刻有个初始状态，那一刻不该为了一个「可能根本
    /// 不会点」的按钮去等异步查询；而精确判定（语言对、语言包）留给真正按下
    /// 按钮的那一刻，那时等待是合理的。
    public var isCloudConfigured: Bool {
        switch settings.selectedStrategy {
        case .automatic:
            return settings.isConfigured(settings.preferredCloudKind)
        case .appleTranslation:
            return true
        case .openAICompatible, .claude:
            guard let kind = settings.selectedStrategy.explicitKind else { return true }
            return settings.isConfigured(kind)
        }
    }

    /// 当前是否可用（结果面板据此决定按钮状态与说明文案）。
    ///
    /// - Parameters:
    ///   - source: 源语言标识；`nil` 表示**尚未判定**。不能因为我们自己没判出来
    ///     就宣布不可用，那等于把「检测失败」伪装成「语言对不支持」。
    ///   - target: 目标语言标识。
    public func availability(source: String?, target: String) async -> TranslationAvailability {
        // 同一个语言：不是「不支持」，而是**不需要翻**。这两句话对用户的意义
        // 完全不同——前者像是功能坏了，后者只需要换个目标语言。
        if TranslationLanguage.isSameLanguage(source, target) {
            return .sameAsTarget(language: target)
        }

        switch settings.selectedStrategy {
        case .automatic:
            if settings.isConfigured(settings.preferredCloudKind) {
                return .available
            }
            // 云端没配：兜底是本机，可用性就完全取决于本机。
            return await localAvailability(source: source, target: target)
        case .appleTranslation:
            return await localAvailability(source: source, target: target)
        case .openAICompatible, .claude:
            guard let kind = settings.selectedStrategy.explicitKind else { return .available }
            guard settings.isConfigured(kind) else {
                return .notConfigured(provider: kind.displayName)
            }
            return .available
        }
    }

    /// 翻译。
    ///
    /// **不抛错**：失败一律表现为「该行未翻译」并保留原文（见 `TranslationProvider`）。
    public func translate(
        lines: [OCRTextLine],
        source: String?,
        target: String
    ) async -> TranslationResult {
        guard !Task.isCancelled, !lines.isEmpty else {
            return untranslatedResult(lines: lines, source: source, target: target)
        }

        switch settings.selectedStrategy {
        case .automatic:
            return await translateAutomatically(lines: lines, source: source, target: target)
        case .appleTranslation, .openAICompatible, .claude:
            guard let kind = settings.selectedStrategy.explicitKind else {
                return untranslatedResult(lines: lines, source: source, target: target)
            }
            // 显式选择即严格：失败就失败，不换 provider。
            return await run(kind: kind, lines: lines, source: source, target: target)
        }
    }

    /// 自动模式：云端优先，拿不到译文再回到本机。
    ///
    /// 「云端不可用」的判据是**实际结果**（一行都没翻出来），而不是可用性查询：
    /// 密钥过期、模型名写错、服务商限流，这些都只在真发一次请求时才暴露，
    /// 而查配置只能查出「密钥是不是空的」。用结果判定会多花一次请求的时间，
    /// 但那是这个功能唯一诚实的可用性来源。
    private func translateAutomatically(
        lines: [OCRTextLine],
        source: String?,
        target: String
    ) async -> TranslationResult {
        let cloud = settings.preferredCloudKind

        if settings.isConfigured(cloud) {
            let result = await run(kind: cloud, lines: lines, source: source, target: target)
            guard !Task.isCancelled else {
                return untranslatedResult(lines: lines, source: source, target: target)
            }
            if !result.isEntirelyUntranslated {
                return result
            }
            // 部分成功也算成功：逐行降级已经在结果里表达了，整段重翻一遍
            // 只会把已经翻好的行也换成另一套译文。
            translationServiceLogger.notice("""
                automatic: 云端未给出任何译文，回落到本机 provider=\(cloud.rawValue, privacy: .public)
                """)
        } else {
            translationServiceLogger.notice("""
                automatic: 首选云端未配置密钥，直接使用本机 provider=\(cloud.rawValue, privacy: .public)
                """)
        }

        return await run(kind: .appleTranslation, lines: lines, source: source, target: target)
    }

    /// 用指定的 provider 完整跑一次，并留下可归因的计时日志。
    ///
    /// 日志里带 `provider` 是硬要求：自动模式下一次点击可能对应两次调用，
    /// 不写明谁跑的，看日志的人无法判断「慢」和「没结果」该算在谁头上。
    private func run(
        kind: TranslationProviderKind,
        lines: [OCRTextLine],
        source: String?,
        target: String
    ) async -> TranslationResult {
        guard !Task.isCancelled else {
            return untranslatedResult(lines: lines, source: source, target: target)
        }
        let provider = makeProvider(kind, settings.config(for: kind))
        let started = Date()
        let result = await provider.translate(lines, from: source, to: target)
        translationServiceLogger.notice("""
            translation: provider=\(kind.rawValue, privacy: .public) \
            \(source ?? "auto", privacy: .public)→\(target, privacy: .public) \
            成功 \(result.translatedCount, privacy: .public)/\(result.segments.count, privacy: .public) 行 \
            耗时=\(Int(Date().timeIntervalSince(started) * 1000), privacy: .public)ms
            """)
        return result
    }

    /// 本机翻译的可用性（系统版本 + 语言对与语言包）。
    private func localAvailability(
        source: String?,
        target: String
    ) async -> TranslationAvailability {
        guard #available(macOS 26.0, *) else {
            // 不用 `TextTranslator.requiredSystemVersion`：那个符号本身标了
            // macOS 26.0 可用性，在「版本不够」的分支里引用它编译不过。
            return .requiresNewerSystem(
                required: TranslationProviderKind.appleTranslation.requiredSystemVersion ?? "macOS 26.0"
            )
        }
        return await TextTranslator.availability(source: source, target: target)
    }
}
