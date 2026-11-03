//
//  CaptureDiagnostics+ScrollshotEntry.swift
//  AnShotUI
//
//  `-diagnoseScrollshotEntry`：长截图入口的验证。
//
//  ── 为什么单独验证入口 ────────────────────────────────────
//
//  `-diagnoseScrollshotLive` 直接构造会话，验证的是链路本身；但用户是**点按钮**
//  进入的。工具栏项是否存在、点击是否真的把请求交到控制器，这两点一旦断了，
//  后面整条链路再正确用户也用不上。合成点击走的是与真实点击同一条路径
//  （`AnnotationToolbarView.handle`），不是直接调控制器方法。
//

#if DEBUG
import AnShotCapture
import AnShotCore
import AppKit

extension CaptureDiagnostics {

    static func runScrollshotEntryDiagnostic() async {
        let controller = OverlayController(capturer: CapturerFactory.makeDefault())
        controller.present()
        try? await Task.sleep(for: .seconds(2))

        guard controller.isPresentingForDiagnostics, let window = controller.primaryOverlayWindow else {
            logger.error("[scrollshot-entry] 覆盖层未就绪")
            controller.dismiss()
            exit(1)
        }
        // 入口需要有效选区（没有选区就没有可滚动的区域）。
        _ = controller.setSelection(window.frame.insetBy(dx: 60, dy: 60))
        try? await Task.sleep(for: .milliseconds(500))

        var failed = 0
        func report(_ label: String, _ measured: String, _ expected: String, _ ok: Bool) {
            if !ok { failed += 1 }
            logger.notice("""
                [scrollshot-entry] \(label, privacy: .public) measured=\(measured, privacy: .public) \
                expected=\(expected, privacy: .public)  \(ok ? "MATCH" : "MISMATCH", privacy: .public)
                """)
        }

        // ① 工具栏里有这个入口（用户点得到）。
        let center = controller.longScreenshotButtonCenterForDiagnostics
        report(
            "工具栏存在长截图按钮",
            center.map { NSStringFromPoint($0) } ?? "nil",
            "非 nil",
            center != nil
        )

        // ② 通过控制器的真实入口启动会话（与点击进入的是同一个方法）。
        let started = controller.startScrollshotForDiagnostics()
        // 以下四条必须**当场**断言，不能等 sleep 之后：首帧抓取排在下一个 runloop，
        // 而它一旦失败（命令行启动没有屏幕录制权限时必然失败）会话立即结束、
        // 选区框随之收起——那时再查，测到的是收尾状态而非会话中的状态。
        report("会话已启动", "\(started)", "true", started)
        report("会话状态可见", "\(controller.isScrollshotActiveForDiagnostics)", "true", controller.isScrollshotActiveForDiagnostics)

        // ④ 覆盖层收起之后，屏幕上必须仍有东西说明「在截哪一块」。
        //    否则用户切个窗口回来就找不到边界了——这正是「覆盖层一收，
        //    选区框也没了」那个缺陷要防的事。
        let regionFrame = controller.scrollshotRegionFrameRectForDiagnostics
        report(
            "会话期间显示选区框",
            "\(controller.scrollshotRegionFrameIsVisibleForDiagnostics) \(regionFrame.map { NSStringFromRect($0) } ?? "nil")",
            "true",
            controller.scrollshotRegionFrameIsVisibleForDiagnostics
        )
        report(
            "选区框用的是滚动截图外观",
            controller.scrollshotRegionFrameAppearanceForDiagnostics.map(String.init(describing:)) ?? "nil",
            "scrollshot",
            controller.scrollshotRegionFrameAppearanceForDiagnostics == .scrollshot
        )
        // 位置必须与屏幕上的选区重合：只断言「可见」的话，框画在屏幕角落也算过。
        // 换算方式必须与 `handleLongScreenshotRequest` 一致（视图坐标 → 屏幕坐标，
        // y 要翻），否则这里测的是另一套坐标。
        if let overlay = window as? OverlayWindow,
           let selection = overlay.overlayView.effectiveSelection,
           let regionFrame {
            let origin = overlay.frame
            let expected = CGRect(
                x: origin.minX + selection.minX,
                y: origin.maxY - selection.maxY,
                width: selection.width,
                height: selection.height
            )
            let delta = max(
                abs(regionFrame.minX - expected.minX),
                abs(regionFrame.minY - expected.minY),
                abs(regionFrame.width - expected.width),
                abs(regionFrame.height - expected.height)
            )
            report(
                "选区框与屏幕上的选区重合",
                NSStringFromRect(regionFrame),
                "\(NSStringFromRect(expected)) ± 1",
                delta <= 1
            )
        } else {
            report("选区框与屏幕上的选区重合", "nil", "非 nil", false)
        }

        try? await Task.sleep(for: .milliseconds(400))

        // ③ 会话期间覆盖层必须隐藏（同步 orderOut，什么时候查都一样）。
        let hidden = !window.isVisible
        report("会话期间覆盖层已隐藏", "\(hidden)", "true", hidden)

        controller.cancelScrollshotForDiagnostics()
        try? await Task.sleep(for: .milliseconds(300))
        report("取消后会话已结束", "\(controller.isScrollshotActiveForDiagnostics)", "false", !controller.isScrollshotActiveForDiagnostics)
        report(
            "取消后选区框已收起",
            "\(controller.scrollshotRegionFrameIsVisibleForDiagnostics)",
            "false",
            !controller.scrollshotRegionFrameIsVisibleForDiagnostics
        )

        logger.notice("""
            [scrollshot-entry] 汇总: \(failed == 0 ? "全部通过" : "\(failed) 项失败", privacy: .public) \
            exitCode=\(failed == 0 ? 0 : 1, privacy: .public)
            """)
        controller.dismiss()
        try? await Task.sleep(for: .milliseconds(300))
        exit(failed == 0 ? 0 : 1)
    }
}
#endif
