//
//  OverlayLoupeView.swift
//  AnShotUI
//
//  覆盖层像素放大镜（Loupe）：跟随光标实时放大采样 8x 像素网格，
//  展示像素坐标与 HEX / RGB 色值，支持候选态按 C 键复制色号。
//

import AnShotCore
import AppKit
import CoreText

/// 单次光标像素采样结果。
struct LoupeSample: Equatable {
    /// 光标命中的底图像素坐标（整数像素位置）。
    let pixelX: Int
    let pixelY: Int
    /// 中心像素的 sRGB 颜色。
    let color: RGBAColor
    /// `#RRGGBB` 大写十六进制色值。
    let hexString: String
    /// `RGB(r, g, b)` 文本。
    let rgbText: String
    /// 周围像素网格位图（边长为 `gridSize × gridSize`）。
    let gridImage: CGImage
    /// 采样网格单边像素数（奇数，中心为目标像素）。
    let gridSize: Int

    static func == (lhs: LoupeSample, rhs: LoupeSample) -> Bool {
        lhs.pixelX == rhs.pixelX
            && lhs.pixelY == rhs.pixelY
            && lhs.hexString == rhs.hexString
            && lhs.gridSize == rhs.gridSize
    }
}

/// 像素采样与避让几何计算（纯逻辑，便于单元测试）。
enum OverlayLoupeSampler {

    /// 默认采样半径：7 → 15×15 网格（放大到 120×120pt 即 8x 像素格）。
    static let defaultGridRadius = 7

    /// 放大镜浮层默认逻辑尺寸：提供 152pt 内容宽，彻底容纳 4K 四位坐标与 RGB/快捷键提示不碰撞。
    static let defaultPanelSize = CGSize(width: 172, height: 204)

    /// 静态缓存 sRGB 色彩空间，避免 120Hz 鼠标移动时每帧重复查找创建。
    private static let sRGBColorSpace: CGColorSpace =
        CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

    /// 将视图逻辑点换算为钳制在底图范围内的整数像素坐标。
    static func pixelCoordinate(
        for viewPoint: CGPoint,
        scaleFactor: CGFloat,
        backdropWidth: Int,
        backdropHeight: Int
    ) -> (x: Int, y: Int)? {
        guard backdropWidth > 0, backdropHeight > 0, scaleFactor > 0 else {
            return nil
        }
        let rawX = Int((viewPoint.x * scaleFactor).rounded(.down))
        let rawY = Int((viewPoint.y * scaleFactor).rounded(.down))
        return (
            min(max(rawX, 0), backdropWidth - 1),
            min(max(rawY, 0), backdropHeight - 1)
        )
    }

