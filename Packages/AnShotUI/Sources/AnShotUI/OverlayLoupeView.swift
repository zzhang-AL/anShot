//
//  OverlayLoupeView.swift
//  AnShotUI
//
//  覆盖层像素放大镜（Loupe）：跟随光标实时放大采样 8x 像素网格，
//  展示像素坐标与 HEX / RGB 色值，支持候选态按 C 键复制色号。
//

import AnShotCore
import AppKit

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

    /// 从底图采集指定视图逻辑点处的像素邻域与色值。
    static func sample(
        from backdrop: CGImage,
        at viewPoint: CGPoint,
        scaleFactor: CGFloat,
        gridRadius: Int = defaultGridRadius
    ) -> LoupeSample? {
        guard backdrop.width > 0, backdrop.height > 0, scaleFactor > 0, gridRadius >= 1 else {
            return nil
        }

        let rawX = Int((viewPoint.x * scaleFactor).rounded(.down))
        let rawY = Int((viewPoint.y * scaleFactor).rounded(.down))
        let pixelX = min(max(rawX, 0), backdrop.width - 1)
        let pixelY = min(max(rawY, 0), backdrop.height - 1)

        let gridSize = gridRadius * 2 + 1
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
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
        self.sample = sample
        self.showsCopyHint = showsCopyHint
        frame = OverlayLoupeSampler.panelFrame(
            forCursor: cursorPoint,
            panelSize: Self.panelSize,
            in: viewBounds,
            safeTopInset: safeTopInset
        )
        isHidden = false
        needsDisplay = true
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

        let hexAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 10.5, weight: .semibold),
            .foregroundColor: NSColor.white,
        ]
        let hexOriginX = swatchRect.maxX + 5
        let hexSize = (sample.hexString as NSString).size(withAttributes: hexAttrs)
        (sample.hexString as NSString).draw(
            at: CGPoint(x: hexOriginX, y: infoTop),
            withAttributes: hexAttrs
        )

        let coordText = "(\(sample.pixelX), \(sample.pixelY))"
        let coordAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 9.5, weight: .regular),
            .foregroundColor: NSColor.white.withAlphaComponent(0.68),
        ]
        let coordSize = (coordText as NSString).size(withAttributes: coordAttrs)
        let coordX = max(hexOriginX + hexSize.width + 4, bounds.width - Self.previewInset - coordSize.width)
        (coordText as NSString).draw(
            at: CGPoint(x: coordX, y: infoTop + 1),
            withAttributes: coordAttrs
        )

        let rgbAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 9.5, weight: .regular),
            .foregroundColor: NSColor.white.withAlphaComponent(0.78),
        ]
        (sample.rgbText as NSString).draw(
            at: CGPoint(x: Self.previewInset, y: infoTop + 18),
            withAttributes: rgbAttrs
        )

        if showsCopyHint {
            let hintText = "C / ⇧C"
            let hintAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedSystemFont(ofSize: 9, weight: .medium),
                .foregroundColor: NSColor.white.withAlphaComponent(0.58),
            ]
            let hintSize = (hintText as NSString).size(withAttributes: hintAttrs)
            (hintText as NSString).draw(
                at: CGPoint(x: bounds.width - Self.previewInset - hintSize.width, y: infoTop + 18.5),
                withAttributes: hintAttrs
            )
        }
    }
}
