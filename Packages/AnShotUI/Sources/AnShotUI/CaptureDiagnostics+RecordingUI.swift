//
//  CaptureDiagnostics+RecordingUI.swift
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

    /// `-diagnoseRecordingFrame`：把录制范围框依次以「预览」「录制中」「暂停」
    /// 三种状态各显示一段稳定时间并各截一图，供外部目视确认边框确实被渲染。
    ///
    /// 只断言 `isVisible` 不足以证明「画出来了」——窗口可以可见但内容为空，
    /// 因此这个诊断的价值在于给出一段可被截图的稳定显示时间。
    /// 三态都截的理由：颜色是区分状态的唯一手段（边框位置完全相同），
    /// 而预览态与截图选框共用同一个蓝，改色时最容易漏改。
    static func runRecordingFrameDiagnostic() async {
        let rect = CGRect(x: 320, y: 320, width: 620, height: 420)
        let frame = RecordingRegionFrame()
        // 整屏：四角都贴屏幕角，应当采用屏幕自身的圆角半径。
        // 范围框没有角括号遮挡，是唯一能干净核验「贴角渲染半径」的载体——
        // 截图覆盖层的角上盖着白色角括号，蓝色边框在那里被压住，测不准。
        let fullScreen = NSScreen.main?.frame ?? rect

        let stages: [(
            appearance: RecordingRegionFrame.Appearance,
            name: String,
            baseName: String,
            rect: CGRect
        )] = [
            (.preview, "预览（蓝）", "recording-frame-preview", rect),
            (.candidate, "候选（蓝虚线）", "recording-frame-candidate", rect),
            (.recording, "录制中（红）", "recording-frame-red", rect),
            (.paused, "暂停（琥珀）", "recording-frame-yellow", rect),
            // 滚动截图的选区框：与预览同为蓝色，但它要能压在被截区域上
            // 而不被拼进长图（该窗口声明了 `sharingType = .none`）。
            (.scrollshot, "滚动截图（蓝，不可被捕获）", "recording-frame-scrollshot", rect),
            // 整屏贴合：四角应为屏幕圆角，而不是被强制成直角或固定 8pt。
            (.preview, "整屏贴合（屏幕圆角）", "recording-frame-flush", fullScreen),
        ]

        for stage in stages {
            frame.show(rect: stage.rect, appearance: stage.appearance)
            logger.notice("""
                [recording-frame-diag] 状态=\(stage.name, privacy: .public) \
                visible=\(frame.isVisible, privacy: .public) \
                rect=\(Int(stage.rect.minX), privacy: .public),\(Int(stage.rect.minY), privacy: .public) \
                \(Int(stage.rect.width), privacy: .public)x\(Int(stage.rect.height), privacy: .public)
                """)
            if stage.baseName == "recording-frame-flush" {
                let radii = DisplayCornerGeometry.radii(for: DisplayGeometry.mainDisplay())
                logger.notice("""
                    [recording-frame-diag] 整屏贴合：屏幕半径=\(radii?.description ?? "nil", privacy: .public) \
                    期望渲染半径（路径）= 屏幕半径 − 描边内缩
                    """)
            }
            try? await Task.sleep(nanoseconds: 600_000_000)

            // 用 anShot 自己的截图能力抓图：终端的 screencapture 需要终端自身
            // 的屏幕录制权限（实测报 "could not create image from display"），
            // 而 anShot 已获授权，抓到的画面里包含范围框本身。
            if let captured = try? await makeCapturer(nil).captureFrame(
                   scope: .display(DisplayGeometry.mainDisplay())
               ),
               let url = savePreview(captured.image, baseName: stage.baseName) {
                logger.notice("""
                    [recording-frame-diag] \(stage.name, privacy: .public) 截图: \
                    \(url.path, privacy: .public) \
                    \(captured.image.width, privacy: .public)x\(captured.image.height, privacy: .public)
                    """)
            } else {
                logger.error("[recording-frame-diag] \(stage.name, privacy: .public) 截图失败")
            }

            try? await Task.sleep(nanoseconds: 2_400_000_000)
        }

        frame.hide()
        logger.notice("[recording-frame-diag] 已释放 visible=\(frame.isVisible, privacy: .public)")

        // 留出日志落盘时间再退出，避免最后一行丢失
        try? await Task.sleep(nanoseconds: 600_000_000)
        exit(0)
    }

    /// `-diagnoseRecordingUI`
    ///
    /// 程序化驱动界面层控制器与控制条，验证：控制条上屏、状态转换、
    /// 暂停期间不写入、时长不含暂停、产出文件可读，以及
    /// **GIF 输出经界面层真的产出 GIF、且导出期间界面状态正确**。
    ///
    /// 界面本身的**观感**无法自动判定，这里只验证可观测的行为契约。
    static func runRecordingUIDiagnostic() async {
        var failed = 0
        func report(_ label: String, _ measured: String, _ expected: String, _ ok: Bool) {
            if !ok { failed += 1 }
            let padded = label.padding(toLength: 30, withPad: " ", startingAt: 0)
            logger.notice("""
                [recording-ui] \(padded, privacy: .public) measured=\(measured, privacy: .public) \
                expected=\(expected, privacy: .public)  \(ok ? "MATCH" : "MISMATCH", privacy: .public)
                """)
        }

        let outputURL = URL(fileURLWithPath: NSTemporaryDirectory() + "anshot-ui-diag.mp4")
        let controller = RecordingController()
        let bar = RecordingControlBar()
        controller.onUpdate = { state, elapsed in
            bar.update(state: state, elapsed: elapsed)
        }

        logger.notice("[recording-ui] 开始界面层验证")
        controller.start(
            scope: .display(DisplayGeometry.mainDisplay()),
            audio: AudioSettings(),
            output: .movie,
            outputURL: outputURL
        )
        bar.show()

        // 等待进入 recording
        let reached = await waitForCondition(timeout: 8) { controller.state == .recording }
        report("reached recording", "\(reached)", "true", reached)
        report("control bar visible", "\(bar.isVisible)", "true", bar.isVisible)

        try? await Task.sleep(nanoseconds: 1_200_000_000)
        await controller.togglePause()
        report("paused state", controller.state.rawValue, "paused", controller.state == .paused)

        // 暂停 1.5 秒：这段时间不应进入时长
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        await controller.togglePause()
        report("resumed state", controller.state.rawValue, "recording", controller.state == .recording)

        try? await Task.sleep(nanoseconds: 1_200_000_000)
        await controller.stop()

        let finished = await waitForCondition(timeout: 8) { controller.state.isTerminal }
        report("terminal state", controller.state.rawValue, "finished", controller.state == .finished)

        // 录制约 2.4 秒 + 暂停 1.5 秒；时长应≈2.4s 而非 3.9s
        let elapsed = controller.elapsed
        report(
            "duration excludes pause",
            String(format: "%.2fs", elapsed),
            "≈2.4s（暂停 1.5s 不计）",
            elapsed >= 1.8 && elapsed <= 3.2
        )

        let probed = await probeMovie(at: outputURL)
        report("output decodable", "\(probed != nil)", "true", probed != nil)
        if let probed {
            report(
                "output duration",
                String(format: "%.2fs", probed.duration),
                "≈2.4s",
                probed.duration >= 1.8 && probed.duration <= 3.2
            )
        }
        bar.hide()
        report("control bar hidden", "\(bar.isVisible)", "false", !bar.isVisible)

        _ = finished
        // 注意：失败已由 `report` 计进外层计数器，内层不再自行累加，
        // 否则同一个 MISMATCH 会被计两次（实测跑出「3 项不符却报 6 项失败」）。
        await runGIFInterfaceSection(report: report)

        logger.notice("[recording-ui] done，失败项=\(failed, privacy: .public)")
        try? await Task.sleep(nanoseconds: 600_000_000)
        exit(failed == 0 ? 0 : 1)
    }

    /// 界面层的 GIF 段：控制器以 `.gif` 输出 → 产物是**可解码的 GIF**，
    /// 且导出期间的界面状态（倒计时、进度、按钮置灰）真的发生过。
    ///
    /// 这里证明的是「意图被正确执行」；「面板选了什么就传出什么」由
    /// `-diagnoseRecordFlow` 证明（那个入口刻意不真录制）。
    private static func runGIFInterfaceSection(
        report: (_ label: String, _ measured: String, _ expected: String, _ ok: Bool) -> Void
    ) async {

        let gifSettings = GIFSettings(maximumDuration: 15, maximumPixelDimension: 800)
        let gifURL = URL(fileURLWithPath: NSTemporaryDirectory() + "anshot-ui-diag.gif")
        try? FileManager.default.removeItem(at: gifURL)

        let controller = RecordingController()
        let bar = RecordingControlBar()
        var progresses: [Double] = []
        controller.onUpdate = { state, elapsed in
            bar.update(state: state, elapsed: elapsed)
        }
        // 必须把进度也交给控制条：只记录到数组里的话，被测的是「回调发生了」，
        // 而不是「界面显示了进度」——首版就是这么漏掉的（实测：提示一直是「收尾中」）。
        controller.onExportProgress = { value in
            progresses.append(value)
            bar.updateExportProgress(value)
        }

        logger.notice("[recording-ui] 开始 GIF 界面层验证")
        controller.start(
            scope: .display(DisplayGeometry.mainDisplay()),
            audio: AudioSettings(),
            output: .gif(gifSettings),
            outputURL: gifURL
        )
        bar.show(near: nil, gifLimit: gifSettings.maximumDuration)

        let reached = await waitForCondition(timeout: 8) { controller.state == .recording }
        report("gif: reached recording", "\(reached)", "true", reached)
        // 上限必须对用户可见：到达上限会自动停录，不显示就等于内容被凭空截断。
        let countdown = bar.hintTextForDiagnostics
        report("gif: countdown visible", countdown, "剩 15s", countdown == "剩 15s")

        try? await Task.sleep(nanoseconds: 1_500_000_000)

        // 停录 → 导出。导出期间 `stop()` 尚未返回，因此可以在这段时间里
        // 轮询界面状态（导出完成后这两个按钮的可用性就不再是重点）。
        let stopTask = Task { await controller.stop() }
        var sawExportHint = false
        var sawButtonsDisabled = false
        for _ in 0..<80 {
            if bar.hintTextForDiagnostics.hasPrefix("GIF ") { sawExportHint = true }
            if !bar.pauseEnabledForDiagnostics, !bar.stopEnabledForDiagnostics {
                sawButtonsDisabled = true
            }
            if sawExportHint, sawButtonsDisabled { break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        await stopTask.value

        report("gif: export hint shown", "\(sawExportHint)", "true", sawExportHint)
        report("gif: buttons disabled in export", "\(sawButtonsDisabled)", "true", sawButtonsDisabled)

        // 判据是「量化 + 严格递增」，不是「值是 1% 的整数倍」：
        // 后者要求浮点除法精确，而报的是 Double 的 0.04 这种本就不精确的值。
        // 真正的契约是「回调次数受 1% 粒度约束，且界面显示的值每次都在变」。
        let percents = progresses.map { Int(($0 * 100).rounded()) }
        report(
            "gif: progress quantized & monotonic",
            "\(progresses.count) 次，首=\(percents.first ?? -1)% 末=\(percents.last ?? -1)%",
            "≤100 次、百分比严格递增、末值 100%",
            progresses.count <= 100
                && zip(percents, percents.dropFirst()).allSatisfy { pair in pair.0 < pair.1 }
                && percents.last == 100
        )
        report("gif: progress reaches 100%", "\(progresses.last ?? -1)", "1.0", progresses.last == 1.0)

        let terminal = await waitForCondition(timeout: 10) { controller.state.isTerminal }
        report("gif: terminal state", controller.state.rawValue, "finished", terminal && controller.state == .finished)

        let probed = probeGIF(at: gifURL)
        report("gif: output decodable", "\(probed != nil)", "true", probed != nil)
        report(
            "gif: output extension",
            gifURL.pathExtension,
            "gif",
            gifURL.pathExtension == "gif"
        )
        if let probed {
            report(
                "gif: frame count",
                "\(probed.frameCount)",
                "≥ 6（1.5s × 12fps 的一半以上）",
                probed.frameCount >= 6
            )
            let longest = max(probed.pixelSize.width, probed.pixelSize.height)
            report(
                "gif: pixel size within limit",
                "\(Int(probed.pixelSize.width))x\(Int(probed.pixelSize.height))",
                "任一边 ≤ 800",
                longest <= 801
            )
        }
        // 提示文案在终态时保留最后一次导出进度（界面上最后看到的就是它）
        report("gif: final hint", bar.hintTextForDiagnostics, "GIF 100%", bar.hintTextForDiagnostics == "GIF 100%")
        bar.hide()
    }

    /// `-diagnoseWindowFollow`：窗口录制时范围框是否真的跟随窗口。
    ///
    /// **完全受控**：自建一个普通窗口并移动它，验证三段链路
    /// `WindowFrameProbe` → `WindowFrameFollower` → `RecordingRegionFrame`。
    ///
    /// 判据用**相对位移**而不是绝对坐标：`CGWindowListCopyWindowInfo` 的 bounds
    /// 与 `NSWindow.frame` 可能在阴影/圆角上差几个点，绝对值比较会把这种固有偏差
    /// 记成失败。位移量在两个坐标系里相同（两者只差一个整体平移），
    /// 因此不需要任何换算，也就不可能因为换算写错而"通过"。
    static func runWindowFollowDiagnostic() async {
        var failed = 0
        func report(_ label: String, _ measured: String, _ expected: String, _ ok: Bool) {
            if !ok { failed += 1 }
            logger.notice("""
                [window-follow] \(label, privacy: .public) measured=\(measured, privacy: .public) \
                expected=\(expected, privacy: .public)  \(ok ? "MATCH" : "MISMATCH", privacy: .public)
                """)
        }

        let window = NSWindow(
            contentRect: NSRect(x: 320, y: 420, width: 360, height: 240),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "anShot 跟随诊断"
        window.isReleasedWhenClosed = false
        window.orderFrontRegardless()
        try? await Task.sleep(for: .milliseconds(700))   // 等 WindowServer 登记该窗口

        let windowID = CGWindowID(window.windowNumber)
        guard let initialGlobal = WindowFrameProbe.frame(of: windowID) else {
            report("探测到自建窗口的实时矩形", "nil", "非 nil（windowID=\(windowID)）", false)
            window.close()
            finishWindowFollowDiagnostic(failed: failed)
            return
        }
        let initialScreen = OverlayWindow.appKitScreenRect(forGlobalRect: initialGlobal)
        report(
            "探测到自建窗口的实时矩形",
            "global=\(NSStringFromRect(initialGlobal)) screen=\(NSStringFromRect(initialScreen))",
            "非空矩形",
            initialGlobal.width >= 1 && initialGlobal.height >= 1
        )

        // 跟随器 + 范围框：与真实录制路径同一套 API。
        let frame = RecordingRegionFrame()
        frame.show(rect: initialScreen, appearance: .preview)
        let follower = WindowFrameFollower(windowID: windowID, interval: 0.2) { rect in
            frame.update(rect: rect)
        }
        follower.start()
        try? await Task.sleep(for: .milliseconds(800))

        let before = follower.lastKnownRect
        let expectedShift = CGSize(width: 160, height: 90)
        // AppKit 坐标向上移动 90pt → 观察到的位移应为 (+160, −90)
        window.setFrameOrigin(NSPoint(
            x: window.frame.origin.x + expectedShift.width,
            y: window.frame.origin.y - expectedShift.height
        ))
        try? await Task.sleep(for: .milliseconds(1000))

        let after = follower.lastKnownRect
        let shift = before.flatMap { b in after.map { CGSize(width: $0.minX - b.minX, height: $0.minY - b.minY) } }
        report(
            "跟随器上报的位移与窗口位移一致",
            shift.map { String(format: "dx=%.0f dy=%.0f", $0.width, $0.height) } ?? "nil",
            String(format: "dx=%.0f dy=%.0f（容差 ±3pt）", expectedShift.width, -expectedShift.height),
            shift.map {
                abs($0.width - expectedShift.width) <= 3 && abs($0.height + expectedShift.height) <= 3
            } ?? false
        )

        // 端到端：范围框窗口本身也必须移动，而不是只有跟随器内部记了值。
        let frameRect = frame.currentRect
        report(
            "范围框窗口跟随移动",
            frameRect.map { NSStringFromRect($0) } ?? "nil",
            after.map { NSStringFromRect($0) } ?? "nil",
            frameRect != nil && after != nil && frameRect == after
        )
        report("范围框可见", "visible=\(frame.isVisible)", "visible=true", frame.isVisible)

        // 窗口消失：不得把范围框藏起来或挪走（录制仍在继续）。
        //
        // **关闭有动画**：动画期间窗口仍在屏上、尺寸在缩小，跟随器会如实跟随——
        // 那是正确行为（跟随的就是窗口的实际矩形），所以判据不能拿"关闭前"的值比，
        // 必须等动画结束、窗口彻底离屏之后再判"不再变化"。
        let rectAtClose = frame.currentRect
        window.close()
        try? await Task.sleep(for: .milliseconds(1200))   // 等关闭动画结束
        let settled = frame.currentRect
        let lastKnownAtSettle = follower.lastKnownRect
        try? await Task.sleep(for: .milliseconds(900))    // 再等一个轮询周期
        logger.notice("""
            [window-follow] 关闭动画期间跟随: \
            关闭前=\(rectAtClose.map { NSStringFromRect($0) } ?? "nil", privacy: .public) \
            动画后=\(settled.map { NSStringFromRect($0) } ?? "nil", privacy: .public) \
            （动画期间尺寸在变，跟随器如实跟随属正确行为）
            """)
        report(
            "窗口消失后保持现状且不隐藏",
            "rect=\(frame.currentRect.map { NSStringFromRect($0) } ?? "nil") visible=\(frame.isVisible)",
            "rect 稳定不变且仍可见",
            frame.isVisible && frame.currentRect == settled && follower.lastKnownRect == lastKnownAtSettle
        )

        follower.stop()
        frame.hide()
        logger.notice("""
            [window-follow] 汇总: \(failed == 0 ? "全部通过" : "\(failed) 项失败", privacy: .public) \
            exitCode=\(failed == 0 ? 0 : 1, privacy: .public)
            """)
        try? await Task.sleep(for: .milliseconds(400))
        exit(failed == 0 ? 0 : 1)
    }

    /// 收尾：打印汇总并以退出码结束（与其它诊断一致）。
    private static func finishWindowFollowDiagnostic(failed: Int) {
        logger.notice("""
            [window-follow] 汇总: \(failed == 0 ? "全部通过" : "\(failed) 项失败", privacy: .public) \
            exitCode=\(failed == 0 ? 0 : 1, privacy: .public)
            """)
        exit(failed == 0 ? 0 : 1)
    }
}

#endif
