//
//  Phase3OCRAndPinTests.swift
//  AnShotUITests
//
//  Phase 3 专项单元测试：
//    - 独立 OCR 浮窗与覆盖层解耦、宽选区避让定位、二维码卡片、无损合并换行、7 语种与可编辑重译；
//    - 划词翻译密码框安全过滤与配置持久化；
//    - PinWindow 全屏置顶、原地更新不增计数、原地补画取消恢复、鼠标穿透恢复、边框与实时 HUD。
//

import AnShotCore
import AppKit
import CoreGraphics
import Foundation
import Testing

@testable import AnShotUI

@MainActor
@Suite("Phase 3 · 独立 OCR、划词安全与贴图闭环")
struct Phase3OCRAndPinTests {

    private func makeTestSettings() -> AppSettings {
        let suiteName = "com.anshot.tests.phase3.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return AppSettings(store: defaults)
    }

    private func makeSolidImage(width: Int, height: Int, red: CGFloat = 0.2) -> CGImage {
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        ctx.setFillColor(CGColor(red: red, green: 0.4, blue: 0.8, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()!
    }

    // MARK: - OCR 浮窗与定位避让

    @Test("宽选区避让算法优先右/左，放不下放下方且绝不覆盖宽选区")
    func ocrPanelAvoidsWideSelection() {
        let visible = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let panelSize = CGSize(width: 460, height: 340)

        // 1. 常规窄选区在左侧 → 应落右侧，互不重叠
        let leftSelection = CGRect(x: 100, y: 400, width: 300, height: 180)
        let rightFrame = OCRResultPanel.preferredFrame(
            near: leftSelection,
            panelSize: panelSize,
            visibleFrame: visible
        )
        #expect(rightFrame.minX >= leftSelection.maxX)
        #expect(!rightFrame.intersects(leftSelection))

        // 2. 宽选区横跨屏幕上部（左右皆不够 460pt）→ 应落选区下方且绝不重叠
        let wideTopSelection = CGRect(x: 120, y: 600, width: 1200, height: 220)
        let belowFrame = OCRResultPanel.preferredFrame(
            near: wideTopSelection,
            panelSize: panelSize,
            visibleFrame: visible
        )
        #expect(belowFrame.maxY <= wideTopSelection.minY)
        #expect(!belowFrame.intersects(wideTopSelection))
        #expect(visible.contains(belowFrame))

        // 3. 宽选区贴底（左右下皆不够）→ 应翻到上方且绝不重叠
        let wideBottomSelection = CGRect(x: 120, y: 60, width: 1200, height: 220)
        let aboveFrame = OCRResultPanel.preferredFrame(
            near: wideBottomSelection,
            panelSize: panelSize,
            visibleFrame: visible
        )
        #expect(aboveFrame.minY >= wideBottomSelection.maxY)
        #expect(!aboveFrame.intersects(wideBottomSelection))
        #expect(visible.contains(aboveFrame))
    }

    @Test("OCR 浮窗具备可缩放、跟随系统语义主题、置顶切换、无损合并换行与二维码卡片能力")
    func ocrPanelSupportsResizeMergeLineBreaksBarcodesAndPinOnTop() {
        let panel = OCRResultPanel()
        defer { panel.hide() }

        #expect(panel.windowForDiagnostics.styleMask.contains(.resizable))
        #expect(panel.windowForDiagnostics.minSize == OCRResultPanel.minimumSize)
        #expect(panel.windowForDiagnostics.appearance == nil, "应跟随系统浅/深主题，不再写死 darkAqua")

        // 置顶图钉切换
        #expect(panel.isAlwaysOnTop)
        #expect(panel.windowForDiagnostics.level == .floating)
        panel.setAlwaysOnTop(false)
        #expect(!panel.isAlwaysOnTop)
        #expect(panel.windowForDiagnostics.level == .normal)
        panel.setAlwaysOnTop(true)
        #expect(panel.windowForDiagnostics.level == .floating)

        // 展示带二维码与可合并换行的 OCR 结果
        let lines = [
            OCRTextLine(
                text: "这是一段跨行折断的中文",
                candidates: [],
                confidence: 1,
                boundingBox: PixelRect(origin: PixelPoint(x: 0, y: 0), size: PixelSize(width: 200, height: 24))
            ),
            OCRTextLine(
                text: "句子内容。",
                candidates: [],
                confidence: 1,
                boundingBox: PixelRect(origin: PixelPoint(x: 0, y: 28), size: PixelSize(width: 120, height: 24))
            ),
        ]
        let barcode = BarcodeItem(payload: "https://example.com/qr", symbology: "VNBarcodeSymbologyQR")
        let result = OCRResult(
            lines: lines,
            imagePixelSize: PixelSize(width: 400, height: 200),
            barcodes: [barcode]
        )

        panel.applyTranslationAvailability(.available)
        panel.show(result: result, near: CGRect(x: 100, y: 300, width: 200, height: 100))

        #expect(panel.currentBarcodes == [barcode])
        #expect(panel.text == "这是一段跨行折断的中文\n句子内容。")

        // 无损切到「合并换行」，再切回「逐行」
        panel.setMergeLineBreaks(true)
        #expect(panel.text == "这是一段跨行折断的中文句子内容。")
        panel.setMergeLineBreaks(false)
        #expect(panel.text == "这是一段跨行折断的中文\n句子内容。")

        // 智能复制：未翻译时返回原文，翻译后优先返回译文
        #expect(panel.smartCopyText == "这是一段跨行折断的中文\n句子内容。")
        let translated = TranslationResult(
            sourceLanguage: "zh-Hans",
            targetLanguage: "en",
            segments: [
                TranslationSegment(sourceText: "这是一段跨行折断的中文", translatedText: "This is a wrapped Chinese"),
                TranslationSegment(sourceText: "句子内容。", translatedText: "sentence."),
            ]
        )
        panel.showTranslation(translated)
        #expect(panel.smartCopyText == "This is a wrapped Chinese\nsentence.")
    }

    @Test("独立 OCR 浮窗脱离覆盖层生命周期：dismiss() 不关闭已打开的 OCR 浮窗")
    func ocrPanelSurvivesOverlayDismiss() {
        let settings = makeTestSettings()
        let controller = OverlayController(settings: settings)
        defer { controller.ocrPanelForTesting.hide() }

        controller.presentTextTranslation("Hello World", near: CGRect(x: 200, y: 200, width: 120, height: 40))
        #expect(controller.ocrPanelForTesting.isVisible)

        // 模拟打开并关闭图片编辑会话，覆盖层 dismiss() 不应把独立 OCR 浮窗关掉。
        let image = makeSolidImage(width: 240, height: 160)
        controller.present(image: image)
        #expect(controller.isPresenting)
        controller.dismiss()
        #expect(!controller.isPresenting)
        #expect(controller.ocrPanelForTesting.isVisible, "独立 OCR 浮窗必须脱离覆盖层生命周期持续存活")
    }

    // MARK: - 划词翻译安全过滤与设置持久化

    @Test("划词读取安全过滤显式拦截密码输入框与安全角色")
    func selectionReaderRejectsSensitiveRoles() {
        #expect(SelectionTextReader.isSensitiveRole("AXSecureTextField", subrole: nil))
        #expect(SelectionTextReader.isSensitiveRole("AXTextField", subrole: "AXSecureTextField"))
        #expect(SelectionTextReader.isSensitiveRole("AXTextField", subrole: "PasswordInput"))
        #expect(!SelectionTextReader.isSensitiveRole("AXTextArea", subrole: "AXStandardText"))
        #expect(!SelectionTextReader.isSensitiveRole("AXStaticText", subrole: nil))
    }

    @Test("Phase 3 新增配置项与热键默认键值正确读写持久化")
    func phase3SettingsPersistence() {
        let suiteName = "com.anshot.tests.phase3.persist.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = AppSettings(store: defaults)
        #expect(settings.ocrLanguage == .auto)
        #expect(settings.ocrMergeLineBreaks == false)
        #expect(settings.ocrDetectBarcodes == true)
        #expect(settings.translationTargetLanguage == "zh-Hans")
        #expect(settings.selectionTranslateFloatingButton == false)
        #expect(settings.pinShowBorder == true)
        #expect(settings.ocrAutoTranslateShortcut.displayName == "⌥S")
        #expect(settings.selectionTranslateShortcut.displayName == "⌥D")

        settings.setOCRLanguage(.jaJP)
        settings.setOCRMergeLineBreaks(true)
        settings.setOCRDetectBarcodes(false)
        settings.setTranslationTargetLanguage("en")
        settings.setSelectionTranslateFloatingButton(true)
        settings.setPinShowBorder(false)

        let reloaded = AppSettings(store: defaults)
        #expect(reloaded.ocrLanguage == .jaJP)
        #expect(reloaded.ocrMergeLineBreaks == true)
        #expect(reloaded.ocrDetectBarcodes == false)
        #expect(reloaded.translationTargetLanguage == "en")
        #expect(reloaded.selectionTranslateFloatingButton == true)
        #expect(reloaded.pinShowBorder == false)
    }

    // MARK: - 贴图（Pin）闭环：全屏置顶、原地补画、点击穿透、边框与 HUD

    @Test("PinWindow 支持全屏前置顶、原地替换不增计数、点击穿透恢复、边框切换、微调与 HUD")
    func pinWindowFullLifecycleAndFeatures() throws {
        let settings = makeTestSettings()
        let manager = PinManager(settings: settings)
        defer { manager.closeAll() }

        let img1 = makeSolidImage(width: 400, height: 300, red: 0.2)
        guard case .created(let pin) = manager.pin(image: img1, screenScale: 2) else {
            Issue.record("创建贴图失败")
            return
        }

        // 1. 全屏前置顶 collectionBehavior
        #expect(pin.collectionBehavior.contains(.canJoinAllSpaces))
        #expect(pin.collectionBehavior.contains(.fullScreenAuxiliary))
        #expect(pin.showsBorder == true)

        // 2. 原地替换图像：保持 pinID 与贴图总数不变
        let originalID = pin.pinID
        let img2 = makeSolidImage(width: 600, height: 360, red: 0.9)
        pin.updateImage(img2, screenScale: 2)
        #expect(pin.pinID == originalID)
        #expect(manager.pins.count == 1)
        #expect(pin.contentImage?.width == 600)
        #expect(pin.contentImage?.height == 360)

        // 3. 实时 HUD（缩放与透明度）
        pin.applyScale(1.25, pixelSize: pin.pixelSize, screenScale: pin.screenScale)
        #expect(pin.hudTextForTesting == "125%")
        pin.setAlpha(0.75)
        #expect(pin.hudTextForTesting == "透明度 75%")

        // 4. 边框开关
        pin.toggleBorder()
        #expect(pin.showsBorder == false)
        #expect(pin.hudTextForTesting == "边框：关")

        // 5. 方向键微调坐标
        let originBefore = pin.frame.origin
        pin.nudgePosition(dx: 5, dy: -1)
        #expect(abs(pin.frame.origin.x - (originBefore.x + 5)) < 0.5)
        #expect(abs(pin.frame.origin.y - (originBefore.y - 1)) < 0.5)

        // 6. 鼠标穿透与一键恢复
        pin.setAlpha(0.95, showHUD: false)
        pin.setClickThrough(true, showToast: false)
        #expect(pin.isClickThrough)
        #expect(pin.ignoresMouseEvents)
        #expect(pin.alphaValue <= 0.821)
        #expect(manager.hasClickThroughPins)
        #expect(manager.clickThroughCount == 1)
        // 穿透状态下 pin(at:) 跳过该贴图
        let center = CGPoint(x: pin.frame.midX, y: pin.frame.midY)
        #expect(manager.pin(at: center) == nil)

        manager.disableAllClickThrough()
        #expect(!pin.isClickThrough)
        #expect(!pin.ignoresMouseEvents)
        #expect(abs(pin.alphaValue - 0.95) < 0.01)
        #expect(!manager.hasClickThroughPins)
    }

    @Test("贴图原地补画取消时无损恢复原贴图可见且不增加计数")
    func inlinePinEditCancelRestoresOriginalPin() {
        let settings = makeTestSettings()
        let controller = OverlayController(settings: settings)
        defer {
            controller.dismiss()
            controller.pinManager.closeAll()
        }

        let img = makeSolidImage(width: 320, height: 240)
        guard case .created(let pin) = controller.pinManager.pin(image: img, screenScale: 2) else {
            Issue.record("创建贴图失败")
            return
        }
        #expect(!pin.isUserHidden)
        #expect(controller.pinManager.pins.count == 1)

        // 进入原地补画：原贴图临时隐藏，编辑窗展开
        controller.presentInlinePinEdit(pin)
        #expect(pin.isUserHidden)
        #expect(controller.isPresenting)

        // 取消（Esc / dismiss）：原贴图恢复显示，位图与总数保持不变
        controller.dismiss()
        #expect(!controller.isPresenting)
        #expect(!pin.isUserHidden)
        #expect(controller.pinManager.pins.count == 1)
        #expect(pin.contentImage?.width == 320)
    }
}
