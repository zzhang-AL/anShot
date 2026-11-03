//
//  CaptureDiagnostics+OCR.swift
//  AnShotUI
//
//  `-diagnoseOCR`：文字识别的端到端验证。
//
//  ── 为什么自己渲染测试图 ──────────────────────────────────
//
//  契约点名 OCR 的最高易错点是坐标转换（Vision 归一化 + 左下原点 → 模型像素 + 左上原点）。
//  要验证它，必须有**已知文字位置**的图：这里用 CoreText 把两行中文分别画在
//  图像的上半部与下半部，然后断言识别结果的包围盒落在对应的半边。
//  漏掉 y 翻转时，两行的包围盒会整体上下对调，这条断言立刻失败。
//
//  自己渲染还带来一个好处：不需要屏幕录制权限，也不需要网络。
//

#if DEBUG
import AnShotCapture
import AnShotCore
import AppKit
import CoreText

extension CaptureDiagnostics {

    static func runOCRDiagnostic() async {
        var failed = 0
        func report(_ label: String, _ measured: String, _ expected: String, _ ok: Bool) {
            if !ok { failed += 1 }
            logger.notice("""
                [ocr] \(label, privacy: .public) measured=\(measured, privacy: .public) \
                expected=\(expected, privacy: .public)  \(ok ? "MATCH" : "MISMATCH", privacy: .public)
                """)
        }

        // ── 能力查询（语言必须在运行时问，不能硬编码）──
        let availability = TextRecognizer.availability()
        logger.notice("""
            [ocr] 本机支持 \(availability.supportedLanguages.count, privacy: .public) 种语言，\
            含中文=\("\(availability.supportsChinese)", privacy: .public)，\
            本次选用=\(availability.preferredLanguages.joined(separator: ","), privacy: .public)
            """)
        report("本机支持中文识别", "\(availability.supportsChinese)", "true", availability.supportsChinese)
        report("至少支持一种语言", "\(availability.supportedLanguages.count)", "> 0", !availability.supportedLanguages.isEmpty)

        // ── 已知位置的测试图 ──
        guard let image = makeOCRTestImage() else {
            report("构造测试图", "nil", "非 nil", false)
            exit(1)
        }
        let half = Double(image.height) / 2

        do {
            let result = try await TextRecognizer.recognize(in: image)
            logger.notice("""
                [ocr] 识别 \(result.lines.count, privacy: .public) 行：\
                \(result.lines.map { "\($0.text)@y=\(Int($0.boundingBox.origin.y))" }.joined(separator: " | "), privacy: .public)
                """)

            report("识别到多行文字", "\(result.lines.count)", ">= 2", result.lines.count >= 2)
            report(
                "包围盒参照系为图像像素尺寸",
                "\(Int(result.imagePixelSize.width))x\(Int(result.imagePixelSize.height))",
                "\(image.width)x\(image.height)",
                Int(result.imagePixelSize.width) == image.width
                    && Int(result.imagePixelSize.height) == image.height
            )

            // ★ 坐标转换的核心断言：上半部的文字，包围盒必须落在上半部。
            let upper = result.lines.first { $0.text.contains("上半") }
            let lower = result.lines.first { $0.text.contains("下半") }
            report(
                "上半部文字识别到",
                upper.map { "y=\(Int($0.boundingBox.origin.y))" } ?? "nil",
                "非 nil 且 y < \(Int(half))",
                upper.map { $0.boundingBox.origin.y < half } ?? false
            )
            report(
                "下半部文字识别到",
                lower.map { "y=\(Int($0.boundingBox.origin.y))" } ?? "nil",
                "非 nil 且 y > \(Int(half))",
                lower.map { $0.boundingBox.origin.y > half } ?? false
            )
            report(
                "两行没有上下对调（y 翻转正确）",
                "上=\(upper.map { Int($0.boundingBox.origin.y) } ?? -1) 下=\(lower.map { Int($0.boundingBox.origin.y) } ?? -1)",
                "上 < 下",
                (upper.map(\.boundingBox.origin.y) ?? 0) < (lower.map(\.boundingBox.origin.y) ?? 0)
            )

            let candidatesPresent = result.lines.allSatisfy { !$0.candidates.isEmpty }
            report("每行都有备选结果", "\(candidatesPresent)", "true", candidatesPresent)
            let plain = result.plainText
            report("纯文本包含两行内容", "\(plain.count) 字符", "包含 上半/下半",
                   plain.contains("上半") && plain.contains("下半"))
            report(
                "阅读顺序为上→下",
                result.lines.map(\.text).joined(separator: "/"),
                "上半在前",
                result.lines.first?.text.contains("上半") ?? false
            )
        } catch {
            report("识别成功", "错误 \(error)", "无错误", false)
        }

        logger.notice("""
            [ocr] 汇总: \(failed == 0 ? "全部通过" : "\(failed) 项失败", privacy: .public) \
            exitCode=\(failed == 0 ? 0 : 1, privacy: .public)
            """)
        try? await Task.sleep(for: .milliseconds(300))
        exit(failed == 0 ? 0 : 1)
    }

    /// 渲染一张「上半部一行、下半部一行」的中文测试图。
    private static func makeOCRTestImage() -> CGImage? {
        let width = 700
        let height = 420
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        // 上下文原点在**左下**，所以「视觉上的上半部」对应较大的 y。
        func draw(_ text: String, topOffset: CGFloat, size: CGFloat) {
            let font = CTFontCreateWithName("PingFang SC" as CFString, size, nil)
            let attributes: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: CGColor(gray: 0.1, alpha: 1),
            ]
            let line = CTLineCreateWithAttributedString(
                NSAttributedString(string: text, attributes: attributes)
            )
            context.textPosition = CGPoint(x: 60, y: CGFloat(height) - topOffset - size)
            CTLineDraw(line, context)
        }
        draw("上半部分的中文文字", topOffset: 40, size: 34)
        draw("下半部分的中文文字", topOffset: 280, size: 34)

        return context.makeImage()
    }
}
#endif
