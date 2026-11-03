//
//  ColorPickerView.swift
//  AnShotUI
//
//  自绘取色器（P6 优化）。
//
//  ── 为什么不用系统 NSColorPanel ────────────────────────────
//
//  1. 它是共享窗口，在本应用（无 Dock 图标的菜单栏辅助程序）下
//     默认 `hidesOnDeactivate = true`，显示后立刻因「应用失活」自我隐藏：
//     `isVisible` 仍为 true，窗口却已被 order out。
//  2. 外观是系统浅色风格，与覆盖层的深色浮层不一致。
//
//  ── 设计取向：只留必要的东西 ──────────────────────────────
//
//  取色只需三件事，其余（色轮/色盘/蜡笔/色彩空间面板）都是负担：
//    - 正方形取色区：横轴饱和度、纵轴明度
//    - 竖向色相条
//    - Hex 输入 + 一排常用色卡
//
//  ── 一个容易忽略的细节 ────────────────────────────────────
//
//  当饱和度为 0（灰）或明度为 0（黑）时，色相在数学上无意义，
//  但**不能把它丢掉**：否则从纯黑拖到有彩色时会跳回红色。
//  因此色相单独保存在 `hue` 里，只有色相条被拖动时才更新。
//

import AppKit
import AnShotCore

/// 自绘取色器内容视图。
final class ColorPickerView: NSView {

    // MARK: - 对外接口

    /// 当前颜色。外部设置时只更新色相/饱和度/明度，不改动正在输入的文字。
    var color: RGBAColor = RGBAColor(r: 1, g: 0.23, b: 0.19, a: 1) {
        didSet {
            let hsv = color.hsv
            // 只在色相有意义时同步：灰度色的色相是 0，覆盖保存值会让色相条乱跳。
            if hsv.saturation > 0.0001, hsv.value > 0.0001 {
                hue = hsv.hue
            }
            syncHexField()
            needsDisplay = true
        }
    }

    /// 颜色变化回调（拖动过程中持续触发）。
    var onChange: ((RGBAColor) -> Void)?

    // MARK: - 内部状态

    /// 独立保存的色相（度）。见文件头说明：黑/灰时色相无意义但不能丢。
    private var hue: Double = 0

    /// 拖拽中的目标部位。
    private enum Tracking {
        case none
        case saturationValue
        case hue
    }

    private var tracking: Tracking = .none
    private var hoveredSwatch: Int?

    /// 常用色卡（两行）。
    private static let swatches: [RGBAColor] = [
        RGBAColor(r: 0.00, g: 0.00, b: 0.00, a: 1),
        RGBAColor(r: 0.42, g: 0.42, b: 0.45, a: 1),
        RGBAColor(r: 0.75, g: 0.75, b: 0.78, a: 1),
        RGBAColor(r: 1.00, g: 1.00, b: 1.00, a: 1),
        RGBAColor(r: 1.00, g: 0.23, b: 0.19, a: 1),
        RGBAColor(r: 1.00, g: 0.58, b: 0.00, a: 1),
        RGBAColor(r: 1.00, g: 0.80, b: 0.00, a: 1),
        RGBAColor(r: 0.20, g: 0.78, b: 0.35, a: 1),
        RGBAColor(r: 0.00, g: 0.48, b: 1.00, a: 1),
        RGBAColor(r: 0.35, g: 0.34, b: 0.84, a: 1),
        RGBAColor(r: 0.75, g: 0.35, b: 0.95, a: 1),
        RGBAColor(r: 0.90, g: 0.20, b: 0.50, a: 1),
    ]

    // MARK: - 布局常量

    private let inset: CGFloat = 12
    private let svSize = CGSize(width: 150, height: 110)
    private let hueBarWidth: CGFloat = 14
    private let hueBarGap: CGFloat = 8
    private let blockGap: CGFloat = 10
    private let hexFieldSize = CGSize(width: 92, height: 24)
    private let swatchSize: CGFloat = 12
    private let swatchGap: CGFloat = 3

    private var svRect: CGRect {
        CGRect(origin: CGPoint(x: inset, y: inset), size: svSize)
    }

    private var hueBarRect: CGRect {
        CGRect(
            x: inset + svSize.width + hueBarGap,
            y: inset,
            width: hueBarWidth,
            height: svSize.height
        )
    }

    private var hexFieldRect: CGRect {
        CGRect(
            x: inset,
            y: inset + svSize.height + blockGap,
            width: hexFieldSize.width,
            height: hexFieldSize.height
        )
    }

