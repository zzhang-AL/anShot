//
//  SettingsButtonStyles.swift
//  AnShotUI
//
//  设置窗口的现代按钮组件群：
//  - SettingsOptionButton：带柔和彩底图标与强调色勾选圆徽章的双选大卡片；
//  - SettingsSidebarItem：带 22×22 彩色微光泽徽章与柔和选中胶囊的侧栏导航项；
//  - SettingsPushButton：精炼 28pt 圆角按钮（支持 primary / secondary / destructive 与悬停反馈）；
//  - SettingsIconButton：26×26 无冗余灰框轻巧图标按钮（用于快捷键行尾清空/复位）；
//  - SettingsAccessoryButton：输入框尾部极简图标按钮。
//
import AppKit

// MARK: - 卡片式单选按钮

final class SettingsOptionButton: NSButton {

    struct Model {
        let symbolName: String
        let title: String
        let subtitle: String
        let accentColor: NSColor?

        init(symbolName: String, title: String, subtitle: String, accentColor: NSColor? = nil) {
            self.symbolName = symbolName
            self.title = title
            self.subtitle = subtitle
            self.accentColor = accentColor
        }
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
        NSSize(width: 244, height: 64)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
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

    override func drawFocusRingMask() {
        NSBezierPath(
            roundedRect: bounds.insetBy(dx: 1, dy: 1),
            xRadius: SettingsTheme.optionRadius,
            yRadius: SettingsTheme.optionRadius
        ).fill()
    }

    override var focusRingMaskBounds: NSRect { bounds }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let selected = state == .on
        let activeColor = model.accentColor ?? SettingsTheme.accent

        let rect = bounds.insetBy(dx: 1, dy: 1)
        if selected {
            SettingsTheme.fillRoundedRect(
                rect,
                radius: SettingsTheme.optionRadius,
                color: activeColor.withAlphaComponent(isHovered ? 0.14 : 0.09),
                in: context
            )
        } else if isHovered {
            SettingsTheme.fillRoundedRect(
                rect,
                radius: SettingsTheme.optionRadius,
                color: SettingsTheme.hoverSurface,
                in: context
            )
        } else {
            SettingsTheme.fillRoundedRect(
                rect,
                radius: SettingsTheme.optionRadius,
                color: SettingsTheme.insetBackground.withAlphaComponent(0.55),
                in: context
            )
        }

        SettingsTheme.strokeRoundedRect(
            rect,
            radius: SettingsTheme.optionRadius,
            color: selected ? activeColor : SettingsTheme.cardBorder,
            lineWidth: selected ? 1.6 : 1,
            in: context
        )

        drawSymbol(in: context, selected: selected, activeColor: activeColor)
        drawText()
    }

    private func drawSymbol(in context: CGContext, selected: Bool, activeColor: NSColor) {
        let badge = CGRect(x: 13, y: bounds.midY - 16, width: 32, height: 32)
        SettingsTheme.fillRoundedRect(
            badge,
            radius: 8,
            color: selected
                ? activeColor.withAlphaComponent(0.18)
                : NSColor.labelColor.withAlphaComponent(0.06),
            in: context
        )

        let iconColor: NSColor = selected ? activeColor : .secondaryLabelColor
        let base = NSImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
        let palette = NSImage.SymbolConfiguration(paletteColors: [iconColor])
        if let image = NSImage(systemSymbolName: model.symbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(base.applying(palette)) {
            let size = image.size
            image.draw(
                in: NSRect(
                    x: badge.midX - size.width / 2,
                    y: badge.midY - size.height / 2,
                    width: size.width,
                    height: size.height
                ),
                from: .zero,
                operation: .sourceOver,
                fraction: 1
            )
        }

        if selected {
            drawCheckmark(in: context, color: activeColor)
        }
    }

    private func drawCheckmark(in context: CGContext, color: NSColor) {
        let diameter: CGFloat = 17
        let circle = CGRect(
            x: bounds.width - diameter - 12,
            y: 12,
            width: diameter,
            height: diameter
        )

        context.saveGState()
        context.setFillColor(color.cgColor)
        context.fillEllipse(in: circle)

        context.setStrokeColor(NSColor.white.cgColor)
        context.setLineWidth(1.9)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.move(to: CGPoint(x: circle.minX + 4.5, y: circle.midY + 0.2))
        context.addLine(to: CGPoint(x: circle.minX + 7.2, y: circle.midY + 3.0))
        context.addLine(to: CGPoint(x: circle.maxX - 4.2, y: circle.midY - 3.0))
        context.strokePath()
        context.restoreGState()
    }

    private func drawText() {
        let title = NSAttributedString(string: model.title, attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
            .foregroundColor: NSColor.labelColor,
        ])
        let subtitle = NSAttributedString(string: model.subtitle, attributes: [
            .font: NSFont.systemFont(ofSize: 11.5),
            .foregroundColor: NSColor.secondaryLabelColor,
        ])

        let textX: CGFloat = 55
        title.draw(at: NSPoint(x: textX, y: 14))
        subtitle.draw(at: NSPoint(x: textX, y: 34))
    }
}

