//
//  Phase5PolishAndMigrationTests.swift
//  AnShotUITests
//
//  Phase 5 专项单元测试：
//    - 新装 v2（防冲突热键 + 静默直存）与老用户 v1 升级无感兼容迁移；
//    - 快捷键无修饰键 F1–F20 注册校验与一键清空解绑持久化；
//    - 多格式保存（PNG / JPEG / HEIC / WebP 无损）与剪贴板按需 TIFF 开关；
//    - 轻量化中英双语热切换、设置窗口可缩放与跨分类实时搜索、AnShotTheme 浅/深动态解析；
//    - 录屏控制条防误丢两步确认与层级高于范围框、历史预览窗智能左右摆位。
//

import AnShotCapture
import AnShotCore
import AppKit
import Carbon.HIToolbox
import CoreGraphics
import Foundation
import ImageIO
import Testing

@testable import AnShotUI

@Suite("Phase 5 · 导出压缩、迁移兼容、设置搜索与全域体验精修", .serialized)
@MainActor
struct Phase5PolishAndMigrationTests {

    private func makeIsolatedDefaults() -> (UserDefaults, String) {
        let suiteName = "com.anshot.tests.phase5.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return (defaults, suiteName)
    }

    private func makeTestImage(width: Int = 96, height: Int = 64) -> CGImage {
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
        ctx.setFillColor(CGColor(red: 0.18, green: 0.52, blue: 0.88, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()!
    }

    // MARK: - 1. 新装 v2 与老用户 v1 兼容迁移

    @Test("全新安装默认启用 schema v2：防冲突热键与静默直存文件夹")
    func freshInstallUsesSchemaV2Defaults() {
        let (defaults, suiteName) = makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = AppSettings(store: defaults)
        #expect(settings.installSchemaVersion == 2)
        #expect(settings.optionalShortcut(for: .capture) == AppSettings.defaultCaptureShortcut)
        #expect(settings.optionalShortcut(for: .windowCapture) == AppSettings.defaultWindowCaptureShortcut)
        #expect(settings.optionalShortcut(for: .longScreenshot) == AppSettings.defaultLongScreenshotShortcut)
        #expect(settings.optionalShortcut(for: .ocr) == AppSettings.defaultOCRShortcut)
        #expect(settings.optionalShortcut(for: .recording) == AppSettings.defaultRecordingShortcut)
        #expect(settings.optionalShortcut(for: .pinToggle) == AppSettings.defaultPinToggleShortcut)

        if case .folder(let dir) = settings.saveDestination {
            #expect(!dir.path.isEmpty)
        } else {
            Issue.record("新装用户默认保存模式应为静默直存文件夹")
        }
    }

    @Test("老用户升级自动识别 schema v1：完整保留「每次询问」与 ⌃1–⌃5 肌肉记忆")
    func legacyUpgradePreservesAskModeAndOldShortcuts() {
        let (defaults, suiteName) = makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        // 模拟老版本仅存在旧的 saveMode = "ask" 键，没有 installSchemaVersion
        defaults.set("ask", forKey: "settings.save.mode")

        let settings = AppSettings(store: defaults)
        #expect(settings.installSchemaVersion == 1)
        #expect(settings.saveDestination == .ask)
        #expect(settings.optionalShortcut(for: .capture) == AppSettings.legacyCaptureShortcut)
        #expect(settings.optionalShortcut(for: .recording) == AppSettings.legacyRecordingShortcut)
        #expect(settings.optionalShortcut(for: .longScreenshot) == AppSettings.legacyLongScreenshotShortcut)
        #expect(settings.optionalShortcut(for: .ocr) == AppSettings.legacyOCRShortcut)
        #expect(settings.optionalShortcut(for: .pinToggle) == AppSettings.legacyPinToggleShortcut)
        #expect(settings.optionalShortcut(for: .windowCapture) == nil, "老用户升级时新增的独立窗体热键默认不抢占绑定")
    }

    // MARK: - 2. F1–F20 单键与快捷键清空解绑

    @Test("Shortcut 允许无修饰键 F1–F20 注册，拒绝裸字母，且支持一键清空解绑持久化")
    func shortcutSupportsFunctionKeysAndUnbinding() {
        let f5 = Shortcut(keyCode: UInt32(kVK_F5), modifiers: 0)
        #expect(f5.registrationIssue == nil)
        #expect(f5.displayName == "F5")

        let f12 = Shortcut(keyCode: UInt32(kVK_F12), modifiers: 0)
        #expect(f12.registrationIssue == nil)

        let bareA = Shortcut(keyCode: UInt32(kVK_ANSI_A), modifiers: 0)
        #expect(bareA.registrationIssue == .missingStrongModifier)

        let (defaults, suiteName) = makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = AppSettings(store: defaults)
        #expect(settings.optionalShortcut(for: .ocr) != nil)
        settings.clearShortcut(for: .ocr)
        #expect(settings.optionalShortcut(for: .ocr) == nil)

        // 重建实例后仍保持解绑状态
        let reloaded = AppSettings(store: defaults)
        #expect(reloaded.optionalShortcut(for: .ocr) == nil)

        // 重新绑定 F5 后自动脱离解绑状态
        reloaded.setShortcut(f5, for: .ocr)
        #expect(reloaded.optionalShortcut(for: .ocr) == f5)
    }

    // MARK: - 3. 多格式导出落盘与剪贴板按需 TIFF 开关

    @Test("SessionExporter 支持 PNG / JPEG / HEIC / WebP 写入磁盘，且按配置控制剪贴板 TIFF 声明")
    func multiFormatSaveAndPasteboardLazyTIFFToggle() throws {
        let fm = FileManager.default
        let tempDir = fm.temporaryDirectory.appendingPathComponent("anshot-phase5-export-\(UUID().uuidString)")
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempDir) }

        let image = makeTestImage(width: 80, height: 60)

        for option in ExportFormatOption.allCases {
            let outcome = SessionExporter.save(
                image,
                suggestedName: "shot-\(option.rawValue).png",
                destination: .folder(tempDir),
                backingScale: 2.0,
                formatOption: option,
                quality: 0.85,
                enablePNGOptimization: false
            )
            guard case .saved(let url) = outcome else {
                Issue.record("格式 \(option.rawValue) 导出失败")
                continue
            }
            #expect(url.pathExtension.lowercased() == option.fileExtension)
            let data = try Data(contentsOf: url)
            #expect(!data.isEmpty)
            let src = try #require(CGImageSourceCreateWithData(data as CFData, nil))
            let decoded = try #require(CGImageSourceCreateImageAtIndex(src, 0, nil))
            #expect(decoded.width == 80 && decoded.height == 60)
        }

        // 测试私有剪贴板：关闭按需 TIFF 时，NSPasteboardItem 仅声明 .png（不挂载 LazyTIFFProvider）；
        // 开启时 NSPasteboardItem 同时声明 .png 与 .tiff 且可真实读出懒加载 TIFF 图像。
        // 注：NSPasteboard.types 顶层属性会由系统自动附加历史格式翻译表，故需校验 pasteboardItems.first.types。
        let pbNoTIFF = NSPasteboard(name: NSPasteboard.Name("anshot.test.notiff.\(UUID().uuidString)"))
        defer { pbNoTIFF.releaseGlobally() }
        let r1 = SessionExporter.copyToPasteboardWithPNG(image, backingScale: 2.0, includeLazyTIFF: false, to: pbNoTIFF)
        #expect(r1?.didCopy == true)
        let itemTypesNoTIFF = pbNoTIFF.pasteboardItems?.first?.types ?? []
        #expect(itemTypesNoTIFF.contains(.png))
        #expect(!itemTypesNoTIFF.contains(.tiff))

        let pbWithTIFF = NSPasteboard(name: NSPasteboard.Name("anshot.test.withtiff.\(UUID().uuidString)"))
        defer { pbWithTIFF.releaseGlobally() }
        let r2 = SessionExporter.copyToPasteboardWithPNG(image, backingScale: 2.0, includeLazyTIFF: true, to: pbWithTIFF)
        #expect(r2?.didCopy == true)
        let itemTypesWithTIFF = pbWithTIFF.pasteboardItems?.first?.types ?? []
        #expect(itemTypesWithTIFF.contains(.png))
        #expect(itemTypesWithTIFF.contains(.tiff))
        let tiffData = try #require(pbWithTIFF.data(forType: .tiff))
        let tiffRep = try #require(NSBitmapImageRep(data: tiffData))
        #expect(tiffRep.pixelsWide == 80 && tiffRep.pixelsHigh == 60)
    }