    /// 色卡网格：两行六列，排在输入框右侧。
    private func swatchRect(at index: Int) -> CGRect {
        let columns = 6
        let column = index % columns
        let row = index / columns
        let startX = hexFieldRect.maxX + 12
        let startY = hexFieldRect.midY - (swatchSize * 2 + swatchGap) / 2
        return CGRect(
            x: startX + CGFloat(column) * (swatchSize + swatchGap),
            y: startY + CGFloat(row) * (swatchSize + swatchGap),
            width: swatchSize,
            height: swatchSize
        )
    }

    /// 视图整体尺寸（由父级窗口使用）。
    static let preferredSize = CGSize(width: 208, height: 170)

    // MARK: - 子视图

    private lazy var hexField: NSTextField = {
        let field = NSTextField(frame: .zero)
        // 用自定义 cell 保证单行文字在框内严格垂直居中：
        // 默认 cell 会给文字留出自己的内边距，在自绘的底块里看起来偏上。
        field.cell = CenteredHexFieldCell(textCell: "")
        field.isBordered = false
        // 不让 AppKit 自己画底：处于编辑态时 field editor 会用系统浅色样式接管绘制，
        // 与深色面板撞成「浅底深字」。底色统一由本视图的 draw 负责。
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .monospacedSystemFont(ofSize: 12, weight: .medium)
        field.textColor = .white
        field.alignment = .center
        // 单行输入框的文字默认按 cell 内边距排版，这里压掉内边距让它在本视图
        // 画的底块里居中。
        field.cell?.usesSingleLineMode = true
        field.placeholderString = "RRGGBB"
        field.delegate = self
        return field
    }()

    override var isFlipped: Bool { true }

