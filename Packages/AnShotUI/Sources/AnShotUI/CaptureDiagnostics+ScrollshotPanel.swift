//
//  CaptureDiagnostics+ScrollshotPanel.swift
//  AnShotUI
//
//  `-diagnoseScrollshotPanel`：滚动截图浮层的**两栏布局与联动**验证。
//
//  ── 为什么不复用 `-diagnoseScrollshotOverlay` ──────────────
//
//  那条路验的是「浮层不会被拍进长图」，必须先抓一帧基线——没有屏幕录制权限时
//  它当场 MISMATCH 退出（实测 TCC `auth_value = false`），根本走不到渲染那一步。
//  而浮层的**布局与联动**只取决于它自己的视图树：整幅导航图怎么缩、定位框落在哪、
//  放大栏要的是哪一段。这些都不需要屏幕内容，也就不需要任何权限。所以拆开单跑：
//  未授权也能跑，CI 也能跑。
//
//  ── 判据（全部是行为判据，成图只供人眼核对配色）────────────
//
//  1. 两栏、状态行与按钮互不重叠且都在面板内；
//  2. 整幅缩略图**完整**落在导航栏内（contain 的直接证据）；
//  3. 定位框中心换算回世界行 = 放大栏窗口中心 —— 专抓 flipped 坐标（y 向下）
//     与世界行之间的**方向错误**：搞反了定位框会画到对称的另一端，而其余判据
//     全都自洽，只有这一条能发现；
//  4. 浮层**实际发出**的切片请求就是定位窗口那一段，且该行数恰好让放大图铺满
//     放大栏 —— 「框住多少 = 右边显示多少」的端到端证据；
//  5. 拖动→锁定、点状态行→回到采集位置的状态机。
//

#if DEBUG
import AnShotCore
import AppKit

extension CaptureDiagnostics {