    // MARK: - 4. 设置窗口可缩放、跨分类实时搜索、双语与 AnShotTheme

    @Test("设置窗口支持缩放与跨分类实时搜索，双语热切换与 AnShotTheme 浅/深动态色生效")
    func settingsSearchResizableLocalizationAndTheme() {
        let (defaults, suiteName) = makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = AppSettings(store: defaults)
        let host = Phase5StubShortcutHost()
        let controller = SettingsWindowController(settings: settings, shortcutHost: host)
        defer { controller.close() }

        let window = controller.window!
        #expect(window.styleMask.contains(.resizable))
        #expect(window.minSize == AnShotTheme.windowMinSize)

        // 搜索 "webp" 仅命中保存与导出页并自动切换
        controller.applySearchForTesting("webp")
        #expect(controller.visibleSidebarPagesForTesting == [.save])
        #expect(controller.currentPageForTesting == .save)

        // 搜索 "tcc" 命中通用页
        controller.applySearchForTesting("tcc")
        #expect(controller.visibleSidebarPagesForTesting == [.general])
        #expect(controller.currentPageForTesting == .general)

        // 搜索 "shadow" 命中独立「截图与标注」页
        controller.applySearchForTesting("shadow")
        #expect(controller.visibleSidebarPagesForTesting == [.capture])
        #expect(controller.currentPageForTesting == .capture)

        // 搜索 "f12" 命中独立快捷键页
        controller.applySearchForTesting("f12")
        #expect(controller.visibleSidebarPagesForTesting == [.shortcuts])
        #expect(controller.currentPageForTesting == .shortcuts)

        // 清空搜索恢复全部 7 页
        controller.applySearchForTesting("")
        #expect(controller.visibleSidebarPagesForTesting.count == SettingsPage.allCases.count)

        // 双语热切换测试（结束恢复系统语言）
        defer { AnShotLocalization.apply(.system) }
        AnShotLocalization.apply(.en)
        #expect(L("menu.capture", fallback: "截图") == "Capture Area")
        AnShotLocalization.apply(.zhHans)
        #expect(L("menu.capture", fallback: "截图") == "截图")

        // AnShotTheme 浅色与深色解析出截然不同的窗口背景明度
        let lightAppearance = NSAppearance(named: .aqua)!
        let darkAppearance = NSAppearance(named: .darkAqua)!
        var lightBright: CGFloat = 0
        var darkBright: CGFloat = 0
        lightAppearance.performAsCurrentDrawingAppearance {
            lightBright = AnShotTheme.windowBackground.usingColorSpace(.deviceRGB)?.brightnessComponent ?? 0
        }
        darkAppearance.performAsCurrentDrawingAppearance {
            darkBright = AnShotTheme.windowBackground.usingColorSpace(.deviceRGB)?.brightnessComponent ?? 0
        }
        #expect(lightBright > 0.8)
        #expect(darkBright < 0.25)
    }

