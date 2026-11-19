//
//  OCRResultPanel.swift
//  AnShotUI
//
//  独立的现代 OCR 与翻译悬浮卡片：
//    - 无红绿灯通透圆角浮窗，支持自由缩放、背景拖拽、跟随系统浅/深语义主题与置顶图钉；
//    - 场景化顶栏（「文字识别」/「截图翻译」/「划词翻译」）与彩色微光泽语义徽章；
//    - 单卡自适应布局：纯 OCR 态单区大字舒展排版；翻译态自动在同卡内展开「可编辑原文 → 语种流向条 → 高对比译文」上下对照；
//    - 原文区支持直接编辑与 `⌘Enter` 重译、无损「合并换行」胶囊切换、二维码/条码内嵌操作卡、`⇧⌘C` 智能复制与原地「✓ 已复制」反馈。
//

import AnShotCore
import AppKit

// MARK: - 独立悬浮面板窗口

/// 支持 `Esc` / `⌘W` / `⌘Enter` / `⇧⌘C` 快捷键且隐藏系统红绿灯的现代独立悬浮面板。
@MainActor
private final class OCRFloatingPanel: NSPanel {

    var onCloseShortcut: (() -> Void)?
    var onRetranslateShortcut: (() -> Void)?
    var onSmartCopyShortcut: (() -> Void)?

    override func cancelOperation(_ sender: Any?) {
        onCloseShortcut?()
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let key = event.charactersIgnoringModifiers?.lowercased()

        // ⌘W 关闭面板
        if flags == .command, key == "w" {
            onCloseShortcut?()
            return true
        }
        // ⌘Enter 立即翻译 / 重新翻译
        if flags == .command, (event.keyCode == 36 || event.keyCode == 76) {
            onRetranslateShortcut?()
            return true
        }
        // ⇧⌘C 智能复制（译文优先，否则原文）
        if flags == [.command, .shift], key == "c" {
            onSmartCopyShortcut?()
            return true
        }
        // Esc 关闭面板
        if flags.isEmpty, event.keyCode == 53 {
            onCloseShortcut?()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

// MARK: - 现代微控件组件

/// 顶栏 22×22 彩色微光泽圆角语义徽章（与设置侧栏共享 `AnShotTheme.drawBadgeTile` 视觉语言）。
private final class OCRHeaderBadgeView: NSView {

    var symbolName: String {
        didSet { if oldValue != symbolName { needsDisplay = true } }
    }

    var badgeColor: NSColor {
        didSet { needsDisplay = true }
    }

    init(symbolName: String, badgeColor: NSColor) {
        self.symbolName = symbolName
        self.badgeColor = badgeColor
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 22),
            heightAnchor.constraint(equalToConstant: 22),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("不支持从 nib 构造")
    }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        AnShotTheme.drawBadgeTile(
            in: bounds,
            radius: 6,
            baseColor: badgeColor,
            symbolName: symbolName,
            symbolPointSize: 11,
            symbolWeight: .semibold,
            in: ctx
        )
    }
}

/// 顶栏置顶图钉按钮：激活态自动呈现强调色柔和圆角底 + 填充图钉。
private final class OCRPinToggleButton: NSButton {

    var isPinned: Bool = true {
        didSet {
            if oldValue != isPinned { needsDisplay = true }
        }
    }

    private var isHovered = false {
        didSet { if oldValue != isHovered { needsDisplay = true } }
    }

    init(target: AnyObject?, action: Selector?) {
        super.init(frame: .zero)
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
        NSBezierPath(roundedRect: bounds, xRadius: 6.5, yRadius: 6.5).fill()
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
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        if isPinned {
            AnShotTheme.fillRoundedRect(
                bounds,
                radius: 6.5,
                color: isHovered ? AnShotTheme.accent.withAlphaComponent(0.22) : AnShotTheme.accentSoft,
                in: ctx
            )
        } else if isHovered || isHighlighted {
            AnShotTheme.fillRoundedRect(
                bounds,
                radius: 6.5,
                color: AnShotTheme.hoverSurface,
                in: ctx
            )
        }

        let symbolName = isPinned ? "pin.fill" : "pin"
        let tint: NSColor = isPinned
            ? AnShotTheme.accent
            : (isHovered ? .labelColor : .secondaryLabelColor)
        let config = NSImage.SymbolConfiguration(pointSize: 11.5, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [tint]))
        guard let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: toolTip)?
            .withSymbolConfiguration(config) else { return }
        let s = image.size
        image.draw(in: CGRect(
            x: bounds.midX - s.width / 2,
            y: bounds.midY - s.height / 2,
            width: s.width,
            height: s.height
        ))
    }
}

/// 精致内嵌胶囊外壳，用于包裹无边框 `NSPopUpButton`，消除旧式灰凹凸下拉框的陈旧感。
private final class OCRCompactPopUpContainer: NSView {

    let popUp: NSPopUpButton

    init(popUp: NSPopUpButton, leadingSymbol: String? = nil, minWidth: CGFloat = 78) {
        self.popUp = popUp
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true

        popUp.isBordered = false
        popUp.bezelStyle = .inline
        popUp.controlSize = .small
        popUp.font = .systemFont(ofSize: 12, weight: .medium)
        popUp.setContentHuggingPriority(.required, for: .horizontal)
        popUp.translatesAutoresizingMaskIntoConstraints = false

        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)

        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false

        if let leadingSymbol {
            let icon = NSImageView()
            let config = NSImage.SymbolConfiguration(pointSize: 10.5, weight: .medium)
                .applying(NSImage.SymbolConfiguration(paletteColors: [.secondaryLabelColor]))
            icon.image = NSImage(systemSymbolName: leadingSymbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(config)
            icon.translatesAutoresizingMaskIntoConstraints = false
            stack.addArrangedSubview(icon)
        }
        stack.addArrangedSubview(popUp)
        addSubview(stack)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 25),
            widthAnchor.constraint(greaterThanOrEqualToConstant: minWidth),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: leadingSymbol == nil ? 7 : 8),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -5),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("不支持从 nib 构造")
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = AnShotTheme.insetBackground.cgColor
        layer?.cornerRadius = 7
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 1
        layer?.borderColor = AnShotTheme.cardBorder.cgColor
    }
}

/// 轻量胶囊切换按钮（用于「合并换行」无损切换，取代原生复选框）。
private final class OCRPillToggleButton: NSButton {

    var isActive: Bool {
        get { state == .on }
        set {
            let next: NSControl.StateValue = newValue ? .on : .off
            if state != next {
                state = next
                needsDisplay = true
            }
        }
    }

    private let symbolName: String
    private var isHovered = false {
        didSet { if oldValue != isHovered { needsDisplay = true } }
    }

    private static let height: CGFloat = 22
    private static let radius: CGFloat = 6

    init(title: String, symbolName: String, target: AnyObject?, action: Selector?) {
        self.symbolName = symbolName
        super.init(frame: .zero)
        self.title = title
        self.target = target
        self.action = action
        isBordered = false
        bezelStyle = .regularSquare
        setButtonType(.toggle)
        focusRingType = .default
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: Self.height).isActive = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("不支持从 nib 构造")
    }

    override var isFlipped: Bool { true }

    override var intrinsicContentSize: NSSize {
        let font = NSFont.systemFont(ofSize: 11, weight: .medium)
        let textW = (title as NSString).size(withAttributes: [.font: font]).width
        return NSSize(width: ceil(textW) + 28, height: Self.height)
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
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let active = state == .on

        let bg: NSColor
        let border: NSColor?
        if active {
            bg = isHovered ? AnShotTheme.accent.withAlphaComponent(0.20) : AnShotTheme.accentSoft
            border = AnShotTheme.accent.withAlphaComponent(0.32)
        } else {
            bg = isHovered ? AnShotTheme.hoverSurface : AnShotTheme.insetBackground.withAlphaComponent(0.75)
            border = AnShotTheme.cardBorder
        }

        AnShotTheme.fillRoundedRect(bounds, radius: Self.radius, color: bg, in: ctx)
        if let border {
            AnShotTheme.strokeRoundedRect(bounds, radius: Self.radius, color: border, lineWidth: 1, in: ctx)
        }

        let fg: NSColor = active ? AnShotTheme.accent : (isHovered ? .labelColor : .secondaryLabelColor)
        let font = NSFont.systemFont(ofSize: 11, weight: active ? .semibold : .medium)
        let textAttr = NSAttributedString(string: title, attributes: [
            .font: font,
            .foregroundColor: fg,
        ])
        let textSize = textAttr.size()

        let symConfig = NSImage.SymbolConfiguration(pointSize: 10, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [fg]))
        let icon = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(symConfig)
        let iconW = icon?.size.width ?? 0
        let gap: CGFloat = icon == nil ? 0 : 4
        let totalW = iconW + gap + textSize.width
        var x = bounds.midX - totalW / 2

        if let icon {
            let s = icon.size
            icon.draw(in: CGRect(
                x: x,
                y: bounds.midY - s.height / 2,
                width: s.width,
                height: s.height
            ))
            x += s.width + gap
        }
        textAttr.draw(at: CGPoint(x: x, y: bounds.midY - textSize.height / 2))
    }
}

/// 轻量化无框微操作按钮（用于「复制原文」、「复制双语」及二维码行操作），支持原地瞬态成功反馈。
private final class OCRGhostActionButton: NSButton {

    enum Style {
        case neutral
        case accent
    }

    private let style: Style
    private var defaultSymbolName: String?
    private var defaultTitle: String
    private var isShowingSuccess = false
    private var resetTask: Task<Void, Never>?

