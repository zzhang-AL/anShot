//
//  CaptureDiagnostics+ScrollshotLive.swift
//  AnShotUI
//
//  `-diagnoseScrollshotLive`：滚动截图**会话**的端到端验证。
//
//  ── 与 `-diagnoseScrollshot` 的区别 ────────────────────────
//
//  那个诊断验证的是**配准内核**（逐档给真值、对照系统实现）。
//  这个验证的是**会话链路**：抓帧循环 → 自适应采样 → 世界坐标追踪 → 拼接 → 落盘，
//  也就是用户点下「长截图」之后真正跑的那条路。
//
//  ── 怎么模拟用户滚动 ──────────────────────────────────────
//
//  会话本身是「手动滚动」模式：我们不去合成系统滚轮事件（那需要辅助功能权限），
//  只按帧变化采样。所以诊断用一个自己拥有的 `WKWebView` 显示长页面，
//  再用 `window.scrollBy` 推动它——对截图链路而言，这与用户滚动**不可区分**
//  （都是屏幕内容在变），但不需要任何额外权限。
//
//  ── 判据 ──────────────────────────────────────────────────
//
//  断言链路行为（采到多帧、输出比单帧高、进度与预览回调被调用），
//  外加**上下滚动的两条硬要求**：
//
//  1. 回滚期间帧数与输出高度都不增长（不反复采集）；
//  2. 回滚帧在计划里被明确记为 `rewind`（不是被当成「又向下滚了」）。
//
//  具体像素的对错由 `ScrollshotSessionTests` / `ScrollStitcherTests` 用已知真值覆盖。
//

#if DEBUG
import AnShotCapture
import AnShotCore
import AppKit
import WebKit

extension CaptureDiagnostics {