    /// 从底图采集指定视图逻辑点处的像素邻域与色值。
    static func sample(
        from backdrop: CGImage,
        at viewPoint: CGPoint,
        scaleFactor: CGFloat,
        gridRadius: Int = defaultGridRadius
    ) -> LoupeSample? {
        guard gridRadius >= 1,
              let coord = pixelCoordinate(
                  for: viewPoint,
                  scaleFactor: scaleFactor,
                  backdropWidth: backdrop.width,
                  backdropHeight: backdrop.height
              ) else {
            return nil
        }

        let pixelX = coord.x
        let pixelY = coord.y

        let gridSize = gridRadius * 2 + 1
        let colorSpace = sRGBColorSpace
        var buffer = [UInt8](repeating: 0, count: gridSize * gridSize * 4)
        let bytesPerRow = gridSize * 4

        guard let context = CGContext(
            data: &buffer,
            width: gridSize,
            height: gridSize,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        ) else {
            return nil
        }

        // 边缘出界部分保持纯黑底，内部与源底图 1:1 像素对齐。
        context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: gridSize, height: gridSize))
        context.interpolationQuality = .none

        // 源底图左上原点区域 `[pixelX - gridRadius, pixelY - gridRadius, gridSize, gridSize]`
        let srcLeft = pixelX - gridRadius
        let srcTop = pixelY - gridRadius
        let srcRect = CGRect(x: srcLeft, y: srcTop, width: gridSize, height: gridSize)
        let imageBounds = CGRect(x: 0, y: 0, width: backdrop.width, height: backdrop.height)
        let validRect = srcRect.intersection(imageBounds)

        if !validRect.isNull, !validRect.isEmpty,
           let cropped = backdrop.cropping(to: validRect) {
            // `context` 是左下原点：顶部行 `srcTop` 对应 CGContext 顶边 `y = gridSize`。
            let destX = validRect.minX - CGFloat(srcLeft)
            let destY = CGFloat(srcTop + gridSize) - validRect.maxY
            context.draw(
                cropped,
                in: CGRect(x: destX, y: destY, width: validRect.width, height: validRect.height)
            )
        }

        guard let gridImage = context.makeImage() else {
            return nil
        }

        // 缓冲区第 0 行在顶部：中心像素位于 `(gridRadius, gridRadius)`。
        let centerOffset = (gridRadius * gridSize + gridRadius) * 4
        let rByte = buffer[centerOffset]
        let gByte = buffer[centerOffset + 1]
        let bByte = buffer[centerOffset + 2]

        let color = RGBAColor(
            r: Double(rByte) / 255.0,
            g: Double(gByte) / 255.0,
            b: Double(bByte) / 255.0,
            a: 1.0
        )
        let hexString = String(format: "#%02X%02X%02X", rByte, gByte, bByte)
        let rgbText = "RGB(\(rByte), \(gByte), \(bByte))"

        return LoupeSample(
            pixelX: pixelX,
            pixelY: pixelY,
            color: color,
            hexString: hexString,
            rgbText: rgbText,
            gridImage: gridImage,
            gridSize: gridSize
        )
    }

    /// 计算放大镜在视图内的四角避让落点，确保不遮挡光标且不越界。
    static func panelFrame(
        forCursor cursorPoint: CGPoint,
        panelSize: CGSize,
        in viewBounds: CGRect,
        safeTopInset: CGFloat = 0
    ) -> CGRect {
        let offset: CGFloat = 18
        let margin: CGFloat = 8
        let minTop = viewBounds.minY + max(margin, safeTopInset + margin)

        var x = cursorPoint.x + offset
        if x + panelSize.width > viewBounds.maxX - margin {
            x = cursorPoint.x - panelSize.width - offset
        }
        x = min(max(viewBounds.minX + margin, x), max(viewBounds.minX + margin, viewBounds.maxX - panelSize.width - margin))

        var y = cursorPoint.y + offset
        if y + panelSize.height > viewBounds.maxY - margin {
            y = cursorPoint.y - panelSize.height - offset
        }
        y = min(max(minTop, y), max(minTop, viewBounds.maxY - panelSize.height - margin))

        return CGRect(origin: CGPoint(x: x, y: y), size: panelSize)
    }
}

/// 覆盖层上的非交互像素放大镜视图。
final class OverlayLoupeView: NSView {

    nonisolated static var panelSize: CGSize { OverlayLoupeSampler.defaultPanelSize }
    private static let previewSize: CGFloat = 152
    private static let previewInset: CGFloat = 10

    // 静态缓存纯 CoreText 字体与颜色，避免高频重绘时每帧创建 NSFont / 触发 AppKit NSString.size(withAttributes:)
    // 在 macOS 27 CoreText TAttributes::ApplyFont → initWithDictionary:copyItems: 路径下的 nil 崩溃。
    private static let hexFont: CTFont = NSFont.monospacedSystemFont(ofSize: 10.5, weight: .semibold) as CTFont
    private static let coordFont: CTFont = NSFont.monospacedDigitSystemFont(ofSize: 9.5, weight: .regular) as CTFont
    private static let rgbFont: CTFont = NSFont.monospacedDigitSystemFont(ofSize: 9.5, weight: .regular) as CTFont
    private static let hintFont: CTFont = NSFont.systemFont(ofSize: 9.5, weight: .medium) as CTFont

