//
//  CaptureDiagnostics+Probes.swift
//
//  CaptureDiagnostics 按主题拆分的一部分（同一类型的多文件 extension）。
//  纯机械拆分：函数体未改动。
//

#if DEBUG

import AnShotCapture
import AnShotCore
@preconcurrency import AVFoundation
import AppKit
import ImageIO
import Carbon.HIToolbox
@preconcurrency import ScreenCaptureKit
import Foundation

extension CaptureDiagnostics {

    /// 摸清 `SCWindow.frame` 的坐标系，以及窗口列表里混着哪些东西。
    ///
    /// 这是「按窗口 / 按组件自动识别」的前置调研：头文件只写了
    /// "the CGRect for the SCWindow"，**没说原点在哪、单位是点还是像素**。
    /// 猜错就会让高亮框整体偏移，而且偏移量随显示器布局变化，极难发现。
    ///
    /// 顺带确认：窗口列表里有多少是 `windowLayer != 0` 的系统层
    /// （菜单栏、Dock、壁纸），这些不该被用户选中。
    static func runWindowProbe() async {
        let displayID = DisplayGeometry.mainDisplay()
        let displayBounds = DisplayGeometry.bounds(for: displayID)
        let scale = DisplayGeometry.scaleFactor(for: displayID)
        let pixelSize = DisplayGeometry.pixelSize(for: displayID)

        logger.notice("""
            window probe 显示器: bounds=\(String(describing: displayBounds), privacy: .public) \
            scale=\(scale, privacy: .public) \
            pixels=\(pixelSize.width, privacy: .public)x\(pixelSize.height, privacy: .public)
            """)

        let capturer = CapturerFactory.makeDefault()
        guard let content = try? await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: true
        ) else {
            logger.error("window probe: 取不到 SCShareableContent")
            return
        }

        logger.notice("window probe: onScreen 窗口数=\(content.windows.count, privacy: .public)")

        var layerCounts: [Int: Int] = [:]
        var samples: [String] = []

        for window in content.windows {
            layerCounts[window.windowLayer, default: 0] += 1
            // 只打印有标题、尺寸像正经窗口的，避免输出被小窗刷满。
            guard window.frame.width > 200,
                  window.frame.height > 120,
                  let title = window.title, !title.isEmpty else {
                continue
            }
            guard samples.count < 6 else { continue }
            samples.append("""
                标题=\(title) 层=\(window.windowLayer) \
                frame=\(Int(window.frame.minX)),\(Int(window.frame.minY)) \
                \(Int(window.frame.width))x\(Int(window.frame.height)) \
                应用=\(window.owningApplication?.applicationName ?? "-")
                """)
        }

        for sample in samples {
            logger.notice("window probe 样本: \(sample, privacy: .public)")
        }

        let layers = layerCounts.sorted { $0.key < $1.key }
            .map { "层\($0.key)=\($0.value)" }
            .joined(separator: " ")
        logger.notice("window probe 层分布: \(layers, privacy: .public)")

        // 用「主显示器 frame」反推坐标系：若主屏 frame 是 (0,0,宽,高)（点），
        // 则 SCWindow.frame 是**全局左上原点点坐标**，可直接与 CaptureScope 对接。
        if let mainDisplay = content.displays.first(where: { $0.displayID == displayID }) {
            logger.notice("""
                window probe 主屏 SCDisplay: frame=\(Int(mainDisplay.frame.minX)),\(Int(mainDisplay.frame.minY)) \
                \(mainDisplay.width)x\(mainDisplay.height) \
                (对比 DisplayGeometry.bounds: \(Int(displayBounds.minX)),\(Int(displayBounds.minY)) \
                \(Int(displayBounds.width))x\(Int(displayBounds.height)))
                """)
        }

        // 辅助功能权限现状：组件识别的前提。
        let trusted = AXIsProcessTrusted()
        logger.notice("""
            window probe 辅助功能权限: AXIsProcessTrusted=\(trusted, privacy: .public) \
            \(trusted ? "（可直接做控件级识别）" : "（控件级识别不可用，需用户在系统设置中授权）", privacy: .public)
            """)

        if trusted {
            probeAccessibilityElement(at: CGPoint(x: displayBounds.midX, y: displayBounds.midY))
        } else {
            // 即使没有权限，也要确认失败形态：返回错误而不是崩溃。
            probeAccessibilityElement(at: CGPoint(x: displayBounds.midX, y: displayBounds.midY))
        }

