//
//  CaptureDiagnostics+History.swift
//  AnShotUI
//
//  `-diagnoseHistory`：历史记录（M3-6）的验证。
//
//  ── 分工 ──────────────────────────────────────────────────
//
//  存储契约（只记路径、丢失不报错、上限淘汰、清空不动源文件）已由
//  AnShotCore 的 11 项单测覆盖。这里只验证**单测覆盖不到的两层**：
//
//  * 缩略图真的能从全尺寸图生成出来（涉及 CGContext 绘制，属 AnShotUI）；
//  * 面板能把这些条目渲染出来、能区分「文件还在」与「文件已丢失」、
//    并且 AppDelegate 的保存回调确实接上了（单测看不到接线）。
//
//  用临时目录，绝不碰用户真实的历史记录。
//

#if DEBUG
import AnShotCapture
import AnShotCore
import AppKit

extension CaptureDiagnostics {

    static func runHistoryDiagnostic() async {
        var failed = 0
        func report(_ label: String, _ measured: String, _ expected: String, _ ok: Bool) {
            if !ok { failed += 1 }
            logger.notice("""
                [history] \(label, privacy: .public) measured=\(measured, privacy: .public) \
                expected=\(expected, privacy: .public)  \(ok ? "MATCH" : "MISMATCH", privacy: .public)
                """)
        }

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("anshot-history-diag-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        func makeImage(width: Int, height: Int) -> CGImage? {
            guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
                  let context = CGContext(
                      data: nil, width: width, height: height,
                      bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace,
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                  ) else { return nil }
            context.setFillColor(CGColor(red: 0.9, green: 0.3, blue: 0.2, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            context.fill(CGRect(x: 20, y: 20, width: width / 2, height: height / 3))
            return context.makeImage()
        }

        guard let image = makeImage(width: 1600, height: 1000) else {
            report("构造测试图", "nil", "非 nil", false)
            exit(1)
        }

        // ① 缩略图生成：能解码回来，且尺寸按 maxWidth 缩到位。
        let thumbnail = HistoryThumbnail.makePNG(from: image, maxWidth: 180, scale: 2)
        let decoded = thumbnail.flatMap { NSImage(data: $0) }
        report("缩略图生成成功", "\(thumbnail?.count ?? 0) 字节", "> 0", (thumbnail?.count ?? 0) > 0)
        report("缩略图可解码", "\(decoded != nil)", "true", decoded != nil)
        if let rep = decoded?.representations.first {
            // 1600 宽缩到 180 逻辑点、2x = 360 像素。
            report("缩略图尺寸按 maxWidth 收敛",
                   "\(rep.pixelsWide)x\(rep.pixelsHigh)", "约 360x225",
                   abs(rep.pixelsWide - 360) <= 2 && abs(rep.pixelsHigh - 225) <= 2)
        }

        // ② 写入历史并渲染面板。
        let store = HistoryStore(directory: root)
        let presentFile = root.appendingPathComponent("present.png")
        try? Data(repeating: 0xEE, count: 1024).write(to: presentFile)
        let missingFile = root.appendingPathComponent("missing.png")
        try? Data(repeating: 0xEE, count: 1024).write(to: missingFile)

        store.add(fileURL: presentFile, thumbnailPNG: thumbnail, pixelWidth: 1600, pixelHeight: 1000)
        store.add(fileURL: missingFile, thumbnailPNG: thumbnail, pixelWidth: 800, pixelHeight: 600)
        // 把第二条的源文件移走，模拟用户自己整理文件夹。
        try? FileManager.default.removeItem(at: missingFile)

        let panel = HistoryPanel(store: store)
        panel.show(store.entries)
        try? await Task.sleep(for: .milliseconds(600))

        report("面板已打开", "\(panel.isVisible)", "true", panel.isVisible)
        report("面板列出全部条目", "\(panel.debugRowCountForDiagnostics)", "2",
               panel.debugRowCountForDiagnostics == 2)
        report("区分文件仍在与已丢失",
               "present=\(panel.debugPresentCountForDiagnostics) missing=\(panel.debugMissingCountForDiagnostics)",
               "present=1 missing=1",
               panel.debugPresentCountForDiagnostics == 1 && panel.debugMissingCountForDiagnostics == 1)
        report("摘要文案反映了丢失情况",
               panel.debugSummaryForDiagnostics, "含「文件已移走」",
               panel.debugSummaryForDiagnostics.contains("文件已移走"))

        // ③ 清空：只清列表，不动源文件。
        store.clear()
        panel.refresh(store.entries)
        try? await Task.sleep(for: .milliseconds(300))
        report("清空后条目为空", "\(panel.debugRowCountForDiagnostics)", "0",
               panel.debugRowCountForDiagnostics == 0)
        report("清空不动源文件", "\(FileManager.default.fileExists(atPath: presentFile.path))", "true",
               FileManager.default.fileExists(atPath: presentFile.path))
        panel.hide()

        // ④ 接线：单测看不到这一层——AppDelegate 必须真的挂上了保存回调，
        //    否则「保存了截图却不出现在历史里」这个缺陷在单测里永远绿。
        if let delegate = NSApp.delegate as? AppDelegate {
            report("AppDelegate 已挂保存回调",
                   "\(delegate.overlayControllerForDiagnosticsHasSavedHandler)",
                   "true",
                   delegate.overlayControllerForDiagnosticsHasSavedHandler)
            report("历史存储已就绪",
                   "\(delegate.historyStoreForDiagnostics.maximumEntries)",
                   "> 0",
                   delegate.historyStoreForDiagnostics.maximumEntries > 0)
        } else {
            report("AppDelegate 可用", "\(NSApp.delegate == nil ? "nil" : "非 AppDelegate")", "AppDelegate", false)
        }

        try? FileManager.default.removeItem(at: root)
        logger.notice("""
            [history] 汇总: \(failed == 0 ? "全部通过" : "\(failed) 项失败", privacy: .public) \
            exitCode=\(failed == 0 ? 0 : 1, privacy: .public)
            """)
        try? await Task.sleep(for: .milliseconds(300))
        exit(failed == 0 ? 0 : 1)
    }
}
#endif