    private static let whiteColor: CGColor = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
    private static let coordColor: CGColor = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.68)
    private static let rgbColor: CGColor = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.78)
    private static let hintColor: CGColor = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.58)

    /// 构造纯 CoreText `CTLine`（使用 `CFAttributedString` 绕开 AppKit `NSCoreTypesetter` 字典深拷贝崩溃）。
    private static func makeLine(_ text: String, font: CTFont, color: CGColor) -> (line: CTLine, width: CGFloat, ascent: CGFloat) {
        let cfText = text as CFString
        let attrStr = CFAttributedStringCreateMutable(kCFAllocatorDefault, 0)!
        CFAttributedStringReplaceString(attrStr, CFRange(location: 0, length: 0), cfText)
        let range = CFRange(location: 0, length: CFAttributedStringGetLength(attrStr))
        CFAttributedStringSetAttribute(attrStr, range, kCTFontAttributeName, font)
        CFAttributedStringSetAttribute(attrStr, range, kCTForegroundColorAttributeName, color)
        let line = CTLineCreateWithAttributedString(attrStr)
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        var leading: CGFloat = 0
        let width = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
        return (line, width, ascent)
    }

    /// 在翻转坐标系（左上原点）的 `CGContext` 中绘制纯 CoreText `CTLine`。
    private static func drawLine(
        _ line: CTLine,
        atTopLeft origin: CGPoint,
        ascent: CGFloat,
        in context: CGContext
    ) {
        context.saveGState()
        // 视图为 isFlipped = true，设置 y 轴翻转文本矩阵以正向绘制字形。
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        context.textPosition = CGPoint(x: origin.x, y: origin.y + ascent)
        CTLineDraw(line, context)
        context.restoreGState()
    }

    private var sample: LoupeSample?
    private var showsCopyHint = true

    override var isFlipped: Bool { true }

    /// 鼠标完全穿透，不拦截任何覆盖层事件。
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func update(
        sample: LoupeSample?,
        cursorPoint: CGPoint,
        viewBounds: CGRect,
        safeTopInset: CGFloat = 0,
        showsCopyHint: Bool
    ) {
        guard let sample else {
            isHidden = true
            self.sample = nil
            return
        }
        let contentChanged: Bool = {
            guard let prev = self.sample else { return true }
            return prev.pixelX != sample.pixelX
                || prev.pixelY != sample.pixelY
                || prev.hexString != sample.hexString
                || prev.rgbText != sample.rgbText
                || prev.gridSize != sample.gridSize
                || prev.gridImage !== sample.gridImage
                || self.showsCopyHint != showsCopyHint
        }()
        let wasHidden = isHidden
        self.sample = sample
        self.showsCopyHint = showsCopyHint
        let targetFrame = OverlayLoupeSampler.panelFrame(
            forCursor: cursorPoint,
            panelSize: Self.panelSize,
            in: viewBounds,
            safeTopInset: safeTopInset
        )
        if frame != targetFrame {
            frame = targetFrame
        }
        if wasHidden {
            isHidden = false
        }
        if contentChanged || wasHidden {
            needsDisplay = true
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let sample, let context = NSGraphicsContext.current?.cgContext else { return }

        // 1. 深色圆角底板与外框描边
        let cardPath = CGPath(
            roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
            cornerWidth: 10,
            cornerHeight: 10,
            transform: nil
        )
        context.saveGState()
        context.setFillColor(NSColor.black.withAlphaComponent(0.88).cgColor)
        context.addPath(cardPath)
        context.fillPath()
        context.setStrokeColor(NSColor.white.withAlphaComponent(0.18).cgColor)
        context.setLineWidth(1)
        context.addPath(cardPath)
        context.strokePath()
        context.restoreGState()

        // 2. 8x 像素网格区
        let previewRect = CGRect(
            x: Self.previewInset,
            y: Self.previewInset,
            width: Self.previewSize,
            height: Self.previewSize
        )
        let previewPath = CGPath(
            roundedRect: previewRect,
            cornerWidth: 6,
            cornerHeight: 6,
            transform: nil
        )

        context.saveGState()
        context.addPath(previewPath)
        context.clip()
        context.translateBy(x: 0, y: previewRect.minY + previewRect.maxY)
        context.scaleBy(x: 1, y: -1)
        context.interpolationQuality = .none
        context.draw(sample.gridImage, in: previewRect)
        context.restoreGState()

        // 像素网格线
        let cellSize = Self.previewSize / CGFloat(sample.gridSize)
        context.saveGState()
        context.addPath(previewPath)
        context.clip()
        context.setStrokeColor(NSColor.white.withAlphaComponent(0.12).cgColor)
        context.setLineWidth(0.5)
        for index in 1 ..< sample.gridSize {
            let offset = CGFloat(index) * cellSize
            context.move(to: CGPoint(x: previewRect.minX + offset, y: previewRect.minY))
            context.addLine(to: CGPoint(x: previewRect.minX + offset, y: previewRect.maxY))
            context.move(to: CGPoint(x: previewRect.minX, y: previewRect.minY + offset))
            context.addLine(to: CGPoint(x: previewRect.maxX, y: previewRect.minY + offset))
        }
        context.strokePath()

        // 中心像素高亮方框
        let centerIndex = CGFloat(sample.gridSize / 2)
        let centerRect = CGRect(
            x: previewRect.minX + centerIndex * cellSize,
            y: previewRect.minY + centerIndex * cellSize,
            width: cellSize,
            height: cellSize
        )
        context.setStrokeColor(NSColor.black.withAlphaComponent(0.8).cgColor)
        context.setLineWidth(2)
        context.stroke(centerRect)
        context.setStrokeColor(NSColor.white.cgColor)
        context.setLineWidth(1)
        context.stroke(centerRect)
        context.restoreGState()

        // 预览框边线
        context.saveGState()
        context.setStrokeColor(NSColor.white.withAlphaComponent(0.22).cgColor)
        context.setLineWidth(1)
        context.addPath(previewPath)
        context.strokePath()
        context.restoreGState()

        // 3. 信息栏：第 1 行色块 + #HEX + 右对齐像素坐标；第 2 行 RGB + 右对齐 C/⇧C 提示
        let infoTop = previewRect.maxY + 7
        let swatchRect = CGRect(x: Self.previewInset, y: infoTop + 2, width: 10, height: 10)
        context.saveGState()
        context.setFillColor(sample.color.cgColor)
        context.fillEllipse(in: swatchRect)
        context.setStrokeColor(NSColor.white.withAlphaComponent(0.45).cgColor)
        context.setLineWidth(0.75)
        context.strokeEllipse(in: swatchRect)
        context.restoreGState()

        let hexOriginX = swatchRect.maxX + 5
        let hex = Self.makeLine(sample.hexString, font: Self.hexFont, color: Self.whiteColor)
        Self.drawLine(hex.line, atTopLeft: CGPoint(x: hexOriginX, y: infoTop), ascent: hex.ascent, in: context)

        let coordText = "(\(sample.pixelX), \(sample.pixelY))"
        let coord = Self.makeLine(coordText, font: Self.coordFont, color: Self.coordColor)
        let coordX = max(hexOriginX + hex.width + 4, bounds.width - Self.previewInset - coord.width)
        Self.drawLine(coord.line, atTopLeft: CGPoint(x: coordX, y: infoTop + 1), ascent: coord.ascent, in: context)

        let rgb = Self.makeLine(sample.rgbText, font: Self.rgbFont, color: Self.rgbColor)
        Self.drawLine(rgb.line, atTopLeft: CGPoint(x: Self.previewInset, y: infoTop + 18), ascent: rgb.ascent, in: context)

        if showsCopyHint {
            let hint = Self.makeLine("C / ⇧C", font: Self.hintFont, color: Self.hintColor)
            let hintX = bounds.width - Self.previewInset - hint.width
            Self.drawLine(hint.line, atTopLeft: CGPoint(x: hintX, y: infoTop + 18), ascent: hint.ascent, in: context)
        }
    }
}
