//
//  CaptureDiagnostics+ScrollshotOverlay.swift
//  AnShotUI
//
//  `-diagnoseScrollshotOverlay`：验证进度浮层**不会被抓进长图**。
//
//  ── 为什么这条必须实测 ────────────────────────────────────
//
//  预览浮层比原来的纯文字浮层大得多（460×332：导航栏 + 放大栏），在多数屏幕上
//  放不进选区外的缝隙。
//  方案依赖 `sharingType = .none`（窗口层面声明「不可被捕获」）让它可以自由摆放。
//
//  但这是**系统行为**，不是我们能从代码推断的事实：ScreenCaptureKit 是否遵守
//  窗口的 `sharingType`，必须在本机、本系统版本上抓一帧才能确认。
//  一旦不生效，浮层就会被逐帧拍进长图——而且因为它在会话期间一直显示，
//  每一帧都会被污染，产出的长图会带着一串浮层的残影。
//
//  ── 做法 ──────────────────────────────────────────────────
//
//  造一个已知纯色（品红）的窗口，把浮层**压在它中央**，然后抓这一块：
//
//  * 无浮层 vs 有浮层两张图应当**逐像素相同**；
//  * 中央区域必须仍是纯品红（浮层是深灰，混进去一眼就能识别）。
//

#if DEBUG
import AnShotCapture
import AnShotCore
import AppKit

extension CaptureDiagnostics {

    static func runScrollshotOverlayDiagnostic() async {
        let displayID = DisplayGeometry.mainDisplay()
        let scale = DisplayGeometry.scaleFactor(for: displayID)

        // 已知纯色窗口：品红。与浮层的深灰差异极大，任何一像素的污染都看得出来。
        let viewRect = CGRect(x: 480, y: 180, width: 600, height: 420)
        let screenHeight = DisplayGeometry.bounds(for: displayID).height
        let captureRect = CGRect(
            x: viewRect.minX,
            y: screenHeight - viewRect.maxY,
            width: viewRect.width,
            height: viewRect.height
        )

        let window = NSWindow(
            contentRect: viewRect,
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "anShot 浮层遮挡诊断"
        window.isReleasedWhenClosed = false
        let content = NSView(frame: CGRect(origin: .zero, size: viewRect.size))
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor(srgbRed: 1, green: 0, blue: 1, alpha: 1).cgColor
        window.contentView = content
        window.orderFrontRegardless()
        try? await Task.sleep(for: .milliseconds(800))

        var failed = 0
        func report(_ label: String, _ measured: String, _ expected: String, _ ok: Bool) {
            if !ok { failed += 1 }
            logger.notice("""
                [scrollshot-overlay] \(label, privacy: .public) measured=\(measured, privacy: .public) \
                expected=\(expected, privacy: .public)  \(ok ? "MATCH" : "MISMATCH", privacy: .public)
                """)
        }

        let capturer = CapturerFactory.makeDefault()
        let scope = CaptureScope.region(displayID, rect: captureRect)

        // ① 基线：无浮层。
        let baselineFrame = try? await capturer.captureFrame(scope: scope)
        guard let baseline = baselineFrame.flatMap({ ScrollshotImage($0.image) }) else {
            report("抓取基线帧", "nil", "非 nil", false)
            window.close()
            exit(1)
        }
        let baselineRatio = magentaRatio(baseline, sampleWidth: 240, sampleHeight: 180)

        // ② 浮层压在窗口中央。
        let bar = ScrollshotProgressBar()
        // 喂一份**可辨认**的预览内容（整幅条纹导航 + 按需取切片），
        // 这样浮层的外观可以被人工核对——诊断自拍不到它（sharingType = .none）。
        if let preview = makeInspectablePreview() {
            bar.onDetailRequest = preview.detailImage
            bar.updatePreview(preview.content)
        }
        let overlayRect = CGRect(
            x: viewRect.midX - 230,
            y: viewRect.midY - 166,
            width: 460,
            height: 332
        )
        bar.placeForDiagnostics(at: overlayRect)
        // 留足时间给人工/脚本截屏核对外观。
        try? await Task.sleep(for: .seconds(6))
        report("浮层已显示", "\(bar.isVisible)", "true", bar.isVisible)

        let coveredFrame = try? await capturer.captureFrame(scope: scope)
        guard let covered = coveredFrame.flatMap({ ScrollshotImage($0.image) }) else {
            report("抓取遮挡帧", "nil", "非 nil", false)
            bar.hide()
            window.close()
            exit(1)
        }

        let coveredRatio = magentaRatio(covered, sampleWidth: 240, sampleHeight: 180)
        report(
            "基线中央为纯品红",
            String(format: "%.3f", baselineRatio),
            "1.000",
            baselineRatio > 0.999
        )
        // 这一条是本次诊断的核心：浮层压在待抓区域上，抓到的仍应是背景色。
        report(
            "浮层区域仍为纯品红（未被拍进帧）",
            String(format: "%.3f", coveredRatio),
            "1.000",
            coveredRatio > 0.999
        )

        // 更强的判据：**浮层覆盖的那块区域**在有/无浮层时应当逐像素相同。
        //
        // 只比这块而不是整帧：整帧比较会被屏幕上其它地方的微小变化干扰
        //（鼠标光标、系统重绘），实测会出现个位数像素的假阳性——
        // 而那些像素与本诊断要回答的问题无关。
        var different = 0
        var worst = 0
        if baseline.width == covered.width, baseline.height == covered.height {
            let left = Int((overlayRect.minX - viewRect.minX) * scale)
            let top = Int((viewRect.maxY - overlayRect.maxY) * scale)
            let width = Int(overlayRect.width * scale)
            let height = Int(overlayRect.height * scale)
            baseline.withPixels { a in
                covered.withPixels { b in
                    for row in top..<min(top + height, baseline.height) {
                        for column in left..<min(left + width, baseline.width) {
                            let index = (row * baseline.width + column) * 4
                            guard index + 2 < a.count, index + 2 < b.count else { continue }
                            let error = max(
                                abs(Int(a[index]) - Int(b[index])),
                                max(
                                    abs(Int(a[index + 1]) - Int(b[index + 1])),
                                    abs(Int(a[index + 2]) - Int(b[index + 2]))
                                )
                            )
                            if error > 12 {
                                different += 1
                                worst = max(worst, error)
                            }
                        }
                    }
                }
            }
        } else {
            different = Int.max
        }
        report(
            "浮层区域内两帧逐像素一致",
            "不同像素 \(different)（最大误差 \(worst)）",
            "0",
            different == 0
        )

        // 浮层外观：渲染成图（屏幕捕获看不到它，见 `contentViewForDiagnostics`）。
        if let view = bar.contentViewForDiagnostics,
           let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: rep)
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("scrollshot-overlay.png")
            if let data = rep.representation(using: .png, properties: [:]) {
                try? data.write(to: url)
                logger.notice("[scrollshot-overlay] 浮层外观已渲染 \(url.path, privacy: .public)")
            }
        }