    // MARK: - 5. 录屏控制条防误丢二次确认、层级与历史预览智能摆位

    @Test("录屏控制条层级严格高于录制范围框，录制中取消需两步确认防误丢")
    func recordingControlBarLevelAndTwoStepCancelConfirmation() {
        let bar = RecordingControlBar()
        defer { bar.hide() }

        // 层级必须严格高于 RecordingRegionFrame (screenSaver + 1)
        #expect(bar.windowLevelForTesting.rawValue > NSWindow.Level.screenSaver.rawValue + 1)

        var cancelCount = 0
        bar.onCancel = { cancelCount += 1 }
        bar.update(state: .recording, elapsed: 5.0)

        // 首次点击进入二次确认态，不立刻丢弃素材
        bar.triggerCancelForTesting()
        #expect(bar.isAwaitingCancelConfirmationForTesting)
        #expect(cancelCount == 0)

        // 二次点击真正触发取消并退出确认态
        bar.triggerCancelForTesting()
        #expect(!bar.isAwaitingCancelConfirmationForTesting)
        #expect(cancelCount == 1)
    }

    @Test("历史预览窗口优先贴历史窗左侧，左侧空间不足自动翻至右侧且绝不重叠")
    func historyPreviewSmartPlacement() {
        let visible = CGRect(x: 0, y: 0, width: 1600, height: 900)
        let previewSize = CGSize(width: 700, height: 560)

        // 1. 历史窗靠右停靠 → 预览窗落左侧且不重叠
        let rightHistory = CGRect(x: 920, y: 180, width: 620, height: 560)
        let leftOrigin = HistoryPreviewPanel.preferredOrigin(
            panelSize: previewSize,
            anchorFrame: rightHistory,
            visibleFrame: visible
        )
        let leftFrame = CGRect(origin: leftOrigin, size: previewSize)
        #expect(leftFrame.maxX <= rightHistory.minX)
        #expect(!leftFrame.intersects(rightHistory))

        // 2. 历史窗靠左停靠（左侧不够 700pt）→ 自动翻到右侧且不重叠
        let leftHistory = CGRect(x: 40, y: 180, width: 620, height: 560)
        let rightOrigin = HistoryPreviewPanel.preferredOrigin(
            panelSize: previewSize,
            anchorFrame: leftHistory,
            visibleFrame: visible
        )
        let rightFrame = CGRect(origin: rightOrigin, size: previewSize)
        #expect(rightFrame.minX >= leftHistory.maxX)
        #expect(!rightFrame.intersects(leftHistory))
    }

