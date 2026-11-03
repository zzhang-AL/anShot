//
//  CaptureDiagnostics+Scrollshot.swift
//  AnShotUI
//
//  `-diagnoseScrollshot`：滚动截图（M3-1）可行性的第一手实测。
//
//  ── 为什么必须在 app 内、用真实页面 ────────────────────────
//
//  1. **TCC**：截图要屏幕录制权限，而权限锚定在 app 身份上。脚本直跑截图会被拒，
//     所以这类测量只能放在 app 的诊断里。
//  2. **合成图不能代表真实滚动内容**：离线探针已测出配准质量**高度依赖纹理的
//     2D 丰富度**——稀疏横线（真实网页文本行的抽象）会让 Vision 给出完全错误、
//     而且**自洽**的位移（+147 与 -147 互为反向，双向一致性检查抓不到）；
//     而 2D 随机纹理上它精确到亚像素。真实网页是哪一类，只能实测。
//  3. **滚动量必须已知**：本诊断自己发滚动命令，因此每帧的期望位移是真值，
//     可以把配准结果与之对照——这是判断「配准够不够用」的唯一硬标准。
//
//  ── 输出是测量数据，不是通过/失败 ──────────────────────────
//
//  这里记录真值 vs 实测、对齐后像素差异率、耗时。断言只用来保证诊断本身没坏
//  （例如「没滚动时位移必须是 0」），不用来断言某种算法合格。
//

#if DEBUG
import AnShotCapture
import AnShotCore
import AppKit
import Vision
import WebKit

extension CaptureDiagnostics {

    /// 测量一档滚动的结果。
    private struct ScrollshotSample {
        let page: String
        let expected: Double
        let measured: Double
        let meanError: Double
        let diffRatio: Double
        let milliseconds: Double
        var error: Double { measured - expected }
        var isExact: Bool { abs(error) <= 1 }
    }