    static func runScrollshotPanelDiagnostic() async {
        var failed = 0
        func report(_ label: String, _ measured: String, _ expected: String, _ ok: Bool) {
            if !ok { failed += 1 }
            logger.notice("""
                [scrollshot-panel] \(label, privacy: .public) measured=\(measured, privacy: .public) \
                expected=\(expected, privacy: .public)  \(ok ? "MATCH" : "MISMATCH", privacy: .public)
                """)
        }

        guard let fixture = makeInspectablePreview() else {
            report("构造诊断预览内容", "nil", "非 nil", false)
            exit(1)
        }
        let content = fixture.content
        let panelSize = CGSize(width: 460, height: 332)

        let bar = ScrollshotProgressBar()
        // 录下浮层实际发出的切片请求（见判据 4）。
        var lastRequest: (rows: Range<Int>, width: Int)?
        bar.onDetailRequest = { rows, width in
            lastRequest = (rows, width)
            return fixture.detailImage(rows, width)
        }
        bar.placeForDiagnostics(at: CGRect(origin: CGPoint(x: 240, y: 260), size: panelSize))
        bar.updatePreview(content)
        // 视图布局与首帧渲染都排到主线程的下一轮才生效。
        try? await Task.sleep(for: .milliseconds(200))

        // ① 布局：各栏都在面板内，且互不重叠。
        let frames = bar.layoutFramesForDiagnostics
        let panel = CGRect(origin: .zero, size: panelSize)
        let allFrames = [frames.navigator, frames.detail, frames.status, frames.guide, frames.cancel, frames.finish]
        report(
            "各栏都在面板内",
            allFrames.map { "\(Int($0.width))x\(Int($0.height))@\(Int($0.minX)),\(Int($0.minY))" }
                .joined(separator: " "),
            "都在 460×332 内",
            allFrames.allSatisfy { panel.contains($0) }
        )
        let pairs = [
            (frames.navigator, frames.detail),
            (frames.navigator, frames.status),
            (frames.detail, frames.status),
            (frames.detail, frames.finish),
            (frames.guide, frames.cancel),
            (frames.guide, frames.finish),
            (frames.cancel, frames.finish),
            (frames.status, frames.finish)
        ]
        let overlapCount = pairs.filter { $0.0.intersects($0.1) }.count
        report("各栏互不重叠", "\(overlapCount) 处", "0 处", overlapCount == 0)

        // ①' 引导行：长截图靠用户自己滚动推进（不申请辅助功能权限），
        //     所以「请滚动」是界面唯一必须说清的操作指引；
        //     跟丢时必须换成警示语，否则用户会接着白滚。
        report(
            "引导行给出滚动指引",
            bar.guideTextForDiagnostics,
            ScrollshotProgressBar.guideScrolling,
            bar.guideTextForDiagnostics == ScrollshotProgressBar.guideScrolling
        )
        bar.updateGuide(ScrollshotProgressBar.guideStalled, isWarning: true)
        report(
            "跟丢后引导行换成警示语",
            bar.guideTextForDiagnostics,
            ScrollshotProgressBar.guideStalled,
            bar.guideTextForDiagnostics == ScrollshotProgressBar.guideStalled
        )
        // 断言「语义」而不只是「等于当前常量」：文案一旦被改回「请重新开始」
        // 这类说法，断言必须失败——而重锚之后会话并没有停，叫用户重来是错的。
        report(
            "跳变提示指向「可以继续」而不是「重新开始」",
            ScrollshotProgressBar.guideStalled,
            "含「可继续滚动」且不含「重新开始」",
            ScrollshotProgressBar.guideStalled.contains("可继续滚动")
                && !ScrollshotProgressBar.guideStalled.contains("重新开始")
        )
        // 上限与跟丢必须说成不同的话：前者是一张**可用**的长图（该收尾），
        // 后者是位置不可信（该重来）。说反了用户会白丢一张能用的图。
        report(
            "高度到顶时提示的是上限而非跟丢",
            ScrollshotProgressBar.guideHeightLimit,
            "与「\(ScrollshotProgressBar.guideStalled)」不同",
            ScrollshotProgressBar.guideHeightLimit != ScrollshotProgressBar.guideStalled
        )
        report(
            "帧数到顶的提示也与跟丢不同",
            ScrollshotProgressBar.guideFrameLimit,
            "与「\(ScrollshotProgressBar.guideStalled)」不同",
            ScrollshotProgressBar.guideFrameLimit != ScrollshotProgressBar.guideStalled
        )
        // 断言完就恢复，免得后续成图里留下警示语（成图要给人看正常状态）。
        bar.updateGuide(ScrollshotProgressBar.guideScrolling)

        // ② 整幅缩略图必须完整落在导航栏内。
        let nav = bar.navigatorFramesForDiagnostics
        report(
            "整幅缩略图完整落在导航栏内",
            "缩略 \(Int(nav.thumbnail.width))x\(Int(nav.thumbnail.height)) / 栏 \(Int(frames.navigator.width))x\(Int(frames.navigator.height))",
            "不溢出",
            frames.navigator.contains(nav.thumbnail)
        )

        guard let focusFrame = nav.focus, let window = bar.focusWindowForDiagnostics else {
            report("定位框与放大栏窗口存在", "nil", "非 nil", false)
            bar.hide()
            exit(1)
        }

        // ③ 定位框的位置必须与放大栏窗口对应：把窗口中心的世界行**独立地**换算成面板
        //    坐标（面板是左下原点，所以「从缩略图顶部往下 0.425」= `maxY - 0.425×高`），
        //    再与定位框的实际位置比。这条专抓 flipped 坐标（导航视图内 y 向下）与世界行
        //    之间的**方向错误**——搞反了定位框会画到对称的另一端，而其余判据全都自洽，
        //    只有这一条能发现。
        let windowCenter = window.lowerBound + window.count / 2
        let expectedRatio = Double(windowCenter - content.worldStart) / Double(content.worldHeight)
        let expectedCenterY = nav.thumbnail.maxY - expectedRatio * nav.thumbnail.height
        report(
            "定位框落在放大栏窗口对应的位置上",
            String(format: "%.1f", focusFrame.midY),
            String(format: "%.1f ± 2", expectedCenterY),
            abs(focusFrame.midY - expectedCenterY) <= 2
        )
        report(
            "定位框高度在导航栏内且不低于下限",
            String(format: "%.1f 点", focusFrame.height),
            "14 点 ≤ h ≤ \(Int(frames.navigator.height)) 点",
            focusFrame.height >= 13.5 && focusFrame.height <= frames.navigator.height + 0.5
        )

        // ④ 切片请求：宽度是放大栏的 2x 像素宽，行区间就是定位窗口，且该行数
        //    恰好让放大图铺满放大栏高度。
        if let request = lastRequest {
            report(
                "切片请求宽度 = 放大栏像素宽",
                "\(request.width)",
                "\(ScrollshotProgressBar.detailPixelWidth)",
                request.width == ScrollshotProgressBar.detailPixelWidth
            )
            report(
                "切片请求行区间 = 定位窗口",
                "\(request.rows.lowerBound)..<\(request.rows.upperBound)",
                "\(window.lowerBound)..<\(window.upperBound)",
                request.rows == window
            )
            // 放大图横向铺满放大栏（344 点 = 688 像素）→ 每世界像素占
            // `344 / 长图宽` 点 → 这些行纵向显示为 `行数 × 344 / 长图宽` 点。
            let coveredPoints = Double(request.rows.count) * Double(frames.detail.width)
                / Double(content.worldWidth)
            report(
                "放大图恰好铺满放大栏高度",
                String(format: "%.1f 点", coveredPoints),
                String(format: "%.0f 点 ± 2", frames.detail.height),
                abs(coveredPoints - Double(frames.detail.height)) <= 2
            )
        } else {
            report("浮层发出了切片请求", "nil", "非 nil", false)
        }

        // ⑤ 状态机：拖动 → 锁定；点状态行 → 回到采集位置。
        bar.focusForDiagnostics(worldRow: 600)
        let dragged = bar.focusWindowForDiagnostics
        report(
            "拖动后定位窗口跟随目标世界行",
            dragged.map { "\($0.lowerBound)..<\($0.upperBound)" } ?? "nil",
            "含 600",
            dragged?.contains(600) == true
        )
        report("拖动后进入锁定态", "\(bar.isPinnedForDiagnostics)", "true", bar.isPinnedForDiagnostics)

        bar.followCurrentForDiagnostics()
        let viewport = content.viewportWorldRows ?? 0..<1
        let viewportCenter = viewport.lowerBound + viewport.count / 2
        let restored = bar.focusWindowForDiagnostics
        let restoredCenter = (restored?.lowerBound ?? 0) + (restored?.count ?? 0) / 2
        report(
            "回到采集位置后焦点落在屏幕视口中心",
            "\(restoredCenter)",
            "\(viewportCenter) ± 2",
            abs(restoredCenter - viewportCenter) <= 2
        )
        report("回到采集位置后解除锁定", "\(bar.isPinnedForDiagnostics)", "false", !bar.isPinnedForDiagnostics)

        // 成图：浮层声明了 `sharingType = .none`，屏幕捕获看不到它，只能直接渲染视图。
        if let view = bar.contentViewForDiagnostics,
           let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: rep)
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("scrollshot-panel.png")
            if let data = rep.representation(using: .png, properties: [:]) {
                try? data.write(to: url)
                logger.notice("[scrollshot-panel] 浮层外观已渲染 \(url.path, privacy: .public)")
            }
        }

        bar.hide()
        try? await Task.sleep(for: .milliseconds(200))
        logger.notice("""
            [scrollshot-panel] 汇总: \(failed == 0 ? "全部通过" : "\(failed) 项失败", privacy: .public) \
            exitCode=\(failed == 0 ? 0 : 1, privacy: .public)
            """)
        exit(failed == 0 ? 0 : 1)
    }
}
#endif