    private var isHovered = false {
        didSet { if oldValue != isHovered { needsDisplay = true } }
    }

    private static let height: CGFloat = 22
    private static let radius: CGFloat = 6

    init(
        title: String,
        symbolName: String? = nil,
        style: Style = .neutral,
        target: AnyObject?,
        action: Selector?
    ) {
        self.defaultTitle = title
        self.defaultSymbolName = symbolName
        self.style = style
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

    override var isFlipped: Bool { true }

    /// 触发原地「已复制」微反馈，1.2 秒后自动恢复默认态。
    func flashCopiedFeedback() {
        resetTask?.cancel()
        isShowingSuccess = true
        invalidateIntrinsicContentSize()
        needsDisplay = true
        resetTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(1200))
            guard !Task.isCancelled, let self else { return }
            self.isShowingSuccess = false
            self.invalidateIntrinsicContentSize()
            self.needsDisplay = true
        }
    }

    func resetFeedback() {
        resetTask?.cancel()
        resetTask = nil
        if isShowingSuccess {
            isShowingSuccess = false
            invalidateIntrinsicContentSize()
            needsDisplay = true
        }
    }

    private var activeTitle: String {
        isShowingSuccess ? "已复制" : defaultTitle
    }

    private var activeSymbol: String? {
        isShowingSuccess ? "checkmark" : defaultSymbolName
    }

    override var intrinsicContentSize: NSSize {
        let font = NSFont.systemFont(ofSize: 11.5, weight: style == .accent ? .semibold : .medium)
        let w = (activeTitle as NSString).size(withAttributes: [.font: font]).width
        let iconExtra: CGFloat = activeSymbol == nil ? 0 : 15
        return NSSize(width: ceil(w) + iconExtra + 14, height: Self.height)
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
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        let bg: NSColor?
        let fg: NSColor
        if isShowingSuccess {
            bg = AnShotTheme.success.withAlphaComponent(0.14)
            fg = AnShotTheme.dynamic(
                light: NSColor(srgbRed: 0.08, green: 0.50, blue: 0.28, alpha: 1),
                dark: NSColor(srgbRed: 0.36, green: 0.88, blue: 0.56, alpha: 1)
            )
        } else {
            switch style {
            case .neutral:
                bg = (isHovered || isHighlighted) ? AnShotTheme.hoverSurface : nil
                fg = isHovered ? .labelColor : .secondaryLabelColor
            case .accent:
                bg = isHovered
                    ? AnShotTheme.accent.withAlphaComponent(0.20)
                    : AnShotTheme.accentSoft
                fg = AnShotTheme.accent
            }
        }

        if let bg {
            AnShotTheme.fillRoundedRect(bounds, radius: Self.radius, color: bg, in: ctx)
        }

        let font = NSFont.systemFont(ofSize: 11.5, weight: (style == .accent || isShowingSuccess) ? .semibold : .medium)
        let attr = NSAttributedString(string: activeTitle, attributes: [
            .font: font,
            .foregroundColor: fg,
        ])
        let textSize = attr.size()

        var icon: NSImage?
        if let sym = activeSymbol {
            let cfg = NSImage.SymbolConfiguration(pointSize: 10.5, weight: .semibold)
                .applying(NSImage.SymbolConfiguration(paletteColors: [fg]))
            icon = NSImage(systemSymbolName: sym, accessibilityDescription: nil)?
                .withSymbolConfiguration(cfg)
        }

        let iconW = icon?.size.width ?? 0
        let gap: CGFloat = icon == nil ? 0 : 4
        let totalW = iconW + gap + textSize.width
        var x = bounds.midX - totalW / 2

        if let icon {
            let s = icon.size
            icon.draw(in: CGRect(
                x: x,
                y: bounds.midY - s.height / 2,
                width: s.width,
                height: s.height
            ))
            x += s.width + gap
        }
        attr.draw(at: CGPoint(x: x, y: bounds.midY - textSize.height / 2))
    }
}

/// 底栏主操作按钮：支持带图标的强调色主按钮、次要按钮，以及原地「✓ 已复制」绿色瞬态反馈。
private final class OCRFooterButton: NSButton {

    enum Emphasis {
        case primary
        case secondary
    }

    private let emphasis: Emphasis
    private var defaultSymbolName: String?
    private var isShowingSuccess = false
    private var resetTask: Task<Void, Never>?

    private var isHovered = false {
        didSet { if oldValue != isHovered { needsDisplay = true } }
    }

    static let height: CGFloat = 30
    private static let radius: CGFloat = 8
    private static let horizontalPadding: CGFloat = 14

    init(
        title: String,
        symbolName: String? = nil,
        emphasis: Emphasis,
        target: AnyObject?,
        action: Selector?
    ) {
        self.emphasis = emphasis
        self.defaultSymbolName = symbolName
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

    override var isFlipped: Bool { true }

    override var title: String {
        didSet {
            if oldValue != title {
                invalidateIntrinsicContentSize()
                needsDisplay = true
            }
        }
    }

    override var isEnabled: Bool {
        didSet { if oldValue != isEnabled { needsDisplay = true } }
    }

    override var isHighlighted: Bool {
        didSet { if oldValue != isHighlighted { needsDisplay = true } }
    }

    func setSymbolName(_ symbol: String?) {
        guard defaultSymbolName != symbol else { return }
        defaultSymbolName = symbol
        invalidateIntrinsicContentSize()
        needsDisplay = true
    }

    func flashCopiedFeedback() {
        resetTask?.cancel()
        isShowingSuccess = true
        invalidateIntrinsicContentSize()
        needsDisplay = true
        resetTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(1200))
            guard !Task.isCancelled, let self else { return }
            self.isShowingSuccess = false
            self.invalidateIntrinsicContentSize()
            self.needsDisplay = true
        }
    }

    func resetFeedback() {
        resetTask?.cancel()
        resetTask = nil
        if isShowingSuccess {
            isShowingSuccess = false
            invalidateIntrinsicContentSize()
            needsDisplay = true
        }
    }

    private var displayTitle: String {
        isShowingSuccess ? "已复制" : title
    }

    private var displaySymbol: String? {
        isShowingSuccess ? "checkmark" : defaultSymbolName
    }

    private var textFont: NSFont {
        .systemFont(ofSize: 12.5, weight: emphasis == .primary ? .semibold : .medium)
    }

    override var intrinsicContentSize: NSSize {
        let textW = (displayTitle as NSString).size(withAttributes: [.font: textFont]).width
        let symW: CGFloat = displaySymbol == nil ? 0 : 17
        return NSSize(width: max(76, ceil(textW) + symW + Self.horizontalPadding * 2), height: Self.height)
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

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let stateAlpha: CGFloat = isEnabled ? (isHighlighted ? 0.78 : 1.0) : 0.42

        let bg: NSColor
        let border: NSColor?
        let fg: NSColor

        if isShowingSuccess {
            bg = AnShotTheme.success
            border = nil
            fg = .white
        } else {
            switch emphasis {
            case .primary:
                bg = AnShotTheme.accent.withAlphaComponent(isHovered ? 0.90 : 1.0)
                border = nil
                fg = AnShotTheme.onAccent
            case .secondary:
                bg = isHovered ? AnShotTheme.hoverSurface : AnShotTheme.cardBackground
                border = AnShotTheme.cardBorder
                fg = .labelColor
            }
        }

        AnShotTheme.fillRoundedRect(
            bounds,
            radius: Self.radius,
            color: bg.withAlphaComponent(bg.alphaComponent * stateAlpha),
            in: ctx
        )
        if let border {
            AnShotTheme.strokeRoundedRect(
                bounds,
                radius: Self.radius,
                color: border.withAlphaComponent(border.alphaComponent * (isEnabled ? 1 : 0.45)),
                lineWidth: 1,
                in: ctx
            )
        }

        let textColor = isEnabled ? fg : fg.withAlphaComponent(0.48)
        let attr = NSAttributedString(string: displayTitle, attributes: [
            .font: textFont,
            .foregroundColor: textColor,
        ])
        let textSize = attr.size()

        var icon: NSImage?
        if let sym = displaySymbol {
            let cfg = NSImage.SymbolConfiguration(pointSize: 11.5, weight: .semibold)
                .applying(NSImage.SymbolConfiguration(paletteColors: [textColor]))
            icon = NSImage(systemSymbolName: sym, accessibilityDescription: nil)?
                .withSymbolConfiguration(cfg)
        }

        let iconW = icon?.size.width ?? 0
        let gap: CGFloat = icon == nil ? 0 : 5
        let totalW = iconW + gap + textSize.width
        var x = bounds.midX - totalW / 2

        if let icon {
            let s = icon.size
            icon.draw(in: CGRect(
                x: x,
                y: bounds.midY - s.height / 2,
                width: s.width,
                height: s.height
            ))
            x += s.width + gap
        }
        attr.draw(at: CGPoint(x: x, y: bounds.midY - textSize.height / 2))
    }
}

/// 软着陆中腰语种桥梁表面（跟随系统明暗主题动态刷新）。
private final class OCRBridgeSurfaceView: NSView {
    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = AnShotTheme.insetBackground.withAlphaComponent(0.68).cgColor
    }
}

// MARK: - OCR / 翻译悬浮卡片控制器

/// 独立的现代 OCR 识别与翻译浮窗。
@MainActor
final class OCRResultPanel: NSObject, NSWindowDelegate, NSTextViewDelegate {

