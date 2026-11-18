//
//  CoordinateGridRenderer.swift
//  AnShotAutomation
//
//  在导出图像上叠加逻辑点坐标标尺与辅助网格，辅助 AI Agent 精确定位点击与裁切坐标。
//

import CoreGraphics
import CoreText
import Foundation

/// 逻辑点坐标网格渲染器。
enum CoordinateGridRenderer {

    /// 在给定图像上绘制逻辑点坐标标尺与网格。
    ///
    /// - Parameters:
    ///   - image: 已经过最终缩放的目标图像。
    ///   - logicalOrigin: 图像左上角对应的逻辑点坐标原点。
    ///   - logicalSize: 图像覆盖的逻辑点尺寸。
    /// - Returns: 叠加网格后的新图像；无法创建绘图上下文时回退原图。
    static func render(
        on image: CGImage,
        logicalOrigin: CGPoint,
        logicalSize: CGSize
    ) -> CGImage {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0,
              logicalSize.width > 0, logicalSize.height > 0,
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil,
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bytesPerRow: 0,
                  space: colorSpace,
                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                      | CGBitmapInfo.byteOrder32Little.rawValue
              ) else {
            return image
        }

        // 先以标准 CoreGraphics 左下原点绘制原始位图。
        let imageRect = CGRect(x: 0, y: 0, width: width, height: height)
        context.draw(image, in: imageRect)

        // 切换为左上原点坐标系，便于与逻辑点坐标一致地计算位置。
        context.saveGState()
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)

        let scaleX = CGFloat(width) / logicalSize.width
        let scaleY = CGFloat(height) / logicalSize.height
        let step = chooseStep(pixelsPerPoint: min(scaleX, scaleY))

        // 绘制半透明纵向与横向辅助线。
        drawGridLines(
            in: context,
            imageSize: CGSize(width: width, height: height),
            logicalOrigin: logicalOrigin,
            logicalSize: logicalSize,
            scaleX: scaleX,
            scaleY: scaleY,
            step: step
        )

        // 绘制顶部与左侧边缘标尺条与刻度数字。
        drawRulerLabels(
            in: context,
            imageSize: CGSize(width: width, height: height),
            logicalOrigin: logicalOrigin,
            logicalSize: logicalSize,
            scaleX: scaleX,
            scaleY: scaleY,
            step: step
        )

        context.restoreGState()
        return context.makeImage() ?? image
    }

    /// 根据当前图像每逻辑点对应的输出像素数，选择不拥挤的整数逻辑点步长。
    static func chooseStep(pixelsPerPoint: CGFloat) -> CGFloat {
        let candidates: [CGFloat] = [25, 50, 100, 200, 250, 500, 1000]
        let minimumPixelSpacing: CGFloat = 72
        for candidate in candidates {
            if candidate * pixelsPerPoint >= minimumPixelSpacing {
                return candidate
            }
        }
        return 1000
    }

    private static func drawGridLines(
        in context: CGContext,
        imageSize: CGSize,
        logicalOrigin: CGPoint,
        logicalSize: CGSize,
        scaleX: CGFloat,
        scaleY: CGFloat,
        step: CGFloat
    ) {
        let minorColor = CGColor(red: 0.0, green: 0.85, blue: 1.0, alpha: 0.25)
        let majorColor = CGColor(red: 0.0, green: 0.85, blue: 1.0, alpha: 0.45)

        let startX = (logicalOrigin.x / step).rounded(.up) * step
        let endX = logicalOrigin.x + logicalSize.width
        var x = startX
        while x < endX {
            let px = ((x - logicalOrigin.x) * scaleX).rounded() + 0.5
            let isMajor = Int(x.rounded()) % Int(step * 2) == 0
            context.setStrokeColor(isMajor ? majorColor : minorColor)
            context.setLineWidth(1)
            context.move(to: CGPoint(x: px, y: 0))
            context.addLine(to: CGPoint(x: px, y: imageSize.height))
            context.strokePath()
            x += step
        }

        let startY = (logicalOrigin.y / step).rounded(.up) * step
        let endY = logicalOrigin.y + logicalSize.height
        var y = startY
        while y < endY {
            let py = ((y - logicalOrigin.y) * scaleY).rounded() + 0.5
            let isMajor = Int(y.rounded()) % Int(step * 2) == 0
            context.setStrokeColor(isMajor ? majorColor : minorColor)
            context.setLineWidth(1)
            context.move(to: CGPoint(x: 0, y: py))
            context.addLine(to: CGPoint(x: imageSize.width, y: py))
            context.strokePath()
            y += step
        }
    }

    private static func drawRulerLabels(
        in context: CGContext,
        imageSize: CGSize,
        logicalOrigin: CGPoint,
        logicalSize: CGSize,
        scaleX: CGFloat,
        scaleY: CGFloat,
        step: CGFloat
    ) {
        let fontSize = max(10, min(13, min(imageSize.width, imageSize.height) * 0.016))
        let font = CTFontCreateWithName("Menlo-Bold" as CFString, fontSize, nil)

        let startX = (logicalOrigin.x / step).rounded(.up) * step
        let endX = logicalOrigin.x + logicalSize.width
        var x = startX
        while x < endX - step * 0.25 {
            let px = (x - logicalOrigin.x) * scaleX
            if px >= 36 && px <= imageSize.width - 36 {
                drawBadge(
                    text: "\(Int(x.rounded()))",
                    atTopLeft: CGPoint(x: px + 2, y: 3),
                    font: font,
                    in: context
                )
            }
            x += step
        }

        let startY = (logicalOrigin.y / step).rounded(.up) * step
        let endY = logicalOrigin.y + logicalSize.height
        var y = startY
        while y < endY - step * 0.25 {
            let py = (y - logicalOrigin.y) * scaleY
            if py >= 24 && py <= imageSize.height - 20 {
                drawBadge(
                    text: "\(Int(y.rounded()))",
                    atTopLeft: CGPoint(x: 3, y: py + 2),
                    font: font,
                    in: context
                )
            }
            y += step
        }

        // 左上角标注原点坐标与单位。
        let originLabel = "pt(\(Int(logicalOrigin.x.rounded())),\(Int(logicalOrigin.y.rounded())))"
        drawBadge(text: originLabel, atTopLeft: CGPoint(x: 3, y: 3), font: font, in: context)
    }

    private static func drawBadge(
        text: String,
        atTopLeft point: CGPoint,
        font: CTFont,
        in context: CGContext
    ) {
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(
                red: 0.92, green: 0.98, blue: 1.0, alpha: 1.0
            )
        ]
        let attributed = NSAttributedString(string: text, attributes: attributes)
        let line = CTLineCreateWithAttributedString(attributed)
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        var leading: CGFloat = 0
        let textWidth = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
        let paddingX: CGFloat = 4
        let paddingY: CGFloat = 2
        let box = CGRect(
            x: point.x,
            y: point.y,
            width: ceil(textWidth) + paddingX * 2,
            height: ceil(ascent + descent) + paddingY * 2
        )

        context.saveGState()
        let bgPath = CGPath(roundedRect: box, cornerWidth: 3, cornerHeight: 3, transform: nil)
        context.setFillColor(CGColor(red: 0.05, green: 0.08, blue: 0.12, alpha: 0.78))
        context.addPath(bgPath)
        context.fillPath()

        // 局部翻转回 CoreText 需要的正向文字坐标系（左下原点）后再绘制。
        context.translateBy(x: box.minX + paddingX, y: box.maxY - paddingY - descent)
        context.scaleBy(x: 1, y: -1)
        context.textPosition = .zero
        CTLineDraw(line, context)
        context.restoreGState()
    }
}