    /// 取色器本身接受第一响应者：打开面板时焦点应落在这里，
    /// 而不是直接跳进 Hex 输入框（那会让键盘看起来「黏」在输入框上）。
    override var acceptsFirstResponder: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        addSubview(hexField)
        syncHexField()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        hexField.frame = hexFieldRect
    }

    /// 是否正在编辑 Hex 输入框。
    ///
    /// 用显式标志而不是「是否存在 field editor」：面板成为 key window 后
    /// 输入框可能自动获得 field editor，那样判断会让十六进制值
    /// 在拖动取色区时永远不更新（实测踩过）。
    private var isEditingHex = false

    /// 把当前颜色的十六进制写进输入框——**仅在用户没在输入时**，
    /// 否则拖动取色区会把用户正在打的字顶掉。
    private func syncHexField() {
        guard !isEditingHex else { return }
        hexField.stringValue = color.hexString
    }

    // MARK: - 绘制

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }

        drawHexFieldBackground(in: context)
        drawSaturationValueArea(in: context)
        drawHueBar(in: context)
        drawSwatches(in: context)
    }

    /// 十六进制输入框的底：自绘圆角块，与整体风格一致。
    private func drawHexFieldBackground(in context: CGContext) {
        let rect = hexFieldRect
        let path = CGPath(
            roundedRect: rect,
            cornerWidth: 6,
            cornerHeight: 6,
            transform: nil
        )
        context.saveGState()
        context.setFillColor(NSColor.white.withAlphaComponent(0.10).cgColor)
        context.addPath(path)
        context.fillPath()
        context.setStrokeColor(NSColor.white.withAlphaComponent(0.14).cgColor)
        context.setLineWidth(1)
        context.addPath(path)
        context.strokePath()
        context.restoreGState()
    }

    /// 取色区：底色是纯色相，横向叠白、纵向叠黑。
    private func drawSaturationValueArea(in context: CGContext) {
        let rect = svRect
        let sRGB = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

        context.saveGState()
        // 圆角裁切让方块与整体风格一致。
        let clip = CGPath(
            roundedRect: rect,
            cornerWidth: 6,
            cornerHeight: 6,
            transform: nil
        )
        context.addPath(clip)
        context.clip()

        context.setFillColor(RGBAColor(hsv: HSVColor(hue: hue, saturation: 1, value: 1)).cgColor)
        context.fill(rect)

        // 横向：白 → 透明（饱和度）
        if let gradient = CGGradient(
            colorsSpace: sRGB,
            colors: [
                CGColor(red: 1, green: 1, blue: 1, alpha: 1),
                CGColor(red: 1, green: 1, blue: 1, alpha: 0),
            ] as CFArray,
            locations: [0, 1]
        ) {
            context.drawLinearGradient(
                gradient,
                start: CGPoint(x: rect.minX, y: rect.midY),
                end: CGPoint(x: rect.maxX, y: rect.midY),
                options: []
            )
        }

        // 纵向：透明 → 黑（明度）
        if let gradient = CGGradient(
            colorsSpace: sRGB,
            colors: [
                CGColor(red: 0, green: 0, blue: 0, alpha: 0),
                CGColor(red: 0, green: 0, blue: 0, alpha: 1),
            ] as CFArray,
            locations: [0, 1]
        ) {
            context.drawLinearGradient(
                gradient,
                start: CGPoint(x: rect.midX, y: rect.minY),
                end: CGPoint(x: rect.midX, y: rect.maxY),
                options: []
            )
        }
        context.restoreGState()

        // 指示器：白环 + 深色描边，深浅背景上都看得见。
        let hsv = color.hsv
        let point = CGPoint(
            x: rect.minX + CGFloat(hsv.saturation) * rect.width,
            y: rect.minY + (1 - CGFloat(hsv.value)) * rect.height
        )
        drawRingIndicator(at: point, radius: 7, in: context)
    }

    private func drawRingIndicator(at point: CGPoint, radius: CGFloat, in context: CGContext) {
        context.saveGState()
        context.setStrokeColor(NSColor.black.withAlphaComponent(0.35).cgColor)
        context.setLineWidth(3)
        context.strokeEllipse(in: CGRect(
            x: point.x - radius,
            y: point.y - radius,
            width: radius * 2,
            height: radius * 2
        ))
        context.setStrokeColor(NSColor.white.cgColor)
        context.setLineWidth(2)
        context.strokeEllipse(in: CGRect(
            x: point.x - radius,
            y: point.y - radius,
            width: radius * 2,
            height: radius * 2
        ))
        context.restoreGState()
    }

    /// 色相条：竖向彩虹 + 位置指示。
    private func drawHueBar(in context: CGContext) {
        let rect = hueBarRect
        let sRGB = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

        let stops: [CGColor] = stride(from: 0, through: 6, by: 1).map { step in
            let hueValue = Double(step) / 6
            return NSColor(
                hue: CGFloat(hueValue.truncatingRemainder(dividingBy: 1)),
                saturation: 1,
                brightness: 1,
                alpha: 1
            ).cgColor
        }

        context.saveGState()
        let clip = CGPath(
            roundedRect: rect,
            cornerWidth: rect.width / 2,
            cornerHeight: rect.width / 2,
            transform: nil
        )
        context.addPath(clip)
        context.clip()

        if let gradient = CGGradient(
            colorsSpace: sRGB,
            colors: stops as CFArray,
            locations: [0, 1.0 / 6, 2.0 / 6, 3.0 / 6, 4.0 / 6, 5.0 / 6, 1]
        ) {
            context.drawLinearGradient(
                gradient,
                start: CGPoint(x: rect.midX, y: rect.minY),
                end: CGPoint(x: rect.midX, y: rect.maxY),
                options: []
            )
        }
        context.restoreGState()

        // 指示：一条横贯色相条的白线 + 深色描边。
        let y = rect.minY + CGFloat(hue / 360) * rect.height
        let indicator = CGRect(x: rect.minX - 3, y: y - 1.5, width: rect.width + 6, height: 3)
        context.saveGState()
        let path = CGPath(
            roundedRect: indicator,
            cornerWidth: 1.5,
            cornerHeight: 1.5,
            transform: nil
        )
        context.setFillColor(NSColor.white.cgColor)
        context.addPath(path)
        context.fillPath()
        context.setStrokeColor(NSColor.black.withAlphaComponent(0.35).cgColor)
        context.setLineWidth(1)
        context.addPath(path)
        context.strokePath()
        context.restoreGState()
    }

    private func drawSwatches(in context: CGContext) {
        for (index, swatch) in Self.swatches.enumerated() {
            let rect = swatchRect(at: index)
            context.saveGState()
            context.setFillColor(swatch.cgColor)
            context.fillEllipse(in: rect)
            context.restoreGState()

            // 深色/白色圆点在深色底上需要描边才看得清边界。
            let isCurrent = swatch.hexString == color.hexString
            let isHovered = hoveredSwatch == index
            context.saveGState()
            context.setStrokeColor(
                (isCurrent || isHovered ? NSColor.white : NSColor.white.withAlphaComponent(0.28)).cgColor
            )
            context.setLineWidth(isCurrent ? 2 : 1)
            let outline = isCurrent
                ? rect.insetBy(dx: -3, dy: -3)
                : rect.insetBy(dx: 0.5, dy: 0.5)
            context.strokeEllipse(in: outline)
            context.restoreGState()
        }
    }

    // MARK: - 交互

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)

        if svRect.contains(point) {
            tracking = .saturationValue
            updateSaturationValue(at: point)
            return
        }

        if hueBarRect.insetBy(dx: -6, dy: 0).contains(point) {
            tracking = .hue
            updateHue(at: point)
            return
        }

        for index in Self.swatches.indices where swatchRect(at: index).insetBy(dx: -3, dy: -3).contains(point) {
            color = Self.swatches[index]
            onChange?(color)
            return
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        switch tracking {
        case .saturationValue: updateSaturationValue(at: point)
        case .hue: updateHue(at: point)
        case .none: break
        }
    }

    override func mouseUp(with event: NSEvent) {
        tracking = .none
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let hovered = Self.swatches.indices.first {
            swatchRect(at: $0).insetBy(dx: -3, dy: -3).contains(point)
        }
        guard hovered != hoveredSwatch else { return }
        hoveredSwatch = hovered
        needsDisplay = true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas {
            removeTrackingArea(area)
        }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways],
            owner: self,
            userInfo: nil
        ))
    }

    /// 取色区拖动：横轴饱和度、纵轴明度（上方更亮）。
    private func updateSaturationValue(at point: CGPoint) {
        let rect = svRect
        let saturation = min(max((point.x - rect.minX) / rect.width, 0), 1)
        let value = min(max(1 - (point.y - rect.minY) / rect.height, 0), 1)

        color = RGBAColor(hsv: HSVColor(
            hue: hue,
            saturation: Double(saturation),
            value: Double(value)
        ))
        onChange?(color)
    }

    /// 色相条拖动：只有这里会改色相。
    private func updateHue(at point: CGPoint) {
        let rect = hueBarRect
        let ratio = min(max((point.y - rect.minY) / rect.height, 0), 1)
        hue = Double(ratio) * 360

        let hsv = color.hsv
        color = RGBAColor(hsv: HSVColor(
            hue: hue,
            // 灰度（饱和度 0）时拖色相条应当直接变成有彩色，否则看起来没有反应。
            saturation: hsv.saturation > 0.0001 ? hsv.saturation : 1,
            value: hsv.value > 0.0001 ? hsv.value : 1
        ))
        onChange?(color)
    }
}

