//
//  SettingsButtonStyles.swift
//  AnShotUI
//
//  设置窗口的按钮样式：选项按钮、侧栏项、主要按钮、附件按钮。
//
//  四者的差别只在形制（分段控件 / 侧栏行 / 强调按钮 / 图标按钮），
//  共同点是都继承 `NSButton` 并自绘外观，设计令牌见 `SettingsTheme.swift`。
//
import AppKit

/// 一个可选的「卡片式」选项。
///
/// 继承 `NSButton` 而不是 `NSView`：键盘激活、辅助功能角色、
/// 焦点环、`state` 语义都由 AppKit 负责，这些自己实现一遍只会更容易出错。
/// 这里只把绘制换掉。
final class SettingsOptionButton: NSButton {

    struct Model {
        let symbolName: String
        let title: String
        let subtitle: String
    }

    var model: Model {
        didSet { needsDisplay = true }
    }

    private var isHovered = false
    private var trackingArea: NSTrackingArea?

    init(model: Model, target: AnyObject?, action: Selector) {
        self.model = model
        super.init(frame: .zero)
        self.target = target
        self.action = action
        translatesAutoresizingMaskIntoConstraints = false
        // 关掉系统外观，全部自绘；但保留 NSButton 的交互与无障碍语义。
        isBordered = false
        setButtonType(.toggle)
        focusRingType = .default
        toolTip = "\(model.title)：\(model.subtitle)"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("不支持从 nib 构造")
    }

    override var isFlipped: Bool { true }

    override var intrinsicContentSize: NSSize {
        NSSize(width: 244, height: 62)
    }

    // MARK: 悬停

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow],
            owner: self
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        needsDisplay = true
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    // MARK: 焦点环

    // 自绘视图需要显式告诉 AppKit 焦点环画在哪，
    // 否则键盘 Tab 到这一项时屏幕上没有任何指示。
    override func drawFocusRingMask() {
        NSBezierPath(
            roundedRect: bounds.insetBy(dx: 1, dy: 1),
            xRadius: SettingsTheme.optionRadius,
            yRadius: SettingsTheme.optionRadius
        ).fill()
    }

    override var focusRingMaskBounds: NSRect { bounds }

    // MARK: 绘制

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let selected = state == .on

        // 底：选中用淡强调色，悬停用轻微的中性色，未选中是透明的。
        let rect = bounds.insetBy(dx: 1, dy: 1)
        if selected {
            SettingsTheme.fillRoundedRect(
                rect, radius: SettingsTheme.optionRadius,
                color: SettingsTheme.accentSoft.withAlphaComponent(isHovered ? 0.13 : 0.07),
                in: context
            )
        } else if isHovered {
            SettingsTheme.fillRoundedRect(
                rect, radius: SettingsTheme.optionRadius,
                color: NSColor.labelColor.withAlphaComponent(0.05),
                in: context
            )
        }

        // 边框：选中用强调色，未选中用细中性边。
        SettingsTheme.strokeRoundedRect(
            rect,
            radius: SettingsTheme.optionRadius,
            color: selected ? SettingsTheme.accent : SettingsTheme.cardBorder,
            lineWidth: selected ? 1.5 : 1,
            in: context
        )

        drawSymbol(in: context, selected: selected)
        drawText(selected: selected)
    }

    /// 把 SF Symbol 按指定颜色画出来。
    ///
    /// AppKit 没有 `withTintColor`（那是 UIKit）。给符号上色的正确做法是
    /// 用 `SymbolConfiguration(paletteColors:)` 生成一份着色后的图像副本，
    /// 再用 `NSImage.draw(in:)` 绘制。
    ///
    /// 用 `draw(in:)` 而不是往 `CGContext` 里塞图像：视图是 `isFlipped`，
    /// AppKit 会自己处理这个翻转，手写坐标系转换只会多一处出错机会。
    private static func tinted(
        symbolName: String,
        pointSize: CGFloat,
        weight: NSFont.Weight,
        color: NSColor
    ) -> NSImage? {
        let base = NSImage.SymbolConfiguration(pointSize: pointSize, weight: weight)
        let palette = NSImage.SymbolConfiguration(paletteColors: [color])
        return NSImage(
            systemSymbolName: symbolName,
            accessibilityDescription: nil
        )?.withSymbolConfiguration(base.applying(palette))
    }

    private func drawSymbol(in context: CGContext, selected: Bool) {
        let color: NSColor = selected ? SettingsTheme.accent : .secondaryLabelColor
        guard let image = Self.tinted(
            symbolName: model.symbolName,
            pointSize: 15,
            weight: .semibold,
            color: color
        ) else {
            return
        }
        // 归一化到固定方框内居中：不同 SF Symbol 的包围盒不一样
        //（`hand.point.up.left` 与 `folder` 的高度能差好几个点），
        // 不归一化会让两个选项的图标在视觉上错开。
        let box = CGRect(x: 16, y: 17, width: 18, height: 18)
        let size = image.size
        image.draw(
            in: NSRect(
                x: box.midX - size.width / 2,
                y: box.midY - size.height / 2,
                width: size.width,
                height: size.height
            ),
            from: .zero,
            operation: .sourceOver,
            fraction: 1
        )

        if selected {
            drawCheckmark(in: context)
        }
    }

    /// 右上角的选中标记：实心圆 + 反色勾。
    ///
    /// 自绘而不是用 `checkmark.circle.fill` + `paletteColors`：
    /// 后者会把整个符号（包括勾）涂成同一个颜色，
    /// 结果就是一个实心圆点——勾看不见了。
    private func drawCheckmark(in context: CGContext) {
        let diameter: CGFloat = 17
        let circle = CGRect(
            x: bounds.width - diameter - 14,
            y: 14,
            width: diameter,
            height: diameter
        )

        context.saveGState()
        context.setFillColor(SettingsTheme.accent.cgColor)
        context.fillEllipse(in: circle)

        // 视图是 flipped（y 向下），所以「向上的一笔」是 y 变小。
        context.setStrokeColor(SettingsTheme.onAccent.cgColor)
        context.setLineWidth(2)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.move(to: CGPoint(x: circle.minX + 4.5, y: circle.midY))
        context.addLine(to: CGPoint(x: circle.minX + 7, y: circle.midY + 3.5))
        context.addLine(to: CGPoint(x: circle.maxX - 4.5, y: circle.midY - 3.5))
        context.strokePath()
        context.restoreGState()
    }

    private func drawText(selected: Bool) {
        let title = NSAttributedString(string: model.title, attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
            .foregroundColor: NSColor.labelColor
        ])
        let subtitle = NSAttributedString(string: model.subtitle, attributes: [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.secondaryLabelColor
        ])

        // 文字从图标右侧开始，与 `drawSymbol` 的 16pt 起点加图标宽度对齐。
        let textX: CGFloat = 42
        title.draw(at: NSPoint(x: textX, y: 14))
        subtitle.draw(at: NSPoint(x: textX, y: 33))
    }
}

