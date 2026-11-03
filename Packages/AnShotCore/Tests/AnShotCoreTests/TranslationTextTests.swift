//
//  TranslationTextTests.swift
//  AnShotCoreTests
//
//  翻译结果模型（M3-3）的对齐与降级契约。
//
//  这些测试盯的是契约里最容易在实现中走形的两条：
//  「逐行一一对应」与「单行失败保留原文、不影响其余行」。
//

import Foundation
import Testing

@testable import AnShotCore

@Suite("TranslationText")
struct TranslationTextTests {

    private func line(_ text: String, y: Double = 0) -> OCRTextLine {
        OCRTextLine(
            text: text,
            candidates: [text],
            confidence: 0.9,
            boundingBox: PixelRect(origin: PixelPoint(x: 0, y: y), size: PixelSize(width: 100, height: 20))
        )
    }

    // MARK: - 一一对应

    @Test("译文数量与顺序与 OCR 行严格一致")
    func alignsOneToOne() {
        let lines = [line("你好", y: 0), line("世界", y: 30), line("再见", y: 60)]

        let result = TranslationAligner.align(
            lines: lines,
            translations: ["Hello", "World", "Goodbye"],
            sourceLanguage: "zh-Hans",
            targetLanguage: "en-US"
        )

        #expect(result.segments.count == lines.count)
        #expect(result.segments.map(\.sourceText) == ["你好", "世界", "再见"])
        #expect(result.segments.map(\.translatedText) == ["Hello", "World", "Goodbye"])
        #expect(result.sourceLanguage == "zh-Hans")
        #expect(result.targetLanguage == "en-US")
    }

    @Test("译文少于行数时，缺失的行按未翻译处理而不是丢弃行")
    func missingTranslationsDoNotDropLines() {
        let lines = [line("一"), line("二"), line("三")]

        let result = TranslationAligner.align(
            lines: lines,
            translations: ["One"],
            sourceLanguage: nil,
            targetLanguage: "en-US"
        )

        #expect(result.segments.count == 3, "对齐绝不能改变行数")
        #expect(result.segments[0].isTranslated)
        #expect(result.segments[1].isTranslated == false)
        #expect(result.segments[2].isTranslated == false)
        #expect(result.segments[1].displayText == "二", "未翻译的行显示原文")
    }

    // MARK: - 单行失败降级

    @Test("单行失败保留原文，其余行照常翻译")
    func partialFailureKeepsOriginalText() {
        let lines = [line("甲"), line("乙"), line("丙")]

        let result = TranslationAligner.align(
            lines: lines,
            translations: ["Alpha", nil, "Gamma"],
            sourceLanguage: "zh-Hans",
            targetLanguage: "en-US"
        )

        #expect(result.segments[1].isTranslated == false)
        #expect(result.segments[1].displayText == "乙")
        #expect(result.translatedCount == 2)
        #expect(result.isPartiallyTranslated)
        #expect(result.isEntirelyUntranslated == false)
    }

    @Test("空白译文算未翻译（否则界面上会出现整行空白）")
    func blankTranslationIsTreatedAsFailure() {
        let lines = [line("甲"), line("乙")]

        let result = TranslationAligner.align(
            lines: lines,
            translations: ["   ", "\n"],
            sourceLanguage: nil,
            targetLanguage: "en-US"
        )

        #expect(result.segments.allSatisfy { !$0.isTranslated })
        #expect(result.segments.map(\.displayText) == ["甲", "乙"])
        #expect(result.isEntirelyUntranslated)
    }

    @Test("全部失败时整体标记为未翻译，调用方可据此提示不可用")
    func allFailedIsFlagged() {
        let result = TranslationAligner.align(
            lines: [line("甲"), line("乙")],
            translations: [nil, nil],
            sourceLanguage: nil,
            targetLanguage: "en-US"
        )

        #expect(result.translatedCount == 0)
        #expect(result.isEntirelyUntranslated)
        #expect(result.isPartiallyTranslated == false)
    }

    @Test("没有行时不算「全部未翻译」（避免空选区被报成失败）")
    func emptyInputIsNotAFailure() {
        let result = TranslationAligner.align(
            lines: [],
            translations: [],
            sourceLanguage: nil,
            targetLanguage: "en-US"
        )

        #expect(result.segments.isEmpty)
        #expect(result.isEntirelyUntranslated == false)
    }

    // MARK: - 可用性

    @Test("低版本系统报告为需要更新的系统，而不是可用")
    func availabilityGatesOnSystemVersion() {
        let state = TranslationAvailability.requiresNewerSystem(required: "macOS 15.0")

        #expect(state.isAvailable == false)
        #expect(state.explanation.contains("15.0"))
        // 文案必须同时给出**出路**：只说「不可用」，云端用户会不知道还有别的选择。
        //
        // （这条断言原本写的是 `contains("不可用")`。文案在 M3-3 的 provider 改造时
        //   已改成「本机翻译需要 …；可在设置中改用云端翻译服务」，断言没跟上，
        //   于是一直是红的——一个永远红的断言等于没有断言，会盖住真正的回归。）
        #expect(state.explanation.contains("本机翻译需要"))
        #expect(state.explanation.contains("云端"))
    }

    @Test("可用性说明区分「系统不支持」与「语言对不支持」")
    func availabilityExplainsReason() {
        let unsupported = TranslationAvailability.unsupportedLanguagePair(source: "ja-JP", target: "zh-Hans")

        #expect(unsupported.isAvailable == false)
        #expect(unsupported.explanation.contains("ja-JP"))
        #expect(unsupported.explanation.contains("zh-Hans"))
        #expect(TranslationAvailability.available.isAvailable)
    }
}
