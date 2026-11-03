//
//  TextTranslator.swift
//  AnShotCapture
//
//  系统本地翻译的封装（M3-3）。
//
//  ── 为什么可用性是「正常状态」而不是错误 ────────────────
//
//  系统翻译框架要求 macOS 15.0，而本项目部署基线是 13.0；即使系统够新，
//  目标语言包也可能还没装。这两种情形都不是缺陷，而是**预期内的不可用**，
//  所以这里返回 `TranslationAvailability` 而**不抛错**：
//  界面需要把「系统不支持」和「翻译调用失败」分开表达，否则用户只会看到
//  一句没有信息量的「翻译失败」。
//
//  ── 为什么不走 SwiftUI 的 translationTask ────────────────
//
//  官方推荐的入口是 SwiftUI modifier，因为它会在需要时提示用户下载语言包。
//  本应用是菜单栏 AppKit 应用，没有承载该 modifier 的视图，因此使用
//  `TranslationSession(installedSource:target:)`——它只对**已安装**的语言
//  可用，语言包缺失时抛错，由上层降级为「翻译不可用」并给出说明。
//  这是刻意的取舍：宁可明确地说「不可用」，也不偷偷把截图内容送到云端。
//
//  ── 隐私 ──────────────────────────────────────────────────
//
//  只调用系统本地翻译框架，不发起任何网络请求，不外发像素与文本。
//

import AnShotCore
import Foundation
import NaturalLanguage
import Translation

private let translatorLogger = AnShotLog.translation
/// 系统本地翻译。
///
/// **可用性台阶是 macOS 26.0，不是框架自身的 15.0**：`Translation` 框架从
/// 15.0 起存在，但它的 SwiftUI 入口 `translationTask` 之外，唯一能在
/// 无视图环境里构造会话的 `TranslationSession(installedSource:target:)`
/// 标记为 macOS 26.0+（实测编译期拒绝，非推测）。
/// 本应用是 AppKit 菜单栏应用，没有承载 SwiftUI modifier 的视图，
/// 因此对更低版本只能明确报告「不可用」。
@available(macOS 26.0, *)
public enum TextTranslator {

    /// 系统版本要求（用于向用户说明为什么不可用）。
    public static let requiredSystemVersion = "macOS 26.0"

    /// 查询某个语言对是否可用。
    ///
    /// - Parameters:
    ///   - source: 源语言标识；`nil` 或空串表示**尚未判定**。
    ///   - target: 目标语言标识。
    ///
    ///   尚未判定时返回 `.available` 而不是「不支持」：检测不出来是我们自己
    ///   的限制（`NLLanguageRecognizer` 对短文本经常给 nil），不是系统能力
    ///   的问题。把它报成「语言对不支持」会让用户看到一个错误的结论，
    ///   而真实的失败会由实际调用时的降级如实暴露。
    public static func availability(
        source: String?,
        target: String
    ) async -> TranslationAvailability {
        guard let source,
              !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .available
        }
        let status = await LanguageAvailability().status(
            from: Locale.Language(identifier: source),
            to: Locale.Language(identifier: target)
        )
        switch status {
        case .installed:
            return .available
        case .supported:
            // ⚠️ 这一条不能当成可用。`TranslationSession(installedSource:target:)`
            // 只吃**已安装**的语言包，实测这种语言对上会直接抛 `Unable to Translate`。
            // 报「缺语言包」是**可行动**的（去系统设置下载），报「可用」只会
            // 让用户对着一个点了没反应的按钮发呆。
            return .languagePackNotInstalled(source: source, target: target)
        case .unsupported:
            return .unsupportedLanguagePair(source: source, target: target)
        @unknown default:
            return .unsupportedLanguagePair(source: source, target: target)
        }
    }

    /// 逐行翻译。
    ///
    /// 返回结果与 `lines` **顺序与数量一一对应**；任何单行失败都只让那一行
    /// 保留原文，不影响其余行（契约 §5.2）。
    ///
    /// - Parameters:
    ///   - lines: OCR 行。
    ///   - source: 源语言标识；nil 时交给系统检测。
    ///   - target: 目标语言标识。
    public static func translate(
        lines: [OCRTextLine],
        source: String,
        target: String
    ) async -> TranslationResult {
        guard !lines.isEmpty else {
            return TranslationAligner.align(
                lines: [],
                translations: [],
                sourceLanguage: source,
                targetLanguage: target
            )
        }

        // 直接构造 `TranslationSession(installedSource:target:)` 的入口只存在于
        // macOS 26 SDK。Xcode 16 / Swift 6.0（CI 默认镜像）的 SDK 里没有这个
        // 初始化器，连类型检查都会报「没有可访问的初始化器」；因此必须先按
        // **编译器版本**把这段代码排除掉，否则整个包在 CI 上编译失败。
        //
        // 运行时仍然由外层 `#available(macOS 26.0, *)` 守住：Xcode 26 构建的
        // 二进制在 15/25 上也不会走到这里，`availability` 会先报「需要更新系统」。
        #if swift(>=6.2)
        let session = TranslationSession(
            installedSource: Locale.Language(identifier: source),
            target: Locale.Language(identifier: target)
        )

        // 一次性批量提交：系统按提交顺序返回，避免逐行往返。
        let requests = lines.enumerated().map { index, line in
            TranslationSession.Request(
                sourceText: line.text,
                clientIdentifier: String(index)
            )
        }

        var translations = [String?](repeating: nil, count: lines.count)
        do {
            for try await response in session.translate(batch: requests) {
                guard let identifier = response.clientIdentifier,
                      let index = Int(identifier),
                      index >= 0, index < translations.count else { continue }
                translations[index] = response.targetText
            }
        } catch {
            // 整体失败时也保持「不抛错 + 逐行降级」的语义：已返回的行保留，
            // 其余行显示原文。用户看到的仍是完整的一段文字。
            translatorLogger.notice("""
                translation: 部分或全部行翻译失败 → \(error.localizedDescription, privacy: .public)
                """)
        }
        #else
        // 旧 SDK 没有直接构造会话的入口；上层 `availability` 已经会报
        // 「需要 macOS 26」，这里保持逐行原文，不制造一个假的成功。
        let translations = [String?](repeating: nil, count: lines.count)
        #endif

        return TranslationAligner.align(
            lines: lines,
            translations: translations,
            sourceLanguage: source,
            targetLanguage: target
        )
    }

    /// 从识别出的文本推断源语言。
    ///
    /// 契约要求「优先用 OCR 的语言检测结果，避免二次检测产生分歧」，但
    /// Vision 的 `automaticallyDetectsLanguage` 只在请求内部生效、**不对外暴露**
    /// 检测结果。因此在 OCR 之后用 NaturalLanguage 做一次本地判定——
    /// 输入是 OCR 已经识别出来的文本，不是重新对图像做一次识别，所以
    /// 不会产生两套互相矛盾的图像理解。
    public static func detectSourceLanguage(of lines: [OCRTextLine]) -> String? {
        // 委托 `SourceLanguageDetector`：检测能力本身与系统 Translation 框架毫无关系，
        // 留在这里只是为了不打断既有调用点。
        SourceLanguageDetector.detect(in: lines)
    }

    /// 可用的目标语言（用于界面的语言选择）。
    public static func supportedTargetLanguages() async -> [Locale.Language] {
        await LanguageAvailability().supportedLanguages
    }
}