// MARK: - 侧边栏现代彩徽导航项

/// 侧边栏单项：左侧 22×22 分类语义彩色微光泽圆角图标徽章 + 选中柔光胶囊 + 悬停微底。
final class SettingsSidebarItem: NSButton {

    let page: SettingsPage

    var isCurrent = false {
        didSet {
            if oldValue != isCurrent {
                needsDisplay = true
            }
        }
    }

    private var isHovered = false {
        didSet {
            if oldValue != isHovered { needsDisplay = true }
        }
    }

    private static let leadingInset: CGFloat = 9
    private static let badgeSize: CGFloat = 22
    private static let iconTextGap: CGFloat = 9

    init(page: SettingsPage, target: AnyObject?, action: Selector?) {
        self.page = page
        super.init(frame: .zero)

        isBordered = false
        bezelStyle = .regularSquare
        setButtonType(.momentaryChange)
        focusRingType = .default
        translatesAutoresizingMaskIntoConstraints = false
        self.target = target
        self.action = action
        heightAnchor.constraint(equalToConstant: 34).isActive = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("不支持从 nib 构造")
    }

    override var isFlipped: Bool { true }

    override var focusRingMaskBounds: NSRect { bounds }

    override func drawFocusRingMask() {
        NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8).fill()
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
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }

        if isCurrent {
            SettingsTheme.fillRoundedRect(
                bounds,
                radius: 8,
                color: SettingsTheme.accentSoft,
                in: context
            )
            // 左侧极细语义强调竖条，一眼定位当前分类。
            let indicator = CGRect(x: 2.5, y: 8, width: 3, height: bounds.height - 16)
            SettingsTheme.fillRoundedRect(indicator, radius: 1.5, color: page.badgeColor, in: context)
        } else if isHovered {
            SettingsTheme.fillRoundedRect(
                bounds,
                radius: 8,
                color: SettingsTheme.hoverSurface,
                in: context
            )
        }

        // 22×22 彩色微光泽圆角图标徽章。
        let badgeRect = CGRect(
            x: Self.leadingInset,
            y: bounds.midY - Self.badgeSize / 2,
            width: Self.badgeSize,
            height: Self.badgeSize
        )
        SettingsTheme.drawBadgeTile(
            in: badgeRect,
            radius: 6,
            baseColor: isCurrent ? page.badgeColor : page.badgeColor.withAlphaComponent(0.86),
            symbolName: page.symbolName,
            symbolPointSize: 11,
            symbolWeight: .semibold,
            in: context
        )

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: isCurrent ? .semibold : .regular),
            .foregroundColor: isCurrent ? NSColor.labelColor : NSColor.secondaryLabelColor,
        ]
        let attributed = NSAttributedString(string: page.title, attributes: attributes)
        let size = attributed.size()
        attributed.draw(at: CGPoint(
            x: badgeRect.maxX + Self.iconTextGap,
            y: bounds.midY - size.height / 2
        ))
    }
}

// MARK: - 现代精炼按钮

final class SettingsPushButton: NSButton {

    enum Emphasis {
        case primary
        case secondary
        case destructive
    }

    private let emphasis: Emphasis

    static let height: CGFloat = 28
    private static let horizontalPadding: CGFloat = 13
    private static let radius: CGFloat = 7.5

    private var isHovered = false {
        didSet {
            if oldValue != isHovered { needsDisplay = true }
        }
    }

    private var titleAttributes: [NSAttributedString.Key: Any] {
        let color: NSColor
        switch emphasis {
        case .primary: color = SettingsTheme.onAccent
        case .secondary: color = .labelColor
        case .destructive: color = AnShotTheme.danger
        }
        return [
            .font: NSFont.systemFont(ofSize: 12.5, weight: emphasis == .primary ? .semibold : .medium),
            .foregroundColor: color,
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
        focusRingType = .default
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: Self.height).isActive = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("不支持从 nib 构造")
    }

    override var focusRingMaskBounds: NSRect { bounds }

