import AnShotCore
import AppKit
import Testing

@testable import AnShotUI

@Suite("OCR 结果面板", .serialized)
@MainActor
struct OCRResultPanelTests {
    @Test("复制全部使用当前显示的译文，部分失败的行保留原文")
    func copiesDisplayedTranslation() throws {
        _ = NSApplication.shared
        let panel = OCRResultPanel()
        defer { panel.hide() }
        let lines = ["hello", "world"].map {
            OCRTextLine(text: $0, candidates: [], confidence: 1, boundingBox: .zero)
        }
        panel.show(result: OCRResult(lines: lines, imagePixelSize: .zero), near: .zero)
        panel.showTranslation(TranslationAligner.align(
            lines: lines, translations: ["你好", nil], sourceLanguage: "en", targetLanguage: "zh-Hans"
        ))
        var copied: String?
        panel.onCopyAll = { copied = $0 }
        let copyButton = try #require(button(title: "复制全部", in: panel.windowForDiagnostics.contentView))
        let action = try #require(copyButton.action)
        NSApplication.shared.sendAction(action, to: copyButton.target, from: copyButton)

        #expect(copied == "你好\nworld")
    }

    @Test("翻译中不重复提交，且仍可换语言；关闭面板通知取消")
    func busyStateAndNativeClose() {
        _ = NSApplication.shared
        let panel = OCRResultPanel()
        let line = OCRTextLine(text: "hello", candidates: [], confidence: 1, boundingBox: .zero)
        panel.show(result: OCRResult(lines: [line], imagePixelSize: .zero), near: .zero)
        panel.applyTranslationAvailability(.available)
        panel.setTranslating(true)
        #expect(!panel.debugTranslateEnabledForDiagnostics)
        #expect(panel.debugLanguagePopUpEnabledForDiagnostics)
        panel.setTranslating(false)
        #expect(panel.debugTranslateEnabledForDiagnostics)

        var closed = false
        panel.onClose = { closed = true }
        panel.windowForDiagnostics.close()
        #expect(closed)
        #expect(!panel.isVisible)
    }

    @Test("原文与目标同语言时，仍能选择其他目标语言")
    func unavailableTranslationDoesNotDisableLanguageChoice() {
        _ = NSApplication.shared
        let panel = OCRResultPanel()
        defer { panel.hide() }
        let line = OCRTextLine(text: "hello", candidates: [], confidence: 1, boundingBox: .zero)
        panel.show(result: OCRResult(lines: [line], imagePixelSize: .zero), near: .zero)
        panel.applyTranslationAvailability(.sameAsTarget(language: "en-US"))

        #expect(!panel.debugTranslateEnabledForDiagnostics)
        #expect(panel.debugLanguagePopUpEnabledForDiagnostics)
    }

    private func button(title: String, in view: NSView?) -> NSButton? {
        guard let view else { return nil }
        if let button = view as? NSButton, button.title == title { return button }
        return view.subviews.lazy.compactMap { button(title: title, in: $0) }.first
    }
}
