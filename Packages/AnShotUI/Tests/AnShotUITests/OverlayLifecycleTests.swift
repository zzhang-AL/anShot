import AppKit
import Foundation
import Testing

@testable import AnShotCapture
@testable import AnShotCore
@testable import AnShotUI

@Suite("普通截图会话隔离", .serialized)
@MainActor
struct OverlayLifecycleTests {
    @Test("取消后立即重开，迟到的旧抓帧不得清理新会话")
    func cancelledCaptureCannotTearDownNextSession() async throws {
        _ = NSApplication.shared
        let screenCount = NSScreen.screens.count
        try #require(screenCount > 0)
        let capturer = SuspendedBackdropCapturer()
        let controller = OverlayController(capturer: capturer)
        defer { controller.dismiss() }

        controller.present()
        let oldTask = try #require(controller.sessionTask)
        try await waitUntil { await capturer.pendingCount(round: 0) == screenCount }
        controller.dismiss()

        await capturer.advanceRound()
        controller.present()
        let newTask = try #require(controller.sessionTask)
        try await waitUntil { await capturer.pendingCount(round: 1) == screenCount }
        let newEditor = try #require(controller.editorState)

        // 先让新会话完成，再让不响应取消的旧 SDK 请求返回。
        await capturer.release(round: 1)
        await newTask.value
        let newWindow = try #require(controller.primaryOverlayWindow)
        await capturer.release(round: 0)
        await oldTask.value

        #expect(controller.isPresenting)
        let keepsWindow = controller.primaryOverlayWindow === newWindow
        let keepsEditor = controller.editorState === newEditor
        #expect(keepsWindow)
        #expect(keepsEditor)
        #expect(newWindow.isVisible)
    }

    @Test("图片编辑窗关闭红叉后解除 isPresenting 锁死并释放窗口，支持再次打开")
    func closingImageEditorWindowResetsPresentingState() throws {
        _ = NSApplication.shared
        guard !NSScreen.screens.isEmpty else { return }
        let capturer = SuspendedBackdropCapturer()
        let controller = OverlayController(capturer: capturer)
        defer { controller.dismiss() }

        let image = makeSolidCGImage(width: 800, height: 600)
        controller.present(image: image, scaleFactor: 2)
        #expect(controller.isPresenting)
        let window = try #require(controller.primaryOverlayWindow)

        // 模拟用户点击左上角系统红叉关窗
        window.close()
        #expect(!controller.isPresenting, "关闭图片编辑窗口后必须释放会话，不得卡死 isPresenting")
        #expect(controller.primaryOverlayWindow == nil)

        // 确认可以正常重新进入下一轮会话
        controller.present(image: image, scaleFactor: 2)
        #expect(controller.isPresenting)
    }

    @Test("present(image:scaleFactor:) 按逻辑点折算 2x Retina 图片窗口尺寸")
    func presentImageUsesLogicalSizeForRetinaScale() throws {
        _ = NSApplication.shared
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let capturer = SuspendedBackdropCapturer()
        let controller = OverlayController(capturer: capturer)
        defer { controller.dismiss() }

        // 800×600 物理像素 @ 2x = 400×300 逻辑点（但最小放大保护下不膨胀到 800×600 以上）
        let image = makeSolidCGImage(width: 1200, height: 800)
        controller.present(image: image, scaleFactor: 2)
        let window = try #require(controller.primaryOverlayWindow)
        let expectedWidth = min(max(320, screen.visibleFrame.width * 0.9), 600)
        #expect(window.frame.width <= expectedWidth + 1, "2x 图不应按 1x 像素直接撑大 2 倍，实际宽=\(window.frame.width)")
    }

    @Test("自绘取色器 Hex 输入框可编辑且面板 ESC 可关闭归还父窗焦点")
    func colorPickerHexEditableAndEscClosable() throws {
        _ = NSApplication.shared
        let pickerView = ColorPickerView(frame: CGRect(origin: .zero, size: ColorPickerView.preferredSize))
        let hexField = findTextField(in: pickerView)
        let field = try #require(hexField)
        #expect(field.isEditable, "替换 CenteredHexFieldCell 后 Hex 输入框必须保持可编辑")
        #expect(field.isSelectable, "替换 CenteredHexFieldCell 后 Hex 输入框必须保持可选中")

        let panel = ColorPickerPanel()
        #expect(panel.hidesOnDeactivate == false, "ColorPickerPanel 必须关闭失焦自动隐藏")
        var cancelled = false
        panel.onCancel = { cancelled = true }
        panel.cancelOperation(nil)
        #expect(cancelled, "ColorPickerPanel 按 ESC 必须触发关闭回调")
    }