// MARK: - 分组标题

/// 侧边栏的一项。
///
/// 完全自绘：`NSButton` 的图文布局在垂直居中、左边距、图标尺寸上都不可控，
/// 而侧边栏恰恰是最需要这几处对齐的地方（一列图标必须严格共线）。
/// 点击与高亮仍由 `NSButton` 负责。
final class SettingsSidebarItem: NSButton {

    let page: SettingsPage

    /// 是否是当前页。由侧边栏统一维护，避免各按钮各自判断。
    var isCurrent = false {
        didSet {
            if oldValue != isCurrent {
                needsDisplay = true
                // 键窗时才画选中背景：窗口失焦后选中项应当退到次要色，
                // 这与系统侧边栏的行为一致。
                contentTintColor = isCurrent ? .labelColor : .secondaryLabelColor
            }
        }
    }

    private static let leadingInset: CGFloat = 10
    private static let iconSize: CGFloat = 16
    private static let iconTextGap: CGFloat = 8

    init(page: SettingsPage, target: AnyObject?, action: Selector?) {
        self.page = page
        super.init(frame: .zero)

        isBordered = false
        bezelStyle = .regularSquare
        setButtonType(.momentaryChange)
        translatesAutoresizingMaskIntoConstraints = false
        self.target = target
        self.action = action
        heightAnchor.constraint(equalToConstant: 32).isActive = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("不支持从 nib 构造")
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }

        if isCurrent {
            SettingsTheme.fillRoundedRect(bounds, radius: 7, color: SettingsTheme.accentSoft, in: context)
        }

        let foreground: NSColor = isCurrent ? .labelColor : .secondaryLabelColor

        let iconOriginX = bounds.minX + Self.leadingInset
        let configuration = NSImage.SymbolConfiguration(pointSize: 12, weight: .medium)
            .applying(NSImage.SymbolConfiguration(hierarchicalColor: foreground))
        if let symbol = NSImage(systemSymbolName: page.symbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration) {
            let size = symbol.size
            symbol.draw(in: CGRect(
                x: iconOriginX + (Self.iconSize - size.width) / 2,
                y: bounds.midY - size.height / 2,
                width: size.width,
                height: size.height
            ))
        }

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13),
            .foregroundColor: foreground,
        ]
        let attributed = NSAttributedString(string: page.title, attributes: attributes)
        let size = attributed.size()
        attributed.draw(at: CGPoint(
            x: iconOriginX + Self.iconSize + Self.iconTextGap,
            y: bounds.midY - size.height / 2
        ))
    }
}

// MARK: - 按钮