    static func runScrollshotDiagnostic() async {
        let displayID = DisplayGeometry.mainDisplay()
        let screen = DisplayGeometry.bounds(for: displayID)

        // 视口：放在屏幕中央偏上，避开 Dock 与菜单栏，且不覆盖系统 UI。
        //
        // **两套坐标系必须分开**：窗口用 AppKit 坐标（原点左下），
        // 而 `CaptureScope.region` 的 rect 是显示器坐标（原点左上）。
        // 拿同一个 CGRect 两边用，抓到的是「窗口上方的一块桌面」——
        // 表观症状是「页面明明滚了、配准却恒为 0」，光看数字分辨不出来。
        let viewportLogical = CGRect(x: 400, y: 160, width: 720, height: 480)
        let captureRect = CGRect(
            x: viewportLogical.minX,
            y: screen.height - viewportLogical.maxY,
            width: viewportLogical.width,
            height: viewportLogical.height
        )

        let window = NSWindow(
            contentRect: viewportLogical,
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "anShot 滚动截图诊断页"
        window.isReleasedWhenClosed = false
        let webView = WKWebView(frame: CGRect(origin: .zero, size: viewportLogical.size))
        window.contentView = webView
        window.orderFrontRegardless()
        try? await Task.sleep(for: .milliseconds(900))

        let pages: [(name: String, html: String)] = [
            ("真实排版（标题/段落/列表/图片）", Self.htmlRealistic),
            ("等距列表（周期内容）", Self.htmlPeriodic),
            ("含 sticky 顶栏", Self.htmlSticky),
        ]
        // 滚动量覆盖：不动、小幅、半周期、跨周期、大幅
        let scrollSteps: [Double] = [0, 1, 7, 17, 44, 137, 400]

        var samples: [ScrollshotSample] = []
        var failed = 0

        for page in pages {
            webView.loadHTMLString(page.html, baseURL: nil)
            try? await Task.sleep(for: .milliseconds(1200))

            // 先确认页面真的可滚动：内容高度不足时 scrollTo 静默无效，
            // 表现就是「所有档位位移都是 0」——光看位移数字分辨不出这个原因。
            let pageHeight = await jsNumber(webView, "document.documentElement.scrollHeight")
            let viewportHeight = await jsNumber(webView, "window.innerHeight")
            logger.notice("""
                [scrollshot] \(page.name, privacy: .public)：内容高度 \(pageHeight, privacy: .public)px \
                视口 \(viewportHeight, privacy: .public)px
                """)

            var previous: CGImage?
            for step in scrollSteps {
                // 先回到顶部，再滚到目标位置：避免累积误差影响真值。
                await setScrollY(webView, 0)
                try? await Task.sleep(for: .milliseconds(200))
                let beforeY = await jsNumber(webView, "window.scrollY")
                let before = try? await captureRegion(displayID: displayID, rect: captureRect)

                await setScrollY(webView, Int(step))
                try? await Task.sleep(for: .milliseconds(250))
                let afterY = await jsNumber(webView, "window.scrollY")
                let after = try? await captureRegion(displayID: displayID, rect: captureRect)
                if step > 0 {
                    logger.notice("""
                        [scrollshot] scrollY: 期望 \(Int(step), privacy: .public) 实际 before=\(beforeY, privacy: .public) \
                        after=\(afterY, privacy: .public)
                        """)
                }

                guard let beforeImage = before?.image, let afterImage = after?.image else {
                    logger.error("[scrollshot] \(page.name, privacy: .public) step=\(Int(step), privacy: .public) 抓帧失败")
                    failed += 1
                    continue
                }

                let scale = before?.scaleFactor ?? 2
                // 诊断用：把一对帧落盘并打印尺寸，用来核对「抓帧区域」是否正确——
                // 抓错区域会表现为「两帧都一样、位移恒为 0」，而看数字分辨不出来。
                if step == 137, page.name.hasPrefix("真实排版") {
                    logger.notice("""
                        [scrollshot] 帧尺寸 before=\(beforeImage.width, privacy: .public)x\(beforeImage.height, privacy: .public) \
                        after=\(afterImage.width, privacy: .public)x\(afterImage.height, privacy: .public) \
                        scale=\(scale, privacy: .public) rect=\(NSStringFromRect(captureRect), privacy: .public)
                        """)
                    for (image, name) in [(beforeImage, "scrollshot-before"), (afterImage, "scrollshot-after")] {
                        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(name).png")
                        try? ImageEncoding.write(image, to: url, format: .png)
                        logger.notice("[scrollshot] 已保存 \(url.path, privacy: .public)")
                    }
                }
                let start = Date()
                let measured = Self.translationY(from: afterImage, reference: beforeImage)
                let ms = Date().timeIntervalSince(start) * 1000

                // 自研内核（M3-1）：同一对帧、同一批真值，直接对照。
                let oursStart = Date()
                let ours = Self.estimateWithOwnKernel(
                    previous: beforeImage, next: afterImage,
                    ignoreTopRows: page.name.hasPrefix("含 sticky") ? 56 : 0
                )
                let oursMs = Date().timeIntervalSince(oursStart) * 1000
                // `alignmentTransform.ty` 的单位是**像素**（诊断实测：137pt 滚动
                // 在 2x 屏上得到 ty=±274），不要再乘一次 scale。
                let quality = Self.alignmentQuality(
                    image: afterImage,
                    reference: beforeImage,
                    shiftPixels: Int(measured.rounded())
                )
                _ = previous
                previous = afterImage

                let sample = ScrollshotSample(
                    page: page.name,
                    // 符号约定以**抓帧图**为准（诊断实测）：向下滚动 = 内容上移
                    // → `ty` 为**正**。离线合成探针给出的是相反符号，因为
                    // CGContext 的 y 轴向上，合成图的「上移」落进像素数组是下移——
                    // 这类符号只能信真实管线。
                    expected: step * scale,
                    measured: measured,
                    meanError: quality.meanError,
                    diffRatio: quality.diffRatio,
                    milliseconds: ms
                )
                samples.append(sample)
                logger.notice("""
                    [scrollshot] \(page.name, privacy: .public) 滚动 \(Int(step), privacy: .public)pt \
                    → 期望 ty=\(sample.expected, privacy: .public) 实测=\(sample.measured, privacy: .public) \
                    误差=\(sample.error, privacy: .public) \
                    对齐后误差=\(sample.meanError, privacy: .public) 不同像素=\(sample.diffRatio * 100, privacy: .public)% \
                    耗时=\(ms, privacy: .public)ms
                    """)
                let visionText = String(format: "%.1f", measured)
                let oursText = ours.map { String($0.deltaY) } ?? "nil"
                let confidenceText = ours.map { String(format: "%.2f", $0.confidence) } ?? "-"
                let expectedText = String(format: "%.1f", sample.expected)
                logger.notice("""
                    [scrollshot][对照] \(page.name, privacy: .public) 滚动 \(Int(step), privacy: .public)pt \
                    期望=\(expectedText, privacy: .public) \
                    Vision=\(visionText, privacy: .public)(\(ms, privacy: .public)ms) \
                    自研=\(oursText, privacy: .public)(置信度 \(confidenceText, privacy: .public), \(oursMs, privacy: .public)ms)
                    """)
            }
        }

        // ── 连续滚动 + 真实拼接（自研内核端到端）──
        //
        // 前面的循环每次先回到顶部，只能验证「单次配准」。这里不回头，
        // 连续滚动并按帧采集，交给 `ScrollStitcher` 拼成一张长图再落盘——
        // 配准误差会在这里累积暴露，也能直接肉眼看结果。
        for page in pages {
            webView.loadHTMLString(page.html, baseURL: nil)
            let scrollable = await waitUntilScrollable(webView)
            await setScrollY(webView, 0)
            try? await Task.sleep(for: .milliseconds(200))
            if !scrollable {
                logger.error("""
                    [scrollshot][拼接] \(page.name, privacy: .public)：页面未进入可滚动状态，                    本项结果会失真（位移可能全为 0）
                    """)
            }

            var collected: [ScrollshotImage] = []
            if let frame = try? await captureRegion(displayID: displayID, rect: captureRect),
               let image = ScrollshotImage(frame.image) {
                collected.append(image)
            }
            for _ in 0..<4 {
                await setScrollY(webView, await jsNumber(webView, "window.scrollY") + 150)
                try? await Task.sleep(for: .milliseconds(260))
                if let frame = try? await captureRegion(displayID: displayID, rect: captureRect),
                   let image = ScrollshotImage(frame.image) {
                    collected.append(image)
                }
            }

            let options = ScrollStitcher.Options(
                stickyHeaderRows: page.name.hasPrefix("含 sticky") ? 56 : 0
            )
            let result = ScrollStitcher.stitch(frames: collected, options: options)
            let accepted = result.plan.frames.filter { $0.outputY != nil && $0.inputIndex > 0 }.count
            let deltas = result.plan.frames.filter { $0.inputIndex > 0 }.map(\.deltaY)
            logger.notice("""
                [scrollshot][拼接] \(page.name, privacy: .public)：采集 \(collected.count, privacy: .public) 帧，\
                采纳 \(accepted, privacy: .public) 帧，各帧位移 \(deltas.map(String.init).joined(separator: ","), privacy: .public)，\
                输出 \(result.plan.outputWidth, privacy: .public)x\(result.plan.outputHeight, privacy: .public) \
                失败=\(String(describing: result.failure), privacy: .public) 告警=\(result.plan.warnings.joined(separator: " | "), privacy: .public)
                """)
            // 对照：吸顶行**自动检测** vs 显式指定。
            // 真实网页的导航栏与合成内容不同（色块 + 文字），这条验证检测
            // 在真实像素上是否可用——它决定「向上扩展 + sticky」缺陷是否真的修好了。
            if page.name.hasPrefix("含 sticky") {
                var autoSession = ScrollshotSession()
                for frame in collected {
                    autoSession.submit(frame)
                }
                let autoResult = autoSession.result()
                logger.notice("""
                    [scrollshot][吸顶检测] 自动检测 \(autoSession.detectedStickyRows, privacy: .public) 行                    （显式指定 56）；输出高度 自动=\(autoResult.plan.outputHeight, privacy: .public)                     显式=\(result.plan.outputHeight, privacy: .public)
                    """)
            }
            if let image = result.image {
                let url = FileManager.default.temporaryDirectory
                    .appendingPathComponent("scrollshot-stitched-\(page.name.prefix(4)).png")
                let cgImage = Self.makeCGImage(from: image)
                if let cgImage {
                    try? ImageEncoding.write(cgImage, to: url, format: .png)
                    logger.notice("[scrollshot][拼接] 已保存 \(url.path, privacy: .public)")
                }
            }
        }

        // ── 汇总 ──
        let byPage = Dictionary(grouping: samples, by: \.page)
        for (page, list) in byPage.sorted(by: { $0.key < $1.key }) {
            let exact = list.filter(\.isExact).count
            let worst = list.map { abs($0.error) }.max() ?? 0
            let maxMs = list.map(\.milliseconds).max() ?? 0
            logger.notice("""
                [scrollshot] 汇总 \(page, privacy: .public)：\(list.count, privacy: .public) 档中 \
                \(exact, privacy: .public) 档精确（≤1px），最大误差 \(Int(worst.rounded()), privacy: .public)px，\
                单次最长 \(Int(maxMs.rounded()), privacy: .public)ms
                """)
        }
        // 诊断自身的健全性检查：没滚动时必须给出 0，否则测量链路有问题。
        let zeroCases = samples.filter { $0.expected == 0 }
        let zeroOK = zeroCases.allSatisfy { abs($0.measured) <= 1 }
        logger.notice("""
            [scrollshot] 健全性：未滚动时位移为 0 → \(zeroOK ? "通过" : "不通过")；抓帧失败 \(failed, privacy: .public) 次
            """)
        logger.notice("[scrollshot] 汇总: \(zeroOK && failed == 0 ? "完成" : "链路异常", privacy: .public)")

        window.close()
        try? await Task.sleep(for: .milliseconds(300))
        exit(zeroOK && failed == 0 ? 0 : 1)
    }

    /// 用自研内核估计竖直位移；抓帧转换失败时返回 nil。
    private static func estimateWithOwnKernel(
        previous: CGImage,
        next: CGImage,
        ignoreTopRows: Int
    ) -> VerticalOverlap.Match? {
        guard let a = ScrollshotImage(previous), let b = ScrollshotImage(next) else { return nil }
        var options = VerticalOverlap.Options()
        options.ignoreTopRows = ignoreTopRows
        return try? VerticalOverlap.estimate(previous: a, next: b, options: options)
    }

    /// 把拼接结果转回 `CGImage` 以便落盘。
    /// 把 `ScrollshotImage` 转成 `CGImage`。
/// 不是 private：其它诊断文件（如 `+ScrollshotOverlay`）也要用，避免两处各写一份。
static func makeCGImage(from image: ScrollshotImage) -> CGImage? {
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        var buffer = image.data
        return buffer.withUnsafeMutableBytes { raw -> CGImage? in
            guard let context = CGContext(
                data: raw.baseAddress,
                width: image.width,
                height: image.height,
                bitsPerComponent: 8,
                bytesPerRow: image.width * 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return nil }
            return context.makeImage()
        }
    }

    /// 读一个 JS 数字表达式（WKWebView 返回的是 NSNumber）。
    static func jsNumber(_ webView: WKWebView, _ expression: String) async -> Int {
        let value = try? await webView.evaluateJavaScript(expression)
        return (value as? NSNumber)?.intValue ?? -1
    }

    /// 滚动到指定位置，并把 JS 错误显式打出来（不能用 `try?` 吞掉：
    /// `scrollTo` 失败与「页面不可滚动」在结果上完全一样）。
    private static func setScrollY(_ webView: WKWebView, _ y: Int) async {
        do {
            _ = try await webView.evaluateJavaScript("window.scrollTo(0, \(y));")
        } catch {
            logger.error("[scrollshot] scrollTo(\(y, privacy: .public)) 失败：\(String(describing: error), privacy: .public)")
        }
    }

    /// 抓一个**逻辑点**矩形（`CaptureScope.region` 的 rect 就是逻辑点，
    /// 与 `OverlayController` 传选区的方式一致）。
    private static func captureRegion(
        displayID: CGDirectDisplayID,
        rect: CGRect
    ) async throws -> CapturedFrame {
        try await CapturerFactory.makeDefault().captureFrame(
            scope: .region(displayID, rect: rect)
        )
    }

    /// Vision 平移配准的竖直位移（**像素**）。
    private static func translationY(from image: CGImage, reference: CGImage) -> Double {
        let request = VNTranslationalImageRegistrationRequest(targetedCGImage: reference)
        try? VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        guard let observation = request.results?.first as? VNImageTranslationAlignmentObservation else {
            return .nan
        }
        return Double(observation.alignmentTransform.ty)
    }

    /// 按给定位移对齐后，两帧的平均通道误差与「不同像素」占比。
    ///
    /// 它不依赖 Vision 的置信度（Vision 不提供），是判断配准结果是否可信的
    /// 唯一可用信号之一。
    private static func alignmentQuality(
        image: CGImage,
        reference: CGImage,
        shiftPixels: Int
    ) -> (meanError: Double, diffRatio: Double) {
        let width = reference.width
        let height = reference.height
        guard image.width == width, image.height == height, width > 0 else {
            return (.nan, .nan)
        }
        guard let a = grayBuffer(reference), let b = grayBuffer(image) else {
            return (.nan, .nan)
        }
        var sum = 0, count = 0, different = 0
        for y in 0..<height {
            let y2 = y + shiftPixels
            guard y2 >= 0, y2 < height else { continue }
            for x in 0..<width {
                let diff = abs(Int(a[y * width + x]) - Int(b[y2 * width + x]))
                sum += diff
                count += 1
                if diff > 10 { different += 1 }
            }
        }
        guard count > 0 else { return (.nan, .nan) }
        return (Double(sum) / Double(count), Double(different) / Double(count))
    }

    private static func grayBuffer(_ image: CGImage) -> [UInt8]? {
        let width = image.width
        let height = image.height
        var buffer = [UInt8](repeating: 0, count: width * height)
        let ok = buffer.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(
                data: raw.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return ok ? buffer : nil
    }

    // MARK: - 三种测试页

    private static let pageStyle = """
    <style>
      body { margin: 0; font: 14px/1.7 -apple-system, sans-serif; color: #1a1a1a; background: #fdfdfd; }
      h2 { margin: 18px 0 8px 24px; font-size: 20px; }
      p { margin: 0 24px 12px; }
      li { margin: 0 24px 6px 40px; }
      .banner { height: 64px; background: linear-gradient(90deg,#4da3ff,#ff615d); }
    </style>
    """

    /// 真实排版：标题、段落、列表、彩色块——2D 纹理丰富。
    private static var htmlRealistic: String {
        let blocks = (0..<40).map { index in
            """
            <h2>第 \(index + 1) 节 标题</h2>
            <p>这是一段用于测试滚动截图配准的正文，长度不一，夹杂 English words 与数字 \(index * 37)。\
            段落的作用是提供稳定的文字行结构，同时避免完全等距。</p>
            <ul><li>列表项 A\(index)</li><li>列表项 B\(index)</li></ul>
            <div class="banner"></div>
            """
        }.joined()
        return "<html><head><meta charset='utf-8'>\(pageStyle)</head><body>\(blocks)</body></html>"
    }

    /// 等距列表：行高严格一致，制造周期内容。
    private static var htmlPeriodic: String {
        let rows = (0..<200).map { index in
            "<div style='height:28px;border-bottom:1px solid #ddd;padding-left:24px'>第 \(index) 行</div>"
        }.joined()
        return "<html><head><meta charset='utf-8'>\(pageStyle)</head><body>\(rows)</body></html>"
    }

    /// 等待页面进入「可滚动」状态。
    ///
    /// 定长 `sleep` 在系统负载高时不够：页面还没渲染完，`scrollTo` 静默无效，
    /// 表现成「所有档位位移都是 0」——**看起来像算法回归，其实是环境**（本机实测踩过，
    /// load average 3.5+ 时连续两次复现）。两种成因在日志里不可分辨，
    /// 所以这里必须轮询，超时还要显式报错而不是默默继续。
    static func waitUntilScrollable(_ webView: WKWebView, timeout: TimeInterval = 8) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let height = await jsNumber(webView, "document.documentElement.scrollHeight")
            let viewport = await jsNumber(webView, "window.innerHeight")
            if height > viewport + 20 {
                return true
            }
            try? await Task.sleep(for: .milliseconds(200))
        }
        return false
    }

    /// 含 sticky 顶栏：滚动时顶栏不动，是配准的经典干扰源。
    private static var htmlSticky: String {
        let blocks = (0..<60).map { index in
            "<p>滚动内容第 \(index) 行：sticky 顶栏会固定不动，它可以污染整帧的位移估计。</p>"
        }.joined()
        return """
        <html><head><meta charset='utf-8'>\(pageStyle)
        <style>.sticky{position:sticky;top:0;height:56px;background:#1f2937;color:#fff;padding:14px 24px;font-weight:600}</style>
        </head><body><div class='sticky'>固定顶栏（不随滚动移动）</div>\(blocks)</body></html>
        """
    }
}
#endif
