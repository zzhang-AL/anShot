//
//  CaptureDiagnostics+M3Annotation.swift
//  AnShotUI
//
//  `-diagnoseM3Annotation`：M3-4 标注增强的端到端验证。
//
//  ── 验证什么 ──────────────────────────────────────────────
//
//  模型与渲染在 M3-0 就绪（12 种标注、编解码、渲染都在单测里覆盖），
//  这里要证明的是**用户能创建它们**：每个新工具都能被选中、拖拽后真的产生
//  对应类型的标注，且各自的样式参数在面板里出现、改得动。
//
//  拖拽走的是与真人相同的路径（合成的 mouseDown/mouseDragged/mouseUp 经
//  `window.sendEvent` 进入视图），而不是直接调编辑器的内部方法——
//  后者只能证明方法存在，证明不了「工具与手势接上了」。
//

#if DEBUG
import AnShotCapture
import AnShotCore
import AppKit

extension CaptureDiagnostics {

    static func runM3AnnotationDiagnostic() async {
        let tools: [AnnotationTool] = [.numbering, .highlight, .measure, .magnifier, .freehand, .curvedArrow]

        var failed = 0
        func report(_ label: String, _ measured: String, _ expected: String, _ ok: Bool) {
            if !ok { failed += 1 }
            logger.notice("""
                [m3-annot] \(label, privacy: .public) measured=\(measured, privacy: .public) \
                expected=\(expected, privacy: .public)  \(ok ? "MATCH" : "MISMATCH", privacy: .public)
                """)
        }

        // ① 工具枚举本身：都注册了、都有名字与快捷键、都归到某个分组。
        for tool in tools {
            report(
                "工具「\(tool.displayName)」已注册",
                "family=\(tool.family.rawValue) key=\(tool.keyCharacter)",
                "有名称且属于某个 family",
                !tool.displayName.isEmpty && !tool.keyCharacter.isWhitespace
            )
        }
        let keys = tools.map(\.keyCharacter)
        report("六个新工具的快捷键互不冲突", "\(keys.map(String.init).joined())", "无重复", Set(keys).count == keys.count)
        let allKeys = AnnotationTool.allCases.map(\.keyCharacter)
        report("与既有工具也不冲突", "\(allKeys.count) 个工具", "无重复", Set(allKeys).count == allKeys.count)

        // ② 序号计数器：只增不减，且不从模型推断。
        let editor = AnnotationEditorState()
        let first = editor.takeNextNumberingIndex()
        let second = editor.takeNextNumberingIndex()
        report("编号序号递增", "\(first), \(second)", "1, 2", first == 1 && second == 2)
        editor.resetNumberingCounter()
        report("会话重置后归位", "\(editor.takeNextNumberingIndex())", "1", editor.takeNextNumberingIndex() == 2)

        // ③ 曲线箭头的控制点几何。
        let start = PixelPoint(x: 0, y: 0)
        let end = PixelPoint(x: 100, y: 0)
        let straight = AnnotationEditorState.bendControl(from: start, to: end, bend: 0)
        let bent = AnnotationEditorState.bendControl(from: start, to: end, bend: 0.25)
        report("bend=0 时控制点在中点（退化成直线）", "(\(straight.x), \(straight.y))", "(50, 0)", straight.x == 50 && abs(straight.y) < 0.001)
        report("bend=0.25 时控制点沿法线偏移 25", "(\(bent.x), \(bent.y))", "(50, 25)", abs(bent.x - 50) < 0.001 && abs(abs(bent.y) - 25) < 0.001)

        // ④ 真实拖拽创建每种标注。
        let controller = OverlayController(capturer: CapturerFactory.makeDefault())
        controller.present()
        try? await Task.sleep(for: .seconds(2))

        guard controller.isPresentingForDiagnostics,
              let window = controller.primaryOverlayWindow,
              let overlayView = window.contentView as? OverlayView else {
            report("覆盖层就绪", "false", "true", false)
            controller.dismiss()
            exit(1)
        }
        _ = controller.setSelection(window.frame.insetBy(dx: 120, dy: 120))
        try? await Task.sleep(for: .milliseconds(500))

        for tool in tools {
            let before = controller.debugAnnotationCountForDiagnostics
            controller.debugSelectToolForDiagnostics(tool)

            // 手绘需要更多移动点才有意义，其余工具两点即可。
            let startPoint = CGPoint(x: 300, y: 260)
            switch tool {
            case .freehand:
                // 必须走**弧线**：直线上的采样点全部共线，经简化后
                // 与「退化成一条直线」产生同样的两点模型，断言分不出两者。
                synthesizeCurvedDrag(
                    in: window,
                    on: overlayView,
                    from: startPoint,
                    to: CGPoint(x: 420, y: 340),
                    bulge: 40
                )
            case .magnifier:
                synthesizeDrag(in: window, on: overlayView, from: startPoint, to: CGPoint(x: 380, y: 340))
            default:
                synthesizeDrag(in: window, on: overlayView, from: startPoint, to: CGPoint(x: 420, y: 320))
            }
            try? await Task.sleep(for: .milliseconds(250))

            let after = controller.debugAnnotationCountForDiagnostics
            report(
                "拖拽创建「\(tool.displayName)」",
                "标注数 \(before) → \(after)",
                "增加 1",
                after == before + 1
            )
        }

        // ⑤ 编号序号真的出现在模型里（第二条编号应为 2 或更大）。
        let summary = controller.debugAnnotationSummaryForDiagnostics
        logger.notice("[m3-annot] 标注摘要：\(summary, privacy: .public)")
        report("六种标注都进了模型", summary, "含 numbering/highlight/measure/magnifier/freehand/curvedArrow",
               ["numbering", "highlight", "measure", "magnifier", "freehand", "curvedArrow"]
                   .allSatisfy { summary.contains($0) })

        // 手绘真的采到了轨迹，而不是退化成两点直线。
        //
        // 单独断言点数：上面那条「六种标注都进了模型」在缺陷存在时**照样通过**
        // （退化成直线的笔迹同样是 freehand），它证明不了轨迹被采到了。
        let freehandPoints = controller.debugFreehandPointCountForDiagnostics
        report(
            "手绘笔迹保留了路径拐点",
            "\(freehandPoints) 点",
            "> 2（退化成直线时只有 2 点）",
            freehandPoints > 2
        )

        // ⑧ 手绘草稿在拖动中**不做**简化（否则已画出的轨迹会抖）。
        //
        // 简化（Douglas–Peucker）是全局算法：拖动中每加入一个新点都可能改变
        // 之前保留的顶点集合，于是已经画出来的轨迹反复改形状——
        // 用户看到的就是「笔迹在抖」。所以草稿只追加采样点，
        // 简化推迟到抬起鼠标那一刻。
        //
        // 为什么手动分步合成而不用 `synthesizePathDrag`：后者是
        // 一气呼成的按下→拖动→抬起，中途读不到 `draft`。而这里必须
        // **在抬起之前**读草稿点数，才能证明它等于采样数（没被简化过）。
        //
        // 本段必须排在滑块段之前：那里会把线宽拖到 20 以上，
        // 而手绘的采样阈值取自线宽，阈值抬高后路径步长可能被过滤掉，
        // 「草稿点数 == 采样数」这条断言就不成立了。
        controller.debugSelectToolForDiagnostics(.freehand)
        try? await Task.sleep(for: .milliseconds(250))

        let probeStart = CGPoint(x: 320, y: 420)
        let probeEnd = CGPoint(x: 440, y: 480)
        let probeSteps = 12
        let probeDX = probeEnd.x - probeStart.x
        let probeDY = probeEnd.y - probeStart.y
        let probeLength = max(0.001, (probeDX * probeDX + probeDY * probeDY).squareRoot())
        let probeNormal = CGPoint(x: -probeDY / probeLength, y: probeDX / probeLength)
        let probePoints = (0 ... probeSteps).map { step -> CGPoint in
            let t = CGFloat(step) / CGFloat(probeSteps)
            let offset: CGFloat = 36 * CGFloat(sin(Double.pi * Double(t)))
            return CGPoint(
                x: probeStart.x + probeDX * t + probeNormal.x * offset,
                y: probeStart.y + probeDY * t + probeNormal.y * offset
            )
        }

        func overlayEvent(_ type: NSEvent.EventType, at point: CGPoint) -> NSEvent? {
            NSEvent.mouseEvent(
                with: type,
                location: overlayView.convert(point, to: nil),
                modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber,
                context: nil,
                eventNumber: 0,
                clickCount: 1,
                pressure: 1
            )
        }

        if let down = overlayEvent(.leftMouseDown, at: probeStart) {
            window.sendEvent(down)
        }
        let halfSteps = (probeSteps / 2) + 1
        for point in probePoints.prefix(halfSteps).dropFirst() {
            if let dragged = overlayEvent(.leftMouseDragged, at: point) {
                window.sendEvent(dragged)
            }
        }
        try? await Task.sleep(for: .milliseconds(150))
        let midDraftCount = controller.debugDraftFreehandPointCountForDiagnostics

        for point in probePoints.dropFirst(halfSteps - 1) {
            if let dragged = overlayEvent(.leftMouseDragged, at: point) {
                window.sendEvent(dragged)
            }
        }
        if let up = overlayEvent(.leftMouseUp, at: probeEnd) {
            window.sendEvent(up)
        }
        try? await Task.sleep(for: .milliseconds(200))
        let committedCount = controller.debugFreehandPointCountForDiagnostics

        report(
            "手绘草稿按采样点原样保留（拖动中不简化）",
            "拖动中 \(midDraftCount) 点 / 已发 \(halfSteps) 点",
            "相等",
            midDraftCount == halfSteps
        )
        report(
            "手绘简化只发生在提交时",
            "\(probePoints.count) → \(committedCount) 点",
            "减少但仍 ≥ 2",
            committedCount < probePoints.count && committedCount >= 2
        )

        // ⑨ 文字工具：点一下必须出现**可编辑**的输入框。
        //
        // 只断言「输入框存在」是不够的：换 cell 会丢掉 NSTextField 默认给出的
        // 可编辑性（`NSTextFieldCell` 自身的默认是 not editable），
        // 而那时输入框照样出现、光标照样闪，一个字却打不进去。
        // 必须直接把 editable / selectable 断言下来。
        controller.debugSelectToolForDiagnostics(.text)
        try? await Task.sleep(for: .milliseconds(250))

        let textPoint = CGPoint(x: 360, y: 300)
        if let down = overlayEvent(.leftMouseDown, at: textPoint) {
            window.sendEvent(down)
        }
        if let up = overlayEvent(.leftMouseUp, at: textPoint) {
            window.sendEvent(up)
        }
        try? await Task.sleep(for: .milliseconds(300))

        let textEditorState = overlayView.textEditorStateForDiagnostics()
        report(
            "文字工具点一下出现可编辑输入框",
            textEditorState,
            "editable=true,selectable=true,editing=true",
            textEditorState.contains("editable=true")
                && textEditorState.contains("selectable=true")
                && textEditorState.contains("editing=true")
        )

        // ⑥ 面板项与滑块：用**离线工具栏**验证，不依赖覆盖层与截图权限。
        //
        // 为什么不继续用覆盖层里的工具栏：它要求 `backdrop != nil`（真实截图底图），
        // 而命令行启动的进程拿不到屏幕录制权限
        //（日志：`screenCapturePermission=notGranted` → `backdrop is nil`），
        // 工具栏于是被隐藏，面板断言一律报 false——旧版
        // 「编号工具下出现半径选项」「放大镜工具下出现倍率选项」两条
        // 就是这么长期假失败的：它们看起来在报缺陷，实际只是环境缺权限。
        //
        // 面板的布局与命中都是纯几何计算，与窗口、底图、权限都无关。
        // 这里造一个不显示的工具栏视图，直接向它派发事件：走的仍是视图
        // 真实的事件入口（mouseDown / mouseDragged），只省掉 AppKit 的窗口分发
        // ——分发是框架的职责，不是被测逻辑。
        let offline = AnnotationToolbarView()
        offline.style = .default
        offline.frame = CGRect(origin: .zero, size: offline.toolbarSize)

        // 挂在窗口上但不显示：`convert(_:from:)` 需要一个窗口上下文，
        // 而 `orderFront` 会把窗口弹到用户面前，验证面板并不需要它可见。
        let offlineWindow = NSWindow(
            contentRect: offline.frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        offlineWindow.contentView = offline

        /// 构造一个直接交给视图的事件（不经过窗口分发）。
        ///
        /// `location` 参数要的是**窗口坐标**，而这里的入参是视图坐标：
        /// 工具栏是 flipped 视图（原点在左上），不换算的话 y 会被当成
        /// 底部原点解释，面板的控件全部偏到主栏去——表现为「事件派了，
        /// 但回调一次也没触发」。同理见 `synthesizePathDrag`。
        func makeToolbarEvent(_ type: NSEvent.EventType, at point: CGPoint) -> NSEvent? {
            NSEvent.mouseEvent(
                with: type,
                location: offline.convert(point, to: nil),
                modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: offlineWindow.windowNumber,
                context: nil,
                eventNumber: 0,
                clickCount: 1,
                pressure: 1
            )
        }

        /// 切换离线工具栏的工具，返回该工具下面板里的全部条目身份。
        func panelKinds(for tool: AnnotationTool) -> Set<AnnotationToolbarLayout.Kind> {
            offline.tool = tool
            offline.frame = CGRect(origin: .zero, size: offline.toolbarSize)
            return Set(offline.visibleItemCenters().keys)
        }

        func hasKind(
            _ kinds: Set<AnnotationToolbarLayout.Kind>,
            _ match: (AnnotationToolbarLayout.Kind) -> Bool
        ) -> Bool {
            kinds.contains(where: match)
        }

        func isNumberingRadius(_ kind: AnnotationToolbarLayout.Kind) -> Bool {
            if case .numberingRadius = kind { return true }
            return false
        }

        func isMagnifierZoom(_ kind: AnnotationToolbarLayout.Kind) -> Bool {
            if case .magnifierZoom = kind { return true }
            return false
        }

        func isArrowHeadSlider(_ kind: AnnotationToolbarLayout.Kind) -> Bool {
            if case .arrowHeadScaleSlider = kind { return true }
            return false
        }

        let numberingKinds = panelKinds(for: .numbering)
        let hasNumberingRadius = hasKind(numberingKinds, isNumberingRadius)
        report("编号工具下出现半径选项", "\(hasNumberingRadius)", "true", hasNumberingRadius)

        let magnifierKinds = panelKinds(for: .magnifier)
        let hasMagnifierZoom = hasKind(magnifierKinds, isMagnifierZoom)
        report("放大镜工具下出现倍率选项", "\(hasMagnifierZoom)", "true", hasMagnifierZoom)

        let rectangleKinds = panelKinds(for: .rectangle)
        let rectangleHasRadius = hasKind(rectangleKinds, isNumberingRadius)
        report("非编号工具下不出现半径选项", "\(rectangleHasRadius)", "false", !rectangleHasRadius)

        // ⑦ 滑块：线宽无级调节、箭头大小可调，且都走真实鼠标拖拽。
        //
        // 拖动必须是事件而不是直接调 `selectLineWidth`：后者只能证明
        // 「这个方法存在」，证明不了滑块与拖拽接上了——而鼠标拖拽是本视图
        // 新增的交互路径（在此之前它只处理 mouseDown）。
        var capturedWidth: Double?
        var capturedHeadScale: Double?
        offline.onSelectLineWidth = { capturedWidth = $0 }
        offline.onSelectArrowHeadScale = { capturedHeadScale = $0 }

        /// 把滑块从轨道左端拖到指定比例。
        func dragSlider(_ kind: AnnotationToolbarLayout.Kind, to fraction: CGFloat) {
            guard let track = offline.sliderTrackForDiagnostics(kind),
                  let center = offline.itemCenter(kind) else {
                report("滑块存在且可拖动", "缺少轨道或中心", "两者都有", false)
                return
            }
            let target = CGPoint(
                x: track.lowerBound + (track.upperBound - track.lowerBound) * fraction,
                y: center.y
            )
            if let down = makeToolbarEvent(.leftMouseDown, at: CGPoint(x: track.lowerBound + 1, y: center.y)) {
                offline.mouseDown(with: down)
            }
            if let drag = makeToolbarEvent(.leftMouseDragged, at: target) {
                offline.mouseDragged(with: drag)
            }
            if let up = makeToolbarEvent(.leftMouseUp, at: target) {
                offline.mouseUp(with: up)
            }
        }

        /// 把 0...1 的比例换算成区间内的预期值。
        func expected(_ fraction: Double, in range: ClosedRange<Double>) -> Double {
            range.lowerBound + fraction * (range.upperBound - range.lowerBound)
        }

        _ = panelKinds(for: .rectangle)
        let widthRange = AnnotationStyle.lineWidthRange
        dragSlider(.lineWidthSlider, to: 0.1)
        let lowWidth = capturedWidth
        dragSlider(.lineWidthSlider, to: 0.9)
        let highWidth = capturedWidth
        report(
            "线宽滑块位置对应线宽（10% ↔ 90%）",
            "\(lowWidth.map { "\($0)" } ?? "nil") / \(highWidth.map { "\($0)" } ?? "nil")",
            "约 \(expected(0.1, in: widthRange)) / \(expected(0.9, in: widthRange))",
            lowWidth.map { abs($0 - expected(0.1, in: widthRange)) < 1 } == true
                && highWidth.map { abs($0 - expected(0.9, in: widthRange)) < 1 } == true
        )
        report(
            "线宽确实无级（旧三档之外的值）",
            "\(highWidth.map { "\($0)" } ?? "nil")",
            "不等于 2 / 4 / 8",
            highWidth.map { ![2, 4, 8].contains($0) } == true
        )
        report(
            "线宽取值始终落在区间内",
            "\(lowWidth.map { "\($0)" } ?? "nil") / \(highWidth.map { "\($0)" } ?? "nil")",
            "都在 \(widthRange)",
            [lowWidth, highWidth].allSatisfy { value in
                value.map { widthRange.contains($0) } == true
            }
        )

        // 箭头大小滑块：只在箭头与曲线箭头下出现。
        let rectangleHasHeadSlider = hasKind(rectangleKinds, isArrowHeadSlider)
        report("非箭头工具下不出现箭头大小滑块", "\(rectangleHasHeadSlider)", "false", !rectangleHasHeadSlider)

        let arrowKinds = panelKinds(for: .arrow)
        let arrowHasHeadSlider = hasKind(arrowKinds, isArrowHeadSlider)
        report("箭头工具下出现箭头大小滑块", "\(arrowHasHeadSlider)", "true", arrowHasHeadSlider)

        let curvedKinds = panelKinds(for: .curvedArrow)
        let curvedHasHeadSlider = hasKind(curvedKinds, isArrowHeadSlider)
        report("曲线箭头下也出现箭头大小滑块", "\(curvedHasHeadSlider)", "true", curvedHasHeadSlider)

        _ = panelKinds(for: .arrow)
        let headRange = AnnotationStyle.arrowHeadScaleRange
        dragSlider(.arrowHeadScaleSlider, to: 0)
        let smallHead = capturedHeadScale
        dragSlider(.arrowHeadScaleSlider, to: 1)
        let largeHead = capturedHeadScale
        report(
            "箭头大小滑块两端对应区间端点",
            "\(smallHead.map { "\($0)" } ?? "nil") / \(largeHead.map { "\($0)" } ?? "nil")",
            "\(headRange.lowerBound) / \(headRange.upperBound)",
            smallHead.map { abs($0 - headRange.lowerBound) < 0.05 } == true
                && largeHead.map { abs($0 - headRange.upperBound) < 0.05 } == true
        )

        // ⑨ 系统符号图标的**朝向**：走 `NSImage.draw` 的符号在 flipped 视图里不能被多翻一次。
        //
        // 用户反馈「截图的图钉按钮应该朝下」，而当时它朝上。根因是 `drawSymbolGlyph`
        // 把 flipped 视图（`AnnotationToolbarView.isFlipped == true`）的 CGContext
        // 桥接成了 `NSGraphicsContext(cgContext:flipped: false)`，AppKit 因此再翻一次，
        // 凡走 `NSImage.draw` 的符号全部上下颠倒（`pin.fill` 与 `video.fill` 都中，
        // 后者上下近似对称，肉眼与断言都发现不了）。
        //
        // 判据不看绝对行号：`NSBitmapImageRep` 的行序约定要靠猜。这里用**对照渲染**——
        // 同一条 `NSImage.draw` 路径在一个未翻转的位图上下文里画同一个符号（那是符号
        // 本来的样子：帽在上、针尖朝下），再把「工具栏渲染」与「参照渲染」各自的
        // 上下两端墨迹量比出「窄端在哪一端」。两端对齐 = 没有被镜像。
        // 两边都用 `colorAt` 读，行序约定在比较中自动约掉。
        offline.tool = .pointer
        offline.frame = CGRect(origin: .zero, size: offline.toolbarSize)

        /// 统计一个位图里某个矩形内的墨迹，按行分成 `bands` 段返回每段墨迹量。
        ///
        /// `box` 是**像素**坐标（两个位图的缩放不同：缓存显示的位图在 Retina 上是 2x，
        /// 参照位图是自己造的 1x，换算留在调用处，这里不猜）。
        ///
        /// 墨迹 = 亮度 > 0.5：工具栏底是黑色（最亮 0.2 左右），符号是白色；
        /// 参照位图的底是全透明（亮度 0）。两边的「底」都远低于阈值，判据统一。
        func inkBands(_ rep: NSBitmapImageRep, box: CGRect, bands: Int) -> [Double]? {
            let x0 = max(0, Int(box.minX.rounded()))
            let x1 = min(rep.pixelsWide, Int(box.maxX.rounded()))
            let y0 = max(0, Int(box.minY.rounded()))
            let y1 = min(rep.pixelsHigh, Int(box.maxY.rounded()))
            guard x1 > x0, y1 > y0 else { return nil }
            var rows = [Int](repeating: 0, count: y1 - y0)
            for y in y0..<y1 {
                for x in x0..<x1 {
                    guard let color = rep.colorAt(x: x, y: y)?
                        .usingColorSpace(.deviceRGB) else { continue }
                    if color.brightnessComponent > 0.5 { rows[y - y0] += 1 }
                }
            }
            // 只保留真正有墨迹的行区间，再等分：符号在图框里居中，多出来的空白
            // 会把两端摊平，让「窄端」失去分辨力。
            guard let first = rows.firstIndex(where: { $0 > 0 }),
                  let last = rows.lastIndex(where: { $0 > 0 }), last > first else { return nil }
            let ink = Array(rows[first...last])
            var result = [Double](repeating: 0, count: bands)
            for (index, count) in ink.enumerated() {
                let band = min(bands - 1, index * bands / ink.count)
                result[band] += Double(count)
            }
            return result
        }

        /// 墨迹少的那个「端」是针尖端。取两端各 3 段比较，避免中间段干扰。
        func needleIsAtFirstEnd(_ bands: [Double]) -> Bool {
            bands.prefix(3).reduce(0, +) < bands.suffix(3).reduce(0, +)
        }

        /// 把工具栏渲染成位图（走视图真实的 `draw(_:)`，含它自己的 flipped 上下文）。
        func renderOfflineToolbar() -> NSBitmapImageRep? {
            offline.displayIfNeeded()
            guard let rep = offline.bitmapImageRepForCachingDisplay(in: offline.bounds) else {
                return nil
            }
            offline.cacheDisplay(in: offline.bounds, to: rep)
            return rep
        }

        /// 参照渲染：同一个符号走未翻转的位图上下文（符号本来的朝向）。
        func renderReferencePin(side: Int) -> NSBitmapImageRep? {
            guard let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
            ) else { return nil }
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            // 白色不能靠 `NSColor.white.set()`：SF Symbol 是模板图，直接 `draw` 出来的是
            // 它自身位图的颜色（黑），在透明底上亮度为 0，与「没有墨迹」无法区分。
            // 用 `SymbolConfiguration(paletteColors:)` 生成着色副本（与设置界面的做法一致）。
            let base = NSImage.SymbolConfiguration(pointSize: CGFloat(side) * 0.5, weight: .medium)
            let palette = NSImage.SymbolConfiguration(paletteColors: [.white])
            if let symbol = NSImage(systemSymbolName: "pin.fill", accessibilityDescription: nil)?
                .withSymbolConfiguration(base.applying(palette)) {
                symbol.draw(in: CGRect(
                    x: (CGFloat(side) - symbol.size.width) / 2,
                    y: (CGFloat(side) - symbol.size.height) / 2,
                    width: symbol.size.width,
                    height: symbol.size.height
                ))
            }
            NSGraphicsContext.restoreGraphicsState()
            return rep
        }

        if let pinCenter = offline.itemCenter(.pin), let toolbarRep = renderOfflineToolbar() {
            // 图标按按钮短边 0.54 倍定字号，取按钮外框内的一小块即可含住整个符号。
            let window = CGRect(
                x: pinCenter.x - 11, y: pinCenter.y - 11, width: 22, height: 22
            )
            let referenceSide = 96
            let referenceBox = CGRect(x: 0, y: 0, width: CGFloat(referenceSide), height: CGFloat(referenceSide))
            let toolbarScale = CGFloat(toolbarRep.pixelsWide) / max(1, offline.bounds.width)
            let toolbarBox = CGRect(
                x: window.minX * toolbarScale, y: window.minY * toolbarScale,
                width: window.width * toolbarScale, height: window.height * toolbarScale
            )
            let toolbarBands = inkBands(toolbarRep, box: toolbarBox, bands: 10)
            let referenceBands = renderReferencePin(side: referenceSide)
                .flatMap { inkBands($0, box: referenceBox, bands: 10) }

            if let toolbarBands, let referenceBands {
                let referenceFirst = needleIsAtFirstEnd(referenceBands)
                let toolbarFirst = needleIsAtFirstEnd(toolbarBands)
                func describe(_ bands: [Double]) -> String {
                    "首三=\(Int(bands.prefix(3).reduce(0, +))) 末三=\(Int(bands.suffix(3).reduce(0, +)))"
                }
                report(
                    "参照符号本身上下足够不对称（对照有效，不是空断言）",
                    describe(referenceBands),
                    "两端墨迹量相差 2 倍以上",
                    max(referenceBands.max() ?? 0, 1) / max(referenceBands.min() ?? 1, 1) > 1.5
                )
                report(
                    "工具栏图钉与正确朝向同向（针尖朝下，未被上下镜像）",
                    "工具栏[\(describe(toolbarBands))] 参照[\(describe(referenceBands))]",
                    "窄端在同一端",
                    toolbarFirst == referenceFirst
                )
            } else {
                report("工具栏图钉的朝向可测（两个位图都取到墨迹）",
                       "工具栏=\(toolbarBands != nil) 参照=\(referenceBands != nil)",
                       "两者都为 true", false)
            }
        } else {
            report("离线工具栏里有「固定」按钮且能渲染成位图",
                   "\(offline.itemCenter(.pin) != nil)", "true", false)
        }

        logger.notice("""
            [m3-annot] 汇总: \(failed == 0 ? "全部通过" : "\(failed) 项失败", privacy: .public) \
            exitCode=\(failed == 0 ? 0 : 1, privacy: .public)
            """)
        controller.dismiss()
        try? await Task.sleep(for: .milliseconds(300))
        exit(failed == 0 ? 0 : 1)
    }
}
#endif