/// 设置窗口里的按钮。
///
/// ── 为什么不用系统 `NSButton` ──────────────────────────────
///
/// 系统按钮是「圆角浮凸 + 系统蓝按下态 + 系统蓝聚焦环」。放进卡片里，
/// 它像一块从别的界面贴过来的东西：整窗的层次全靠明度，而它自带高光与彩色高亮。
/// 自绘之后，按钮与输入框外壳共享同一套圆角、底色与描边语言。
final class SettingsPushButton: NSButton {

    /// 强调级别。
    enum Emphasis {
        /// 主操作：实心强调色底 + 反色文字。
        case primary
        /// 次要操作：与输入框外壳同一层底色 + 描边。
        case secondary
    }

    private let emphasis: Emphasis

    /// 与 `SettingsFieldShell.height` 保持一致（理由见那里）。
    static let height: CGFloat = 32
    private static let horizontalPadding: CGFloat = 16
    private static let radius: CGFloat = 8

    private var titleAttributes: [NSAttributedString.Key: Any] {
        [
            .font: NSFont.systemFont(ofSize: 13),
            .foregroundColor: emphasis == .primary ? SettingsTheme.onAccent : NSColor.labelColor,
        ]
    }

    init(title: String, emphasis: Emphasis = .secondary, target: AnyObject?, action: Selector?) {
        self.emphasis = emphasis
        super.init(frame: .zero)

        self.title = title
        self.target = target
        self.action = action
        isBordered = false
        bezelStyle = .regularSquare
        setButtonType(.momentaryChange)
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: Self.height).isActive = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("不支持从 nib 构造")
    }

    override var intrinsicContentSize: NSSize {
        let width = (title as NSString).size(withAttributes: titleAttributes).width
        return NSSize(width: ceil(width) + Self.horizontalPadding * 2, height: Self.height)
    }

    /// 按下态要重绘。
    ///
    /// 自绘按钮没有系统的高光反馈，少了这一步，按下时界面毫无变化，
    /// 用户会以为「点了没反应」。
    override var isHighlighted: Bool {
        didSet {
            if oldValue != isHighlighted { needsDisplay = true }
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }

        let background: NSColor
        let border: NSColor?
        switch emphasis {
        case .primary:
            background = SettingsTheme.accent
            border = nil
        case .secondary:
            background = SettingsTheme.insetBackground
            // 描边比卡片边框明显一档：按钮需要「可以按」的轮廓，
            // 而卡片边框只是把卡片与背景分开，两者承担的作用不同。
            border = NSColor.labelColor.withAlphaComponent(0.16)
        }

        SettingsTheme.fillRoundedRect(
            bounds,
            radius: Self.radius,
            color: background.withAlphaComponent(isHighlighted ? 0.7 : 1),
            in: context
        )
        if let border {
            SettingsTheme.strokeRoundedRect(
                bounds,
                radius: Self.radius,
                color: border,
                lineWidth: 1,
                in: context
            )
        }

        let attributed = NSAttributedString(string: title, attributes: titleAttributes)
        let size = attributed.size()
        attributed.draw(at: CGPoint(
            x: bounds.midX - size.width / 2,
            y: bounds.midY - size.height / 2
        ))
    }
}

// MARK: - 主菜单

/// 输入框尾部的图标按钮（目前用于密钥的显示/隐藏切换）。
///
/// 自绘并保持极简：它是一个**附属动作**，不该在视觉上与输入框本身争注意力。
/// 因此没有底色、没有描边，只有一枚次要色图标；悬停时才浮出一层极淡的背景，
/// 让人知道它可以点。
final class SettingsAccessoryButton: NSButton {

    /// 当前图标名。赋值即重绘。
    var symbolName: String {
        didSet {
            if oldValue != symbolName { needsDisplay = true }
        }
    }

    private static let side: CGFloat = 20

    init(symbolName: String, target: AnyObject?, action: Selector?) {
        self.symbolName = symbolName
        super.init(frame: .zero)

        isBordered = false
        bezelStyle = .regularSquare
        setButtonType(.momentaryChange)
        self.target = target
        self.action = action
        translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Self.side),
            heightAnchor.constraint(equalToConstant: Self.side),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("不支持从 nib 构造")
    }

    private var isHovered = false {
        didSet {
            if oldValue != isHovered { needsDisplay = true }
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self
        ))
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }

        if isHovered || isHighlighted {
            SettingsTheme.fillRoundedRect(
                bounds,
                radius: 5,
                color: NSColor.labelColor.withAlphaComponent(isHighlighted ? 0.14 : 0.07),
                in: context
            )
        }

        let tint = NSColor.secondaryLabelColor
        let configuration = NSImage.SymbolConfiguration(pointSize: 11, weight: .medium)
            .applying(NSImage.SymbolConfiguration(hierarchicalColor: tint))
        guard let symbol = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration) else {
            return
        }
        let size = symbol.size
        symbol.draw(in: CGRect(
            x: bounds.midX - size.width / 2,
            y: bounds.midY - size.height / 2,
            width: size.width,
            height: size.height
        ))
    }
}