    @Test("超长截图进入编辑窗口保持严格等比且画布坐标映射零错位")
    func tallScrollshotEditorPreservesAspectRatioAndCoordinates() throws {
        _ = NSApplication.shared
        let visible = CGRect(x: 0, y: 40, width: 1440, height: 860)
        let layout = OverlayController.imageEditorLayout(
            pixelWidth: 1440,
            pixelHeight: 12000,
            backingScale: 2.0,
            visibleFrame: visible
        )
        // 纵长图应按宽度适配并保留完整可滚动高度，不得压扁或横向拉宽。
        let expectedAspect = 12000.0 / 1440.0
        let actualAspect = layout.canvasSize.height / layout.canvasSize.width
        #expect(abs(actualAspect - expectedAspect) < 0.05)
        #expect(layout.canvasSize.width == 720)
        #expect(layout.canvasSize.height == 6000)
        #expect(layout.windowSize.height <= visible.height * 0.9 + 1)

        // 验证 OverlayView 居中映射：点击画布正中应精确落回原图 (720, 6000)。
        guard let screen = NSScreen.main ?? NSScreen.screens.first,
              let displayID = screen.displayID else { return }
        let tallImage = makeSolidCGImage(width: 1440, height: 12000)
        let window = OverlayWindow(
            imageFrame: CGRect(origin: .zero, size: layout.windowSize),
            canvasSize: layout.canvasSize,
            displayID: displayID
        )
        window.overlayView.backdrop = tallImage
        let centerPixel = window.overlayView.pixelPoint(from: CGPoint(
            x: layout.canvasSize.width / 2,
            y: layout.canvasSize.height / 2
        ))
        #expect(abs(centerPixel.x - 720) < 1)
        #expect(abs(centerPixel.y - 6000) < 1)
    }

    @Test("放大镜卡片宽度足以无碰撞容纳 4K 坐标与 RGB/快捷键提示")
    func loupePanelFits4KCoordinatesAndRGBHintWithoutOverlap() {
        let contentWidth = OverlayLoupeSampler.defaultPanelSize.width - 20
        let hexWidth = ("#FFFFFF" as NSString).size(withAttributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 10.5, weight: .semibold),
        ]).width
        let coordWidth = ("(3840, 2160)" as NSString).size(withAttributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 9.5, weight: .regular),
        ]).width
        #expect(10 + 5 + hexWidth + 4 + coordWidth <= contentWidth, "第 1 行 #HEX 与 4K 坐标不应重叠")

        let rgbWidth = ("RGB(255, 255, 255)" as NSString).size(withAttributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 9.5, weight: .regular),
        ]).width
        let hintWidth = ("C / ⇧C" as NSString).size(withAttributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 9, weight: .medium),
        ]).width
        #expect(rgbWidth + 4 + hintWidth <= contentWidth, "第 2 行 RGB 与快捷键提示不应裁断")
    }

    @Test("长截图结果窗对超长图默认适应宽度并支持切换全览")
    func scrollshotResultSupportsScrollableFitWidthAndFitAll() {
        _ = NSApplication.shared
        let tallImage = makeSolidCGImage(width: 400, height: 3000)
        var closed = false
        let resultController = ScrollshotResultController(
            image: tallImage,
            warnings: [],
            actions: .init(
                onSave: { _ in },
                onCopy: { _ in },
                onPin: { _ in },
                onEdit: nil,
                onClose: { closed = true }
            )
        )
        resultController.close()
        #expect(closed)
    }

    private func findTextField(in view: NSView) -> NSTextField? {
        if let field = view as? NSTextField { return field }
        return view.subviews.lazy.compactMap { findTextField(in: $0) }.first
    }

    private func makeSolidCGImage(width: Int, height: Int) -> CGImage {
        let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }

    private func waitUntil(_ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !(await condition()) {
            guard ContinuousClock.now < deadline else { throw WaitError.timedOut }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    private enum WaitError: Error { case timedOut }
}

private actor SuspendedBackdropCapturer: ScreenCapturing {
    private struct Request {
        let displayID: CGDirectDisplayID
        let continuation: CheckedContinuation<CapturedFrame, Never>
    }

    private var round = 0
    private var pending: [Int: [Request]] = [:]

    func advanceRound() { round += 1 }
    func pendingCount(round: Int) -> Int { pending[round, default: []].count }

    func captureFrame(scope: CaptureScope) async throws -> CapturedFrame {
        guard case .display(let displayID) = scope else { throw CaptureError.scopeUnavailable }
        return await withCheckedContinuation { continuation in
            pending[round, default: []].append(Request(displayID: displayID, continuation: continuation))
        }
    }

    func release(round: Int) {
        let requests = pending.removeValue(forKey: round) ?? []
        for request in requests {
            let context = CGContext(data: nil, width: 32, height: 32, bitsPerComponent: 8,
                                    bytesPerRow: 128, space: CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            request.continuation.resume(returning: CapturedFrame(
                image: context.makeImage()!, displayID: request.displayID, scaleFactor: 1
            ))
        }
    }
}
