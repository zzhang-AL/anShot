//
//  CaptureDiagnostics+Capture.swift
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

    /// 捕获 3 次。
    ///
    /// 第 1 次是进程内的首次调用，代表冷启动；后续代表稳态。
    /// 用单调时钟（`ContinuousClock`）计时，避免墙钟被 NTP 调整影响。
    static func runCapture(
        scope: CaptureScope,
        implementation: CapturerFactory.Implementation?,
        label: String
    ) async {
        let capturer = makeCapturer(implementation)
        // 本诊断只传入 display / region 两种范围，窗口范围没有确定的显示器归属
        guard let displayID = scope.displayID else {
            logger.error("capture diag [\(label, privacy: .public)] 缺少显示器上下文，跳过")
            return
        }
        let pointSize = DisplayGeometry.bounds(for: displayID).size
        let pixelSize = DisplayGeometry.pixelSize(for: displayID)

        logger.notice("""
            capture diag [\(label, privacy: .public)] implementation=\(String(describing: capturer), privacy: .public) \
            logical=\(pointSize.width, format: .fixed(precision: 0))x\(pointSize.height, format: .fixed(precision: 0))pt \
            expectedPixel=\(pixelSize.width, format: .fixed(precision: 0))x\(pixelSize.height, format: .fixed(precision: 0))px \
            scale=\(DisplayGeometry.scaleFactor(for: displayID), format: .fixed(precision: 3))
            """)

        let attempts = parseIntArgument(CommandLine.arguments, "-attempts") ?? 3
        for attempt in 1...attempts {
            let start = ContinuousClock.now
            do {
                let frame = try await capturer.captureFrame(scope: scope)
                let duration = ContinuousClock.now - start
                let ms = Double(duration.components.seconds) * 1000
                       + Double(duration.components.attoseconds) / 1e15

                logger.notice("""
                    capture #\(attempt) (\(attempt == 1 ? "first" : "subsequent", privacy: .public)): \
                    \(frame.image.width)x\(frame.image.height)px \
                    scale=\(frame.scaleFactor, format: .fixed(precision: 2)) \
                    elapsed=\(ms, format: .fixed(precision: 1))ms
                    """)

                if attempt == 1 {
                    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
                        "anshot-\(label)-\(frame.image.width)x\(frame.image.height).png"
                    )
                    try ImageEncoding.write(frame.image, to: url, format: .png)
                    let size = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int) ?? 0
                    logger.notice("saved \(size)bytes -> \(url.path, privacy: .public)")
                }
            } catch {
                logger.error("capture #\(attempt) failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// 同时抓整屏与区域，用于坐标一致性比对。
    static func runBoth(implementation: CapturerFactory.Implementation?) async {
        let capturer = makeCapturer(implementation)
        let displayID = DisplayGeometry.mainDisplay()
        let region = CGRect(x: 200, y: 150, width: 600, height: 400)

        do {
            let full = try await capturer.captureFrame(scope: .display(displayID))
            let part = try await capturer.captureFrame(scope: .region(displayID, rect: region))

            let dir = FileManager.default.temporaryDirectory
            let fullURL = dir.appendingPathComponent("anshot-full.png")
            let partURL = dir.appendingPathComponent("anshot-region.png")
            try ImageEncoding.write(full.image, to: fullURL, format: .png)
            try ImageEncoding.write(part.image, to: partURL, format: .png)

            logger.notice("coordinate check saved: full=\(full.image.width)x\(full.image.height) region=\(part.image.width)x\(part.image.height) -> \(dir.path, privacy: .public)")
        } catch {
            logger.error("coordinate check failed: \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: - 自动识别诊断

    static func runBenchmark() async {
        logger.notice("benchmark: start (no capture performed)")
        await CapturerFactory.benchmarkShareableContentCost()
    }

    // MARK: - 选区坐标诊断

    /// 单独测量窗口创建与显示耗时，**不包含**底图抓取。
    static func measureWindowCreationCost() {
        guard let screen = NSScreen.main ?? NSScreen.screens.first,
              let displayID = screen.displayID else {
            logger.error("window creation benchmark skipped: no usable NSScreen")
            return
        }

        let clock = ContinuousClock()
        var creationCosts: [String] = []

        for _ in 0..<5 {
            let start = clock.now
            let window = OverlayWindow(screen: screen, displayID: displayID)
            creationCosts.append(milliseconds(start, clock.now))
            window.close()
        }

        // 显示与销毁也各测一次：orderFrontRegardless 到返回即窗口已提交合成。
        let window = OverlayWindow(screen: screen, displayID: displayID)
        let showStart = clock.now
        window.presentWithoutActivating()
        let showCost = milliseconds(showStart, clock.now)

        let closeStart = clock.now
        window.orderOut(nil)
        window.close()
        let closeCost = milliseconds(closeStart, clock.now)

        logger.notice("""
            overlay window benchmark: create=[\(creationCosts.joined(separator: ", "), privacy: .public)]ms \
            show=\(showCost, privacy: .public)ms close=\(closeCost, privacy: .public)ms
            """)
    }

    /// 覆盖层展示期间抓一张全屏，用于核对底图是否真的被绘制。
    ///
    /// 存在的理由：终端缺屏幕录制权限，`screencapture` 报
    /// 「could not create image from display」，而本应用有权限。
    /// 这是无人值守下唯一能「看到」覆盖层实际效果的手段。
    static func captureOverlaySelfShot(round: Int) async {
        do {
            let capturer = CapturerFactory.makeDefault()
            let frame = try await capturer.captureFrame(scope: .display(DisplayGeometry.mainDisplay()))
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("anshot-overlay-selfshot-\(round).png")
            try ImageEncoding.write(frame.image, to: url, format: .png)
            let size = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int) ?? 0
            logger.notice("overlay self-shot #\(round, privacy: .public): \(size, privacy: .public)bytes -> \(url.path, privacy: .public)")
        } catch {
            logger.error("overlay self-shot #\(round, privacy: .public) failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// 进程内读取 phys_footprint（MB）。
    ///
    /// 用进程内读数而非外部 `footprint` 命令：外部采样有延迟，
    /// 在「dismiss 后是否已释放」这类瞬时判断上会给出错误的结论。
    ///
    /// **这个数不能单独当内存判据。** 实测：跑完 100 次会话后
    /// 本函数读到 120.9MB，而 `footprint -p` 只有 32MB，
    /// 差额全在「可回收」的 malloc 保留区里（`leaks` 同时证明
    /// 没有任何本项目对象或 CGImage 残留）。
    /// 单看 phys_footprint 会把正常的分配器高水位误判成泄漏。
    /// 判据应看外部 `footprint` 的 Footprint 值 + `CG Image` 类目 + `leaks`。
    ///
    /// 另有两点：`phys_footprint_peak` 不在 `task_vm_info` 里（峰值只能靠采样逼近，
    /// 或由外部工具给出）；读取失败时返回 0 而不是抛错——诊断不该因为
    /// 一次读数失败而整体崩掉。
    static func footprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else {
            logger.error("footprint read failed; kern_return=\(result, privacy: .public)")
            return 0
        }
        return Double(info.phys_footprint) / 1024 / 1024
    }

    /// 记录一次 footprint（判据与限制见 `footprintMB`）。
    static func logFootprint(action: String) {
        logger.notice("""
            footprint [\(action, privacy: .public)]: \
            当前=\(footprintMB(), format: .fixed(precision: 1))MB
            """)
    }

    static func makeSolidImage(width: Int, height: Int, gray: CGFloat) -> CGImage? {
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        context.setFillColor(CGColor(red: gray, green: gray, blue: gray, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    /// 诊断用的可控底图。
    ///
    /// 用它替换真实桌面有两个原因：
    ///
    /// 1. **审查产物不得包含用户的真实屏幕内容**。诊断会抓整屏，
    ///    而覆盖层的遮罩是半透明的，底下的终端、文档、密码都会出现在图里。
    /// 2. 马赛克、线宽、文字这些东西需要**有纹理、有文字、有色彩边界**的背景
    ///    才看得出效果。纯色底图对马赛克是幂等的，什么都验证不了。
    private static func makeDiagnosticBackdrop(width: Int, height: Int) -> CGImage? {
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue
        ) else {
            return nil
        }

        // 翻成左上原点，用与模型一致的行列坐标书写。
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)

        context.setFillColor(CGColor(red: 0.86, green: 0.87, blue: 0.89, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        // 色块：给马赛克与颜色标注提供明确的色彩边界。
        let blocks: [(CGRect, CGColor)] = [
            (
                CGRect(x: Double(width) * 0.06, y: Double(height) * 0.08,
                       width: Double(width) * 0.22, height: Double(height) * 0.16),
                CGColor(red: 0.92, green: 0.30, blue: 0.24, alpha: 1)
            ),
            (
                CGRect(x: Double(width) * 0.32, y: Double(height) * 0.08,
                       width: Double(width) * 0.22, height: Double(height) * 0.16),
                CGColor(red: 0.20, green: 0.60, blue: 0.95, alpha: 1)
            ),
            (
                CGRect(x: Double(width) * 0.58, y: Double(height) * 0.08,
                       width: Double(width) * 0.22, height: Double(height) * 0.16),
                CGColor(red: 0.25, green: 0.75, blue: 0.40, alpha: 1)
            ),
            (
                CGRect(x: Double(width) * 0.06, y: Double(height) * 0.30,
                       width: Double(width) * 0.74, height: Double(height) * 0.12),
                CGColor(red: 0.16, green: 0.17, blue: 0.20, alpha: 1)
            ),
        ]
        for (rect, color) in blocks {
            context.setFillColor(color)
            context.fill(rect)
        }

        // 细横线：检验线宽落点，也检验马赛克是否真把细线糊掉。
        context.setStrokeColor(CGColor(red: 0.32, green: 0.33, blue: 0.37, alpha: 1))
        context.setLineWidth(1)
        for index in 0 ..< 14 {
            let y = Double(height) * 0.50 + Double(index) * 5
            context.move(to: CGPoint(x: Double(width) * 0.06, y: y))
            context.addLine(to: CGPoint(x: Double(width) * 0.80, y: y))
        }
        context.strokePath()

        // 文字：检验标注字号是否与输入框一致，也检验马赛克对文字的遮挡。
        let paragraphs = [
            "AnShot 诊断底图 · 合成内容，不含真实屏幕",
            "The quick brown fox jumps over the lazy dog 0123456789",
            "这一段文字应当被马赛克糊成不可辨认的块",
            "细线区域用于检查线宽标注的精确落点",
        ]
        for (index, text) in paragraphs.enumerated() {
            let attributed = NSAttributedString(
                string: text,
                attributes: [
                    .font: NSFont.systemFont(ofSize: 15, weight: .regular),
                    .foregroundColor: NSColor.black,
                ]
            )
            let line = CTLineCreateWithAttributedString(attributed)
            context.saveGState()
            // 上下文已翻转为左上原点，文字排版需要 y 轴向上，再翻一次抵消。
            context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
            context.textPosition = CGPoint(
                x: Double(width) * 0.06,
                y: Double(height) * (0.68 + Double(index) * 0.055)
            )
            CTLineDraw(line, context)
            context.restoreGState()
        }

        return context.makeImage()
    }

    /// 把指定显示器的覆盖层底图换成合成底图。
    ///
    /// 诊断会抓整屏，而覆盖层遮罩是半透明的，
    /// 不换底图就会把用户的真实屏幕内容一起写进审查产物。
    static func applyDiagnosticBackdrop(
        to controller: OverlayController,
        displayID: CGDirectDisplayID
    ) {
        let pixelSize = DisplayGeometry.pixelSize(for: displayID)
        guard let backdrop = makeDiagnosticBackdrop(
            width: Int(pixelSize.width.rounded()),
            height: Int(pixelSize.height.rounded())
        ) else {
            logger.error("diagnostic backdrop: build failed")
            return
        }
        controller.setBackdropForDiagnostics(backdrop, displayID: displayID)
    }

    /// 构造一幅小尺寸测试图像。不捕获屏幕，避免诊断依赖权限。
    static func makeDiagnosticImage() -> CGImage? {
        let width = 8
        let height = 8
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }
        context.setFillColor(CGColor(red: 0.2, green: 0.6, blue: 0.9, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    // MARK: - 导出诊断
}

#endif