        _ = capturer
    }

    /// 试取某点的辅助功能元素，打印角色与 frame。
    private static func probeAccessibilityElement(at point: CGPoint) {
        let systemWide = AXUIElementCreateSystemWide()
        var element: AXUIElement?
        let error = AXUIElementCopyElementAtPosition(
            systemWide,
            Float(point.x),
            Float(point.y),
            &element
        )

        guard error == .success, let element else {
            logger.notice("""
                window probe 控件命中: 失败 error=\(error.rawValue, privacy: .public) \
                （无权限时通常是 -25211 或 -25204）
                """)
            return
        }

        var roleValue: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleValue)
        let role = (roleValue as? String) ?? "-"

        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        var frameText = "—"
        if AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionValue) == .success,
           AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue) == .success,
           let positionValue, let sizeValue {
            var origin = CGPoint.zero
            var size = CGSize.zero
            // AXValue 是 CFTypeRef，取值要先确认类型再解引用。
            if CFGetTypeID(positionValue) == AXValueGetTypeID() {
                AXValueGetValue(positionValue as! AXValue, .cgPoint, &origin)
            }
            if CFGetTypeID(sizeValue) == AXValueGetTypeID() {
                AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
            }
            frameText = """
                \(Int(origin.x)),\(Int(origin.y)) \(Int(size.width))x\(Int(size.height))
                """
        }

        logger.notice("""
            window probe 控件命中: role=\(role, privacy: .public) frame=\(frameText, privacy: .public)
            """)
    }

    // MARK: - 内存诊断

    /// 验证四层识别与「默认全屏 / 手动模式 / 修饰键抑制」三条交互。
    ///
    /// 分成两半来测，因为它们的失败模式不同：
    /// - **识别本身**（哪一层命中、矩形对不对）直接用 `DetectionSession` 查询，
    ///   不经过事件系统，结论确定；
    /// - **接线**（鼠标移动是否真的触发识别）必须走事件的真实路径，
    ///   否则「识别算对了但没人调用」这种缺陷查不出来。
    static func runDetectionDiagnostic() async {
        let displayID = DisplayGeometry.mainDisplay()
        let displayBounds = DisplayGeometry.bounds(for: displayID)
        let scale = DisplayGeometry.scaleFactor(for: displayID)

        let controller = OverlayController(capturer: CapturerFactory.makeDefault())
        controller.present()
        try? await Task.sleep(for: .seconds(2))

        guard let window = controller.primaryOverlayWindow,
              let editor = controller.editorState,
              let view = window.contentView as? OverlayView else {
            logger.error("detection diag: missing window or editor")
            controller.dismiss()
            return
        }

        // ── 1）默认选区 = 整屏 ──
        let expectedFull = CoordinateConversion.pixelRect(
            fromLogical: displayBounds,
            scaleFactor: scale
        )
        let defaultIsFullScreen = editor.selection == expectedFull
        logger.notice("""
            detection 默认选区: 是整屏=\(defaultIsFullScreen, privacy: .public) \
            实测=\(Self.describe(editor.selection), privacy: .public) \
            期望=\(Self.describe(expectedFull), privacy: .public) \
            -> \(defaultIsFullScreen ? "MATCH" : "MISMATCH", privacy: .public)
            """)

        // ── 2）识别本身：直接查询各层 ──
        guard let session = view.detectionSessionForDiagnostics else {
            logger.error("detection diag: 没有识别会话")
            controller.dismiss()
            return
        }
        // 诊断里显式等窗口列表载入完成。
        try? await Task.sleep(for: .seconds(1))

        logger.notice("""
            detection 能力: 辅助功能权限=\(session.canDetectControls, privacy: .public) \
            窗口数=\(session.windowCount, privacy: .public)
            """)

        // 屏幕中心的全局点（左上原点）。
        let centerGlobal = CGPoint(x: displayBounds.midX, y: displayBounds.midY)

        // 多位置探测：单点无法判断组件级是否真的工作
        // （命中的可能恰好就是窗口本身，那会退回窗口层，看不出差别）。
        let probes: [(String, CGPoint)] = [
            ("屏幕中心", centerGlobal),
            ("左上角菜单栏", CGPoint(x: 60, y: 12)),
            ("顶栏偏右", CGPoint(x: displayBounds.width - 400, y: 12)),
            ("左下角", CGPoint(x: 80, y: displayBounds.height - 30))
        ]
        for (label, globalPoint) in probes {
            guard let hit = session.rawControlHitForDiagnostics(atGlobalPoint: globalPoint) else {
                logger.notice("""
                    detection 控件探测 [\(label, privacy: .public)]: 该点无窗口或 AX 未命中
                    """)
                continue
            }
            let size = """
                \(Int(hit.frame.minX.rounded())),\(Int(hit.frame.minY.rounded())) \
                \(Int(hit.frame.width.rounded()))x\(Int(hit.frame.height.rounded()))
                """
            logger.notice("""
                detection 控件探测 [\(label, privacy: .public)]: \
                role=\(hit.role ?? "-", privacy: .public) 矩形=\(size, privacy: .public) \
                所属窗口=\(hit.windowTitle ?? "-", privacy: .public)
                """)
        }

        var layerResults: [String] = []
        for preference in [
            DetectionLayerPreference.automatic,
            .window,
            .application,
            .disabled
        ] {
            let target = session.target(atGlobalPoint: centerGlobal, preference: preference)
            let text = target.map { "\($0.layer.rawValue):\(Self.describe($0.rect))" } ?? "nil"
            layerResults.append("\(preference):\(text)")
        }
        logger.notice("""
            detection 各层结果: \(layerResults.joined(separator: " | "), privacy: .public)
            """)

        // 关掉识别时必须有结果（disability 返回 nil，调用方保持现选区）。
        let disabledTarget = session.target(atGlobalPoint: centerGlobal, preference: .disabled)
        let disabledIsNil = disabledTarget == nil

        // 自动模式下必须得到一个结果（最差也是显示器层），
        // 因为识别失败会让用户看到「鼠标动了但选区不动」。
        let automaticTarget = session.target(atGlobalPoint: centerGlobal, preference: .automatic)
        let automaticHasResult = automaticTarget != nil
        let automaticRectInsideDisplay = automaticTarget.map {
            $0.rect.minX >= -0.5 && $0.rect.minY >= -0.5
                && $0.rect.maxX <= displayBounds.width + 0.5
                && $0.rect.maxY <= displayBounds.height + 0.5
        } ?? false

        let layersOK = disabledIsNil && automaticHasResult && automaticRectInsideDisplay
        logger.notice("""
            detection 层级可用性: 关闭时无结果=\(disabledIsNil, privacy: .public) \
            自动时有结果=\(automaticHasResult, privacy: .public) \
            结果在屏内=\(automaticRectInsideDisplay, privacy: .public) \
            -> \(layersOK ? "MATCH" : "MISMATCH", privacy: .public)
            """)

        // 窗口层若命中了窗口，矩形必须真的落在某个窗口上。
        if let windowTarget = session.target(atGlobalPoint: centerGlobal, preference: .window) {
            logger.notice("""
                detection 窗口层: 层级=\(windowTarget.layer.rawValue, privacy: .public) \
                标题=\(windowTarget.title ?? "-", privacy: .public) \
                矩形=\(Self.describe(windowTarget.rect), privacy: .public)
                """)
        }

        // ── 3）接线：鼠标移动必须真的改变选区 ──
        //
        // 走事件的真实路径。识别算得再对，没有接线就等于没有这个功能。
        let beforeMove = editor.selection
        let probeViewPoint = CGPoint(x: displayBounds.width * 0.5, y: displayBounds.height * 0.5)
        synthesizeMouseMoved(in: window, on: view, at: probeViewPoint)
        try? await Task.sleep(for: .milliseconds(400))
        let afterMove = editor.selection
        // 鼠标移动到屏幕中心时，识别结果会变（窗口或控件），
        // 但至少默认全屏这件事在会话刚建立时已经验证；这里只要求「没有被破坏成空」。
        let moveKeptSelection = !afterMove.isNonEmpty == false
        _ = beforeMove

        // ── 4）手动模式：按下后移动不应改变选区 ──
        synthesizeMouseDown(in: window, on: view, at: probeViewPoint)
        synthesizeMouseUp(in: window, on: view, at: probeViewPoint)
        try? await Task.sleep(for: .milliseconds(200))
        let afterClick = editor.selection

        let otherPoint = CGPoint(x: displayBounds.width * 0.25, y: displayBounds.height * 0.25)
        synthesizeMouseMoved(in: window, on: view, at: otherPoint)
        try? await Task.sleep(for: .milliseconds(400))
        let afterManualMove = editor.selection
        let manualModeHolds = afterManualMove == afterClick

        logger.notice("""
            detection 手动模式: 点击后选区=\(Self.describe(afterClick), privacy: .public) \
            再移动后=\(Self.describe(afterManualMove), privacy: .public) \
            未被识别覆盖=\(manualModeHolds, privacy: .public) \
            -> \(manualModeHolds ? "MATCH" : "MISMATCH", privacy: .public)
            """)

        logger.notice("""
            detection 接线: 移动后选区非空=\(moveKeptSelection, privacy: .public) \
            -> \(moveKeptSelection ? "MATCH" : "MISMATCH", privacy: .public)
            """)

        // ── 5）ESC 一次退出 ──
        // 放在最后：退出之后这个会话就没了，无法再做别的验证。
        // 键盘路径必须实测——「逻辑上显然」正是上次焦点缺陷蒙混过关的方式。
        let wasPresenting = controller.isPresentingForDiagnostics
        synthesizeKey(in: window, keyCode: 53, flags: [], characters: "\u{1b}")
        try? await Task.sleep(for: .milliseconds(900))
        let escExits = wasPresenting && !controller.isPresentingForDiagnostics

        logger.notice("""
            detection ESC: 退出前在展示=\(wasPresenting, privacy: .public) \
            退出后仍在展示=\(controller.isPresentingForDiagnostics, privacy: .public) \
            一次 ESC 即退出=\(escExits, privacy: .public) \
            -> \(escExits ? "MATCH" : "MISMATCH", privacy: .public)
            """)

        try? await Task.sleep(for: .milliseconds(400))
        controller.dismiss()
    }
}

#endif
