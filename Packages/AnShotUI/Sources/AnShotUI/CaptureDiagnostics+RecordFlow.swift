//
//  CaptureDiagnostics+RecordFlow.swift
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

    /// `-diagnoseRecordFlow`：走**真实的工具栏录制链路**做端到端验证。
    ///
    /// 与其它录制诊断的区别：那些直接构造控制器与配置，绕过了界面；
    /// 这个从「覆盖层收到录制请求」开始，经准备面板与目标选取，到发出录制通知
    /// 为止——正是用户点工具栏摄影机按钮所走的那条路。
    ///
    /// **只跳过物理投递**：鼠标与键盘事件仍经 `window.sendEvent` 走 responder chain，
    /// 因此它证明的是「应用内事件处理正确」，**不**证明 WindowServer 的物理路由
    /// （真实鼠标移动的路由、窗口遮挡顺序、键盘焦点都由系统决定）。
    ///
    /// 本诊断**不执行真正的录制**：装配层在该模式下不监听录制通知
    /// （见 `shouldSkipRecordingRequests`）。否则它会写文件、开麦克风、
    /// 还会与诊断抢捕获资源——一个声称只验证通知的诊断不该有这些副作用。
    /// 成片质量由 `-diagnoseRecording` 覆盖。
    ///
    /// 失败时以非零退出码结束，供脚本判断（只看日志需要人盯着）。
    static func runRecordFlowDiagnostic() async {
        var failed = 0
        func report(_ label: String, _ measured: String, _ expected: String, _ ok: Bool) {
            if !ok { failed += 1 }
            logger.notice("""
                [record-flow] \(label, privacy: .public) measured=\(measured, privacy: .public) \
                expected=\(expected, privacy: .public)  \(ok ? "MATCH" : "MISMATCH", privacy: .public)
                """)
        }

        let displayID = DisplayGeometry.mainDisplay()
        let controller = OverlayController(capturer: CapturerFactory.makeDefault())

        // ── 受控识别数据源：两个互不重叠、形状不同的窗口 ──
        let windowA = DetectedWindow(
            windowID: 9001,
            frame: CGRect(x: 100, y: 100, width: 400, height: 300),
            layer: 0,
            title: "诊断窗口A",
            processID: 9101,
            applicationName: "诊断应用A"
        )
        let windowB = DetectedWindow(
            windowID: 9002,
            frame: CGRect(x: 760, y: 640, width: 300, height: 200),
            layer: 0,
            title: "诊断窗口B",
            processID: 9102,
            applicationName: "诊断应用B"
        )

        let probe = NotificationProbe()
        let observer = NotificationCenter.default.addObserver(
            forName: .anShotStartRecording,
            object: nil,
            queue: nil
        ) { note in
            probe.record(note)
        }

        func finish() async -> Never {
            NotificationCenter.default.removeObserver(observer)
            logger.notice("""
                [record-flow] 汇总: \(failed == 0 ? "全部通过" : "\(failed) 项失败", privacy: .public) \
                exitCode=\(failed == 0 ? 0 : 1, privacy: .public)
                """)
            controller.dismiss()
            try? await Task.sleep(nanoseconds: 600_000_000)
            exit(failed == 0 ? 0 : 1)
        }

        /// 每个场景都从干净状态开始。
        ///
        /// `present()` 在已有会话时会被**静默忽略**，前一个场景没收干净就会
        /// 让后面所有断言跑在一个不属于它的覆盖层上——这是最难看出的一类假结果。
        func beginSession(installFixedDetection: Bool = true) async -> OverlayWindow? {
            controller.dismiss()
            try? await Task.sleep(for: .milliseconds(500))
            probe.reset()
            controller.present()
            try? await Task.sleep(for: .seconds(2))
            if installFixedDetection {
                let session = DetectionSession(
                    detector: FixedWindowDetector(windows: [windowA, windowB]),
                    displayID: displayID,
                    displayBounds: DisplayGeometry.bounds(for: displayID)
                )
                await session.load()
                controller.setDetectionSessionForDiagnostics(session)
            }
            guard controller.isPresentingForDiagnostics else {
                logger.error("[record-flow] 会话未能建立，诊断终止")
                await finish()
            }
            return controller.primaryOverlayWindow as? OverlayWindow
        }

        func describeSelection(_ rect: PixelRect?) -> String {
            guard let rect else { return "nil" }
            return describe(rect)
        }

        /// 取某个范围在面板选项里的下标；缺失时报失败并返回 nil。
        ///
        /// **不用 `?? 1` 这类兜底**：那会把「选项少了」变成「选错了另一项」，
        /// 后续断言全在一个错前提上继续跑，制造一串看不出根因的假失败。
        func scopeIndex(_ kind: RecordingScopeKind, _ context: String) -> Int? {
            let kinds = controller.setupScopeOptionKindsForDiagnostics
            guard let index = kinds.firstIndex(of: kind) else {
                report(
                    "\(context)：范围选项缺少\(kind.displayName)",
                    "\(kinds.map(\.rawValue))",
                    "含 \(kind.rawValue)",
                    false
                )
                return nil
            }
            return index
        }

        // 期望值全部**自己算**：若复用产品的 `appKitScreenRect`，换算写错时
        // 两边一起错，断言就永远通过。
        let selection = CGRect(x: 200, y: 150, width: 600, height: 400)
        let pointA = CGPoint(x: 200, y: 200)
        let pointB = CGPoint(x: 800, y: 700)

        // 真实指针挪到两个受控窗口之外。
        //
        // 这是**测试装置的确定性**，不是产品修复：覆盖层接收真实鼠标移动，
        // 指针若恰好落在受控窗口里，「进入选取」时会立刻产生一个候选，
        // 后续断言就取决于指针恰好在哪。位置 (1300,500) 在显示器内且不在 A/B 内。
        CGWarpMouseCursorPosition(CGPoint(x: 1300, y: 500))

        // ══ 场景 1：区域范围 + 准备阶段的输入归属 ══
        guard let window = await beginSession() else { await finish() }
        let displayHeight = window.frame.height
        let selectionScreenRect = CGRect(
            x: selection.minX,
            y: displayHeight - selection.maxY,
            width: selection.width,
            height: selection.height
        )
        let fullScreenRect = CGRect(x: 0, y: 0, width: window.frame.width, height: displayHeight)
        let rectA = CGRect(x: 100, y: displayHeight - 400, width: 400, height: 300)

        controller.simulateRecordRequestForDiagnostics(
            rect: selection,
            detected: nil,
            displayID: displayID
        )
        try? await Task.sleep(for: .milliseconds(600))

        let panelVisible = controller.setupPanelIsVisibleForDiagnostics
        let previewRect = controller.setupPreviewFrameRectForDiagnostics
        report(
            "面板弹出且预览框等于选区",
            "visible=\(panelVisible) rect=\(formatRect(previewRect))",
            "visible=true rect=\(formatRect(selectionScreenRect))",
            panelVisible && previewRect == selectionScreenRect
        )

        // 手动框出的选区也必须有窗口/应用可选。此前这两个选项只在点录制按钮时
        // 鼠标恰好悬停在窗口/应用上才出现，鼠标一移到面板上就再也选不到。
        let kinds = controller.setupScopeOptionKindsForDiagnostics
        let defaultKind = controller.setupPanelSelectedKindForDiagnostics
        report(
            "手动选区四类范围齐全且默认区域",
            "kinds=\(kinds.map(\.rawValue)) default=\(defaultKind?.rawValue ?? "nil")",
            "region,window,application,display default=region",
            kinds == [.region, .window, .application, .display] && defaultKind == .region
        )

        let defaultAudio = controller.setupPanelAudioForDiagnostics
        report(
            "音频默认都勾选",
            "systemAudio=\(defaultAudio.systemAudio) microphone=\(defaultAudio.microphone)",
            "systemAudio=true microphone=true",
            defaultAudio.systemAudio && defaultAudio.microphone
        )

        // 准备阶段：截图侧输入必须被接管。
        let setupActive = controller.overlayIsRecordSetupActiveForDiagnostics
        let toolbarHidden = controller.overlayToolbarHiddenForDiagnostics
        let startEnabledForRegion = controller.setupPanelStartEnabledForDiagnostics
        report(
            "准备阶段接管输入且区域可直接开始",
            "setupActive=\(setupActive) toolbarHidden=\(toolbarHidden) startEnabled=\(startEnabledForRegion)",
            "setupActive=true toolbarHidden=true startEnabled=true",
            setupActive && toolbarHidden && startEnabledForRegion
        )

        // 准备阶段拖拽不得改动截图选区/标注/草稿。
        // 面板里的「区域」范围与预览框取自打开面板那一刻，还能拖选区就会当场矛盾。
        let selectionAtSetup = controller.selection
        let annotationsAtSetup = controller.debugAnnotationCountForDiagnostics
        simulateDrag(in: window, from: CGPoint(x: 900, y: 700), to: CGPoint(x: 1120, y: 820))
        try? await Task.sleep(for: .milliseconds(300))
        report(
            "准备阶段框选不改选区与标注",
            "selection=\(describeSelection(controller.selection)) 标注=\(controller.debugAnnotationCountForDiagnostics) 草稿=\(controller.debugHasDraftForDiagnostics)",
            "selection=\(describeSelection(selectionAtSetup)) 标注=\(annotationsAtSetup) 草稿=false",
            controller.selection == selectionAtSetup
                && controller.debugAnnotationCountForDiagnostics == annotationsAtSetup
                && !controller.debugHasDraftForDiagnostics
        )

        if let captured = try? await makeCapturer(nil).captureFrame(scope: .display(displayID)),
           let url = savePreview(captured.image, baseName: "record-setup-panel") {
            logger.notice("[record-flow] 区域态面板截图: \(url.path, privacy: .public)")
        }

        // 回车 = 面板的「开始录制」（可用性由面板判定，视图不自行判断）。
        synthesizeKey(in: window, keyCode: 36, characters: "\r")
        try? await Task.sleep(for: .seconds(1))
        var regionPosted = false
        if case .region? = probe.scope { regionPosted = true }
        report(
            "回车按面板可开始状态发出区域请求",
            "scope=\(String(describing: probe.scope)) rect=\(formatRect(probe.recordingRect))",
            "region rect=\(formatRect(selectionScreenRect))",
            regionPosted && probe.recordingRect == selectionScreenRect
        )
        report(
            "开始后面板与覆盖层收起",
            "panel=\(controller.setupPanelIsVisibleForDiagnostics) presenting=\(controller.isPresentingForDiagnostics)",
            "panel=false presenting=false",
            !controller.setupPanelIsVisibleForDiagnostics && !controller.isPresentingForDiagnostics
        )

        // ══ 场景 2：窗口目标选取（悬停 → 单击）══
        guard let window2 = await beginSession() else { await finish() }
        // 把选区明确置为**候选**，而不是依赖会话起点的默认状态。
        // 这条路径本身就是产品路径（识别结果 → 预览选区，不算用户的决定），
        // 因此断言的前提是可复现的。
        let hoverTarget = DetectionTarget(
            layer: .window,
            rect: CGRect(x: 100, y: 100, width: 400, height: 300),
            displayID: displayID,
            title: windowA.title,
            windowID: windowA.windowID,
            processID: windowA.processID,
            globalRect: windowA.frame
        )
        controller.debugApplyDetectionTarget(hoverTarget)
        try? await Task.sleep(for: .milliseconds(300))
        let confirmedAtStart = controller.debugIsSelectionConfirmed
        let selectionBaseline = controller.selection
        let annotationsBaseline = controller.debugAnnotationCountForDiagnostics
        controller.simulateRecordRequestForDiagnostics(
            rect: selection,
            detected: hoverTarget,
            displayID: displayID
        )
        try? await Task.sleep(for: .milliseconds(600))

        guard let windowIndex = scopeIndex(.window, "场景2") else { await finish() }
        controller.selectSetupScopeForDiagnostics(index: windowIndex)
        try? await Task.sleep(for: .milliseconds(400))

        let pickKind = controller.setupPickKindForDiagnostics
        let overlayPickKind = controller.overlayPickKindForDiagnostics
        report(
            "候选选区下悬停不自动算作已选目标",
            "已确认=\(confirmedAtStart) pick=\(pickKind?.rawValue ?? "nil") overlay=\(overlayPickKind?.rawValue ?? "nil")",
            "已确认=false 两者都是 window",
            !confirmedAtStart && pickKind == .window && overlayPickKind == .window
        )
        report(
            "未选目标时无预览框、禁止开始、面板不关闭",
            "preview=\(controller.setupPreviewFrameIsVisibleForDiagnostics) isEnabled=\(controller.setupPanelStartEnabledForDiagnostics) panel=\(controller.setupPanelIsVisibleForDiagnostics)",
            "preview=false isEnabled=false panel=true",
            !controller.setupPreviewFrameIsVisibleForDiagnostics
                && !controller.setupPanelStartEnabledForDiagnostics
                && controller.setupPanelIsVisibleForDiagnostics
        )

        // 提示文案要指明对象类型：只写「目标」等于没说。
        report(
            "等待选取的提示指明对象类型",
            "status=\(controller.setupPanelStatusTextForDiagnostics)",
            "含「要录的窗口」",
            controller.setupPanelStatusTextForDiagnostics.contains("要录的窗口")
        )

        // 选取期间回车不能把会话导掉，也不能悄悄开始录制。
        synthesizeKey(in: window2, keyCode: 36, characters: "\r")
        try? await Task.sleep(for: .milliseconds(400))
        report(
            "选取期间回车被吞掉",
            "presenting=\(controller.isPresentingForDiagnostics) 请求数=\(probe.count)",
            "presenting=true 请求数=0",
            controller.isPresentingForDiagnostics && probe.count == 0
        )

        // 未锁定目标时点「开始录制」：按钮不可点，且**真的**发不出请求。
        controller.confirmRecordSetupForDiagnostics()
        try? await Task.sleep(for: .milliseconds(300))
        report(
            "未选目标时点开始无效",
            "请求数=\(probe.count) 面板=\(controller.setupPanelIsVisibleForDiagnostics)",
            "请求数=0 面板=true",
            probe.count == 0 && controller.setupPanelIsVisibleForDiagnostics
        )

        if let captured = try? await makeCapturer(nil).captureFrame(scope: .display(displayID)),
           let url = savePreview(captured.image, baseName: "record-setup-target-pick") {
            logger.notice("[record-flow] 选取中面板截图: \(url.path, privacy: .public)")
        }

        // **直接点击，没有任何先行悬停**：点击必须按位置命中，而不是消费悬停缓存。
        synthesizeMouseDown(in: window2, on: window2.overlayView, at: pointA)
        synthesizeMouseUp(in: window2, on: window2.overlayView, at: pointA)
        try? await Task.sleep(for: .milliseconds(500))

        var lockedWindowA = false
        if case .window(let id)? = controller.setupComposedScopeForDiagnostics,
           id == windowA.windowID {
            lockedWindowA = true
        }
        report(
            "无先行悬停的点击直接锁定窗口",
            "scope=\(String(describing: controller.setupComposedScopeForDiagnostics)) rect=\(formatRect(controller.setupComposedRectForDiagnostics))",
            "window(\(windowA.windowID)) rect=\(formatRect(rectA))",
            lockedWindowA && controller.setupComposedRectForDiagnostics == rectA
        )
        report(
            "锁定后退出选取、允许开始、预览框转实线",
            "pick=\(controller.setupPickKindForDiagnostics?.rawValue ?? "nil") isEnabled=\(controller.setupPanelStartEnabledForDiagnostics) appearance=\(controller.setupPreviewFrameAppearanceForDiagnostics?.rawValue ?? "nil")",
            "pick=nil isEnabled=true appearance=preview",
            controller.setupPickKindForDiagnostics == nil
                && controller.setupPanelStartEnabledForDiagnostics
                && controller.setupPreviewFrameAppearanceForDiagnostics == .preview
        )

        report(
            "已选定提示带对象类型",
            "status=\(controller.setupPanelStatusTextForDiagnostics)",
            "含「已选定窗口」",
            controller.setupPanelStatusTextForDiagnostics.contains("已选定窗口")
        )

        if let captured = try? await makeCapturer(nil).captureFrame(scope: .display(displayID)),
           let url = savePreview(captured.image, baseName: "record-setup-target-locked") {
            logger.notice("[record-flow] 已选定面板截图: \(url.path, privacy: .public)")
        }

        // 悬停其它窗口：锁定目标、矩形、截图选区、标注都不得改变。
        CGWarpMouseCursorPosition(pointB)
        simulateMouseMove(in: window2, to: pointB)
        try? await Task.sleep(for: .milliseconds(400))
        var stillWindowA = false
        if case .window(let id)? = controller.setupComposedScopeForDiagnostics,
           id == windowA.windowID {
            stillWindowA = true
        }
        report(
            "移过其它窗口不改锁定目标与截图选区",
            "scope=\(String(describing: controller.setupComposedScopeForDiagnostics)) rect=\(formatRect(controller.setupComposedRectForDiagnostics)) selection=\(describeSelection(controller.selection)) 标注=\(controller.debugAnnotationCountForDiagnostics)",
            "scope=window(\(windowA.windowID)) rect=\(formatRect(rectA)) selection=\(describeSelection(selectionBaseline)) 标注=\(annotationsBaseline)",
            stillWindowA
                && controller.setupComposedRectForDiagnostics == rectA
                && controller.selection == selectionBaseline
                && controller.debugAnnotationCountForDiagnostics == annotationsBaseline
        )

        // 重新选择：选取期间一律禁止开始（画面显示的是候选，可能是另一个目标），
        // ESC 退出选取后旧目标与其预览必须恢复。
        controller.beginPickForDiagnostics(kind: .window)
        try? await Task.sleep(for: .milliseconds(300))
        report(
            "重新选择期间禁止开始",
            "isEnabled=\(controller.setupPanelStartEnabledForDiagnostics) pick=\(controller.setupPickKindForDiagnostics?.rawValue ?? "nil") 候选=\(controller.setupPanelCandidateTitleForDiagnostics ?? "nil")",
            "isEnabled=false pick=window",
            !controller.setupPanelStartEnabledForDiagnostics && controller.setupPickKindForDiagnostics == .window
        )

        // 重选态截图：画面上是「候选」（可能已是另一个窗口），开始按钮必须是不可点的。
        if let captured = try? await makeCapturer(nil).captureFrame(scope: .display(displayID)),
           let url = savePreview(captured.image, baseName: "record-setup-target-repick") {
            logger.notice("[record-flow] 重选态面板截图: \(url.path, privacy: .public)")
        }
        synthesizeKey(in: window2, keyCode: 53, characters: "\u{1b}")
        try? await Task.sleep(for: .milliseconds(400))
        var restoredWindowA = false
        if case .window(let id)? = controller.setupComposedScopeForDiagnostics,
           id == windowA.windowID {
            restoredWindowA = true
        }
        report(
            "ESC 取消重选后恢复旧目标与预览",
            "isEnabled=\(controller.setupPanelStartEnabledForDiagnostics) pick=\(controller.setupPickKindForDiagnostics?.rawValue ?? "nil") rect=\(formatRect(controller.setupPreviewFrameRectForDiagnostics))",
            "isEnabled=true pick=nil rect=\(formatRect(rectA))",
            restoredWindowA
                && controller.setupPanelStartEnabledForDiagnostics
                && controller.setupPickKindForDiagnostics == nil
                && controller.setupPreviewFrameRectForDiagnostics == rectA
        )

        // 回车开始：通知必须携带锁定的身份与**捕获范围**矩形。
        synthesizeKey(in: window2, keyCode: 36, characters: "\r")
        try? await Task.sleep(for: .seconds(1))
        var postedWindowA = false
        if case .window(let id)? = probe.scope, id == windowA.windowID { postedWindowA = true }
        report(
            "窗口请求携带身份、捕获矩形与音频",
            "scope=\(String(describing: probe.scope)) rect=\(formatRect(probe.recordingRect)) audio=sys\(probe.audio?.systemAudio ?? false)/mic\(probe.audio?.microphone ?? false)",
            "window(\(windowA.windowID)) rect=\(formatRect(rectA)) audio=sys true/mic true",
            postedWindowA
                && probe.recordingRect == rectA
                && probe.audio?.systemAudio == true
                && probe.audio?.microphone == true
        )

        // ══ 场景 3：应用目标 + 捕获范围（整块显示器）+ 音频开关 ══
        guard let window3 = await beginSession() else { await finish() }
        let confirmedTarget = DetectionTarget(
            layer: .window,
            rect: CGRect(x: 100, y: 100, width: 400, height: 300),
            displayID: displayID,
            title: windowA.title,
            windowID: windowA.windowID,
            processID: windowA.processID,
            globalRect: windowA.frame
        )
        // 先明确确认一个选区（程序化设置视为已确认），再打开面板：
        // 此时悬停身份代表一次真实选择，可以预填。
        controller.setSelection(selection)
        try? await Task.sleep(for: .milliseconds(400))
        let confirmedNow = controller.debugIsSelectionConfirmed
        controller.simulateRecordRequestForDiagnostics(
            rect: selection,
            detected: confirmedTarget,
            displayID: displayID
        )
        try? await Task.sleep(for: .milliseconds(600))
        // 先看「窗口」：预填的是窗口身份，选窗口时不应再要求用户重选。
        guard let windowIndex3 = scopeIndex(.window, "场景3 预填") else { await finish() }
        controller.selectSetupScopeForDiagnostics(index: windowIndex3)
        try? await Task.sleep(for: .milliseconds(400))
        var prefilledWindow = false
        if case .window(let id)? = controller.setupComposedScopeForDiagnostics,
           id == windowA.windowID {
            prefilledWindow = true
        }
        report(
            "已确认选区下悬停身份可作为预填",
            "已确认=\(confirmedNow) pick=\(controller.setupPickKindForDiagnostics?.rawValue ?? "nil") windowScope=\(String(describing: controller.setupComposedScopeForDiagnostics)) isEnabled=\(controller.setupPanelStartEnabledForDiagnostics)",
            "已确认=true pick=nil windowScope=window(\(windowA.windowID)) isEnabled=true",
            confirmedNow
                && controller.setupPickKindForDiagnostics == nil
                && prefilledWindow
                && controller.setupPanelStartEnabledForDiagnostics
        )

        // 再看「应用」：它没有预填身份，必须进入选取。
        guard let applicationIndex = scopeIndex(.application, "场景3 应用") else { await finish() }
        controller.selectSetupScopeForDiagnostics(index: applicationIndex)
        try? await Task.sleep(for: .milliseconds(400))

        CGWarpMouseCursorPosition(pointA)
        try? await Task.sleep(for: .milliseconds(200))
        simulateMouseMove(in: window3, to: pointA)
        try? await Task.sleep(for: .milliseconds(300))
        let appCandidate = controller.setupPanelCandidateTitleForDiagnostics
        synthesizeMouseDown(in: window3, on: window3.overlayView, at: pointA)
        synthesizeMouseUp(in: window3, on: window3.overlayView, at: pointA)
        try? await Task.sleep(for: .milliseconds(500))

        var lockedApplication = false
        if case .application(let pid, let onDisplay)? = controller.setupComposedScopeForDiagnostics,
           pid == 9101, onDisplay == displayID {
            lockedApplication = true
        }
        report(
            "应用级选取锁定进程与显示器",
            "candidate=\(appCandidate ?? "nil") scope=\(String(describing: controller.setupComposedScopeForDiagnostics))",
            "candidate=诊断应用A scope=application(9101, on: \(displayID))",
            appCandidate == "诊断应用A" && lockedApplication
        )
        // 应用录制的捕获范围是**整块显示器**（`CaptureScope.application` 的契约），
        // 不是该应用窗口的外接矩形——否则范围框会画在一块比成片小得多的区域上。
        report(
            "应用范围框按捕获契约取整屏",
            "rect=\(formatRect(controller.setupComposedRectForDiagnostics))",
            "rect=\(formatRect(fullScreenRect))",
            controller.setupComposedRectForDiagnostics == fullScreenRect
        )

        // 关掉系统声音：通知必须跟着变（只断言非 nil 会放过「面板改了但传的是旧值」）。
        controller.setSystemAudioForDiagnostics(false)
        try? await Task.sleep(for: .milliseconds(200))
        synthesizeKey(in: window3, keyCode: 36, characters: "\r")
        try? await Task.sleep(for: .seconds(1))
        var postedApplication = false
        if case .application(let pid, let onDisplay)? = probe.scope,
           pid == 9101, onDisplay == displayID {
            postedApplication = true
        }
        report(
            "应用请求携带进程、显示器、整屏矩形与开关状态",
            "scope=\(String(describing: probe.scope)) rect=\(formatRect(probe.recordingRect)) audio=sys\(probe.audio?.systemAudio ?? true)/mic\(probe.audio?.microphone ?? false)",
            "application(9101, on: \(displayID)) rect=\(formatRect(fullScreenRect)) audio=sys false/mic true",
            postedApplication
                && probe.recordingRect == fullScreenRect
                && probe.audio?.systemAudio == false
                && probe.audio?.microphone == true
        )

        // ══ 场景 4：取消路径与残留鼠标事件 ══
        guard let window4 = await beginSession() else { await finish() }
        controller.setSelection(selection)
        try? await Task.sleep(for: .milliseconds(400))

        // 先真的画一笔标注，让「已有编辑内容不变」有东西可验——
        // 只数标注数量不够：一次意外的编辑可能只是改了某条标注的几何。
        controller.debugSelectToolForDiagnostics(.rectangle)
        simulateDrag(in: window4, from: CGPoint(x: 300, y: 250), to: CGPoint(x: 520, y: 400))
        try? await Task.sleep(for: .milliseconds(400))
        let annotationContentBaseline = controller.debugFirstAnnotationForDiagnostics
        let canUndoBaseline = controller.debugCanUndoForDiagnostics

        // 文字输入控件的第一响应者必须也被接管：它一旦还在，键盘就归输入框，
        // 准备阶段的 ESC/回车都不再打到覆盖层上（走的是 field editor）。
        controller.debugSelectToolForDiagnostics(.text)
        synthesizeMouseDown(in: window4, on: window4.overlayView, at: CGPoint(x: 400, y: 300))
        synthesizeMouseUp(in: window4, on: window4.overlayView, at: CGPoint(x: 400, y: 300))
        try? await Task.sleep(for: .milliseconds(400))
        let editingBeforeSetup = controller.debugIsTextEditingForDiagnostics

        controller.simulateRecordRequestForDiagnostics(
            rect: selection,
            detected: nil,
            displayID: displayID
        )
        try? await Task.sleep(for: .milliseconds(600))
        report(
            "准备阶段结束文字编辑并交回键盘",
            "编辑中（进入前）=\(editingBeforeSetup) 编辑中（进入后）=\(controller.debugIsTextEditingForDiagnostics) setupActive=\(controller.overlayIsRecordSetupActiveForDiagnostics)",
            "进入前=true 进入后=false setupActive=true",
            editingBeforeSetup
                && !controller.debugIsTextEditingForDiagnostics
                && controller.overlayIsRecordSetupActiveForDiagnostics
        )
        let selectionBeforeCancel = controller.selection
        let annotationsBeforeCancel = controller.debugAnnotationCountForDiagnostics
        report(
            "准备阶段不改已有标注内容与撤销栈",
            "标注数=\(controller.debugAnnotationCountForDiagnostics) 首条=\(controller.debugFirstAnnotationForDiagnostics) canUndo=\(controller.debugCanUndoForDiagnostics)",
            "标注数=\(annotationsBeforeCancel) 首条=\(annotationContentBaseline) canUndo=\(canUndoBaseline)（均不变）",
            controller.debugAnnotationCountForDiagnostics == annotationsBeforeCancel
                && controller.debugFirstAnnotationForDiagnostics == annotationContentBaseline
                && controller.debugCanUndoForDiagnostics == canUndoBaseline
        )
        guard let applicationIndex4 = scopeIndex(.application, "场景4") else { await finish() }
        controller.selectSetupScopeForDiagnostics(index: applicationIndex4)
        try? await Task.sleep(for: .milliseconds(400))

        // 按下 → ESC（取消选取）→ 松手：残留的 mouseUp 必须被吞掉，
        // 否则它会落进截图侧的「提交选区/提交草稿」，把一次取消变成一次编辑。
        synthesizeMouseDown(in: window4, on: window4.overlayView, at: pointA)
        try? await Task.sleep(for: .milliseconds(150))
        synthesizeKey(in: window4, keyCode: 53, characters: "\u{1b}")
        try? await Task.sleep(for: .milliseconds(200))
        let afterEscape = controller.setupPickKindForDiagnostics
        synthesizeMouseUp(in: window4, on: window4.overlayView, at: pointA)
        try? await Task.sleep(for: .milliseconds(400))
        report(
            "ESC 取消选取，残留松手不改编辑器",
            "pick=\(afterEscape?.rawValue ?? "nil") selection=\(describeSelection(controller.selection)) 标注=\(controller.debugAnnotationCountForDiagnostics) 草稿=\(controller.debugHasDraftForDiagnostics)",
            "pick=nil selection=\(describeSelection(selectionBeforeCancel)) 标注=\(annotationsBeforeCancel) 草稿=false",
            afterEscape == nil
                && controller.selection == selectionBeforeCancel
                && controller.debugAnnotationCountForDiagnostics == annotationsBeforeCancel
                && !controller.debugHasDraftForDiagnostics
                && controller.isPresentingForDiagnostics
        )

        // 再按 ESC：退出整个准备，输入交回截图编辑。
        synthesizeKey(in: window4, keyCode: 53, characters: "\u{1b}")
        try? await Task.sleep(for: .milliseconds(500))
        report(
            "准备中 ESC 取消准备并交回输入",
            "panel=\(controller.setupPanelIsVisibleForDiagnostics) presenting=\(controller.isPresentingForDiagnostics) setupActive=\(controller.overlayIsRecordSetupActiveForDiagnostics) toolbarHidden=\(controller.overlayToolbarHiddenForDiagnostics)",
            "panel=false presenting=true setupActive=false toolbarHidden=false",
            !controller.setupPanelIsVisibleForDiagnostics
                && controller.isPresentingForDiagnostics
                && !controller.overlayIsRecordSetupActiveForDiagnostics
                && !controller.overlayToolbarHiddenForDiagnostics
        )
        // 对照组：交回输入后同一次拖拽确实会改选区。
        // 它证明上面的「准备阶段不改选区」来自输入接管，而不是事件根本没到。
        simulateDrag(in: window4, from: CGPoint(x: 900, y: 700), to: CGPoint(x: 1120, y: 820))
        try? await Task.sleep(for: .milliseconds(400))
        report(
            "对照：取消准备后拖拽恢复生效",
            "selection=\(describeSelection(controller.selection))",
            "与 \(describeSelection(selectionBeforeCancel)) 不同",
            controller.selection != selectionBeforeCancel
        )
        controller.cancelRecordSetupForDiagnostics()
        controller.dismiss()
        try? await Task.sleep(for: .milliseconds(400))

        // ══ 场景 5：真实识别数据源（受控数据只用于让其它断言可复现）══
        guard let window5 = await beginSession(installFixedDetection: false) else { await finish() }
        // 等真实识别会话载入窗口列表（异步枚举）。
        try? await Task.sleep(for: .seconds(1))
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let realContent = try? await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: true
        )
        let realWindows = (realContent?.windows ?? []).filter { window in
            guard let owner = window.owningApplication else { return false }
            return owner.processID != ownPID
                && window.isOnScreen
                && window.windowLayer == 0
                && window.frame.width >= 300
                && window.frame.height >= 200
        }
        if let realWindow = realWindows.first {
            let center = CGPoint(x: realWindow.frame.midX, y: realWindow.frame.midY)
            controller.simulateRecordRequestForDiagnostics(
                rect: selection,
                detected: nil,
                displayID: displayID
            )
            try? await Task.sleep(for: .milliseconds(600))
            guard let realWindowIndex = scopeIndex(.window, "场景5") else { await finish() }
            controller.selectSetupScopeForDiagnostics(index: realWindowIndex)
            try? await Task.sleep(for: .milliseconds(300))
            simulateMouseMove(in: window5, to: center)
            try? await Task.sleep(for: .milliseconds(400))
            // 先读识别器在那个点给出的身份，再断言点击锁定的是它。
            //
            // **不能**断言锁定的是 `realWindows.first`：那个列表的顺序（前到后）
            // 尚未在本项目里验证过，而该点可能被另一个窗口盖住——首版就是这么
            // 失败的（实测锁定的是盖在上面的那个窗口）。这里断言的是
            // 「身份来自真实快照，而不是由矩形反查的猜测」。
            // 真实窗口标题通常很长：截一张用于核对截断后的可读性
            // （受控数据源用的短标题看不出这个问题）。
            if let captured = try? await makeCapturer(nil).captureFrame(scope: .display(displayID)),
               let url = savePreview(captured.image, baseName: "record-setup-real-title") {
                logger.notice("[record-flow] 真实长标题面板截图: \(url.path, privacy: .public)")
            }
            let realCandidateID = controller.setupPickCandidateForDiagnostics?.windowID
            synthesizeMouseDown(in: window5, on: window5.overlayView, at: center)
            synthesizeMouseUp(in: window5, on: window5.overlayView, at: center)
            try? await Task.sleep(for: .milliseconds(500))

            let realIDs = Set(realWindows.map(\.windowID))
            var lockedID: CGWindowID?
            if case .window(let id)? = controller.setupComposedScopeForDiagnostics {
                lockedID = id
            }
            report(
                "真实快照下点击锁定其识别身份",
                "候选=\(realCandidateID.map(String.init) ?? "nil") 锁定=\(lockedID.map(String.init) ?? "nil") 真实窗口数=\(realWindows.count)",
                "锁定身份 = 识别候选身份，且属于真实窗口集合",
                lockedID != nil && lockedID == realCandidateID && realIDs.contains(lockedID!)
            )
            controller.cancelRecordSetupForDiagnostics()
        } else {
            // 不能静默跳过：没有真实窗口时这条验证等于没做，必须留下痕迹。
            report(
                "真实窗口列表下选取可锁定身份",
                "未找到可用的真实窗口（realWindows=0）",
                "至少一个层 0 窗口",
                false
            )
        }

        // ══ 场景 6：区域 → 全屏（最终矩形必须跟着换）与无选区时默认全屏 ══
        //
        // 这一条曾被修过一次（矩形曾取自打开面板那一刻）：它必须有独立断言，
        // 否则回退时没人会发现——预览框对了、成片框错了，两边都不会报错。
        guard let window6 = await beginSession() else { await finish() }
        controller.setSelection(selection)
        try? await Task.sleep(for: .milliseconds(400))
        controller.simulateRecordRequestForDiagnostics(
            rect: selection,
            detected: nil,
            displayID: displayID
        )
        try? await Task.sleep(for: .milliseconds(600))
        // 面板现在会记住上次选择：场景 3 在这一轮里关掉过系统声音，
        // 所以第二次弹出应恢复 false，而不是被硬复位成默认全开。
        let audioOnSecondOpen = controller.setupPanelAudioForDiagnostics
        report(
            "再次弹出面板时恢复上次音频选择",
            "systemAudio=\(audioOnSecondOpen.systemAudio) microphone=\(audioOnSecondOpen.microphone)",
            "systemAudio=false microphone=true",
            !audioOnSecondOpen.systemAudio && audioOnSecondOpen.microphone
        )

        let regionStatus = controller.setupPanelStatusTextForDiagnostics
        report(
            "有选区时默认区域且预览框等于选区",
            "selected=\(controller.setupPanelSelectedKindForDiagnostics?.rawValue ?? "nil") rect=\(formatRect(controller.setupPreviewFrameRectForDiagnostics)) status=\(regionStatus)",
            "selected=region rect=\(formatRect(selectionScreenRect)) status 含「区域」",
            controller.setupPanelSelectedKindForDiagnostics == .region
                && controller.setupPreviewFrameRectForDiagnostics == selectionScreenRect
                && regionStatus.contains("区域")
        )
        guard let displayIndex6 = scopeIndex(.display, "场景6") else { await finish() }
        controller.selectSetupScopeForDiagnostics(index: displayIndex6)
        try? await Task.sleep(for: .milliseconds(400))
        // 提示用词必须与分段控件同一套：控件写「全屏」，提示就该写「全屏」。
        let displayStatus = controller.setupPanelStatusTextForDiagnostics
        report(
            "全屏提示用词与控件一致",
            "status=\(displayStatus)",
            "含「全屏」且不含「整块显示器」",
            displayStatus.contains("全屏") && !displayStatus.contains("整块显示器")
        )
        report(
            "切全屏后范围与预览框都取整屏",
            "scope=\(String(describing: controller.setupComposedScopeForDiagnostics)) rect=\(formatRect(controller.setupPreviewFrameRectForDiagnostics))",
            "display(\(displayID)) rect=\(formatRect(fullScreenRect))",
            controller.setupComposedScopeForDiagnostics == .display(displayID)
                && controller.setupPreviewFrameRectForDiagnostics == fullScreenRect
        )
        synthesizeKey(in: window6, keyCode: 36, characters: "\r")
        try? await Task.sleep(for: .seconds(1))
        var postedDisplay = false
        if case .display(let id)? = probe.scope, id == displayID { postedDisplay = true }
        report(
            "全屏请求携带整屏矩形（而非旧区域）",
            "scope=\(String(describing: probe.scope)) rect=\(formatRect(probe.recordingRect))",
            "display(\(displayID)) rect=\(formatRect(fullScreenRect))",
            postedDisplay
                && probe.recordingRect == fullScreenRect
                && probe.recordingRect != selectionScreenRect
        )

        // 无选区：不应把第一项（窗口）当默认——那会一开面板就进入目标选取。
        guard let window7 = await beginSession() else { await finish() }
        controller.simulateRecordRequestForDiagnostics(
            rect: nil,
            detected: nil,
            displayID: displayID
        )
        try? await Task.sleep(for: .milliseconds(600))
        let kindsNoSelection = controller.setupScopeOptionKindsForDiagnostics
        report(
            "无选区时不给区域且默认全屏",
            "kinds=\(kindsNoSelection.map(\.rawValue)) selected=\(controller.setupPanelSelectedKindForDiagnostics?.rawValue ?? "nil") isEnabled=\(controller.setupPanelStartEnabledForDiagnostics)",
            "window,application,display selected=display isEnabled=true",
            kindsNoSelection == [.window, .application, .display]
                && controller.setupPanelSelectedKindForDiagnostics == .display
                && controller.setupPanelStartEnabledForDiagnostics
        )
        synthesizeKey(in: window7, keyCode: 36, characters: "\r")
        try? await Task.sleep(for: .seconds(1))
        var postedDisplayDefault = false
        if case .display(let id)? = probe.scope, id == displayID { postedDisplayDefault = true }
        report(
            "无选区时回车发出整屏请求",
            "scope=\(String(describing: probe.scope)) rect=\(formatRect(probe.recordingRect))",
            "display(\(displayID)) rect=\(formatRect(fullScreenRect))",
            postedDisplayDefault && probe.recordingRect == fullScreenRect
        )

        // ══ 场景 8：输出格式（GIF）与音频的交互 ══
        //
        // 这一条证明的是「意图被正确传递」；产物是不是真 GIF 由
        // `-diagnoseRecordingUI` 证明（那个入口会真的录制，本入口刻意不录）。
        guard let window8 = await beginSession() else { await finish() }
        controller.simulateRecordRequestForDiagnostics(
            rect: selection,
            detected: nil,
            displayID: displayID
        )
        try? await Task.sleep(for: .milliseconds(600))
        // 面板会记住上次选择；诊断先把它放回 MP4，避免上一次运行留下的
        // GIF 让这条断言变成「测的是历史」而不是「测的是恢复逻辑」。
        RecordingPreferencesStore.shared.output = .movie
        controller.simulateRecordRequestForDiagnostics(
            rect: selection,
            detected: nil,
            displayID: displayID
        )
        try? await Task.sleep(for: .milliseconds(300))
        let defaultOutput = controller.setupPanelOutputForDiagnostics
        report(
            "面板弹出时恢复上次输出格式",
            "\(describeOutput(defaultOutput))",
            "movie（诊断先把偏好放回 MP4）",
            defaultOutput == .movie
        )
        // MP4 是**默认**状态，它被裁掉的后果最严重（大多数录制都是 MP4）。
        let mp4Height = controller.setupPanelHeightForDiagnostics
        report(
            "MP4 面板内容不溢出",
            String(format: "内容=%.0f 高度=%.0f 余量=%.1f", controller.setupPanelContentHeightForDiagnostics, controller.setupPanelHeightForDiagnostics, controller.setupPanelContentClearanceForDiagnostics),
            "余量 ≥ 0",
            controller.setupPanelContentClearanceForDiagnostics >= 0
        )
        // 「点得到」的直接判据：按钮必须完整落在面板内容区里。
        // 首版只断言了窗口高度常量（==208），而内容高 214、底部 34pt 溢出窗口，
        // 「开始录制」被截掉、用户点不到——那个断言对这个缺陷完全免疫。
        report(
            "MP4 下「开始录制」在面板内（可点）",
            controller.setupPanelStartButtonRectDescriptionForDiagnostics,
            "按钮矩形完全落在内容区内",
            controller.setupPanelStartButtonInsideContentForDiagnostics
        )

        controller.setSetupPanelOutputForDiagnostics(.gif(GIFSettings(
            maximumDuration: 60,
            maximumPixelDimension: 1600
        )))
        try? await Task.sleep(for: .milliseconds(300))
        let selectedOutput = controller.setupPanelOutputForDiagnostics
        report(
            "选 GIF 后面板传出所选档位",
            "\(describeOutput(selectedOutput))",
            "gif(60s, 1600px)",
            selectedOutput == .gif(GIFSettings(maximumDuration: 60, maximumPixelDimension: 1600))
        )
        report(
            "GIF 时音频开关置灰且给出理由",
            "enabled=\(controller.setupPanelAudioEnabledForDiagnostics) notice=\(controller.setupPanelGIFNoticeVisibleForDiagnostics)",
            "enabled=false notice=true",
            !controller.setupPanelAudioEnabledForDiagnostics
                && controller.setupPanelGIFNoticeVisibleForDiagnostics
        )
        report(
            "GIF 时面板变高以容纳参数行",
            String(format: "%.0f", controller.setupPanelHeightForDiagnostics),
            String(format: "高于 MP4 的 %.0f", mp4Height),
            controller.setupPanelHeightForDiagnostics > mp4Height
        )
        // 内容必须**完整装进**面板：常量写小了会把底部按钮裁到窗口外，
        // 而那种裁切在只看窗口高度时完全看不出来（实测就是这么漏掉的）。
        report(
            "GIF 面板内容不溢出",
            String(format: "内容=%.0f 余量=%.1f", controller.setupPanelContentHeightForDiagnostics, controller.setupPanelContentClearanceForDiagnostics),
            "余量 ≥ 0（负数 = 底部按钮被裁、点不到）",
            controller.setupPanelContentClearanceForDiagnostics >= 0
        )
        report(
            "GIF 下「开始录制」在面板内（可点）",
            controller.setupPanelStartButtonRectDescriptionForDiagnostics,
            "按钮矩形完全落在内容区内",
            controller.setupPanelStartButtonInsideContentForDiagnostics
        )

        // 音频开关此刻仍是勾选状态（置灰不改写状态），而请求里必须是归零后的值——
        // 「请求带上了音频开关」正是 GIF 录制会白申请一次麦克风权限的原因。
        let audioWhileGIF = controller.setupPanelAudioForDiagnostics
        synthesizeKey(in: window8, keyCode: 36, characters: "\r")
        try? await Task.sleep(for: .seconds(1))
        var postedGIF: RecordingOutputChoice?
        if let raw = probe.output { postedGIF = raw }
        report(
            "GIF 请求携带格式与档位",
            "output=\(postedGIF.map(describeOutput) ?? "nil") 面板勾选=sys\(audioWhileGIF.systemAudio)/mic\(audioWhileGIF.microphone)",
            "gif(60s, 1600px)",
            postedGIF == .gif(GIFSettings(maximumDuration: 60, maximumPixelDimension: 1600))
        )
        // 音频归一化发生在配置成型处（`normalizedForOutput`），通知里的音频仍是原值——
        // 这是刻意的：通知只传递「用户勾了什么」，归零是**格式层**的事实。
        // 此处断言归零真的发生了，用的是带 GIF 的配置本身。
        var normalizedConfiguration = RecordingConfiguration(
            scope: .display(displayID),
            audio: AudioSettings(systemAudio: true, microphone: true),
            output: .gif(URL(fileURLWithPath: "/tmp/x.gif"), settings: GIFSettings())
        )
        normalizedConfiguration = normalizedConfiguration.normalizedForOutput()
        report(
            "GIF 配置成型时音频归零",
            "sys=\(normalizedConfiguration.audio.systemAudio) mic=\(normalizedConfiguration.audio.microphone)",
            "sys=false mic=false（否则会白申请一次麦克风权限）",
            !normalizedConfiguration.audio.isAnyEnabled
        )
        // 对照：MP4 不得被动过
        var movieConfiguration = RecordingConfiguration(
            scope: .display(displayID),
            audio: AudioSettings(systemAudio: true, microphone: true),
            output: .movie(URL(fileURLWithPath: "/tmp/x.mp4"), container: .mp4)
        )
        movieConfiguration = movieConfiguration.normalizedForOutput()
        report(
            "对照：MP4 配置的音频保持原样",
            "sys=\(movieConfiguration.audio.systemAudio) mic=\(movieConfiguration.audio.microphone)",
            "sys=true mic=true",
            movieConfiguration.audio.isAnyEnabled
        )

        // 切回 MP4：参数行隐去、面板回到原高度、音频恢复可用。
        // 不验这条就不知道「MP4 观感与加功能之前一致」是否成立。
        controller.setSetupPanelOutputForDiagnostics(.movie)
        try? await Task.sleep(for: .milliseconds(300))
        report(
            "切回 MP4 后恢复可用与高度",
            String(format: "enabled=\(controller.setupPanelAudioEnabledForDiagnostics) notice=\(controller.setupPanelGIFNoticeVisibleForDiagnostics) height=%.0f", controller.setupPanelHeightForDiagnostics),
            String(format: "enabled=true notice=false height=%.0f（与弹出时一致）", mp4Height),
            controller.setupPanelAudioEnabledForDiagnostics
                && !controller.setupPanelGIFNoticeVisibleForDiagnostics
                && abs(controller.setupPanelHeightForDiagnostics - mp4Height) < 1
                && controller.setupPanelStartButtonInsideContentForDiagnostics
        )
        controller.cancelRecordSetupForDiagnostics()
        controller.dismiss()
        try? await Task.sleep(for: .milliseconds(400))

        await finish()
    }

    /// 输出选择的可读描述（断言失败时日志里要看得出选了什么）。
    private static func describeOutput(_ output: RecordingOutputChoice) -> String {
        switch output {
        case .movie:
            return "movie"
        case .gif(let settings):
            return "gif(\(Int(settings.maximumDuration))s, \(settings.maximumPixelDimension)px)"
        }
    }

    /// 通知探针：在通知回调（主线程）与诊断主体之间安全传递结果。
    final class NotificationProbe: @unchecked Sendable {
        private let lock = NSLock()
        private var scopeValue: CaptureScope?
        private var audioValue: AudioSettings?
        private var outputValue: RecordingOutputChoice?
        private var rectValue: CGRect?
        private var countValue = 0

        var scope: CaptureScope? { lock.withLock { scopeValue } }
        var audio: AudioSettings? { lock.withLock { audioValue } }
        /// 请求携带的输出格式与档位。
        var output: RecordingOutputChoice? { lock.withLock { outputValue } }
        /// 录制请求携带的录制矩形（**AppKit 屏幕坐标**）。
        var recordingRect: CGRect? { lock.withLock { rectValue } }
        /// 收到的请求条数。用于证明「按钮不可点时**真的**没有请求发出」——
        /// 只读 `isEnabled` 是代理指标，读不出「有别的路径照样发了请求」。
        var count: Int { lock.withLock { countValue } }

        /// 清空记录。每个场景都要从零开始数：跨场景累计的计数无法区分
        /// 「本场景发出了一次」与「上一个场景的残留」。
        func reset() {
            lock.withLock {
                scopeValue = nil
                audioValue = nil
                outputValue = nil
                rectValue = nil
                countValue = 0
            }
        }

        func record(_ note: Notification) {
            lock.withLock {
                countValue += 1
                scopeValue = note.userInfo?[NotificationUserInfoKey.captureScope]
                    as? CaptureScope
                audioValue = note.userInfo?[NotificationUserInfoKey.audioSettings]
                    as? AudioSettings
                outputValue = note.userInfo?[NotificationUserInfoKey.outputChoice]
                    as? RecordingOutputChoice
                rectValue = note.userInfo?[NotificationUserInfoKey.recordingRect]
                    as? CGRect
            }
        }
    }

    /// 受控的识别数据源：返回一份固定窗口列表。
    ///
    /// 选取录制目标的结果取决于「鼠标下恰好有哪个窗口」，而真实窗口列表随桌面
    /// 内容变化，同一个诊断跑两次可能得到不同结果。这里只替换数据源，
    /// 命中测试、悬停、单击、锁定身份仍走产品代码。
    final class FixedWindowDetector: ScreenElementDetecting, @unchecked Sendable {
        private let fixedWindows: [DetectedWindow]

        init(windows: [DetectedWindow]) {
            fixedWindows = windows
        }

        var hasAccessibilityPermission: Bool { false }

        func windows(onDisplay displayID: CGDirectDisplayID) async throws -> [DetectedWindow] {
            fixedWindows
        }

        func control(atGlobalPoint point: CGPoint, inApplication processID: pid_t) -> ControlHit? {
            nil
        }
    }
}

#endif
