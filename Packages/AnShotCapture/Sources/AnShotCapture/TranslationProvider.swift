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
import os

/// macOS 15.0+ SwiftUI `.translationTask` 极薄桥接执行器协议。
///
/// 由 `AnShotUI` 层的 `AppleTranslationBridge` 实现并注册，
/// 既保持 `AnShotCapture` 不依赖 `SwiftUI`/`AppKit`，又把本机系统翻译能力门槛从 macOS 26.0 降至 macOS 15.0，
/// 且可触发系统原生语言包下载弹窗。
public protocol AppleTranslationBridgeExecutor: Sendable {
    func translate(
        _ lines: [OCRTextLine],
        from source: String?,
        to target: String
    ) async -> TranslationExecutionResult
}

/// 线程安全的本机翻译桥接注册表。
public enum AppleTranslationBridgeRegistry {
    private static let lock = OSAllocatedUnfairLock<(any AppleTranslationBridgeExecutor)?>(initialState: nil)

    public static var executor: (any AppleTranslationBridgeExecutor)? {
        lock.withLock { $0 }
    }

    public static func register(_ executor: (any AppleTranslationBridgeExecutor)?) {
        lock.withLock { $0 = executor }
    }
}

/// 附带诊断错误信息的翻译执行结果（用于向结果面板与设置页透传云端失败原因）。
public struct TranslationExecutionResult: Equatable, Sendable {
    public let result: TranslationResult
    public let errorMessage: String?

    public init(result: TranslationResult, errorMessage: String? = nil) {
        self.result = result
        self.errorMessage = errorMessage
    }
}

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

/// 支持透传失败诊断信息的翻译提供者（如云端翻译）。
public protocol DiagnosticTranslationProvider: TranslationProvider {
    func translateWithDiagnostics(
        _ lines: [OCRTextLine],
        from source: String?,
        to target: String
    ) async -> TranslationExecutionResult
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
/// 在 macOS 15.0+ 上优先委托 `AnShotUI` 注册的极薄 SwiftUI `.translationTask` 桥接执行器（支持语言包自动弹窗下载）；
/// 未注册桥接且处于 macOS 26.0+ 时回退到无视图 `TextTranslator`。
public struct AppleTranslationProvider: DiagnosticTranslationProvider {

    public init() {}

    public var kind: TranslationProviderKind { .appleTranslation }

    public func translate(
        _ lines: [OCRTextLine],
        from source: String?,
        to target: String
    ) async -> TranslationResult {
        await translateWithDiagnostics(lines, from: source, to: target).result
    }

    public func translateWithDiagnostics(
        _ lines: [OCRTextLine],
        from source: String?,
        to target: String
    ) async -> TranslationExecutionResult {
        guard !lines.isEmpty else {
            return TranslationExecutionResult(result: untranslatedResult(lines: lines, source: source, target: target))
        }
        guard #available(macOS 15.0, *) else {
            return TranslationExecutionResult(
                result: untranslatedResult(lines: lines, source: source, target: target),
                errorMessage: "本机系统翻译需要 macOS 15.0 或更新版本，请在设置中改用云端翻译服务。"
            )
        }

        // 优先走 macOS 15.0+ SwiftUI `.translationTask` 桥接（支持系统语言包下载提示）。
        if let bridge = AppleTranslationBridgeRegistry.executor {
            return await bridge.translate(lines, from: source, to: target)
        }

        // 无 UI 宿主环境（例如纯 CLI/测试）：macOS 26.0+ 可直接走无视图 `TextTranslator`。
        if #available(macOS 26.0, *) {
            guard let detected = source ?? TextTranslator.detectSourceLanguage(of: lines), !detected.isEmpty else {
                return TranslationExecutionResult(
                    result: untranslatedResult(lines: lines, source: source, target: target),
                    errorMessage: "无法自动识别源语言，请手动指定源语言后重试。"
                )
            }
            let translated = await TextTranslator.translate(lines: lines, source: detected, target: target)
            return TranslationExecutionResult(result: translated)
        }

        return TranslationExecutionResult(
            result: untranslatedResult(lines: lines, source: source, target: target),
            errorMessage: "当前环境未加载系统翻译桥接，请在应用窗口内重试或改用云端翻译。"
        )
    }
}
