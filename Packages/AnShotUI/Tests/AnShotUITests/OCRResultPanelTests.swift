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
        let copyButton = try #require(button(title: "复制译文", in: panel.windowForDiagnostics.contentView))
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

    @Test("翻译后保留原文，支持 原文 / 译文 / 双语 三种模式无损切换")
    func displayModesPreserveOriginalAndShowBilingual() {
        _ = NSApplication.shared
        let panel = OCRResultPanel()
        defer { panel.hide() }
        let lines = ["hello", "world"].map {
            OCRTextLine(text: $0, candidates: [], confidence: 1, boundingBox: .zero)
        }
        panel.show(result: OCRResult(lines: lines, imagePixelSize: .zero), near: .zero)
        #expect(panel.debugDisplayModeForDiagnostics == .original)
        #expect(panel.text == "hello\nworld")

        panel.showTranslation(TranslationAligner.align(
            lines: lines,
            translations: ["你好", "世界"],
            sourceLanguage: "en",
            targetLanguage: "zh-Hans"
        ))
        #expect(panel.debugDisplayModeForDiagnostics == .translation)
        #expect(panel.text == "你好\n世界")

        panel.selectDisplayModeForDiagnostics(.bilingual)
        #expect(panel.text == "hello\n你好\n\nworld\n世界")

        panel.selectDisplayModeForDiagnostics(.original)
        #expect(panel.text == "hello\nworld")
    }

    @Test("纯 OCR 单区态与翻译上下对照态自动切换，并采用无红绿灯现代浮窗")
    func modernCardLayoutTransitions() throws {
        _ = NSApplication.shared
        let panel = OCRResultPanel()
        defer { panel.hide() }

        let win = panel.windowForDiagnostics
        #expect(win.styleMask.contains(.fullSizeContentView))
        #expect(win.titlebarAppearsTransparent)
        #expect(win.standardWindowButton(.closeButton)?.isHidden == true)

        let line = OCRTextLine(text: "Hello anShot", candidates: [], confidence: 1, boundingBox: .zero)
        panel.show(result: OCRResult(lines: [line], imagePixelSize: .zero), near: .zero)
        #expect(!panel.debugIsTranslationExpandedForDiagnostics)
        #expect(button(title: "复制原文", in: win.contentView) != nil)
        #expect(button(title: "翻译", in: win.contentView) != nil)

        panel.showTranslation(TranslationAligner.align(
            lines: [line],
            translations: ["你好 anShot"],
            sourceLanguage: "en",
            targetLanguage: "zh-Hans"
        ))
        #expect(panel.debugIsTranslationExpandedForDiagnostics)
        #expect(button(title: "复制译文", in: win.contentView) != nil)
        #expect(button(title: "重新翻译", in: win.contentView) != nil)

        // 划词翻译入口默认直接展开上下对照态
        panel.showSourceText("Quick translate", near: .zero)
        #expect(panel.debugIsTranslationExpandedForDiagnostics)
        #expect(win.title == "划词翻译")
    }

    @Test("划词文本清洗与现代悬浮翻译胶囊保持无焦点且支持首击触发")
    func selectionNormalizationAndBubblePanel() {
        #expect(SelectionTextReader.normalizeSelectedText("   \n\t  ") == nil)
        #expect(SelectionTextReader.normalizeSelectedText("  Hello World \n") == "Hello World")
        let huge = String(repeating: "A", count: 5000)
        #expect(SelectionTextReader.normalizeSelectedText(huge)?.count == 4000)

        let bubble = SelectionTranslateBubblePanel()
        defer { bubble.hide() }
        #expect(!bubble.canBecomeKey)
        #expect(!bubble.canBecomeMain)
        #expect(bubble.styleMask.contains(.nonactivatingPanel))
        #expect(bubble.frame.size == SelectionTranslateBubblePanel.bubbleSize)
        #expect(bubble.contentView?.acceptsFirstMouse(for: nil) == true)
    }

    private func button(title: String, in view: NSView?) -> NSButton? {
        guard let view else { return nil }
        if let button = view as? NSButton, button.title == title { return button }
        return view.subviews.lazy.compactMap { button(title: title, in: $0) }.first
    }
}