    static func runScrollshotLiveDiagnostic() async {
        let displayID = DisplayGeometry.mainDisplay()
        let scale = DisplayGeometry.scaleFactor(for: displayID)
        let burst = ProcessInfo.processInfo.arguments.contains("-scrollshotBurst")
        let fast = ProcessInfo.processInfo.arguments.contains("-scrollshotFast") || burst

        // 视口：屏幕中央，抓帧矩形用显示器坐标（左上原点），窗口用 AppKit 坐标（左下原点）。
        let displayBounds = DisplayGeometry.bounds(for: displayID)
        let viewRect = fast
            ? CGRect(x: 20, y: 60, width: min(1400, displayBounds.width - 40),
                     height: min(800, displayBounds.height - 160))
            : CGRect(x: 360, y: 150, width: 760, height: 520)
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
        window.title = "anShot 长截图会话诊断"
        window.isReleasedWhenClosed = false
        let webView = WKWebView(frame: CGRect(origin: .zero, size: viewRect.size))
        window.contentView = webView
        // 必须让它**浮在所有窗口之上**并激活 app：WebKit 对**被遮挡**的页面会节流渲染与
        // 滚动，此时 `window.scrollBy` 不再改变屏幕上的像素，会话只会采到首帧。
        // 实测 `makeKeyAndOrderFront` 不够——本 app 是菜单栏 app（LSUIElement），
        // 窗口常被普通窗口盖住，导致同一份代码时好时坏；`level = .floating` 才稳定。
        window.level = .floating
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        try? await Task.sleep(for: .milliseconds(900))

        // 一页足够长的内容：分段标题 + 列表，行距规律、每行内容不同。
        let sections = (0..<120).map { index in
            """
            <h2>第 \(index + 1) 节 标题文本</h2>
            <p>正文第 \(index) 段：用于长截图会话验证的内容，长度不一，夹杂 English 与数字 \(index * 17)。</p>
            <ul><li>条目 A\(index)</li><li>条目 B\(index)</li></ul>
            """
        }.joined()
        webView.loadHTMLString(
            """
            <html><head><meta charset='utf-8'><style>
            body { margin:0; font:14px/1.7 -apple-system, sans-serif; color:#ddd; background:#181818 }
            header, footer, aside { position:fixed; box-sizing:border-box; z-index:2; padding:8px }
            header { top:0; left:0; right:0; height:40px; background:#303030 }
            footer { bottom:0; left:0; right:0; height:40px; background:#333 }
            aside { top:40px; bottom:40px; left:0; width:120px; background:#252525 }
            .marker { display:inline-block; width:18px; height:18px; background:rgb(231,61,88) }
            main { margin-left:120px; padding-top:40px; padding-bottom:40px }
            h2 { margin:16px 0 6px 20px; font-size:19px } p { margin:0 20px 10px }
            li { margin:0 20px 5px 40px }
            \(fast ? "body { background:#fff; color:#252525 } main { max-width:680px; margin-left:30% } header,footer { background:#f6f6f6 } aside { background:#f2f2f2 }" : "")
            </style></head><body>
            <header><span class="marker"></span> 窗口标题栏：在长图顶端保留</header>
            <aside><span class="marker"></span> 固定侧栏</aside>
            <footer><span class="marker"></span> 固定输入栏</footer>
            <main>\(sections)</main></body></html>
            """,
            baseURL: nil
        )
        // WebKit 冷启动时固定等待可能先于页面加载完成，800pt 的初始滚动会被吞掉。
        // 等到长页面真正可滚动，再进入双向扩展的诊断，避免把无效前置条件当作配准失败。
        let pageDeadline = Date().addingTimeInterval(15)
        let readyHeight = """
            (document.readyState === 'complete' && document.querySelectorAll('main h2').length === 120
                && document.fonts.status === 'loaded') ? document.documentElement.scrollHeight : 0
            """
        var pageHeight = 0
        var stableReadings = 0
        while (pageHeight <= 4000 || stableReadings < 5), Date() < pageDeadline {
            try? await Task.sleep(for: .milliseconds(100))
            let measured = await jsNumber(webView, readyHeight)
            stableReadings = measured == pageHeight && measured > 4000 ? stableReadings + 1 : 0
            pageHeight = measured
        }
        guard pageHeight > 4000, stableReadings >= 5 else {
            let message = "MISMATCH 诊断页面就绪：高度 \(pageHeight)，期望 > 4000\n失败项=1"
            logger.error("[scrollshot-live] \(message, privacy: .public)")
            do {
                try message.write(
                    to: FileManager.default.temporaryDirectory.appendingPathComponent("scrollshot-live-report.txt"),
                    atomically: true, encoding: .utf8
                )
            } catch {
                logger.error("[scrollshot-live] 报告保存失败：\(error.localizedDescription, privacy: .public)")
            }
            window.close()
            exit(1)
        }
        logger.notice("[scrollshot-live] 页面高度 \(pageHeight, privacy: .public)px，视口 \(Int(viewRect.height), privacy: .public)pt")

        var failed = 0
        var reports: [String] = []
        func report(_ label: String, _ measured: String, _ expected: String, _ ok: Bool) {
            if !ok { failed += 1 }
            reports.append("\(ok ? "MATCH" : "MISMATCH") \(label)：\(measured)，期望 \(expected)")
            logger.notice("""
                [scrollshot-live] \(label, privacy: .public) measured=\(measured, privacy: .public) \
                expected=\(expected, privacy: .public)  \(ok ? "MATCH" : "MISMATCH", privacy: .public)
                """)
        }
        /// 环境探针的结论：只记录、**不计入失败**。
        ///
        /// 探针回答的是「本机此刻能否让这条诊断跑出有效数据」，而不是「链路契约是否
        /// 成立」。把它计进失败会让「屏幕上有个动画」这种事看起来像链路坏了。
        func note(_ label: String, _ measured: String) {
            logger.notice("""
                [scrollshot-live] \(label, privacy: .public) measured=\(measured, privacy: .public)（环境探针）
                """)
        }

        /// 向下滚动若干次，每次 `step` 点；负数即向上回滚。
        func scroll(times: Int, by step: Int) async {
            if fast {
                let distance = times * step
                let duration = abs(distance) * 1000 / (burst ? 6200 : 2800)
                _ = try? await webView.evaluateJavaScript("""
                    (() => {
                        const start = window.scrollY, began = performance.now();
                        window.anshotScrollFinished = false;
                        function move(now) {
                            const progress = Math.min(1, (now - began) / \(duration));
                            window.scrollTo(0, start + \(distance) * progress);
                            if (progress < 1) requestAnimationFrame(move);
                            else window.anshotScrollFinished = true;
                        }
                        requestAnimationFrame(move);
                    })();
                    """)
                let deadline = Date().addingTimeInterval(Double(duration) / 1000 + 5)
                while await jsNumber(webView, "window.anshotScrollFinished ? 1 : 0") != 1,
                      Date() < deadline {
                    try? await Task.sleep(for: .milliseconds(20))
                }
            } else {
                for _ in 0..<times {
                    _ = try? await webView.evaluateJavaScript("window.scrollBy(0, \(step));")
                    try? await Task.sleep(for: .milliseconds(320))
                }
            }
            // 让「用户停手」后的补采纳先发生，再取快照，否则会把补采纳算进下一阶段。
            try? await Task.sleep(for: .milliseconds(400))
        }

        // ── 走完整会话链路 ──
        let selection = CoordinateConversion.pixelRect(fromLogical: captureRect, scaleFactor: scale)
        let frameCapturer = ScrollshotFrameCapturer(capturer: CapturerFactory.makeDefault())
        let controller = ScrollshotController(
            capturer: frameCapturer,
            selection: selection,
            displayID: displayID,
            scaleFactor: scale
        )
        var progressCalls = 0
        var maxReportedHeight = 0
        var latestFrames = 0
        var latestHeight = 0
        controller.onProgress = { frames, height in
            progressCalls += 1
            latestFrames = frames
            latestHeight = height
            maxReportedHeight = max(maxReportedHeight, height)
        }
        var previewCalls = 0
        var previewNavigatorSizes: [(width: Int, height: Int)] = []
        var previewCoverage: [(start: Int, height: Int)] = []
        var previewViewportRows: [Int] = []
        controller.onPreview = { content in
            previewCalls += 1
            guard let content else { return }
            previewNavigatorSizes.append((content.navigatorPixelWidth, content.navigatorPixelHeight))
            previewCoverage.append((content.worldStart, content.worldHeight))
            if let rows = content.viewportWorldRows { previewViewportRows.append(rows.count) }
        }
        var outcome: ScrollshotController.Outcome?
        var stalls = 0
        controller.onStall = { stalls += 1 }
        controller.onFinish = { result in
            outcome = result
        }
        // 先把页面滚到中间再开会话：这样**首帧上方还有内容**，
        // 「向上滚也能拼」才有东西可验证。首帧落在页面 800pt 处。
        let initialPosition = fast ? 1600 : 800
        let furthestPosition = fast ? 4000 : 2000
        _ = try? await webView.evaluateJavaScript("window.scrollTo(0, \(initialPosition));")
        try? await Task.sleep(for: .milliseconds(600))
        let initialOffset = await jsNumber(webView, "window.scrollY")
        report("首帧位于页面中部", "\(initialOffset)", "\(initialPosition)", initialOffset == initialPosition)

        // ── 探针：抓帧区域里到底有没有「会变的内容」────────────────
        //
        // 采集链路要求「画面在变」才提交帧。若这一块区域根本没落在窗口上（或被别的
        // 窗口挡住），抓到的就是一张静止的桌面：会话只会采到首帧，后面所有「帧数增长」
        // 的判据全部失败——那是**诊断环境**的问题，必须先与链路问题分开，否则会去
        // 改一段本来正确的采集代码。探针跑在会话之前，不干扰它。
        await probeCaptureRegion(
            capturer: CapturerFactory.makeDefault(),
            displayID: displayID,
            rect: captureRect,
            webView: webView,
            note: note
        )

        controller.start()
        // 等待首帧真正就绪，不能用固定延时假定已经建立基准。
        let readyDeadline = Date().addingTimeInterval(5)
        while latestFrames == 0, Date() < readyDeadline {
            try? await Task.sleep(for: .milliseconds(20))
        }

        // ── 阶段 1：向下滚动 6 × 200 = 1200pt（页面 800 → 2000） ──
        if burst {
            // 对应现场的「先只动 8px，随后突然加速」，采集不能在这一刻降到 8Hz。
            _ = try? await webView.evaluateJavaScript("window.scrollBy(0, 4);")
            try? await Task.sleep(for: .milliseconds(100))
        }
        await scroll(times: burst ? 1 : 6, by: burst ? 2396 : (fast ? 400 : 200))
        let forwardFrames = latestFrames
        let forwardHeight = latestHeight

        // ── 阶段 2：向上回滚 4 × 200 = 800pt（2000 → 1200）——
        //    仍在已覆盖区内，属于「往回翻看已采到的部分」──
        await scroll(times: 4, by: fast ? -400 : -200)
        let rewoundFrames = latestFrames
        let rewoundHeight = latestHeight

        // 这两条就是「上下滚动时不反复采集」的验收：回滚期间不该有任何新内容进输出。
        report(
            "回滚到已覆盖区：帧数不增长",
            "\(forwardFrames) → \(rewoundFrames)",
            "相等",
            rewoundFrames == forwardFrames
        )
        report(
            "回滚到已覆盖区：输出高度不增长",
            "\(forwardHeight) → \(rewoundHeight)",
            "相等",
            rewoundHeight == forwardHeight
        )

        // ── 阶段 3：继续向上滚 8 × 200 = 1600pt（1200 → 页面顶部 0）——
        //    越过首帧位置（800）之后是**尚未覆盖的上方内容**，应当向上扩展 ──
        await scroll(times: fast ? 6 : 8, by: fast ? -400 : -200)
        let upwardFrames = latestFrames
        let upwardHeight = latestHeight
        report(
            "向上越过头帧位置：向上扩展（帧数增长）",
            "\(rewoundFrames) → \(upwardFrames)",
            ">",
            upwardFrames > rewoundFrames
        )
        report(
            "向上越过头帧位置：输出高度增长",
            "\(rewoundHeight) → \(upwardHeight)",
            ">",
            upwardHeight > rewoundHeight
        )

        // `finish()` 内部会同步调用 `onFinish`，await 返回后 outcome 已就绪。
        await controller.finish()
        await ScrollshotFrameRecorder.flush()
        let droppedFrames = await frameCapturer.droppedFrames
        report("采集缓冲未丢帧", "\(droppedFrames)", "0", droppedFrames == 0)
        if let image = outcome?.image {
            let bound = (image.height + 2 * Int(selection.size.height)) * image.width * 4
            let retained = controller.retainedPixelBytesForDiagnostics
            report("源图缓存受输出高度约束", "\(retained)", "≤ \(bound)", retained <= bound)
        }
        if fast {
            report("连续快滚无跟丢提示", "\(stalls)", "0", stalls == 0)
            let unresolved = outcome?.plan?.frames.filter { $0.verdict == .unresolved }.count ?? 0
            report("连续快滚每个变化帧均有对齐依据", "\(unresolved)", "0", unresolved == 0)
        }

        guard let outcome else {
            report("会话产出结果", "nil", "非 nil", false)
            window.close()
            exit(1)
        }

        report("采集到多帧", "\(outcome.capturedFrames)", "> 1", outcome.capturedFrames > 1)
        report("进度回调被调用", "\(progressCalls)", ">= 2", progressCalls >= 2)
        report("预览回调被调用", "\(previewCalls)", ">= 3", previewCalls >= 3)
        // 导航栏要**整幅可见**：缩略图必须等比 contain 进导航框（不是按宽度铺满），
        // 所以宽高都不超过框、且至少一边贴边——「拖动定位框看别处」以此为前提。
        let navigatorBox = ScrollshotProgressBar.navigatorPixelSize
        report(
            "导航图等比 contain 进导航栏",
            previewNavigatorSizes.map { "\($0.width)x\($0.height)" }.suffix(3).joined(separator: ","),
            "≤ \(Int(navigatorBox.width))x\(Int(navigatorBox.height))，至少一边贴边",
            !previewNavigatorSizes.isEmpty && previewNavigatorSizes.allSatisfy { size in
                let withinBounds = Double(size.width) <= navigatorBox.width
                    && Double(size.height) <= navigatorBox.height
                let touchesEdge = abs(Double(size.width) - navigatorBox.width) <= 1
                    || abs(Double(size.height) - navigatorBox.height) <= 1
                return withinBounds && touchesEdge
            }
        )
        // 位置标记：每次预览都应当能给出「当前视口在世界坐标里占多少行」。
        report(
            "预览附带当前位置标记",
            "\(previewViewportRows.count)/\(previewNavigatorSizes.count) 次",
            "全部",
            previewNavigatorSizes.isEmpty || previewViewportRows.count == previewNavigatorSizes.count
        )

        let measuredImage = outcome.image
        if let measuredImage {
            // **整幅**的直接证据：最后一次预览覆盖的世界高度应与最终长图高度基本一致。
            //
            // 不能要求严格相等：预览有 0.4s 节流，且 `finish()` 与最后一次采纳之间会隔着
            // 一帧——实测最后一次预览停在 2740 行、而长图已到 3302 行（差 562 < 一屏）。
            // 所以允许落后**一屏**：落后在一屏内的预览依然证明「覆盖的是整段」，
            // 而「只给末尾一段」的实现在这里会差出整张图的高度。
            let coveredHeight = previewCoverage.last?.height ?? 0
            let oneScreen = Int(selection.size.height)
            report(
                "导航图覆盖整个已拼高度（整幅而非末尾）",
                "预览 \(coveredHeight) vs 长图 \(measuredImage.height)",
                "≥ \(measuredImage.height - oneScreen)（长图 − 一屏）",
                coveredHeight >= measuredImage.height - oneScreen
            )
        }

        // 放大栏：按世界行区间取原图切片——浮层拖动定位框时走的就是这条路。
        if let coverage = previewCoverage.last {
            let rows = coverage.start..<(coverage.start + min(400, coverage.height))
            let slice = controller.detailImage(worldRows: rows, targetWidth: ScrollshotProgressBar.detailPixelWidth)
            report(
                "放大栏切片可取（定位框处的原图）",
                slice.map { "\($0.width)x\($0.height)" } ?? "nil",
                "非 nil",
                slice != nil
            )
        }

        // 决策序列（定位「向下滚却被判成回滚」这类方向问题）。
        let trace = (outcome.plan?.frames ?? []).prefix(14).map { decision in
            "\(decision.inputIndex):\(decision.verdict.rawValue)(d=\(decision.deltaY),c=\(String(format: "%.2f", decision.confidence)))"
        }.joined(separator: " ")
        logger.notice("[scrollshot-live] 决策序列: \(trace, privacy: .public)")

        // 回滚到**已覆盖区**的帧必须被明确记录为 rewind，而不是含混地算作「又滚了」。
        let rewinds = outcome.plan?.frames.filter { $0.verdict == .rewind }.count ?? 0
        report("回滚到已覆盖区的帧记为 rewind", "\(rewinds)", ">= 3", rewinds >= 3)

        // 而越过首帧位置之后，向上滚的帧必须被**采纳**（deltaY < 0）——
        // 这是「不管向上还是向下都能拼」的直接证据。
        let upwardAccepted = outcome.plan?.frames.filter {
            $0.verdict == .accepted && $0.deltaY < 0
        }.count ?? 0
        report("向上扩展的帧被采纳（deltaY < 0）", "\(upwardAccepted)", ">= 1", upwardAccepted >= 1)

        let singleFrameHeight = Int(selection.size.height)
        if let image = outcome.image {
            let expectedWidth = Int(viewRect.width * scale)
            report("完整保留选区宽度及侧栏", "\(image.width)", "\(expectedWidth)", image.width == expectedWidth)
            let expectedHeight = Int((CGFloat(furthestPosition) + viewRect.height) * scale)
            report("来回滚动的整窗高度无缺行", "\(image.height)", "\(expectedHeight) ± 2", abs(image.height - expectedHeight) <= 2)
            if let pixels = ScrollshotImage(image) {
                var markerPixels = 0
                let band = Int(40 * scale)
                let bodyLeft = Int(120 * scale)
                for y in band..<(pixels.height - band) {
                    for x in bodyLeft..<pixels.width {
                        let offset = (y * pixels.width + x) * 4
                        if (228...234).contains(Int(pixels.data[offset])),
                           (58...64).contains(Int(pixels.data[offset + 1])),
                           (85...91).contains(Int(pixels.data[offset + 2])) {
                            markerPixels += 1
                        }
                    }
                }
                report("标题和底栏没有重复出现在正文中段", "\(markerPixels)", "0", markerPixels == 0)
                var edgeMarkers = 0
                for y in Array(0..<band) + Array((pixels.height - band)..<pixels.height) {
                    for x in 0..<pixels.width {
                        let offset = (y * pixels.width + x) * 4
                        if (228...234).contains(Int(pixels.data[offset])),
                           (58...64).contains(Int(pixels.data[offset + 1])),
                           (85...91).contains(Int(pixels.data[offset + 2])) {
                            edgeMarkers += 1
                        }
                    }
                }
                report("选区两端的窗口界面得到保留", "\(edgeMarkers)", "> 0", edgeMarkers > 0)
            }
            let ratio = Double(image.height) / Double(singleFrameHeight)
            report(
                "输出比单帧高（发生了拼接）",
                "\(image.width)x\(image.height) 单帧 \(singleFrameHeight)",
                "比值 > 1.5",
                ratio > 1.5
            )
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("scrollshot-live-result.png")
            do {
                try ImageEncoding.write(image, to: url, format: .png)
                try ScrollshotLogStore.shared.formattedText().write(
                    to: url.deletingLastPathComponent().appendingPathComponent("scrollshot-live-trace.txt"),
                    atomically: true, encoding: .utf8
                )
            } catch {
                report("诊断证据保存", error.localizedDescription, "成功", false)
            }
            logger.notice("[scrollshot-live] 长图已保存 \(url.path, privacy: .public)")
        } else {
            report("产出长图", "nil", "非 nil", false)
        }
        report("无失败原因", outcome.failure ?? "-", "nil", outcome.failure == nil)
        logger.notice("""
            [scrollshot-live] 帧数: 采纳 \(outcome.capturedFrames, privacy: .public) / \
            观测 \(outcome.observedFrames, privacy: .public)，预览 \(previewCalls, privacy: .public) 次
            """)

        logger.notice("""
            [scrollshot-live] 汇总: \(failed == 0 ? "全部通过" : "\(failed) 项失败", privacy: .public) \
            exitCode=\(failed == 0 ? 0 : 1, privacy: .public)
            """)
        reports.append("失败项=\(failed)")
        do {
            try reports.joined(separator: "\n").write(
                to: FileManager.default.temporaryDirectory.appendingPathComponent("scrollshot-live-report.txt"),
                atomically: true, encoding: .utf8
            )
        } catch {
            logger.error("[scrollshot-live] 报告保存失败：\(error.localizedDescription, privacy: .public)")
            failed += 1
        }
        window.close()
        try? await Task.sleep(for: .milliseconds(300))
        exit(failed == 0 ? 0 : 1)
    }