    /// 文本展示模式（兼容诊断与单元测试契约）。
    enum DisplayMode: Int, CaseIterable {
        case original = 0
        case translation = 1
        case bilingual = 2
    }

    /// 浮窗默认初始尺寸（纯 OCR 态清爽紧凑，翻译展开态自动适度拉高）。
    static let defaultSize = CGSize(width: 480, height: 396)
    /// 浮窗允许缩放的最小尺寸。
    static let minimumSize = CGSize(width: 390, height: 270)
    private static let margin: CGFloat = 14

    /// 语义徽章配色：OCR 青碧、翻译珊瑚粉（与设置页导航语义色严格一致）。
    private static let ocrBadgeColor = NSColor(srgbRed: 0.08, green: 0.64, blue: 0.60, alpha: 1)
    private static let translationBadgeColor = NSColor(srgbRed: 0.94, green: 0.34, blue: 0.42, alpha: 1)

    /// 源语言选项：`id == nil` 表示自动检测。
    static let sourceLanguages: [(id: String?, name: String)] =
        [(nil, "自动检测")] + TranslationLanguage.commonTargetLanguages.map { ($0.id, $0.name) }

    /// 目标语言选项（7 语种，由 `TranslationLanguage.commonTargetLanguages` 统一维护）。
    static let targetLanguages: [(id: String, name: String)] = TranslationLanguage.commonTargetLanguages

    // MARK: - 回调

    var onCopyAll: ((String) -> Void)?
    /// 请求翻译：`(源语言覆盖 nil=自动, 目标语言 BCP-47)`。
    var onTranslate: ((String?, String) -> Void)?
    /// 源或目标语种变化：`(源语言覆盖 nil=自动, 目标语言 BCP-47)`。
    var onTargetLanguageChanged: ((String?, String) -> Void)?
    /// OCR 识别语言偏好切换（仅在持有原图时由调用方触发重识别）。
    var onOCRLanguageChanged: ((OCRLanguagePreference) -> Void)?
    /// 「合并换行」切换通知（用于持久化偏好）。
    var onMergeLineBreaksChanged: ((Bool) -> Void)?
    var onClose: (() -> Void)?

    // MARK: - 视图与控件

    private let panel: OCRFloatingPanel

    // 顶栏
    private let headerBadgeView = OCRHeaderBadgeView(symbolName: "text.viewfinder", badgeColor: ocrBadgeColor)
    private let headerTitleLabel = NSTextField(labelWithString: "文字识别")
    private let ocrLanguagePopUp = NSPopUpButton(frame: .zero, pullsDown: false)
    private var ocrLanguageContainer: OCRCompactPopUpContainer!
    private var pinOnTopButton: OCRPinToggleButton!
    private var closeHeaderButton: SettingsIconButton!

    // 二维码卡片容器
    private let barcodeStackView = NSStackView()

    // 主统一卡片内部
    private let mainCard = ThemedSurfaceView(kind: .card, cornerRadius: AnShotTheme.cardRadius)

    // 原文区（上半区）
    private let sourceHeaderLabel = NSTextField(labelWithString: "原文")
    private var mergeLineBreaksButton: OCRPillToggleButton!
    private var copyOriginalButton: OCRGhostActionButton!
    private let sourceScrollView = NSScrollView()
    private let sourceTextView = NSTextView()
    private var sourceScrollMinHeightConstraint: NSLayoutConstraint!
    private var sourceScrollMaxHeightConstraint: NSLayoutConstraint!

    // 中腰语种桥梁条（仅翻译展开态可见）
    private let bridgeTopDivider = SettingsRowDivider()
    private let translationBridgeView = OCRBridgeSurfaceView()
    private let bridgeBottomDivider = SettingsRowDivider()
    private let bridgeLanguageStack = NSStackView()
    private let sourceLanguagePopUp = NSPopUpButton(frame: .zero, pullsDown: false)
    private var sourceLanguageContainer: OCRCompactPopUpContainer!
    private let bridgeArrowIcon = NSImageView()
    private let languagePopUp = NSPopUpButton(frame: .zero, pullsDown: false)
    private var targetLanguageContainer: OCRCompactPopUpContainer!
    private let bridgeStatusLabel = NSTextField(labelWithString: "")

    // 译文区（下半区，翻译展开态主角）
    private let translationSectionView = NSView()
    private let translationHeaderLabel = NSTextField(labelWithString: "译文")
    private let translationSpinner = NSProgressIndicator()
    private var copyBilingualButton: OCRGhostActionButton!
    private let translationScrollView = NSScrollView()
    private let translationTextView = NSTextView()

    // 识别中 / 失败遮罩（覆盖主卡片）
    private let statusOverlay = ThemedSurfaceView(kind: .card, cornerRadius: AnShotTheme.cardRadius)
    private let progressIndicator = NSProgressIndicator()
    private let overlayLabel = NSTextField(labelWithString: "")

    // 底部动作条
    private let footerRow = NSStackView()
    private var copyButton: OCRFooterButton!
    private let footerRightStack = NSStackView()
    private var translateButton: OCRFooterButton!

    // MARK: - 状态模型

    private var lastOCRResult: OCRResult?
    private var rawOriginalText = ""
    private var editedOriginalText: String?
    private var translationResult: TranslationResult?
    private var displayMode: DisplayMode = .original
    private var displayedBarcodes: [BarcodeItem] = []
    private var isProgrammaticallyUpdatingText = false
    private var isTextOnlyMode = false
    private var isTranslationSectionExpanded = false
    private var translationErrorMessage: String?

    private var translationAvailability: TranslationAvailability = .unknown
    private var isTranslating = false

    /// 浮窗是否处于置顶模式（默认置顶，可随时切换）。
    private(set) var isAlwaysOnTop = true

    // MARK: - 只读状态属性（对外及单测契约）

    var isVisible: Bool { panel.isVisible }

    /// 当前逻辑展示文本（严格兼容 `.original` / `.translation` / `.bilingual` 三态契约）。
    var text: String {
        switch displayMode {
        case .original:
            return currentEditableOriginalText
        case .translation:
            guard let result = translationResult else {
                return currentEditableOriginalText
            }
            return result.segments.map(\.displayText).joined(separator: "\n")
        case .bilingual:
            guard let result = translationResult else {
                return currentEditableOriginalText
            }
            return Self.bilingualText(for: result)
        }
    }

    var isLoadingForDiagnostics: Bool { !statusOverlay.isHidden }
    var isMergeLineBreaksEnabled: Bool { mergeLineBreaksButton.isActive }
    var currentBarcodes: [BarcodeItem] { displayedBarcodes }

    // MARK: - 初始化

    override init() {
        panel = OCRFloatingPanel(
            contentRect: NSRect(origin: .zero, size: Self.defaultSize),
            styleMask: [.titled, .fullSizeContentView, .resizable],
            backing: .buffered,
            defer: true
        )
        super.init()

        // 透明隐藏标题栏与系统红绿灯，保留原生阴影、现代圆角与自由拖拽缩放。
        panel.title = "文字识别"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.minSize = Self.minimumSize
        panel.hidesOnDeactivate = false
        panel.hasShadow = true
        // 跟随系统与用户设置的全局浅/深外观。
        panel.appearance = nil
        panel.backgroundColor = .clear
        panel.delegate = self

        for buttonType: NSWindow.ButtonType in [.closeButton, .miniaturizeButton, .zoomButton] {
            panel.standardWindowButton(buttonType)?.isHidden = true
        }

        panel.onCloseShortcut = { [weak self] in self?.hide() }
        panel.onRetranslateShortcut = { [weak self] in self?.triggerRetranslateShortcut() }
        panel.onSmartCopyShortcut = { [weak self] in self?.triggerSmartCopy() }

        buildUI()
    }

    // MARK: - 构建界面

