//
//  CaptureDiagnostics+Support.swift
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

    /// 把选区格式化为可比对的字符串。
    static func describe(_ rect: PixelRect?) -> String {
        guard let rect else { return "nil" }
        return String(
            format: "%@ %.0fx%.0f",
            NSStringFromRect(CGRect(
                x: rect.origin.x, y: rect.origin.y,
                width: rect.size.width, height: rect.size.height
            )),
            rect.size.width, rect.size.height
        )
    }

    static func describe(_ rect: PixelRect) -> String {
        """
        \(Int(rect.origin.x.rounded())),\(Int(rect.origin.y.rounded())) \
        \(Int(rect.size.width.rounded()))x\(Int(rect.size.height.rounded()))
        """
    }

    static func describe(_ rect: CGRect) -> String {
        """
        \(Int(rect.minX.rounded())),\(Int(rect.minY.rounded())) \
        \(Int(rect.width.rounded()))x\(Int(rect.height.rounded()))
        """
    }

    /// 可选版本：视图层的选区可以不存在（未框选），排查时「不存在」本身
    /// 就是关键信息，不能与「存在但为零」混为一谈。
    static func describe(_ rect: CGRect?) -> String {
        guard let rect else { return "nil" }
        return describe(rect)
    }

    // MARK: - 窗口识别探针

    /// 把矩形格式化成 `x,y wxh`，便于在日志里对比区域/全屏等矩形。
    static func formatRect(_ rect: CGRect?) -> String {
        guard let rect else { return "nil" }
        return String(
            format: "%.0f,%.0f %.0fx%.0f",
            rect.minX, rect.minY, rect.width, rect.height
        )
    }

    /// 预期像素矩形（硬编码选区的换算结果，用作比对基准）。
    static func pixelRect(of logical: CGRect) -> PixelRect {
        CoordinateConversion.pixelRect(
            fromLogical: logical,
            scaleFactor: DisplayGeometry.scaleFactor(for: DisplayGeometry.mainDisplay())
        )
    }

    static func milliseconds(_ from: ContinuousClock.Instant, _ to: ContinuousClock.Instant) -> String {
        let duration = from.duration(to: to)
        let components = duration.components
        let value = Double(components.seconds) * 1000 + Double(components.attoseconds) / 1e15
        return String(format: "%.1f", value)
    }

    // MARK: - 捕获

    /// 把解码帧写成 PNG，便于人工查看录制内容。
    static func savePreview(_ image: CGImage, baseName: String) -> URL? {
        let url = URL(fileURLWithPath: NSTemporaryDirectory() + baseName + "-frame.png")
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL,
            "public.png" as CFString,
            1,
            nil
        ) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? url : nil
    }

    /// 保存原始底图，供与自拍图逐像素比对方向。
    static func saveBackdrop(_ image: CGImage?, round: Int) {
        guard let image else {
            logger.error("no backdrop recorded for round \(round, privacy: .public)")
            return
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("anshot-overlay-backdrop-\(round).png")
        do {
            try ImageEncoding.write(image, to: url, format: .png)
            logger.notice("overlay backdrop #\(round, privacy: .public) saved -> \(url.path, privacy: .public)")
        } catch {
            logger.error("backdrop save failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// 列出给定选项下本机可见的窗口号（本进程有屏幕录制权限时含其它应用）。
    static func windowNumbers(with options: CGWindowListOption) -> [Int] {
        guard let list = CGWindowListCopyWindowInfo(
            options,
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return []
        }
        return list.compactMap { $0[kCGWindowNumber as String] as? Int }
    }

    /// 轮询等待条件成立。
    static func waitForCondition(
        timeout: TimeInterval,
        _ condition: () -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return condition()
    }

    // MARK: - 录制诊断（M2）

    /// 轮询等待录制器进入目标状态。
    static func waitForRecordingState(
        _ recorder: SCStreamRecorder,
        target: RecordingState,
        timeout: TimeInterval
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if recorder.state == target { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return recorder.state == target
    }

    /// 合成一次鼠标移动事件。
    static func synthesizeMouseMoved(
        in window: NSWindow,
        on view: NSView,
        at viewPoint: CGPoint
    ) {
        guard let event = NSEvent.mouseEvent(
            with: .mouseMoved,
            location: view.convert(viewPoint, to: nil),
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 0,
            pressure: 0
        ) else {
            return
        }
        window.sendEvent(event)
    }

    static func synthesizeMouseDown(
        in window: NSWindow,
        on view: NSView,
        at viewPoint: CGPoint
    ) {
        guard let event = NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: view.convert(viewPoint, to: nil),
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        ) else {
            return
        }
        window.sendEvent(event)
    }

    static func synthesizeMouseUp(
        in window: NSWindow,
        on view: NSView,
        at viewPoint: CGPoint
    ) {
        guard let event = NSEvent.mouseEvent(
            with: .leftMouseUp,
            location: view.convert(viewPoint, to: nil),
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 0
        ) else {
            return
        }
        window.sendEvent(event)
    }

    /// 在指定窗口的某个视图上合成一次拖拽。
    static func synthesizeDrag(
        in window: NSWindow,
        on view: NSView,
        from start: CGPoint,
        to end: CGPoint
    ) {
        let steps = 6
        let points = (0 ... steps).map { step -> CGPoint in
            let t = CGFloat(step) / CGFloat(steps)
            return CGPoint(
                x: start.x + (end.x - start.x) * t,
                y: start.y + (end.y - start.y) * t
            )
        }
        synthesizePathDrag(in: window, on: view, points: points)
    }

    /// 沿一条**弧线**合成拖拽：专用于验证手绘这类靠轨迹成形的工具。
    ///
    /// 不能拿直线版 `synthesizeDrag` 验证手绘：那条路径上的采样点全部共线，
    /// 经 Douglas–Peucker 简化后只剩两个端点，于是「真的采到了轨迹」与
    /// 「退化成一条直线」会产生**完全相同**的模型，断言分不出两者。
    /// 路径在中途鼓出 `bulge` 像素，简化后必然保留拐点。
    static func synthesizeCurvedDrag(
        in window: NSWindow,
        on view: NSView,
        from start: CGPoint,
        to end: CGPoint,
        bulge: CGFloat
    ) {
        let steps = 12
        let dx = end.x - start.x
        let dy = end.y - start.y
        let length = max(0.001, (dx * dx + dy * dy).squareRoot())
        let normal = CGPoint(x: -dy / length, y: dx / length)

        let points = (0 ... steps).map { step -> CGPoint in
            let t = CGFloat(step) / CGFloat(steps)
            // sin(πt) 两端为 0、中点最大：弧线仍然准确地起于 start、止于 end。
            let offset = bulge * CGFloat(sin(Double.pi * Double(t)))
            return CGPoint(
                x: start.x + dx * t + normal.x * offset,
                y: start.y + dy * t + normal.y * offset
            )
        }
        synthesizePathDrag(in: window, on: view, points: points)
    }

    /// 沿给定路径点合成一次完整拖拽（按下 → 逐点拖动 → 抬起）。
    ///
    /// 把事件构造与路径生成分开：直线版与弧线版只差「点怎么算」，
    /// 事件循环本身没有第二种写法。
    static func synthesizePathDrag(
        in window: NSWindow,
        on view: NSView,
        points: [CGPoint]
    ) {
        guard let first = points.first, let last = points.last else { return }

        func makeEvent(_ type: NSEvent.EventType, at viewPoint: CGPoint) -> NSEvent? {
            NSEvent.mouseEvent(
                with: type,
                location: view.convert(viewPoint, to: nil),
                modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber,
                context: nil,
                eventNumber: 0,
                clickCount: 1,
                pressure: 1
            )
        }

        if let down = makeEvent(.leftMouseDown, at: first) { window.sendEvent(down) }
        for point in points.dropFirst() {
            if let dragged = makeEvent(.leftMouseDragged, at: point) { window.sendEvent(dragged) }
        }
        if let up = makeEvent(.leftMouseUp, at: last) { window.sendEvent(up) }
    }

    /// 合成一次键盘事件并交给窗口分发。
    ///
    /// 走 `window.sendEvent` 而不是直接调用 `keyDown`：
    /// 后者绕过了 responder chain，测不出「焦点不在覆盖层」这类真实问题。
    static func synthesizeKey(
        in window: NSWindow,
        keyCode: UInt16,
        flags: NSEvent.ModifierFlags = [],
        characters: String = "\r"
    ) {
        guard let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: flags,
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: keyCode
        ) else {
            return
        }
        window.sendEvent(event)
    }

    /// 合成一次按键事件并投递到指定窗口。
    static func sendKeyEvent(
        to window: NSWindow,
        keyCode: UInt32,
        flags: NSEvent.ModifierFlags,
        characters: String
    ) {
        guard let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: flags,
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: UInt16(keyCode)
        ) else {
            return
        }
        window.sendEvent(event)
    }

    /// 在控件中心合成一次点击。
    static func click(_ target: NSView, in window: NSWindow) {
        let center = NSPoint(x: target.bounds.midX, y: target.bounds.midY)
        guard let event = NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: target.convert(center, to: nil),
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        ) else {
            return
        }
        window.sendEvent(event)
    }

    /// 合成一次左键点击。
    static func synthesizeClick(in window: NSWindow, at viewPoint: CGPoint) {
        guard let view = window.contentView else { return }

        func makeEvent(_ type: NSEvent.EventType) -> NSEvent? {
            NSEvent.mouseEvent(
                with: type,
                location: view.convert(viewPoint, to: nil),
                modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber,
                context: nil,
                eventNumber: 0,
                clickCount: 1,
                pressure: 1
            )
        }

        if let down = makeEvent(.leftMouseDown) { window.sendEvent(down) }
        if let up = makeEvent(.leftMouseUp) { window.sendEvent(up) }
    }

    /// 向窗口投递合成的鼠标事件，模拟一次真实拖拽。
    ///
    /// ── 坐标语义陷阱 ──
    /// `NSEvent.locationInWindow` 用的是**窗口坐标（左下原点）**，
    /// 而覆盖层视图是左上原点。直接传入视图坐标会得到垂直翻转的结果
    /// （曾实测到 origin.y 偏为 1912−440−520 = 952）。
    /// 必须先经 `NSView.convert(_:to:)` 转换。
    static func simulateDrag(in window: NSWindow, from start: CGPoint, to end: CGPoint) {
        guard let view = window.contentView else {
            logger.error("selection diag: window has no contentView; cannot synthesize drag")
            return
        }

        func makeEvent(_ type: NSEvent.EventType, at viewPoint: CGPoint) -> NSEvent? {
            NSEvent.mouseEvent(
                with: type,
                location: view.convert(viewPoint, to: nil),
                modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber,
                context: nil,
                eventNumber: 0,
                clickCount: 1,
                pressure: 1
            )
        }

        if let down = makeEvent(.leftMouseDown, at: start) {
            window.sendEvent(down)
        }
        // 分步拖拽：单步跳跃无法暴露「中间状态未更新」这类缺陷。
        let steps = 8
        for step in 1...steps {
            let t = CGFloat(step) / CGFloat(steps)
            let point = CGPoint(
                x: start.x + (end.x - start.x) * t,
                y: start.y + (end.y - start.y) * t
            )
            if let dragged = makeEvent(.leftMouseDragged, at: point) {
                window.sendEvent(dragged)
            }
        }
        if let up = makeEvent(.leftMouseUp, at: end) {
            window.sendEvent(up)
        }
    }

    /// 合成一次鼠标移动。
    ///
    /// 验证「已确认后识别不再替换选区」必须用到它：不移动鼠标，
    /// 识别入口（`mouseMoved`）根本不会被触发，那一条断言就永远为真。
    static func simulateMouseMove(in window: NSWindow, to viewPoint: CGPoint) {
        guard let view = window.contentView,
              let event = NSEvent.mouseEvent(
                  with: .mouseMoved,
                  location: view.convert(viewPoint, to: nil),
                  modifierFlags: [],
                  timestamp: ProcessInfo.processInfo.systemUptime,
                  windowNumber: window.windowNumber,
                  context: nil,
                  eventNumber: 0,
                  clickCount: 0,
                  pressure: 0
              ) else {
            logger.error("phase diag: cannot synthesize mouseMoved")
            return
        }
        window.sendEvent(event)
    }

    // MARK: - 覆盖层诊断

    /// 逐像素比较两幅图是否完全一致。
    static func pixelEqual(_ lhs: CGImage, _ rhs: CGImage) -> Bool {
        guard lhs.width == rhs.width, lhs.height == rhs.height else { return false }

        func bytes(_ image: CGImage) -> [UInt8]? {
            let width = image.width
            let height = image.height
            var buffer = [UInt8](repeating: 0, count: width * height * 4)
            var ok = false
            buffer.withUnsafeMutableBytes { raw in
                guard let context = CGContext(
                    data: raw.baseAddress,
                    width: width,
                    height: height,
                    bitsPerComponent: 8,
                    bytesPerRow: width * 4,
                    space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                ) else { return }
                context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
                ok = true
            }
            return ok ? buffer : nil
        }

        guard let left = bytes(lhs), let right = bytes(rhs) else { return false }
        return left == right
    }

    // MARK: - 录制界面诊断（M2-6）
}

#endif