    @Test("ToastPresenter 中文胶囊精确计入 NSTextFieldCell 内边距，单行绝不折行截断成半句")
    func toastPresenterDoesNotTruncateChineseSingleLine() throws {
        _ = NSApplication.shared
        let screenFrame = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let font = NSFont.systemFont(ofSize: 13, weight: .medium)
        let singleLineCases = [
            "已复制到剪贴板",
            "已固定在屏幕上",
            "长截图已复制到剪贴板",
            "已复制色值 #FF3B30",
            "已撤销上一段拼接",
        ]

        for text in singleLineCases {
            let layout = ToastPresenter.measureLayout(
                message: text,
                messageFont: font,
                actionTitle: nil,
                screenFrame: screenFrame
            )
            let probe = NSTextField(labelWithString: text)
            probe.font = font
            let cellNeeded = try #require(probe.cell?.cellSize(
                forBounds: CGRect(x: 0, y: 0, width: CGFloat.greatestFiniteMagnitude, height: 100)
            ))
            #expect(!layout.isMultiline, "短消息「\(text)」不应误判为多行")
            #expect(layout.textSize.width >= ceil(cellNeeded.width), "「\(text)」宽度必须完整容纳 NSTextFieldCell 内边距")
            #expect(layout.textSize.height >= ceil(cellNeeded.height))
        }

        // 多行长消息或显式换行应正确按多行高度展开
        let multiLayout = ToastPresenter.measureLayout(
            message: "第一行提示\n第二行补充说明",
            messageFont: font,
            actionTitle: "在访达中显示",
            screenFrame: screenFrame
        )
        #expect(multiLayout.isMultiline)
        #expect(multiLayout.capsuleSize.height > 44)
    }

    @Test("DetectionSession.topWindowID 准确识别最顶层窗口，供覆盖层慢移保稳防闪烁")
    func detectionSessionTopWindowIDAndControlStability() async {
        let displayBounds = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let maxWindow = DetectedWindow(
            windowID: 101,
            frame: CGRect(x: 0, y: 25, width: 1440, height: 875),
            layer: 0,
            title: "Editor",
            processID: 1001,
            applicationName: "Xcode"
        )
        let floatingWindow = DetectedWindow(
            windowID: 202,
            frame: CGRect(x: 900, y: 120, width: 420, height: 360),
            layer: 0,
            title: "Note",
            processID: 2002,
            applicationName: "Notes"
        )
        let controlFrame = CGRect(x: 120, y: 140, width: 320, height: 260)
        let detector = FlickerRegressionDetector(
            windows: [floatingWindow, maxWindow],
            controlHit: ControlHit(frame: controlFrame, role: "AXGroup")
        )
        let session = DetectionSession(
            detector: detector,
            displayID: 1,
            displayBounds: displayBounds
        )
        session.suppressesMaximizedWindow = true
        await session.load()

        // 光标在最大化窗口区域内：顶层窗口为 101，且 immediateTarget 抑制整屏误吸返回 nil
        #expect(session.topWindowID(atGlobalPoint: CGPoint(x: 200, y: 200)) == 101)
        #expect(session.immediateTarget(atGlobalPoint: CGPoint(x: 200, y: 200), preference: .automatic) == nil)
        // 移入上层悬浮窗：顶层窗口切换为 202，immediateTarget 立即命中浮窗
        #expect(session.topWindowID(atGlobalPoint: CGPoint(x: 960, y: 200)) == 202)
        #expect(session.immediateTarget(atGlobalPoint: CGPoint(x: 960, y: 200), preference: .automatic)?.windowID == 202)
    }
}

private final class FlickerRegressionDetector: ScreenElementDetecting, @unchecked Sendable {
    let windowsList: [DetectedWindow]
    let controlHit: ControlHit?

    init(windows: [DetectedWindow], controlHit: ControlHit?) {
        self.windowsList = windows
        self.controlHit = controlHit
    }

    var hasAccessibilityPermission: Bool { true }

    func windows(onDisplay displayID: CGDirectDisplayID) async throws -> [DetectedWindow] {
        windowsList
    }

    func control(atGlobalPoint point: CGPoint, inApplication processID: pid_t) -> ControlHit? {
        guard let controlHit, controlHit.frame.contains(point) else { return nil }
        return controlHit
    }
}

@MainActor
private final class Phase5StubShortcutHost: ShortcutHosting {
    func applyCaptureShortcut(_ shortcut: Shortcut) -> String? { nil }
    func suspendCaptureShortcut() -> Bool { true }
    func resumeCaptureShortcut() -> String? { nil }
    func applyPinToggleShortcut(_ shortcut: Shortcut) -> String? { nil }
    func suspendPinToggleShortcut() -> Bool { true }
    func resumePinToggleShortcut() -> String? { nil }
}