    private func buildUI() {
        let content = ThemedSurfaceView(kind: .windowBackground)

        // ── 1. 场景化顶栏 ──────────────────────────────────────
        headerTitleLabel.font = .systemFont(ofSize: 13.5, weight: .semibold)
        headerTitleLabel.textColor = .labelColor
        headerTitleLabel.setContentHuggingPriority(.required, for: .horizontal)

        for lang in OCRLanguagePreference.allCases {
            ocrLanguagePopUp.addItem(withTitle: lang.displayName)
        }
        ocrLanguagePopUp.target = self
        ocrLanguagePopUp.action = #selector(handleOCRLanguageChanged)
        ocrLanguagePopUp.toolTip = "切换 OCR 识别语言（持有原图时立即重新识别）"
        ocrLanguageContainer = OCRCompactPopUpContainer(
            popUp: ocrLanguagePopUp,
            leadingSymbol: "globe",
            minWidth: 92
        )

        pinOnTopButton = OCRPinToggleButton(target: self, action: #selector(handleToggleAlwaysOnTop))
        refreshPinOnTopButton()

        closeHeaderButton = SettingsIconButton(
            symbolName: "xmark",
            toolTip: "关闭（Esc / ⌘W）",
            target: self,
            action: #selector(handleCloseButton)
        )

        let headerSpacer = NSView()
        headerSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let topBar = NSStackView(views: [
            headerBadgeView,
            headerTitleLabel,
            headerSpacer,
            ocrLanguageContainer,
            pinOnTopButton,
            closeHeaderButton,
        ])
        topBar.orientation = .horizontal
        topBar.alignment = .centerY
        topBar.spacing = 7
        topBar.setCustomSpacing(8, after: headerBadgeView)
        topBar.translatesAutoresizingMaskIntoConstraints = false

        // ── 2. 二维码 / 条码内嵌卡片栈 ─────────────────────────
        barcodeStackView.orientation = .vertical
        barcodeStackView.alignment = .leading
        barcodeStackView.spacing = 6
        barcodeStackView.isHidden = true
        barcodeStackView.translatesAutoresizingMaskIntoConstraints = false

        // ── 3. 主统一卡片（单卡上下对照容器） ──────────────────
        mainCard.translatesAutoresizingMaskIntoConstraints = false
        mainCard.setContentHuggingPriority(.defaultLow, for: .vertical)
        mainCard.setContentCompressionResistancePriority(.defaultLow, for: .vertical)

        // 3a. 原文区（上半区）
        sourceHeaderLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        sourceHeaderLabel.textColor = .secondaryLabelColor
        sourceHeaderLabel.setContentHuggingPriority(.required, for: .horizontal)

        mergeLineBreaksButton = OCRPillToggleButton(
            title: "合并换行",
            symbolName: "text.alignleft",
            target: self,
            action: #selector(handleMergeLineBreaksToggled)
        )
        mergeLineBreaksButton.toolTip = "无损合并段内硬换行，保留空行与原文结构"

        copyOriginalButton = OCRGhostActionButton(
            title: "复制原文",
            symbolName: "doc.on.doc",
            style: .neutral,
            target: self,
            action: #selector(handleCopyOriginal)
        )
        copyOriginalButton.toolTip = "复制原文内容"
        copyOriginalButton.isHidden = true

        let sourceHeaderSpacer = NSView()
        sourceHeaderSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let sourceHeaderRow = NSStackView(views: [
            sourceHeaderLabel,
            sourceHeaderSpacer,
            mergeLineBreaksButton,
            copyOriginalButton,
        ])
        sourceHeaderRow.orientation = .horizontal
        sourceHeaderRow.alignment = .centerY
        sourceHeaderRow.spacing = 6
        sourceHeaderRow.translatesAutoresizingMaskIntoConstraints = false

        configureTextView(sourceTextView, editable: true, fontSize: 14, lineHeightMultiple: 1.44)
        sourceTextView.delegate = self

        sourceScrollView.hasVerticalScroller = true
        sourceScrollView.autohidesScrollers = true
        sourceScrollView.drawsBackground = false
        sourceScrollView.borderType = .noBorder
        sourceScrollView.documentView = sourceTextView
        sourceScrollView.automaticallyAdjustsContentInsets = false
        sourceScrollView.contentInsets = NSEdgeInsetsZero
        sourceScrollView.translatesAutoresizingMaskIntoConstraints = false

        let sourceSection = NSView()
        sourceSection.translatesAutoresizingMaskIntoConstraints = false
        sourceSection.addSubview(sourceHeaderRow)
        sourceSection.addSubview(sourceScrollView)

        sourceScrollMinHeightConstraint = sourceScrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 120)
        sourceScrollMaxHeightConstraint = sourceScrollView.heightAnchor.constraint(lessThanOrEqualToConstant: 118)
        sourceScrollMaxHeightConstraint.isActive = false

        NSLayoutConstraint.activate([
            sourceHeaderRow.topAnchor.constraint(equalTo: sourceSection.topAnchor, constant: 10),
            sourceHeaderRow.leadingAnchor.constraint(equalTo: sourceSection.leadingAnchor, constant: 13),
            sourceHeaderRow.trailingAnchor.constraint(equalTo: sourceSection.trailingAnchor, constant: -11),

            sourceScrollView.topAnchor.constraint(equalTo: sourceHeaderRow.bottomAnchor, constant: 4),
            sourceScrollView.leadingAnchor.constraint(equalTo: sourceSection.leadingAnchor, constant: 6),
            sourceScrollView.trailingAnchor.constraint(equalTo: sourceSection.trailingAnchor, constant: -6),
            sourceScrollView.bottomAnchor.constraint(equalTo: sourceSection.bottomAnchor, constant: -8),
            sourceScrollMinHeightConstraint,
        ])

        // 3b. 中腰语种流向桥梁条（自动检测 → 简体中文 + 状态）
        sourceLanguagePopUp.addItems(withTitles: Self.sourceLanguages.map(\.name))
        sourceLanguagePopUp.target = self
        sourceLanguagePopUp.action = #selector(handleTranslationLanguageChanged)
        sourceLanguagePopUp.toolTip = "源语言（默认自动检测）"
        sourceLanguageContainer = OCRCompactPopUpContainer(popUp: sourceLanguagePopUp, minWidth: 74)

        let arrowConfig = NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [.secondaryLabelColor]))
        bridgeArrowIcon.image = NSImage(systemSymbolName: "arrow.right", accessibilityDescription: "翻译为")?
            .withSymbolConfiguration(arrowConfig)
        bridgeArrowIcon.setContentHuggingPriority(.required, for: .horizontal)
        bridgeArrowIcon.translatesAutoresizingMaskIntoConstraints = false

        languagePopUp.addItems(withTitles: Self.targetLanguages.map(\.name))
        languagePopUp.target = self
        languagePopUp.action = #selector(handleTranslationLanguageChanged)
        languagePopUp.toolTip = "目标语言"
        targetLanguageContainer = OCRCompactPopUpContainer(popUp: languagePopUp, minWidth: 80)

        bridgeStatusLabel.font = .systemFont(ofSize: 11.5)
        bridgeStatusLabel.textColor = .secondaryLabelColor
        bridgeStatusLabel.lineBreakMode = .byTruncatingTail
        bridgeStatusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        bridgeStatusLabel.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        bridgeStatusLabel.alignment = .right

        bridgeLanguageStack.orientation = .horizontal
        bridgeLanguageStack.alignment = .centerY
        bridgeLanguageStack.spacing = 6
        bridgeLanguageStack.setContentHuggingPriority(.required, for: .horizontal)
        bridgeLanguageStack.translatesAutoresizingMaskIntoConstraints = false
        bridgeLanguageStack.addArrangedSubview(sourceLanguageContainer)
        bridgeLanguageStack.addArrangedSubview(bridgeArrowIcon)

        let bridgeSpacer = NSView()
        bridgeSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        bridgeSpacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let bridgeRow = NSStackView(views: [bridgeLanguageStack, bridgeSpacer, bridgeStatusLabel])
        bridgeRow.orientation = .horizontal
        bridgeRow.alignment = .centerY
        bridgeRow.spacing = 8
        bridgeRow.translatesAutoresizingMaskIntoConstraints = false

        translationBridgeView.translatesAutoresizingMaskIntoConstraints = false
        translationBridgeView.wantsLayer = true
        translationBridgeView.addSubview(bridgeRow)
        NSLayoutConstraint.activate([
            translationBridgeView.heightAnchor.constraint(equalToConstant: 36),
            bridgeRow.leadingAnchor.constraint(equalTo: translationBridgeView.leadingAnchor, constant: 12),
            bridgeRow.trailingAnchor.constraint(equalTo: translationBridgeView.trailingAnchor, constant: -12),
            bridgeRow.centerYAnchor.constraint(equalTo: translationBridgeView.centerYAnchor),
        ])

        // 3c. 译文区（下半区，视觉主角）
        translationHeaderLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        translationHeaderLabel.textColor = AnShotTheme.accent
        translationHeaderLabel.setContentHuggingPriority(.required, for: .horizontal)

        translationSpinner.style = .spinning
        translationSpinner.controlSize = .mini
        translationSpinner.isIndeterminate = true
        translationSpinner.isHidden = true
        translationSpinner.translatesAutoresizingMaskIntoConstraints = false

        copyBilingualButton = OCRGhostActionButton(
            title: "复制双语",
            symbolName: "text.justify.left",
            style: .neutral,
            target: self,
            action: #selector(handleCopyBilingual)
        )
        copyBilingualButton.toolTip = "复制逐段原文与译文对照"
        copyBilingualButton.isHidden = true

        let transHeaderSpacer = NSView()
        transHeaderSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let transHeaderRow = NSStackView(views: [
            translationHeaderLabel,
            translationSpinner,
            transHeaderSpacer,
            copyBilingualButton,
        ])
        transHeaderRow.orientation = .horizontal
        transHeaderRow.alignment = .centerY
        transHeaderRow.spacing = 6
        transHeaderRow.translatesAutoresizingMaskIntoConstraints = false

        configureTextView(translationTextView, editable: false, fontSize: 15, lineHeightMultiple: 1.48)

        translationScrollView.hasVerticalScroller = true
        translationScrollView.autohidesScrollers = true
        translationScrollView.drawsBackground = false
        translationScrollView.borderType = .noBorder
        translationScrollView.documentView = translationTextView
        translationScrollView.automaticallyAdjustsContentInsets = false
        translationScrollView.contentInsets = NSEdgeInsetsZero
        translationScrollView.translatesAutoresizingMaskIntoConstraints = false

        translationSectionView.translatesAutoresizingMaskIntoConstraints = false
        translationSectionView.setContentHuggingPriority(.defaultLow, for: .vertical)
        translationSectionView.addSubview(transHeaderRow)
        translationSectionView.addSubview(translationScrollView)

        NSLayoutConstraint.activate([
            transHeaderRow.topAnchor.constraint(equalTo: translationSectionView.topAnchor, constant: 10),
            transHeaderRow.leadingAnchor.constraint(equalTo: translationSectionView.leadingAnchor, constant: 13),
            transHeaderRow.trailingAnchor.constraint(equalTo: translationSectionView.trailingAnchor, constant: -11),

            translationScrollView.topAnchor.constraint(equalTo: transHeaderRow.bottomAnchor, constant: 4),
            translationScrollView.leadingAnchor.constraint(equalTo: translationSectionView.leadingAnchor, constant: 6),
            translationScrollView.trailingAnchor.constraint(equalTo: translationSectionView.trailingAnchor, constant: -6),
            translationScrollView.bottomAnchor.constraint(equalTo: translationSectionView.bottomAnchor, constant: -10),
            translationScrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 96),
        ])

        // 主卡片内部纵栈
        let cardStack = NSStackView(views: [
            sourceSection,
            bridgeTopDivider,
            translationBridgeView,
            bridgeBottomDivider,
            translationSectionView,
        ])
        cardStack.orientation = .vertical
        cardStack.alignment = .leading
        cardStack.spacing = 0
        cardStack.translatesAutoresizingMaskIntoConstraints = false
        mainCard.addSubview(cardStack)

        NSLayoutConstraint.activate([
            cardStack.topAnchor.constraint(equalTo: mainCard.topAnchor, constant: 1),
            cardStack.leadingAnchor.constraint(equalTo: mainCard.leadingAnchor, constant: 1),
            cardStack.trailingAnchor.constraint(equalTo: mainCard.trailingAnchor, constant: -1),
            cardStack.bottomAnchor.constraint(equalTo: mainCard.bottomAnchor, constant: -1),

            sourceSection.widthAnchor.constraint(equalTo: cardStack.widthAnchor),
            bridgeTopDivider.widthAnchor.constraint(equalTo: cardStack.widthAnchor),
            translationBridgeView.widthAnchor.constraint(equalTo: cardStack.widthAnchor),
            bridgeBottomDivider.widthAnchor.constraint(equalTo: cardStack.widthAnchor),
            translationSectionView.widthAnchor.constraint(equalTo: cardStack.widthAnchor),
        ])

        // 加载/错误遮罩覆盖整个主卡片
        statusOverlay.isHidden = true
        statusOverlay.translatesAutoresizingMaskIntoConstraints = false
        mainCard.addSubview(statusOverlay)

        progressIndicator.style = .spinning
        progressIndicator.controlSize = .small
        progressIndicator.isIndeterminate = true
        progressIndicator.translatesAutoresizingMaskIntoConstraints = false
        statusOverlay.addSubview(progressIndicator)

        overlayLabel.alignment = .center
        overlayLabel.font = .systemFont(ofSize: 12.5, weight: .medium)
        overlayLabel.textColor = .secondaryLabelColor
        overlayLabel.lineBreakMode = .byWordWrapping
        overlayLabel.maximumNumberOfLines = 0
        overlayLabel.preferredMaxLayoutWidth = Self.minimumSize.width - Self.margin * 2 - 48
        overlayLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        overlayLabel.translatesAutoresizingMaskIntoConstraints = false
        statusOverlay.addSubview(overlayLabel)

        NSLayoutConstraint.activate([
            statusOverlay.topAnchor.constraint(equalTo: mainCard.topAnchor),
            statusOverlay.leadingAnchor.constraint(equalTo: mainCard.leadingAnchor),
            statusOverlay.trailingAnchor.constraint(equalTo: mainCard.trailingAnchor),
            statusOverlay.bottomAnchor.constraint(equalTo: mainCard.bottomAnchor),

            overlayLabel.centerXAnchor.constraint(equalTo: statusOverlay.centerXAnchor),
            overlayLabel.centerYAnchor.constraint(equalTo: statusOverlay.centerYAnchor, constant: 10),
            overlayLabel.leadingAnchor.constraint(equalTo: statusOverlay.leadingAnchor, constant: 24),
            overlayLabel.trailingAnchor.constraint(equalTo: statusOverlay.trailingAnchor, constant: -24),

            progressIndicator.centerXAnchor.constraint(equalTo: statusOverlay.centerXAnchor),
            progressIndicator.bottomAnchor.constraint(equalTo: overlayLabel.topAnchor, constant: -12),
        ])

        // ── 4. 聚焦底栏 ────────────────────────────────────────
        copyButton = OCRFooterButton(
            title: "复制原文",
            symbolName: "doc.on.doc",
            emphasis: .primary,
            target: self,
            action: #selector(handleCopy)
        )
        copyButton.toolTip = "智能复制（⇧⌘C，翻译后优先复制译文）"

        translateButton = OCRFooterButton(
            title: "翻译",
            symbolName: "character.book.closed",
            emphasis: .secondary,
            target: self,
            action: #selector(handleTranslate)
        )
        translateButton.toolTip = "翻译当前文本（⌘↩）"

        footerRightStack.orientation = .horizontal
        footerRightStack.alignment = .centerY
        footerRightStack.spacing = 8
        footerRightStack.translatesAutoresizingMaskIntoConstraints = false
        footerRightStack.addArrangedSubview(translateButton)

        let footerSpacer = NSView()
        footerSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        footerRow.orientation = .horizontal
        footerRow.alignment = .centerY
        footerRow.spacing = 8
        footerRow.translatesAutoresizingMaskIntoConstraints = false
        footerRow.addArrangedSubview(copyButton)
        footerRow.addArrangedSubview(footerSpacer)
        footerRow.addArrangedSubview(footerRightStack)

        // ── 5. 顶层主纵栈 ──────────────────────────────────────
        let mainStack = NSStackView(views: [
            topBar,
            barcodeStackView,
            mainCard,
            footerRow,
        ])
        mainStack.orientation = .vertical
        mainStack.alignment = .leading
        mainStack.spacing = 10
        mainStack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(mainStack)

        NSLayoutConstraint.activate([
            mainStack.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            mainStack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: Self.margin),
            mainStack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -Self.margin),
            mainStack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -Self.margin),

            topBar.widthAnchor.constraint(equalTo: mainStack.widthAnchor),
            barcodeStackView.widthAnchor.constraint(equalTo: mainStack.widthAnchor),
            mainCard.widthAnchor.constraint(equalTo: mainStack.widthAnchor),
            footerRow.widthAnchor.constraint(equalTo: mainStack.widthAnchor),
        ])

        panel.contentView = content

        // 初始落入纯 OCR 单区态
        setTranslationSectionExpanded(false)
    }

    private func configureTextView(
        _ textView: NSTextView,
        editable: Bool,
        fontSize: CGFloat,
        lineHeightMultiple: CGFloat
    ) {
        textView.isEditable = editable
        textView.isSelectable = true
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = editable
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 7, height: 4)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(
            width: Self.defaultSize.width - Self.margin * 2 - 28,
            height: .greatestFiniteMagnitude
        )

        let paragraph = NSMutableParagraphStyle()
        paragraph.lineHeightMultiple = lineHeightMultiple
        paragraph.paragraphSpacing = 3
        textView.defaultParagraphStyle = paragraph
        textView.typingAttributes = [
            .font: NSFont.systemFont(ofSize: fontSize),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: paragraph,
        ]
        textView.font = .systemFont(ofSize: fontSize)
        textView.textColor = .labelColor
    }

    // MARK: - 布局形态切换（纯 OCR 单区 ↔ 翻译双栏上下对照）

    private func setTranslationSectionExpanded(_ expanded: Bool) {
        isTranslationSectionExpanded = expanded

        bridgeTopDivider.isHidden = !expanded
        translationBridgeView.isHidden = !expanded
        bridgeBottomDivider.isHidden = !expanded
        translationSectionView.isHidden = !expanded
        copyOriginalButton.isHidden = !expanded

        // 将目标语言下拉容器平滑摆放到当前形态最自然的位置（唯一实例，零状态失同步）
        targetLanguageContainer.removeFromSuperview()
        if expanded {
            bridgeLanguageStack.addArrangedSubview(targetLanguageContainer)
            sourceScrollMinHeightConstraint.constant = 64
            sourceScrollMaxHeightConstraint.isActive = true
        } else {
            footerRightStack.insertArrangedSubview(targetLanguageContainer, at: 0)
            sourceScrollMaxHeightConstraint.isActive = false
            sourceScrollMinHeightConstraint.constant = 160
        }

        refreshHeaderAppearance()
        refreshFooterAppearance()
        refreshSourceTypography()
    }

    private func refreshHeaderAppearance() {
        if isTextOnlyMode {
            headerBadgeView.symbolName = "character.book.closed.fill"
            headerBadgeView.badgeColor = Self.translationBadgeColor
            headerTitleLabel.stringValue = "划词翻译"
            panel.title = "划词翻译"
        } else if isTranslationSectionExpanded {
            headerBadgeView.symbolName = "character.book.closed.fill"
            headerBadgeView.badgeColor = Self.translationBadgeColor
            headerTitleLabel.stringValue = "截图翻译"
            panel.title = "截图翻译"
        } else {
            headerBadgeView.symbolName = "text.viewfinder"
            headerBadgeView.badgeColor = Self.ocrBadgeColor
            headerTitleLabel.stringValue = "文字识别"
            panel.title = "文字识别"
        }
        ocrLanguageContainer.isHidden = isTextOnlyMode
        mergeLineBreaksButton.isHidden = isTextOnlyMode
    }

    private func refreshFooterAppearance() {
        let hasValidTranslation = (translationResult?.isEntirelyUntranslated == false)
        copyButton.title = hasValidTranslation ? "复制译文" : "复制原文"
        copyButton.setSymbolName("doc.on.doc")

        if isTranslating {
            translateButton.title = "翻译中…"
            translateButton.setSymbolName("hourglass")
        } else if isTranslationSectionExpanded {
            translateButton.title = "重新翻译"
            translateButton.setSymbolName("arrow.clockwise")
        } else {
            translateButton.title = "翻译"
            translateButton.setSymbolName("character.book.closed")
        }
    }

    private func refreshSourceTypography() {
        let size: CGFloat = isTranslationSectionExpanded ? 13 : 14
        let lineHeight: CGFloat = isTranslationSectionExpanded ? 1.40 : 1.46
        applyStyledText(
            sourceTextView.string,
            to: sourceTextView,
            fontSize: size,
            lineHeightMultiple: lineHeight,
            color: .labelColor
        )
    }

    // MARK: - 配置同步

    /// 应用持久化偏好（识别语言、段落合并开关、目标语言）。
    func applyPreferences(
        ocrLanguage: OCRLanguagePreference,
        mergeLineBreaks: Bool,
        targetLanguage: String
    ) {
        if let index = OCRLanguagePreference.allCases.firstIndex(of: ocrLanguage) {
            ocrLanguagePopUp.selectItem(at: index)
        }
        mergeLineBreaksButton.isActive = mergeLineBreaks
        selectTargetLanguage(identifier: targetLanguage)
    }

    /// 选中指定目标语种（不存在时保持当前或回退首项）。
    func selectTargetLanguage(identifier: String) {
        if let index = Self.targetLanguages.firstIndex(where: {
            $0.id.caseInsensitiveCompare(identifier) == .orderedSame
                || TranslationLanguage.isSameLanguage($0.id, identifier)
        }) {
            languagePopUp.selectItem(at: index)
        }
    }

    /// 切换浮窗置顶状态。
    func setAlwaysOnTop(_ alwaysOnTop: Bool) {
        isAlwaysOnTop = alwaysOnTop
        panel.level = alwaysOnTop ? .floating : .normal
        refreshPinOnTopButton()
    }

    private func refreshPinOnTopButton() {
        pinOnTopButton.isPinned = isAlwaysOnTop
        pinOnTopButton.toolTip = isAlwaysOnTop ? "已置顶（点击取消置顶）" : "未置顶（点击置顶）"
    }

    // MARK: - 展示入口

    /// 识别中：立即弹出独立浮窗并展示加载状态。
    func showLoading(near selectionScreenRect: CGRect, message: String = "正在识别文字…") {
        isTextOnlyMode = false
        isTranslating = false
        lastOCRResult = nil
        rawOriginalText = ""
        editedOriginalText = nil
        translationResult = nil
        translationErrorMessage = nil
        displayMode = .original
        copyButton.resetFeedback()
        copyOriginalButton.resetFeedback()
        copyBilingualButton.resetFeedback()

        updateBarcodeCards([])
        setTranslationSectionExpanded(false)
        setSourceText("")
        setTranslationPlaceholder("")
        sourceHeaderLabel.stringValue = "原文"
        bridgeStatusLabel.stringValue = ""
        setOverlay(message: message, spinning: true)
        copyButton.isEnabled = false
        refreshTranslationControls(hasLines: false)
        present(near: selectionScreenRect)
    }

    /// 识别失败：浮窗留在原地展示可读原因。
    func showError(_ message: String, near selectionScreenRect: CGRect) {
        isTranslating = false
        lastOCRResult = nil
        rawOriginalText = ""
        editedOriginalText = nil
        translationResult = nil
        translationErrorMessage = nil
        displayMode = .original
        copyButton.resetFeedback()

        updateBarcodeCards([])
        setTranslationSectionExpanded(false)
        setSourceText("")
        setTranslationPlaceholder("")
        sourceHeaderLabel.stringValue = "原文"
        bridgeStatusLabel.stringValue = ""
        setOverlay(message: message, spinning: false)
        copyButton.isEnabled = false
        refreshTranslationControls(hasLines: false)
        present(near: selectionScreenRect)
    }

    /// 展示完整 OCR 识别结果（含二维码/条码卡片与可编辑原文）。
    func show(result: OCRResult, near selectionScreenRect: CGRect) {
        isTextOnlyMode = false
        setOverlay(message: nil, spinning: false)
        lastOCRResult = result
        rawOriginalText = result.plainText
        editedOriginalText = nil
        translationResult = nil
        translationErrorMessage = nil
        displayMode = .original
        copyButton.resetFeedback()
        copyOriginalButton.resetFeedback()
        copyBilingualButton.resetFeedback()
        copyBilingualButton.isHidden = true

        updateBarcodeCards(result.barcodes)
        setTranslationSectionExpanded(false)
        refreshSourceTextView()
        sourceHeaderLabel.stringValue = Self.sourceHeaderText(for: result)
        bridgeStatusLabel.stringValue = ""

        let hasText = !currentEditableOriginalText.isEmpty
        copyButton.isEnabled = hasText
        refreshTranslationControls(hasLines: hasText)
        present(near: selectionScreenRect)
    }

    /// 展示纯文本划词输入（例如 `⌥D` 划词翻译或悬浮胶囊点击），直接展开上下对照准备翻译。
    func showSourceText(_ text: String, near anchorScreenRect: CGRect) {
        isTextOnlyMode = true
        setOverlay(message: nil, spinning: false)
        lastOCRResult = nil
        rawOriginalText = text
        editedOriginalText = nil
        translationResult = nil
        translationErrorMessage = nil
        displayMode = .original
        copyButton.resetFeedback()
        copyOriginalButton.resetFeedback()
        copyBilingualButton.resetFeedback()
        copyBilingualButton.isHidden = true

        updateBarcodeCards([])
        setTranslationSectionExpanded(true)
        refreshSourceTextView()
        sourceHeaderLabel.stringValue = "原文 · 可编辑后按 ⌘↩ 重译"
        setTranslationPlaceholder("准备翻译…")
        bridgeStatusLabel.stringValue = ""

        let hasText = !currentEditableOriginalText.isEmpty
        copyButton.isEnabled = hasText
        refreshTranslationControls(hasLines: hasText)
        present(near: anchorScreenRect)
    }

    /// 构造供翻译提交的行数组（若用户编辑过原文或开启合并换行，按当前正文实时切行）。
    func linesForTranslation() -> [OCRTextLine] {
        let activeText = currentEditableOriginalText
        guard !activeText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return []
        }
        if editedOriginalText == nil, !isMergeLineBreaksEnabled, let result = lastOCRResult, !result.lines.isEmpty {
            return result.lines
        }
        let rawLines = activeText
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return rawLines.map { text in
            OCRTextLine(text: text, candidates: [text], confidence: 1, boundingBox: .zero)
        }
    }

    /// 当前原文文本（优先人工编辑版；否则根据「合并换行」实时生成无损逐行/合并段落）。
    var currentEditableOriginalText: String {
        if let editedOriginalText {
            return editedOriginalText
        }
        if isMergeLineBreaksEnabled {
            if let result = lastOCRResult {
                return result.paragraphText
            }
            return OCRParagraphMerger.merge(plainText: rawOriginalText)
        }
        return rawOriginalText
    }

    /// 无损切换「合并换行」状态（供单元测试与外部调用）。
    func setMergeLineBreaks(_ enabled: Bool, notify: Bool = false) {
        mergeLineBreaksButton.isActive = enabled
        if editedOriginalText == nil {
            refreshSourceTextView()
        }
        if notify {
            onMergeLineBreaksChanged?(enabled)
        }
    }

    /// 智能复制文本：译文存在时优先返回译文，否则返回当前原文。
    var smartCopyText: String {
        if let result = translationResult, !result.isEntirelyUntranslated {
            return result.segments.map(\.displayText).joined(separator: "\n")
        }
        return currentEditableOriginalText
    }

    private static func sourceHeaderText(for result: OCRResult) -> String {
        let lineCount = result.lines.count
        let codeCount = result.barcodes.count
        if lineCount == 0 && codeCount == 0 {
            return "未识别到文字或二维码"
        }
        var parts: [String] = []
        if lineCount > 0 { parts.append("原文 · \(lineCount) 行") }
        if codeCount > 0 { parts.append("\(codeCount) 个码") }
        return parts.joined(separator: " · ")
    }

    private static func bilingualText(for result: TranslationResult) -> String {
        result.segments.map { segment in
            if let translated = segment.translatedText,
               !translated.isEmpty,
               translated != segment.sourceText {
                return "\(segment.sourceText)\n\(translated)"
            }
            return segment.sourceText
        }.joined(separator: "\n\n")
    }

    // MARK: - 二维码 / 条码内嵌卡片

    private func updateBarcodeCards(_ barcodes: [BarcodeItem]) {
        displayedBarcodes = barcodes
        for view in barcodeStackView.arrangedSubviews {
            barcodeStackView.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        guard !barcodes.isEmpty else {
            barcodeStackView.isHidden = true
            return
        }
        for (index, item) in barcodes.enumerated() {
            let card = makeBarcodeCard(item, index: index)
            barcodeStackView.addArrangedSubview(card)
            card.widthAnchor.constraint(equalTo: barcodeStackView.widthAnchor).isActive = true
        }
        barcodeStackView.isHidden = false
    }

    private func makeBarcodeCard(_ item: BarcodeItem, index: Int) -> NSView {
        let card = ThemedSurfaceView(kind: .card, cornerRadius: 10)
        card.translatesAutoresizingMaskIntoConstraints = false

        // 左侧二维码柔和圆角图标徽章
        let iconTile = NSView()
        iconTile.wantsLayer = true
        iconTile.layer?.cornerRadius = 7
        iconTile.layer?.cornerCurve = .continuous
        iconTile.layer?.backgroundColor = Self.ocrBadgeColor.withAlphaComponent(0.14).cgColor
        iconTile.translatesAutoresizingMaskIntoConstraints = false

        let iconView = NSImageView()
        let symName = item.symbology.lowercased().contains("qr") ? "qrcode" : "barcode"
        let cfg = NSImage.SymbolConfiguration(pointSize: 12.5, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [Self.ocrBadgeColor]))
        iconView.image = NSImage(systemSymbolName: symName, accessibilityDescription: nil)?
            .withSymbolConfiguration(cfg)
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconTile.addSubview(iconView)
        NSLayoutConstraint.activate([
            iconTile.widthAnchor.constraint(equalToConstant: 26),
            iconTile.heightAnchor.constraint(equalToConstant: 26),
            iconView.centerXAnchor.constraint(equalTo: iconTile.centerXAnchor),
            iconView.centerYAnchor.constraint(equalTo: iconTile.centerYAnchor),
        ])

        let kindLabel = NSTextField(labelWithString: Self.symbologyDisplayName(item.symbology))
        kindLabel.font = .systemFont(ofSize: 10.5, weight: .semibold)
        kindLabel.textColor = Self.ocrBadgeColor
        kindLabel.setContentHuggingPriority(.required, for: .horizontal)

        let payloadLabel = NSTextField(labelWithString: item.payload)
        payloadLabel.font = .monospacedSystemFont(ofSize: 11.5, weight: .regular)
        payloadLabel.textColor = .labelColor
        payloadLabel.lineBreakMode = .byTruncatingMiddle
        payloadLabel.toolTip = item.payload
        payloadLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        payloadLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let textStack = NSStackView(views: [kindLabel, payloadLabel])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 1
        textStack.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let copyBtn = OCRGhostActionButton(
            title: "复制",
            symbolName: "doc.on.doc",
            style: .neutral,
            target: self,
            action: #selector(handleCopyBarcode(_:))
        )
        copyBtn.tag = index

        var views: [NSView] = [iconTile, textStack, copyBtn]
        if item.isWebURL {
            let openBtn = OCRGhostActionButton(
                title: "打开",
                symbolName: "arrow.up.right",
                style: .accent,
                target: self,
                action: #selector(handleOpenBarcodeURL(_:))
            )
            openBtn.tag = index
            views.append(openBtn)
        }

        let row = NSStackView(views: views)
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(row)

        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: card.topAnchor, constant: 7),
            row.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -7),
            row.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 9),
            row.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -9),
        ])
        return card
    }

    private static func symbologyDisplayName(_ symbology: String) -> String {
        let lower = symbology.lowercased()
        if lower.contains("qr") { return "二维码" }
        if lower.contains("aztec") { return "Aztec" }
        if lower.contains("pdf417") { return "PDF417" }
        if lower.contains("datamatrix") { return "DataMatrix" }
        return "条形码"
    }

    @objc private func handleCopyBarcode(_ sender: NSButton) {
        guard sender.tag >= 0, sender.tag < displayedBarcodes.count else { return }
        onCopyAll?(displayedBarcodes[sender.tag].payload)
        (sender as? OCRGhostActionButton)?.flashCopiedFeedback()
    }

    @objc private func handleOpenBarcodeURL(_ sender: NSButton) {
        guard sender.tag >= 0, sender.tag < displayedBarcodes.count,
              let url = displayedBarcodes[sender.tag].webURL else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - 选区避让与展示

    /// 计算不遮挡选区且不越出屏幕安全区的最佳落点（纯函数，便于单元测试断言）。
    ///
    /// 优先级：右侧 → 左侧 → 下方 → 上方 → 屏幕居中安全区。
    static func preferredFrame(
        near selectionScreenRect: CGRect,
        panelSize: CGSize,
        visibleFrame: CGRect,
        gap: CGFloat = 12
    ) -> CGRect {
        let width = min(panelSize.width, max(minimumSize.width, visibleFrame.width - gap * 2))
        let height = min(panelSize.height, max(minimumSize.height, visibleFrame.height - gap * 2))
        let size = CGSize(width: width, height: height)

        func clampY(_ y: CGFloat) -> CGFloat {
            let minY = visibleFrame.minY + gap
            let maxY = max(minY, visibleFrame.maxY - size.height - gap)
            return min(max(y, minY), maxY)
        }
        func clampX(_ x: CGFloat) -> CGFloat {
            let minX = visibleFrame.minX + gap
            let maxX = max(minX, visibleFrame.maxX - size.width - gap)
            return min(max(x, minX), maxX)
        }

        // 1. 右侧空间充足
        let rightX = selectionScreenRect.maxX + gap
        if rightX + size.width <= visibleFrame.maxX - gap {
            let y = clampY(selectionScreenRect.maxY - size.height)
            return CGRect(origin: CGPoint(x: rightX, y: y), size: size)
        }

        // 2. 左侧空间充足
        let leftX = selectionScreenRect.minX - gap - size.width
        if leftX >= visibleFrame.minX + gap {
            let y = clampY(selectionScreenRect.maxY - size.height)
            return CGRect(origin: CGPoint(x: leftX, y: y), size: size)
        }

        // 3. 下方空间充足（宽选区避让核心：放下方而不覆盖选区本体）
        let belowY = selectionScreenRect.minY - gap - size.height
        if belowY >= visibleFrame.minY + gap {
            let x = clampX(selectionScreenRect.midX - size.width / 2)
            return CGRect(origin: CGPoint(x: x, y: belowY), size: size)
        }

        // 4. 上方空间充足
        let aboveY = selectionScreenRect.maxY + gap
        if aboveY + size.height <= visibleFrame.maxY - gap {
            let x = clampX(selectionScreenRect.midX - size.width / 2)
            return CGRect(origin: CGPoint(x: x, y: aboveY), size: size)
        }

        // 5. 选区极大（接近整屏）：居中落在可见区安全范围内
        let centerX = clampX(visibleFrame.midX - size.width / 2)
        let centerY = clampY(visibleFrame.midY - size.height / 2)
        return CGRect(origin: CGPoint(x: centerX, y: centerY), size: size)
    }

    private func present(near selectionScreenRect: CGRect) {
        if !panel.isVisible {
            let screen = NSScreen.screens.first { $0.frame.intersects(selectionScreenRect) } ?? NSScreen.main
            let visible = screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
            let targetHeight: CGFloat = isTranslationSectionExpanded ? 430 : 350
            let desiredSize = CGSize(
                width: max(Self.defaultSize.width, panel.frame.width),
                height: max(targetHeight, panel.frame.height)
            )
            let frame = Self.preferredFrame(
                near: selectionScreenRect,
                panelSize: desiredSize,
                visibleFrame: visible
            )
            panel.setFrame(frame, display: true)
        }
        panel.orderFrontRegardless()
        panel.makeKey()
    }

    private func setSourceText(_ text: String) {
        isProgrammaticallyUpdatingText = true
        let size: CGFloat = isTranslationSectionExpanded ? 13 : 14
        let lineHeight: CGFloat = isTranslationSectionExpanded ? 1.40 : 1.46
        applyStyledText(text, to: sourceTextView, fontSize: size, lineHeightMultiple: lineHeight, color: .labelColor)
        isProgrammaticallyUpdatingText = false
        sourceTextView.scrollRangeToVisible(NSRange(location: 0, length: 0))
    }

    private func setTranslationText(_ text: String, color: NSColor = .labelColor) {
        applyStyledText(text, to: translationTextView, fontSize: 15, lineHeightMultiple: 1.48, color: color)
        translationTextView.scrollRangeToVisible(NSRange(location: 0, length: 0))
    }

    private func setTranslationPlaceholder(_ text: String) {
        applyStyledText(text, to: translationTextView, fontSize: 13.5, lineHeightMultiple: 1.44, color: .secondaryLabelColor)
    }

    private func applyStyledText(
        _ text: String,
        to textView: NSTextView,
        fontSize: CGFloat,
        lineHeightMultiple: CGFloat,
        color: NSColor
    ) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineHeightMultiple = lineHeightMultiple
        paragraph.paragraphSpacing = 3
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: fontSize),
            .foregroundColor: color,
            .paragraphStyle: paragraph,
        ]
        textView.typingAttributes = attributes
        textView.textStorage?.setAttributedString(NSAttributedString(string: text, attributes: attributes))
    }

    private func refreshSourceTextView() {
        setSourceText(currentEditableOriginalText)
    }

    private func setOverlay(message: String?, spinning: Bool) {
        if let message {
            overlayLabel.stringValue = message
            statusOverlay.isHidden = false
            if spinning {
                progressIndicator.startAnimation(nil)
            } else {
                progressIndicator.stopAnimation(nil)
            }
            progressIndicator.isHidden = !spinning
        } else {
            progressIndicator.stopAnimation(nil)
            statusOverlay.isHidden = true
        }
    }

    // MARK: - 译文与状态更新

    /// 展示译文（自动展开上下对照单卡，将译文作为视觉主角呈现）。
    func showTranslation(_ result: TranslationResult, diagnosticMessage: String? = nil) {
        translationResult = result
        displayMode = .translation
        translationSpinner.stopAnimation(nil)
        translationSpinner.isHidden = true

        if !isTranslationSectionExpanded {
            setTranslationSectionExpanded(true)
            expandPanelHeightIfNeeded()
        } else {
            refreshHeaderAppearance()
            refreshFooterAppearance()
        }

        let detail = diagnosticMessage?.trimmingCharacters(in: .whitespacesAndNewlines)
        if result.isEntirelyUntranslated {
            let reason = (detail?.isEmpty == false) ? "翻译失败：\(detail!)" : "翻译不可用，已保留原文"
            translationErrorMessage = reason
            setStatusText(reason, tone: .warning)
            setTranslationText(reason, color: AnShotTheme.warning)
            copyBilingualButton.isHidden = true
        } else if result.isPartiallyTranslated {
            translationErrorMessage = nil
            let summary = (detail?.isEmpty == false)
                ? "已译 \(result.translatedCount)/\(result.segments.count) 行（\(detail!)）"
                : "已译 \(result.translatedCount)/\(result.segments.count) 行 · 部分保留原文"
            setStatusText(summary, tone: .neutral)
            setTranslationText(result.segments.map(\.displayText).joined(separator: "\n"))
            copyBilingualButton.isHidden = false
        } else {
            translationErrorMessage = nil
            setStatusText("已译 \(result.translatedCount) 行", tone: .neutral)
            setTranslationText(result.segments.map(\.displayText).joined(separator: "\n"))
            copyBilingualButton.isHidden = false
        }

        copyButton.isEnabled = !smartCopyText.isEmpty
        refreshTranslationControls(hasLines: !currentEditableOriginalText.isEmpty)
    }

    /// 面板从纯 OCR 单区态切入翻译双栏态时，如当前高度偏矮则柔和扩展到舒适双栏高度。
    private func expandPanelHeightIfNeeded() {
        let minDualHeight: CGFloat = 430
        guard panel.frame.height < minDualHeight else { return }
        var next = panel.frame
        let delta = minDualHeight - next.height
        next.size.height = minDualHeight
        next.origin.y -= delta
        if let visible = panel.screen?.visibleFrame {
            if next.minY < visible.minY + 12 {
                next.origin.y = visible.minY + 12
            }
            if next.maxY > visible.maxY - 12 {
                next.size.height = min(next.size.height, visible.height - 24)
                next.origin.y = visible.maxY - 12 - next.size.height
            }
        }
        panel.setFrame(next, display: true, animate: panel.isVisible)
    }

    private enum StatusTone {
        case neutral
        case warning
    }

    private func setStatusText(_ text: String, tone: StatusTone) {
        bridgeStatusLabel.stringValue = text
        bridgeStatusLabel.toolTip = text.isEmpty ? nil : text
        bridgeStatusLabel.textColor = (tone == .warning) ? AnShotTheme.warning : .secondaryLabelColor
    }

    // MARK: - NSTextViewDelegate

    func textDidChange(_ notification: Notification) {
        guard !isProgrammaticallyUpdatingText else { return }
        editedOriginalText = sourceTextView.string
        let hasText = !sourceTextView.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        copyButton.isEnabled = hasText || (translationResult?.isEntirelyUntranslated == false)
        refreshTranslationControls(hasLines: hasText)
    }

    // MARK: - 状态控制

    func showTranslationUnavailable(_ availability: TranslationAvailability) {
        if !isTranslationSectionExpanded {
            setTranslationSectionExpanded(true)
            expandPanelHeightIfNeeded()
        }
        translationSpinner.stopAnimation(nil)
        translationSpinner.isHidden = true
        setStatusText(availability.explanation, tone: .warning)
        setTranslationText(availability.explanation, color: AnShotTheme.warning)
        applyTranslationAvailability(availability)
    }

    func applyTranslationAvailability(_ availability: TranslationAvailability) {
        translationAvailability = availability
        refreshTranslationControls(hasLines: !currentEditableOriginalText.isEmpty)
    }

    func setTranslating(_ translating: Bool) {
        isTranslating = translating
        if translating {
            if !isTranslationSectionExpanded {
                setTranslationSectionExpanded(true)
                expandPanelHeightIfNeeded()
            }
            translationSpinner.isHidden = false
            translationSpinner.startAnimation(nil)
            setStatusText("正在翻译…", tone: .neutral)
            if translationResult == nil {
                setTranslationPlaceholder("正在翻译中…")
            }
        } else {
            translationSpinner.stopAnimation(nil)
            translationSpinner.isHidden = true
            if bridgeStatusLabel.stringValue == "正在翻译…" {
                setStatusText("翻译已取消", tone: .neutral)
            }
        }
        refreshFooterAppearance()
        refreshTranslationControls(hasLines: !currentEditableOriginalText.isEmpty)
    }

    func hide() {
        statusOverlay.isHidden = true
        progressIndicator.stopAnimation(nil)
        translationSpinner.stopAnimation(nil)
        copyButton.resetFeedback()
        copyOriginalButton.resetFeedback()
        copyBilingualButton.resetFeedback()
        panel.orderOut(nil)
        onClose?()
    }

    func windowWillClose(_ notification: Notification) {
        hide()
    }

    /// 当前选中的源语言（`nil` 表示自动检测）。
    var selectedSourceLanguage: String? {
        let index = sourceLanguagePopUp.indexOfSelectedItem
        guard index >= 0, index < Self.sourceLanguages.count else { return nil }
        return Self.sourceLanguages[index].id
    }

    /// 当前选中的目标语言。
    var selectedTargetLanguage: String {
        let index = languagePopUp.indexOfSelectedItem
        guard index >= 0, index < Self.targetLanguages.count else {
            return Self.targetLanguages[0].id
        }
        return Self.targetLanguages[index].id
    }

    /// 当前选中的 OCR 识别语言偏好。
    var selectedOCRLanguage: OCRLanguagePreference {
        let index = ocrLanguagePopUp.indexOfSelectedItem
        guard index >= 0, index < OCRLanguagePreference.allCases.count else { return .auto }
        return OCRLanguagePreference.allCases[index]
    }

    // MARK: - 诊断支持

    var debugTranslateEnabledForDiagnostics: Bool { translateButton.isEnabled }
    var debugLanguagePopUpEnabledForDiagnostics: Bool { languagePopUp.isEnabled }
    var debugDisplayModeForDiagnostics: DisplayMode { displayMode }
    var debugIsTranslationExpandedForDiagnostics: Bool { isTranslationSectionExpanded }
    var windowForDiagnostics: NSWindow { panel }

    func selectDisplayModeForDiagnostics(_ mode: DisplayMode) {
        guard mode == .original || translationResult != nil else { return }
        displayMode = mode
    }

    private func refreshTranslationControls(hasLines: Bool) {
        let availability = translationAvailability
        let enabled = availability.isAvailable && hasLines && !isTranslating
        translateButton.isEnabled = enabled
        languagePopUp.isEnabled = hasLines
        sourceLanguagePopUp.isEnabled = hasLines
        translateButton.toolTip = availability.isAvailable
            ? "翻译当前文本（⌘↩）"
            : availability.explanation
    }

    // MARK: - 动作

    @objc private func handleOCRLanguageChanged() {
        onOCRLanguageChanged?(selectedOCRLanguage)
    }

    @objc private func handleMergeLineBreaksToggled() {
        let enabled = mergeLineBreaksButton.isActive
        if editedOriginalText == nil {
            refreshSourceTextView()
        }
        onMergeLineBreaksChanged?(enabled)
    }

    @objc private func handleToggleAlwaysOnTop() {
        setAlwaysOnTop(!isAlwaysOnTop)
    }

    @objc private func handleCloseButton() {
        hide()
    }

    @objc private func handleTranslate() {
        onTranslate?(selectedSourceLanguage, selectedTargetLanguage)
    }

    @objc private func handleTranslationLanguageChanged() {
        onTargetLanguageChanged?(selectedSourceLanguage, selectedTargetLanguage)
    }

    @objc private func handleCopy() {
        let payload = smartCopyText
        guard !payload.isEmpty else {
            NSSound.beep()
            return
        }
        onCopyAll?(payload)
        copyButton.flashCopiedFeedback()
    }

    @objc private func handleCopyOriginal() {
        let payload = currentEditableOriginalText
        guard !payload.isEmpty else {
            NSSound.beep()
            return
        }
        onCopyAll?(payload)
        copyOriginalButton.flashCopiedFeedback()
    }

    @objc private func handleCopyBilingual() {
        guard let result = translationResult else { return }
        let payload = Self.bilingualText(for: result)
        guard !payload.isEmpty else { return }
        onCopyAll?(payload)
        copyBilingualButton.flashCopiedFeedback()
    }

    private func triggerRetranslateShortcut() {
        guard !isTranslating,
              !currentEditableOriginalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            NSSound.beep()
            return
        }
        onTranslate?(selectedSourceLanguage, selectedTargetLanguage)
    }

    private func triggerSmartCopy() {
        handleCopy()
    }
}

/// 打开结果面板时的系统翻译入口状态闸门。
///
/// 借助 `AppleTranslationBridge` 极薄 SwiftUI 桥接，本机系统翻译版本台阶降至 **macOS 15.0**。
enum TranslationSupport {

    static func availability(
        for strategy: TranslationStrategy,
        isCloudConfigured: Bool
    ) -> TranslationAvailability {
        switch strategy {
        case .automatic:
            if isCloudConfigured { return .available }
            return localGate()
        case .appleTranslation:
            return localGate()
        case .openAICompatible, .claude:
            guard let kind = strategy.explicitKind else { return .available }
            return isCloudConfigured ? .available : .notConfigured(provider: kind.displayName)
        }
    }

    /// 本机翻译的系统版本台阶（macOS 15.0+）。
    private static func localGate() -> TranslationAvailability {
        if #available(macOS 15.0, *) { return .available }
        return .requiresNewerSystem(
            required: TranslationProviderKind.appleTranslation.requiredSystemVersion ?? "macOS 15.0"
        )
    }
}
