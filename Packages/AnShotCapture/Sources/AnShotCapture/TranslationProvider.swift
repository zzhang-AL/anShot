//
//  TranslationProvider.swift
//  AnShotCapture
//
//  翻译提供者协议与本机实现（契约见 docs/model-providers/model.md §7.1）。
//
//  ── 契约核心：结果必须与输入行一一对应 ─────────────────────
//
//  `TranslationResult.segments` 与传入的 `lines` 必须**行数相同、顺序相同**。
//  这不是为了好看：下游（面板逐行显示、将来的译文原位替换）靠下标对齐，
//  少一行或多一行都会让「第 3 行的译文」显示在第 4 行的位置。
//
//  因此所有实现都必须**降级而不是丢弃**：某一行翻不出来就保留原文
//  （`translatedText = nil`，`displayText` 回落到原文），绝不能从数组里删掉它。
//

import AnShotCore
import Foundation

/// 翻译提供者。
public protocol TranslationProvider: Sendable {

    var kind: TranslationProviderKind { get }

    /// 把识别出的行翻译成目标语言。
    ///
    /// 实现**不抛错**：失败一律表现为「该行未翻译」。原因是调用点只有一个
    /// （结果面板的按钮），用户能做的处理也只是重试；把失败做成异常只会
    /// 逼每个调用点重复写一遍降级逻辑，而这套降级正是最容易写错的部分。
    ///
    /// - Parameters:
    ///   - lines: 待翻译的行。
    ///   - source: 源语言标识（BCP-47）；`nil` 表示交给实现自行判断。
    ///   - target: 目标语言标识（BCP-47）。
    func translate(
        _ lines: [OCRTextLine],
        from source: String?,
        to target: String
    ) async -> TranslationResult
}

/// 全部未翻译的结果（降级用）。
///
/// 集中在这里：每个实现都要用到它，各写一遍迟早出现「一边填 nil、
/// 另一边填原文」的分叉。
func untranslatedResult(
    lines: [OCRTextLine],
    source: String?,
    target: String
) -> TranslationResult {
    TranslationAligner.align(
        lines: lines,
        translations: Array(repeating: nil, count: lines.count),
        sourceLanguage: source ?? "",
        targetLanguage: target
    )
}

// MARK: - Apple 本机

/// Apple 系统 Translation 框架（本机）。
///
/// 完全委托 `TextTranslator`，不添任何加工：它已经实现了批量提交、
/// 结果对齐与逐行降级，这里再包一层逻辑只会产生第二套行为。
public struct AppleTranslationProvider: TranslationProvider {

    public init() {}

    public var kind: TranslationProviderKind { .appleTranslation }

    public func translate(
        _ lines: [OCRTextLine],
        from source: String?,
        to target: String
    ) async -> TranslationResult {
        guard !lines.isEmpty else {
            return untranslatedResult(lines: lines, source: source, target: target)
        }
        // 系统版本不够就是不可用，而不是「翻译失败」：这里返回全部原文，
        // 界面上的按钮本来就会因为这个原因被禁用。
        guard #available(macOS 26.0, *) else {
            return untranslatedResult(lines: lines, source: source, target: target)
        }
        // 系统框架要求明确的源语言（不存在「自动检测」这个入参），
        // 识别不出源语言时只能降级——交给系统去猜会得到一个语种错乱的原文回显。
        guard let detected = source ?? TextTranslator.detectSourceLanguage(of: lines), !detected.isEmpty else {
            return untranslatedResult(lines: lines, source: source, target: target)
        }
        return await TextTranslator.translate(lines: lines, source: detected, target: target)
    }
}