        bar.hide()
        try? await Task.sleep(for: .milliseconds(300))
        logger.notice("""
            [scrollshot-overlay] 汇总: \(failed == 0 ? "全部通过" : "\(failed) 项失败", privacy: .public) \
            exitCode=\(failed == 0 ? 0 : 1, privacy: .public)
            """)
        window.close()
        try? await Task.sleep(for: .milliseconds(300))
        exit(failed == 0 ? 0 : 1)
    }

    /// 造一份便于目视核对的预览内容：一张**虚构长图**（横向条纹 + 每 200 行一条
    /// 深色刻度 + 每 80 列一条竖线）。
    ///
    /// 条纹间距恒定，所以「缩到多少」一眼可量；刻度行号则用来核对导航栏的定位框
    /// 与放大栏指的是不是同一段——这正是两栏联动唯一要人工确认的地方。
    ///
    /// 真实会话里放大栏走 `ScrollshotSession.slice(worldRows:targetWidth:)`；
    /// 这里用等价的替身实现，让浮层在没有会话时也能显示出两栏。
    static func makeInspectablePreview() -> (
        content: ScrollshotPreviewContent,
        detailImage: @MainActor (Range<Int>, Int) -> CGImage?
    )? {
        let worldWidth = 800
        let worldHeight = 4000
        guard let world = makeVirtualLongImage(width: worldWidth, height: worldHeight) else {
            return nil
        }
        // 导航图：整幅 contain 进导航框（与会话里的算法同一条判据）。
        let box = ScrollshotProgressBar.navigatorPixelSize
        let scale = min(Double(box.width) / Double(worldWidth), Double(box.height) / Double(worldHeight))
        let thumbnailWidth = max(1, Int((Double(worldWidth) * scale).rounded(.down)))
        guard let thumbnail = scaleToWidth(world, targetWidth: thumbnailWidth),
              let cgImage = makeCGImage(from: thumbnail) else { return nil }

        let content = ScrollshotPreviewContent(
            navigatorImage: cgImage,
            navigatorPixelWidth: thumbnail.width,
            navigatorPixelHeight: thumbnail.height,
            worldWidth: worldWidth,
            worldStart: 0,
            worldHeight: worldHeight,
            // 视口放在长图偏下处：模拟「用户已经滚了一段」。
            viewportWorldRows: 1200..<2200
        )
        let detailImage: @MainActor (Range<Int>, Int) -> CGImage? = { rows, targetWidth in
            guard let slice = cropScale(world, rows: rows, targetWidth: targetWidth) else {
                return nil
            }
            return makeCGImage(from: slice)
        }
        return (content, detailImage)
    }

    /// 虚构长图：白底 + 横向条纹 + 每 200 行刻度 + 每 80 列竖线。
    private static func makeVirtualLongImage(width: Int, height: Int) -> ScrollshotImage? {
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            let band = (y / 50) % 3
            let tone: UInt8 = band == 0 ? 255 : (band == 1 ? 205 : 160)
            let isRuler = y % 200 == 0
            for x in 0..<width {
                let offset = (y * width + x) * 4
                let value: UInt8 = isRuler ? 40 : (x % 80 < 2 ? 120 : tone)
                pixels[offset] = value
                pixels[offset + 1] = value
                pixels[offset + 2] = UInt8(min(255, Int(value) + 20))
                pixels[offset + 3] = 255
            }
        }
        return ScrollshotImage(width: width, height: height, data: pixels)
    }

    /// 等比最近邻缩放到目标宽度（高度按比例）。
    private static func scaleToWidth(_ image: ScrollshotImage, targetWidth: Int) -> ScrollshotImage? {
        cropScale(image, rows: 0..<image.height, targetWidth: targetWidth)
    }

    /// 取 `rows` 行后等比缩放到 `targetWidth`（替代会话的切片，仅供诊断显示）。
    private static func cropScale(
        _ image: ScrollshotImage,
        rows: Range<Int>,
        targetWidth: Int
    ) -> ScrollshotImage? {
        let start = max(0, rows.lowerBound)
        let end = min(image.height, rows.upperBound)
        guard start < end, targetWidth > 0 else { return nil }
        let sourceRows = end - start
        let outputWidth = min(targetWidth, image.width)
        let outputHeight = max(
            1,
            Int((Double(sourceRows) * Double(outputWidth) / Double(image.width)).rounded(.down))
        )
        var buffer = [UInt8](repeating: 0, count: outputWidth * outputHeight * 4)
        let sourceBytesPerRow = image.width * 4
        let outputBytesPerRow = outputWidth * 4
        buffer.withUnsafeMutableBufferPointer { out in
            guard let outBase = out.baseAddress else { return }
            image.withPixels { source in
                guard let src = source.baseAddress else { return }
                for outY in 0..<outputHeight {
                    let sourceY = start + outY * sourceRows / outputHeight
                    let sourceOffset = sourceY * sourceBytesPerRow
                    let targetOffset = outY * outputBytesPerRow
                    for outX in 0..<outputWidth {
                        let column = min(image.width - 1, outX * image.width / outputWidth)
                        let s = sourceOffset + column * 4
                        guard s + 3 < source.count else { continue }
                        let d = targetOffset + outX * 4
                        outBase[d] = src[s]
                        outBase[d + 1] = src[s + 1]
                        outBase[d + 2] = src[s + 2]
                        outBase[d + 3] = 255
                    }
                }
            }
        }
        return ScrollshotImage(width: outputWidth, height: outputHeight, data: buffer)
    }

    /// 图像中央区域里「品红像素」的占比。
    private static func magentaRatio(
        _ image: ScrollshotImage,
        sampleWidth: Int,
        sampleHeight: Int
    ) -> Double {
        let width = min(sampleWidth, image.width)
        let height = min(sampleHeight, image.height)
        guard width > 0, height > 0 else { return 0 }
        let originX = (image.width - width) / 2
        let originY = (image.height - height) / 2

        var magenta = 0
        var total = 0
        image.withPixels { pixels in
            for y in originY..<(originY + height) {
                for x in originX..<(originX + width) {
                    let index = (y * image.width + x) * 4
                    let r = Int(pixels[index])
                    let g = Int(pixels[index + 1])
                    let b = Int(pixels[index + 2])
                    if r > 200, g < 60, b > 200 { magenta += 1 }
                    total += 1
                }
            }
        }
        return total > 0 ? Double(magenta) / Double(total) : 0
    }
}
#endif