    override func drawFocusRingMask() {
        NSBezierPath(roundedRect: bounds, xRadius: Self.radius, yRadius: Self.radius).fill()
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
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }

    override var intrinsicContentSize: NSSize {
        let width = (title as NSString).size(withAttributes: titleAttributes).width
        return NSSize(width: ceil(width) + Self.horizontalPadding * 2, height: Self.height)
    }

    override var isEnabled: Bool {
        didSet {
            if oldValue != isEnabled { needsDisplay = true }
        }
    }

    override var isHighlighted: Bool {
        didSet {
            if oldValue != isHighlighted { needsDisplay = true }
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }

        let stateAlpha: CGFloat = isEnabled ? (isHighlighted ? 0.72 : 1) : 0.42
        let background: NSColor
        let border: NSColor?

        switch emphasis {
        case .primary:
            background = SettingsTheme.accent.withAlphaComponent(isHovered ? 0.90 : 1.0)
            border = nil
        case .secondary:
            background = isHovered ? SettingsTheme.hoverSurface : SettingsTheme.insetBackground
            border = SettingsTheme.cardBorder
        case .destructive:
            background = AnShotTheme.danger.withAlphaComponent(isHovered ? 0.14 : 0.08)
            border = AnShotTheme.danger.withAlphaComponent(0.24)
        }

        SettingsTheme.fillRoundedRect(
            bounds,
            radius: Self.radius,
            color: background.withAlphaComponent(background.alphaComponent * stateAlpha),
            in: context
        )
        if let border {
            SettingsTheme.strokeRoundedRect(
                bounds,
                radius: Self.radius,
                color: border.withAlphaComponent(border.alphaComponent * (isEnabled ? 1 : 0.45)),
                lineWidth: 1,
                in: context
            )
        }

        var attributes = titleAttributes
        if !isEnabled, let baseColor = attributes[.foregroundColor] as? NSColor {
            attributes[.foregroundColor] = baseColor.withAlphaComponent(baseColor.alphaComponent * 0.45)
        }
        let attributed = NSAttributedString(string: title, attributes: attributes)
        let size = attributed.size()
        attributed.draw(at: CGPoint(
            x: bounds.midX - size.width / 2,
            y: bounds.midY - size.height / 2
        ))
    }
}

// MARK: - 紧凑图标动作按钮（用于快捷键行尾清空 / 复位，消除满屏大灰方框）

final class SettingsIconButton: NSButton {

    private let symbolName: String
    private let tintColorOverride: NSColor?
    private var isHovered = false {
        didSet {
            if oldValue != isHovered { needsDisplay = true }
        }
    }

    init(
        symbolName: String,
        toolTip: String,
        tintColor: NSColor? = nil,
        target: AnyObject?,
        action: Selector?
    ) {
        self.symbolName = symbolName
        self.tintColorOverride = tintColor
        super.init(frame: .zero)
        self.toolTip = toolTip
        self.target = target
        self.action = action
        isBordered = false
        bezelStyle = .regularSquare
        setButtonType(.momentaryChange)
        focusRingType = .default
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 26),
            heightAnchor.constraint(equalToConstant: 26),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("不支持从 nib 构造")
    }

    override var focusRingMaskBounds: NSRect { bounds }

    override func drawFocusRingMask() {
        NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
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
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }

    override var isHighlighted: Bool {
        didSet {
            if oldValue != isHighlighted { needsDisplay = true }
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        if isHovered || isHighlighted {
            SettingsTheme.fillRoundedRect(
                bounds,
                radius: 6.5,
                color: isHighlighted ? SettingsTheme.accentSoft : SettingsTheme.hoverSurface,
                in: ctx
            )
        }

        let tint = isHovered
            ? (tintColorOverride ?? NSColor.labelColor)
            : (tintColorOverride?.withAlphaComponent(0.75) ?? NSColor.secondaryLabelColor)
        let config = NSImage.SymbolConfiguration(pointSize: 11.5, weight: .medium)
            .applying(NSImage.SymbolConfiguration(paletteColors: [tint]))
        guard let symbol = NSImage(systemSymbolName: symbolName, accessibilityDescription: toolTip)?
            .withSymbolConfiguration(config) else {
            return
        }
        let s = symbol.size
        symbol.draw(in: CGRect(
            x: bounds.midX - s.width / 2,
            y: bounds.midY - s.height / 2,
            width: s.width,
            height: s.height
        ))
    }
}

// MARK: - 输入框尾部图标按钮

final class SettingsAccessoryButton: NSButton {

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
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }

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