    /// 抓帧区域是否真的覆盖着一个「会随滚动变化的画面」。
    ///
    /// 两步观察：静止时两帧应当**逐字节相同**（不同就说明区域里有动态内容干扰），
    /// 滚动 200pt 之后应当**不再相同**。后者不成立就说明这块区域抓不到窗口，会话必然
    /// 只采到首帧——先修诊断环境，别去动采集链路。结论只记录、不计入失败（见 `note`）。
    private static func probeCaptureRegion(
        capturer: any ScreenCapturing,
        displayID: CGDirectDisplayID,
        rect: CGRect,
        webView: WKWebView,
        note: (String, String) -> Void
    ) async {
        let scope = CaptureScope.region(displayID, rect: rect)
        guard let stillA = try? await capturer.captureFrame(scope: scope),
              let imageA = ScrollshotImage(stillA.image) else {
            note("探针：抓帧区域不可抓", "nil")
            return
        }
        do {
            try ImageEncoding.write(
                stillA.image,
                to: FileManager.default.temporaryDirectory.appendingPathComponent("scrollshot-live-input.png"),
                format: .png
            )
        } catch {
            note("探针：输入图保存失败", error.localizedDescription)
        }
        try? await Task.sleep(for: .milliseconds(250))
        guard let stillB = try? await capturer.captureFrame(scope: scope),
              let imageB = ScrollshotImage(stillB.image) else {
            note("探针：抓帧区域不可抓（第二次）", "nil")
            return
        }
        note("探针：静止时两帧是否一致", imageA == imageB ? "一致" : "不同（区域内有动态内容）")

        _ = try? await webView.evaluateJavaScript("window.scrollBy(0, 200);")
        try? await Task.sleep(for: .milliseconds(400))
        guard let moved = try? await capturer.captureFrame(scope: scope),
              let imageC = ScrollshotImage(moved.image) else {
            note("探针：抓帧区域不可抓（滚动后）", "nil")
            return
        }
        note("探针：滚动后画面是否改变", imageA == imageC ? "未变（区域抓不到窗口）" : "已变")
        // 把页面退回原位，别让探针影响后面的首帧位置。
        _ = try? await webView.evaluateJavaScript("window.scrollBy(0, -200);")
        try? await Task.sleep(for: .milliseconds(400))
    }
}
#endif