// MARK: - 十六进制输入

extension ColorPickerView: NSTextFieldDelegate {
    func controlTextDidBeginEditing(_ notification: Notification) {
        isEditingHex = true
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        isEditingHex = false
        applyHexField()
    }

    /// 回车与失焦都提交；输入非法时回退显示当前颜色，不弹窗打断。
    func control(
        _ control: NSControl,
        textView: NSTextView,
        doCommandBy commandSelector: Selector
    ) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            // 输入法组字中回车属于「确认候选词」，不能当成提交。
            if textView.hasMarkedText() {
                return false
            }
            applyHexField()
            window?.makeFirstResponder(nil)
            return true
        }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            syncHexField()
            window?.makeFirstResponder(nil)
            return true
        }
        return false
    }

    private func applyHexField() {
        guard let parsed = RGBAColor(hexString: hexField.stringValue) else {
            // 非法输入回退当前颜色：不弹窗、不打断，用户继续改就是了。
            syncHexField()
            return
        }
        color = parsed
        onChange?(color)
    }
}

// MARK: - 居中的输入框 cell

/// 让单行文字在输入框内严格垂直居中的 cell。
///
/// `NSTextField` 默认的 `drawingRect` 会按自身的内边距排版，
/// 在一个由外部自绘底块的输入框里，文字看起来会偏上一截。
private final class CenteredHexFieldCell: NSTextFieldCell {
    override func drawingRect(forBounds rect: NSRect) -> NSRect {
        let textHeight = cellSize(forBounds: rect).height
        var result = rect
        result.origin.y += max(0, (rect.height - textHeight) / 2)
        result.size.height = min(textHeight, rect.height)
        return result
    }

    override func titleRect(forBounds rect: NSRect) -> NSRect {
        drawingRect(forBounds: rect)
    }

    override func edit(
        withFrame rect: NSRect,
        in controlView: NSView,
        editor textObj: NSText,
        delegate: Any?,
        event: NSEvent?
    ) {
        super.edit(
            withFrame: drawingRect(forBounds: rect),
            in: controlView,
            editor: textObj,
            delegate: delegate,
            event: event
        )
    }

    override func select(
        withFrame rect: NSRect,
        in controlView: NSView,
        editor textObj: NSText,
        delegate: Any?,
        start selStart: Int,
        length selLength: Int
    ) {
        super.select(
            withFrame: drawingRect(forBounds: rect),
            in: controlView,
            editor: textObj,
            delegate: delegate,
            start: selStart,
            length: selLength
        )
    }
}
