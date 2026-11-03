//
//  CaptureDiagnostics+Selection.swift
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

    /// 覆盖层诊断。
    ///
    /// 回答三个问题：
    ///   1. `NSPanel` 创建本身的耗时（决定是否需要预分配窗口池，DP3-2）
    ///   2. 完整会话的分阶段耗时（首次=冷启动，第二次=稳态）
    ///   3. dismiss 后内存是否回落（P3 验收判据）
    ///
    /// 每轮覆盖层保持展示 6 秒供人工观察（是否盖住菜单栏与全屏应用、
    /// 是否抢焦点、底图是否与抓取瞬间一致），随后自动关闭。
    static func runOverlayDiagnostic() async {
        measureWindowCreationCost()
        logFootprint(action: "baseline")

        let recorder = RecordingCapturer(wrapping: CapturerFactory.makeDefault())
        let controller = OverlayController(capturer: recorder)

        // 两轮：首轮代表进程内首次调用（冷启动），次轮代表稳态。
        // 只测一轮会把冷启动成本当成常态，得出错误的延迟结论。
        for round in 1...2 {
            let label = round == 1 ? "cold" : "warm"
            logger.notice("overlay round \(round, privacy: .public) (\(label, privacy: .public)) starting")

            // 验收判据：覆盖层不得抢焦点。
            // 记录展示前/后的前台应用，若发生变化则说明 `.nonactivatingPanel`
            // 与 `orderFrontRegardless` 的组合未达到预期（P3 核心风险之一）。
            let frontmostBefore = NSWorkspace.shared.frontmostApplication?.localizedName ?? "(none)"

            let start = ContinuousClock.now
            controller.present()

            // 等覆盖层确实显示后再读前台应用；present 是异步的，
            // 立即读取会拿到展示前的旧值。
            try? await Task.sleep(for: .seconds(2))
            let frontmostAfter = NSWorkspace.shared.frontmostApplication?.localizedName ?? "(none)"
            if frontmostBefore == frontmostAfter {
                logger.notice("focus check: frontmost unchanged (\(frontmostBefore, privacy: .public)) — 未抢焦点")
            } else {
                logger.error("focus check FAILED: frontmost '\(frontmostBefore, privacy: .public)' -> '\(frontmostAfter, privacy: .public)'")
            }

            // 剩余时间留作人工观察窗口，同时自拍一张核对绘制结果。
            try? await Task.sleep(for: .seconds(2))
            await captureOverlaySelfShot(round: round)
            saveBackdrop(recorder.lastImage, round: round)
            try? await Task.sleep(for: .seconds(2))
            logger.notice("overlay round \(round, privacy: .public) held; dismissing")

            controller.dismiss()
            try? await Task.sleep(for: .seconds(2))
            logFootprint(action: "after dismiss #\(round)")

            _ = start
        }
    }

    /// 选区坐标诊断。
    ///
    /// 验证 plan.md §5 的要求：「选区边界与导出像素一致」。
    /// 方法与 P2 的坐标验证同源：程序化设置一个**已知**选区，
    /// 把该选区从底图裁出来并落盘，再由外部脚本与「全屏底图的对应区域」
    /// 逐像素比对。
    ///
    /// 选区的数值刻意选得任意（非整数百倍、长宽不等），
    /// 以免恰好在某些取整边界上「碰巧通过」。
    static func runSelectionDiagnostic() async {
        // 先记录本机屏幕圆角来源：它不碰窗口、不读屏幕像素，因此不依赖屏幕录制权限。
        //
        // 之前这几条被埋在 `renderAppearancePreviews` 里，而那个函数需要
        // `recorder.lastImage`（真实抓图）——命令行启动的进程拿不到该权限时
        // 诊断会在前面提前 return，几何断言一次也跑不到，
        // 表现为「明明加了断言却没任何输出」。
        //
        // 不依赖硬件的那几条断言均已迁为单元测试：贴屏角几何见
        // `CornerGeometryTests.swift`，草稿辅助轮廓见 `DraftOutlineTests.swift`。
        reportDisplayCornerGeometry()

        // 已知选区：逻辑点 (350, 220) 480x260 → 2x 屏应得 960x520 像素，
        // 底图内偏移 (700, 440)。
        let logical = CGRect(x: 350, y: 220, width: 480, height: 260)

        let recorder = RecordingCapturer(wrapping: CapturerFactory.makeDefault())
        let controller = OverlayController(capturer: recorder)
        controller.present()

        // 等窗口建好（实测会话总耗时约 100ms，2s 有充足余量）。
        try? await Task.sleep(for: .seconds(2))

        guard let window = controller.primaryOverlayWindow else {
            logger.error("selection diag: no overlay window")
            controller.dismiss()
            return
        }

        // ── 路径一：真实鼠标事件 ──
        // 从左上角拖到右下角，与 `logical` 覆盖同一区域。
        // 这条路径经过 NSEvent → OverlayView → SelectionGeometry → CoordinateConversion，
        // 是 setSelection 无法验证的部分。
        simulateDrag(
            in: window,
            from: CGPoint(x: logical.minX, y: logical.minY),
            to: CGPoint(x: logical.maxX, y: logical.maxY)
        )
        try? await Task.sleep(for: .seconds(1))

        let draggedSelection = controller.selection
        logger.notice("""
            selection diag [drag path]: measured=\(Self.describe(draggedSelection), privacy: .public) \
            expected=\(Self.describe(pixelRect(of: logical)), privacy: .public)
            """)
        if draggedSelection == pixelRect(of: logical) {
            logger.notice("selection diag [drag path]: MATCH")
        } else {
            logger.error("selection diag [drag path]: MISMATCH — 拖拽换算与预期不一致")
        }

        // ── 路径二：程序化设置 + 裁剪落盘 ──
        controller.setSelection(logical)
        try? await Task.sleep(for: .seconds(1))

        guard let pixel = controller.selection, let backdrop = recorder.lastImage else {
            logger.error("selection diag: missing selection or backdrop")
            controller.dismiss()
            return
        }

        logger.notice("""
            selection diag: logical=\(NSStringFromRect(logical), privacy: .public) \
            pixelSize=\(Int(pixel.size.width.rounded()), privacy: .public)x\(Int(pixel.size.height.rounded()), privacy: .public) \
            pixelOrigin=(\(Int(pixel.origin.x.rounded()), privacy: .public),\(Int(pixel.origin.y.rounded()), privacy: .public)) \
            backdrop=\(backdrop.width, privacy: .public)x\(backdrop.height, privacy: .public)
            """)

        let dir = FileManager.default.temporaryDirectory
        let fullURL = dir.appendingPathComponent("anshot-selection-full.png")
        let cropURL = dir.appendingPathComponent("anshot-selection-crop.png")

        do {
            try ImageEncoding.write(backdrop, to: fullURL, format: .png)

            let cropRect = CGRect(
                x: pixel.origin.x,
                y: pixel.origin.y,
                width: pixel.size.width,
                height: pixel.size.height
            )
            guard let cropped = backdrop.cropping(to: cropRect) else {
                logger.error("selection diag: cropping returned nil for \(NSStringFromRect(cropRect), privacy: .public)")
                controller.dismiss()
                return
            }
            try ImageEncoding.write(cropped, to: cropURL, format: .png)
            logger.notice("""
                selection diag files saved: \
                full=\(fullURL.path, privacy: .public) \
                crop=\(cropURL.path, privacy: .public) \
                cropSize=\(cropped.width, privacy: .public)x\(cropped.height, privacy: .public)
                """)
        } catch {
            logger.error("selection diag: write failed \(String(describing: error), privacy: .public)")
        }

        // 留出观察窗口（可用肉眼确认选区内未压暗、尺寸提示是否合理）。
        // 同时自拍一张：视觉细节（角括号、hairline 边框、胶囊提示）
        // 必须能用像素分析客观核对，不能只靠「看代码觉得对」。
        try? await Task.sleep(for: .seconds(1))
        await captureOverlaySelfShot(round: 41)

        // 装饰的可见性取决于底图明暗，而桌面内容不可控。
        // 换成纯色底逐个状态渲染，供人工判断外观。
        await renderAppearancePreviews(controller: controller)

        try? await Task.sleep(for: .seconds(2))
        controller.dismiss()
    }

    // MARK: - 选区阶段（候选 / 已确认）

    /// `-diagnoseSelectionPhase`：自动识别候选与用户已确认两个阶段的交互语义。
    ///
    /// **为什么必须走事件路径**：两个阶段在视图里共用同一个 `selectionRect`，
    /// 「同样一次拖拽是重新框选还是平移整个框」完全取决于 `mouseDown`
    /// 选中了哪个分支。直接设一个布尔量再读回来，只能证明赋值成功，
    /// 证明不了分支选对了——而那正是用户反馈的缺陷所在。
    static func runSelectionPhaseDiagnostic() async {
        let controller = OverlayController(capturer: CapturerFactory.makeDefault())
        controller.present()
        try? await Task.sleep(for: .seconds(2))

        guard let window = controller.primaryOverlayWindow,
              let overlayView = window.contentView as? OverlayView else {
            logger.error("[phase] 没有覆盖层窗口")
            controller.dismiss()
            return
        }

        // 此处**不**暂停识别：场景 0 要断言现实环境下的守卫状态。
        // 暂停统一发生在场景 0 之后（那里已经确定会话起点是对的）。

        var failed = 0
        func report(_ label: String, _ measured: String, _ expected: String, _ ok: Bool) {
            if !ok { failed += 1 }
            logger.notice("""
                [phase] \(label, privacy: .public) measured=\(measured, privacy: .public) \
                expected=\(expected, privacy: .public)  \(ok ? "MATCH" : "MISMATCH", privacy: .public)
                """)
        }

        let displayID = DisplayGeometry.mainDisplay()
        let candidate = CGRect(x: 350, y: 220, width: 480, height: 260)

        /// 注入一次识别命中。走 `applyDetectionTarget` 而非直接写
        /// `selectionRect`：身份记录与编辑器同步都在那条路径里。
        func injectCandidate() {
            controller.debugApplyDetectionTarget(
                DetectionTarget(
                    layer: .window,
                    rect: candidate,
                    displayID: displayID,
                    title: "phase-diag",
                    windowID: 4242,
                    processID: 4242
                )
            )
        }

        func measuredSelection() -> String {
            Self.describe(controller.selection)
        }

        func expect(_ label: String, _ logical: CGRect) {
            report(label, measuredSelection(), Self.describe(pixelRect(of: logical)),
                   controller.selection == pixelRect(of: logical))
        }

        func expectConfirmed(_ label: String, _ expected: Bool) {
            let actual = controller.debugIsSelectionConfirmed
            report(label, "confirmed=\(actual)", "confirmed=\(expected)", actual == expected)
        }

        /// 等重绘与状态回写稳定。
        func settle(_ ms: UInt64 = 300) async {
            try? await Task.sleep(nanoseconds: ms * 1_000_000)
        }

        // ── 0）会话起点 ──
        //
        // 覆盖一次真实回归：会话起点的默认选区（整屏）曾被判为「已确认」，
        // 于是识别被守卫永久挡死，用户看到的现象是
        // 「按 Control+1 后完全没有自动识别，只能拖拽框选」。
        report("会话起点的默认选区是候选态",
               "confirmed=\(controller.debugIsSelectionConfirmed)",
               "confirmed=false",
               controller.debugIsSelectionConfirmed == false)
        report("候选态下识别被放行",
               "allowed=\(overlayView.isDetectionAllowedForDiagnostics)",
               "allowed=true",
               overlayView.isDetectionAllowedForDiagnostics)

        // 场景 1、2 用注入构造候选，并挡住真实识别：
        // 识别结果取决于鼠标底下恰好有什么窗口，不挡就不可复现。
        overlayView.isDetectionPausedForDiagnostics = true

        // ── 1）候选内的首次拖拽应当是「重新框选」，而不是平移候选 ──
        injectCandidate()
        await settle()
        expectConfirmed("注入识别结果后处于候选态", false)
        expect("候选几何来自识别结果", candidate)

        // 起点 (500,300) 在候选内部，终点越出候选右下角。
        // 若语义错了（当成移动），得到的会是「平移后的候选」：
        // origin=(350+150, 220+80)=(500,300)、尺寸仍为 480×260。
        simulateDrag(
            in: window,
            from: CGPoint(x: 500, y: 300),
            to: CGPoint(x: 700, y: 450)
        )
        await settle()
        expect("候选内首次拖拽 = 重新框选", CGRect(x: 500, y: 300, width: 200, height: 150))

        // ── 2）候选角上起拖同样应重新框选（候选态本就不提供手柄）──
        injectCandidate()
        await settle()
        simulateDrag(
            in: window,
            from: CGPoint(x: candidate.minX, y: candidate.minY),
            to: CGPoint(x: 600, y: 400)
        )
        await settle()
        expect("候选角上起拖 = 重新框选", CGRect(x: 350, y: 220, width: 250, height: 180))

        // ── 3）真实识别：候选态会被改写，确认后不再被改写 ──
        //
        // 这一段刻意**不**暂停识别：要验证的正是守卫对真实识别的拦截。
        // 断言不依赖识别的具体几何（那取决于屏幕上恰好有什么窗口），
        // 只比较「有没有被改写」——这样即便真实鼠标在断言前抢先触发了识别，
        // 结论依然成立。
        overlayView.isDetectionPausedForDiagnostics = false
        injectCandidate()
        // 移到鼠标下的真实目标：候选态下识别应当改写注入的候选。
        simulateMouseMove(in: window, to: CGPoint(x: 700, y: 480))
        await settle(600)
        report("候选态下识别会改写候选",
               "after=\(Self.describe(controller.selection))",
               "after != 注入的候选",
               controller.selection != pixelRect(of: candidate))

        guard let identified = controller.selection else {
            logger.error("[phase] 识别没有产出选区，后续场景无法继续")
            controller.dismiss()
            exit(1)
        }
        let identifiedLogical = CoordinateConversion.logicalRect(
            fromPixel: identified,
            scaleFactor: DisplayGeometry.scaleFactor(for: displayID)
        )
        // 在识别结果内部单击（零位移）→ 确认它。
        let identifiedCenter = CGPoint(x: identifiedLogical.midX, y: identifiedLogical.midY)
        simulateDrag(in: window, from: identifiedCenter, to: identifiedCenter)
        await settle()
        expectConfirmed("在识别结果上单击 = 确认", true)
        report("确认后识别被禁止",
               "allowed=\(overlayView.isDetectionAllowedForDiagnostics)",
               "allowed=false",
               !overlayView.isDetectionAllowedForDiagnostics)
        expect("确认保留识别几何", identifiedLogical)
        report("确认保留识别身份",
               "target=\(controller.debugDetectionTarget == nil ? "nil" : "some")",
               "target=some",
               controller.debugDetectionTarget != nil)

        // 换一个位置移动鼠标：确认后识别不得再改写选区。
        simulateMouseMove(in: window, to: CGPoint(x: 300, y: 800))
        await settle(600)
        expect("确认后鼠标移动不替换选区", identifiedLogical)
        overlayView.isDetectionPausedForDiagnostics = true

        // ── 4）已确认之后：内部拖拽 = 移动，手柄仍然能缩放 ──
        //
        // 场景 3 结束时的选区来自真实识别，几何未知；这里回到可控的注入候选，
        // 并用一次单击（含 2pt 抖动，仍在 4pt 阈值内）把它确认为已确认态。
        injectCandidate()
        await settle()
        simulateDrag(
            in: window,
            from: CGPoint(x: 500, y: 300),
            to: CGPoint(x: 502, y: 301)
        )
        await settle()
        expectConfirmed("（场景 4 前置）抖动单击 = 确认候选", true)
        expect("（场景 4 前置）候选几何", candidate)

        simulateDrag(
            in: window,
            from: CGPoint(x: 500, y: 300),
            to: CGPoint(x: 560, y: 360)
        )
        await settle()
        let moved = candidate.offsetBy(dx: 60, dy: 60)
        expect("已确认后内部拖拽 = 移动", moved)
        // 移动后的矩形与任何识别目标无关，身份必须清掉：
        // 留着它，「录制窗口范围」会拿到一个与该矩形无关的窗口 ID。
        report("移动后清除识别身份",
               "windowID=\(controller.debugDetectionTarget?.windowID.map(String.init) ?? "nil")",
               "windowID=nil",
               controller.debugDetectionTarget == nil)

        // 拖右下角手柄：从角点再往外拉 40pt。
        simulateDrag(
            in: window,
            from: CGPoint(x: moved.maxX, y: moved.maxY),
            to: CGPoint(x: moved.maxX + 40, y: moved.maxY + 40)
        )
        await settle()
        expect("已确认后手柄仍可缩放",
               CGRect(x: moved.minX, y: moved.minY, width: moved.width + 40, height: moved.height + 40))

        // ── 5）越过阈值却没拖够尺寸：恢复候选并退回候选态 ──
        injectCandidate()
        await settle()
        // 前置断言：先确认候选确实回到了视图上。若这一条就失败，
        // 下面的失败与「无效拖拽」无关，而是注入没送达。
        expectConfirmed("场景 5 前置：注入后回到候选态", false)
        expect("场景 5 前置：候选几何", candidate)
        logger.notice("""
            [phase] 场景 5 前置: viewSelection=\(Self.describe(overlayView.selectionRectForDiagnostics), privacy: .public) \
            controllerSelection=\(Self.describe(controller.selection), privacy: .public) \
            interaction=\(overlayView.interactionForDiagnostics, privacy: .public)
            """)
        // 只拖 6pt：越过 4pt 拖拽阈值，但小于 8pt 最小选区尺寸。
        // 这是「想拖但手没移开」，不能被当成一次单击确认。
        simulateDrag(
            in: window,
            from: CGPoint(x: 500, y: 300),
            to: CGPoint(x: 506, y: 300)
        )
        await settle()
        logger.notice("""
            [phase] 场景 5 拖拽后: viewSelection=\(Self.describe(overlayView.selectionRectForDiagnostics), privacy: .public) \
            controllerSelection=\(Self.describe(controller.selection), privacy: .public) \
            hasPendingCandidate=\(overlayView.hasPendingCandidateForDiagnostics, privacy: .public)
            """)
        expect("无效拖拽恢复候选几何", candidate)
        expectConfirmed("无效拖拽退回候选态（识别得以恢复）", false)

        // ── 6）程序化选区是既定事实；手动框出的矩形不带识别身份 ──
        let programmatic = CGRect(x: 400, y: 300, width: 200, height: 150)
        controller.setSelection(programmatic)
        await settle()
        expectConfirmed("程序化选区视为已确认", true)
        expect("程序化选区几何", programmatic)

        injectCandidate()
        await settle()
        simulateDrag(
            in: window,
            from: CGPoint(x: 800, y: 500),
            to: CGPoint(x: 1000, y: 700)
        )
        await settle()
        expectConfirmed("手动框选为已确认态", true)
        report("手动框出的矩形不保留识别身份",
               "windowID=\(controller.debugDetectionTarget?.windowID.map(String.init) ?? "nil")",
               "windowID=nil",
               controller.debugDetectionTarget == nil)

        logger.notice("""
            [phase] 汇总: \(failed == 0 ? "全部通过" : "\(failed) 项失败", privacy: .public)
            """)

        controller.dismiss()
        try? await Task.sleep(nanoseconds: 600_000_000)
        exit(failed == 0 ? 0 : 1)
    }

    // MARK: - 外观预览

    /// 渲染代表性状 × 受控背景的预览图。
    ///
    /// 目的在于让「好不好看」这个只能在真实画面上判断的问题
    /// 有一组可重复、可对比的输入：同一组选区形状分别压在浅底与深底上，
    /// 于是边框对比度、手柄可见性、标签可读性都能逐个对照。
    private static func renderAppearancePreviews(controller: OverlayController) async {
        let displayID = DisplayGeometry.mainDisplay()
        let screenSize = CGDisplayBounds(displayID).size

        // 圆角几何的断言在 `runSelectionDiagnostic` 开头就跑了（那里不依赖权限），
        // 这里不再重复。

        // 受控渲染必须挡住真实识别，否则候选态的选区会随鼠标下的窗口漂移。
        controller.debugSetDetectionPaused(true)
        defer { controller.debugSetDetectionPaused(false) }

        let normalRect = CGRect(x: 350, y: 220, width: 480, height: 260)
        let states: [(name: String, rect: CGRect)] = [
            ("normal", normalRect),
            // 小选区：验证紧凑模式只剩四个角括号
            ("small", CGRect(x: 620, y: 400, width: 58, height: 42)),
            // 窄条：验证四角括号与上下中点短棒共存
            ("narrow", CGRect(x: 500, y: 300, width: 340, height: 22)),
            // 贴右下角：验证标签避让与手柄贴边
            (
                "edge",
                CGRect(
                    x: screenSize.width - 420,
                    y: screenSize.height - 300,
                    width: 420,
                    height: 300
                )
            ),
            // 贴屏幕顶部：上方两角必须收成直角，否则框与屏幕上边之间会露出缺口。
            ("flush-top", CGRect(x: 260, y: 0, width: 760, height: 380)),
            // 贴屏幕左上角：左侧与上方四个角里，左上角同时受两条边约束。
            ("flush-corner", CGRect(x: 0, y: 0, width: 620, height: 400)),
            // 整屏：四边都贴，四角都必须是直角（录制整屏时最明显）。
            ("flush-all", CGRect(origin: .zero, size: screenSize)),
            // 悬停态：手柄压在蓝色边框的圆角上，两者若同色手柄就隐身了。
            // 这个冲突只能渲染出来才看得见，故单列一张。
            ("hover", normalRect),
            // 候选态：识别给出的框，尚未被用户确认。它不应有缩放手柄，
            // 工具栏也不应把指针画成「选中」——后者是用户困惑的直接来源。
            ("candidate", normalRect),
        ]

        let backgrounds: [(name: String, gray: CGFloat)] = [
            ("light", 0.86),
            ("dark", 0.12),
        ]

        let pixelSize = DisplayGeometry.pixelSize(for: displayID)
        let width = Int(pixelSize.width.rounded())
        let height = Int(pixelSize.height.rounded())

        for (backgroundName, gray) in backgrounds {
            guard let solid = makeSolidImage(width: width, height: height, gray: gray) else {
                logger.error("preview: failed to build \(backgroundName, privacy: .public) backdrop")
                continue
            }
            controller.setBackdropForDiagnostics(solid, displayID: displayID)

            for state in states {
                if state.name == "candidate" {
                    // 走真实的候选应用路径，而不是 setSelection：
                    // 后者是程序化选区，会被视为已确认。
                    controller.debugApplyDetectionTarget(
                        DetectionTarget(
                            layer: .window,
                            rect: state.rect,
                            displayID: displayID,
                            title: "candidate-preview",
                            windowID: 1,
                            processID: 1
                        )
                    )
                    controller.debugSetHoveredHandle(nil)
                } else {
                    controller.setSelection(state.rect)
                    // 只有 hover 面板把指针“放”在左上角手柄上
                    controller.debugSetHoveredHandle(state.name == "hover" ? .topLeft : nil)
                }
                // 留出重绘时间
                try? await Task.sleep(for: .milliseconds(400))

                logHandleHitTest(
                    controller: controller,
                    state: state.name,
                    rect: state.rect
                )

                do {
                    let capturer = CapturerFactory.makeDefault()
                    let frame = try await capturer.captureFrame(scope: .display(displayID))
                    let url = FileManager.default.temporaryDirectory
                        .appendingPathComponent("anshot-preview-\(backgroundName)-\(state.name).png")
                    try ImageEncoding.write(frame.image, to: url, format: .png)
                    logger.notice("preview [\(backgroundName, privacy: .public)/\(state.name, privacy: .public)] -> \(url.path, privacy: .public)")
                } catch {
                    logger.error("preview [\(backgroundName, privacy: .public)/\(state.name, privacy: .public)] failed: \(String(describing: error), privacy: .public)")
                }
            }
        }
    }

    /// 记录本机屏幕圆角的来源。
    ///
    /// 这一段的性质是**取证**而非断言：记录本机**实际**取到了什么——显示器 ID、
    /// 原始四个出参、显示器缩放、按「点」与按「像素」两种解释。它是
    /// 「值从哪来、单位是什么」的凭证，只能用真机运行产出，无法用推理代替。
    ///
    /// 贴合规则**本身**的断言（不依赖本机硬件，可复现）已迁为单元测试，
    /// 见 `AnShotUITests/CornerGeometryTests.swift`：基准圆角只按尺寸收窄、
    /// 贴屏角扣除描边内缩、只贴一条边不算对齐、极小框的夹取，以及
    /// 「遮罩挖空 = 边框路径 + 描边内缩」。
    ///
    /// **不分析截图**：已实测确认整屏截图的四角是完整内容（非黑非透明），
    /// 屏幕圆角遮罩不在捕获结果里，从像素反推半径这条路不成立。
    private static func reportDisplayCornerGeometry() {
        reportCornerRadiiSource()
    }

    /// 记录本机每块显示器的圆角来源与数值。
    private static func reportCornerRadiiSource() {
        DisplayCornerGeometry.invalidateCache()
        var count = 0
        for screen in NSScreen.screens {
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                continue
            }
            let displayID = CGDirectDisplayID(number.uint32Value)
            let scale = DisplayGeometry.scaleFactor(for: displayID)
            let frame = screen.frame
            guard let radii = DisplayCornerGeometry.radii(for: displayID) else {
                logger.notice("""
                    [corners] 来源: display=\(displayID, privacy: .public) \
                    frame=\(NSStringFromRect(frame), privacy: .public) scale=\(scale, privacy: .public) \
                    → 未取得系统几何（该屏的框保留普通圆角）
                    """)
                continue
            }
            count += 1
            logger.notice("""
                [corners] 来源: display=\(displayID, privacy: .public) \
                frame=\(NSStringFromRect(frame), privacy: .public) scale=\(scale, privacy: .public) \
                radii=\(radii.description, privacy: .public) \
                按点解释=(\(radii.topLeft), \(radii.topRight), \(radii.bottomLeft), \(radii.bottomRight)) \
                按像素解释=(\(radii.topLeft * scale), \(radii.topRight * scale), \(radii.bottomLeft * scale), \(radii.bottomRight * scale)) \
                isRectangular=\(radii.isRectangular, privacy: .public)
                """)
        }
        logger.notice("[corners] 来源汇总: 取得系统几何的显示器数=\(count, privacy: .public)（共 \(NSScreen.screens.count, privacy: .public) 块）")
    }

    /// 聚焦检查：可见手柄与可命中的手柄必须是同一批。
    ///
    /// 本次修订前的缺陷正是两者分家——紧凑模式画面上隐藏了 4 个中点手柄，
    /// 命中判定却仍然认它们。
    private static func logHandleHitTest(
        controller: OverlayController,
        state: String,
        rect: CGRect
    ) {
        let probes: [(String, CGPoint)] = [
            ("corner", CGPoint(x: rect.minX, y: rect.minY)),
            ("midTop", CGPoint(x: rect.midX, y: rect.minY)),
            ("midLeft", CGPoint(x: rect.minX, y: rect.midY)),
        ]
        for (label, point) in probes {
            let hit = controller.debugHandleName(at: point) ?? "nil"
            logger.notice("hit \(state, privacy: .public)/\(label, privacy: .public) -> \(hit, privacy: .public)")
        }
    }

    /// 回归：一次「无业务变化的状态刷新」不得丢掉选区。
    ///
    /// 针对一个真实缺陷：诊断曾用 `setSelection` 直接改视图缓存而没走状态入口，
    /// 于是随后任何一次状态刷新都会发现编辑器里没有选区，反过来把视图上的选区清掉，
    /// 之后的拖拽全被当成「创建选区」，一个标注也建不出来。
    ///
    /// 这条也顺带覆盖 advisor 要求的顺序：**建选区 → 刷新 → 拖动**。
    static func verifySelectionSurvivesRefresh(
        window: NSWindow,
        controller: OverlayController,
        editor: AnnotationEditorState
    ) async {
        guard let view = window.contentView as? OverlayView else { return }

        // 走正常状态入口建立选区（会经过 selectionDidCommit 进入编辑器状态）。
        let rect = CGRect(x: 320, y: 220, width: 420, height: 300)
        _ = controller.setSelection(rect)
        try? await Task.sleep(for: .milliseconds(300))

        let established = view.hasSelection && controller.selection != nil

        // 触发一次**无业务内容变化**的刷新：直接调用变化回调，
        // 这正是「视图重绘但不改数据」的场景。
        editor.onChange?()
        try? await Task.sleep(for: .milliseconds(200))

        let survived = view.hasSelection && controller.selection != nil

        // 刷新后仍然能正常创建标注。
        let before = editor.annotations.count
        editor.select(.rectangle)
        simulateDrag(
            in: window,
            from: CGPoint(x: 360, y: 260),
            to: CGPoint(x: 520, y: 360)
        )
        try? await Task.sleep(for: .milliseconds(300))
        let created = editor.annotations.count == before + 1

        let ok = established && survived && created
        logger.notice("""
            selection survives refresh: 建立=\(established, privacy: .public) \
            刷新后仍在=\(survived, privacy: .public) \
            刷新后仍可建标注=\(created, privacy: .public) \
            -> \(ok ? "MATCH" : "MISMATCH", privacy: .public)
            """)
    }

    /// 独立校验主栏几何：预期值来自**布局约定**，不取自被测的命中函数。
    ///
    /// 只比较 `toolbarItemCenters()` 与自己等于自证——上一轮就是这样漏掉了
    /// 「面板画在主栏位置」的缺陷。这里用布局常量（左内边距 8 + 按钮 28 的一半 = 22，
    /// 栏高 36 的一半 = 18）作为独立预期。
    ///
    /// - Note: 断言本身（含四个分组按钮的位置）已迁为单元测试
    ///   `AnnotationToolbarViewLayoutTests.familyButtonsSitAtConstantPositions`，
    ///   那边用**不挂窗口**的工具栏视图就能跑。这里留下的是 `OverlayView`
    ///   真实子视图层面的集成证据：工具栏已装配、未隐藏、且在祖先坐标系里
    ///   报得出坐标——那几点需要真实窗口，无法在测试进程里等价复现。
    static func assertBarGeometryFromConstants(
        view: OverlayView,
        editor: AnnotationEditorState
    ) {
        editor.select(.pointer)
        let centers = view.toolbarItemCenters()

        guard let first = centers[.family(.pointer)] else {
            logger.error("bar geometry: 取不到主栏首个按钮位置")
            return
        }

        // 命中坐标在祖先视图坐标系里，先换算回工具栏内部坐标再比。
        let origin = view.toolbarFrame.origin
        let local = CGPoint(x: first.x - origin.x, y: first.y - origin.y)

        let expected = CGPoint(x: 22, y: 18)
        let tolerant = abs(local.x - expected.x) < 1.5 && abs(local.y - expected.y) < 1.5
        logger.notice("""
            bar geometry vs constants: local=(\(Int(local.x.rounded()), privacy: .public),\(Int(local.y.rounded()), privacy: .public)) \
            expected=(\(Int(expected.x.rounded()), privacy: .public),\(Int(expected.y.rounded()), privacy: .public)) \
            -> \(tolerant ? "MATCH" : "MISMATCH（布局常量与实际位置不符）", privacy: .public)
            """)
    }

    /// 断言面板项整体位于主栏项之下。
    ///
    /// 先切一次形状工具让形状面板展开，比较两组项的最小/最大纵向中心。
    ///
    /// - Note: 「面板整体在主栏之下、且纵向中心落在 栏高+间距+面板高/2」
    ///   已迁为单元测试 `AnnotationToolbarViewLayoutTests.panelItemsSitBelowBar`，
    ///   同样只需离线工具栏视图。这里的增量证据仍然是 `OverlayView` 层面的装配。
    static func assertPanelBelowBar(view: OverlayView, editor: AnnotationEditorState) {
        // 检查完恢复原工具：本函数只是取坐标，
        // 改动工具会干扰调用方后续的「点分组」流程
        // （点当前分组是收起面板，不是展开）。
        let savedTool = editor.tool
        defer { editor.select(savedTool) }

        editor.select(.rectangle)
        let centers = view.toolbarItemCenters()

        let barKinds: [AnnotationToolbarView.Kind] = [
            .family(.pointer), .family(.shape), .family(.text), .family(.mosaic),
            .undo, .redo,
        ]
        let panelKinds: [AnnotationToolbarView.Kind] = [
            .tool(.rectangle), .tool(.line), .tool(.arrow),
        ]

        let barCenters = barKinds.compactMap { centers[$0]?.y }
        let panelCenters = panelKinds.compactMap { centers[$0]?.y }

        guard let barMaxY = barCenters.max(), let panelMinY = panelCenters.min() else {
            logger.error("""
                toolbar layout: 取不到主栏或面板项坐标                 bar=\(barCenters.count, privacy: .public) panel=\(panelCenters.count, privacy: .public)
                """)
            return
        }

        let separated = panelMinY > barMaxY
        logger.notice("""
            toolbar layout: barMaxY=\(Int(barMaxY.rounded()), privacy: .public)             panelMinY=\(Int(panelMinY.rounded()), privacy: .public)             -> \(separated ? "MATCH" : "MISMATCH（面板与主栏重叠，绘制或命中偏移没对齐）", privacy: .public)
            """)
    }
}

#endif
