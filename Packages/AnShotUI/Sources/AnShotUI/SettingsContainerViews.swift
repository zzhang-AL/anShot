//
//  SettingsContainerViews.swift
//  AnShotUI
//
//  设置窗口的现代容器与可视化控件：分组卡片、行间分隔线、可视化主题选择卡、
//  状态圆点胶囊、工具栏槽位胶囊网格、文件夹内嵌行与文本输入框外壳。
//
import AppKit

// MARK: - 行间极细分隔线

/// 卡片内部行与行之间的极细分隔线（动态响应深浅外观）。
final class SettingsRowDivider: NSView {
    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        heightAnchor.constraint(equalToConstant: 1).isActive = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("不支持从 nib 构造")
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = SettingsTheme.rowSeparator.cgColor
    }
}

// MARK: - 现代分组卡片

/// 现代 macOS 圆角分组卡片（支持可选语义色小图标 + 顶部标题行 + 自动微影与边框）。
final class SettingsCardView: NSView {

    private let symbolName: String
    private let title: String
    private let accentColor: NSColor?
    private let trailingAccessory: NSView?
    private let content: NSView

    init(
        symbolName: String,
        title: String,
        accentColor: NSColor? = nil,
        trailingAccessory: NSView? = nil,
        content: NSView
    ) {
        self.symbolName = symbolName
        self.title = title
        self.accentColor = accentColor
        self.trailingAccessory = trailingAccessory
        self.content = content
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        buildLayout()
    }

    /// 便捷构造：接收一组行视图并在相邻行之间自动插入极细 `SettingsRowDivider`。
    convenience init(
        symbolName: String,
        title: String,
        accentColor: NSColor? = nil,
        trailingAccessory: NSView? = nil,
        rows: [NSView],
        rowSpacing: CGFloat = SettingsTheme.innerGap,
        showsDividers: Bool = true
    ) {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = rowSpacing
        stack.translatesAutoresizingMaskIntoConstraints = false

        for (idx, row) in rows.enumerated() {
            stack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            if showsDividers && idx < rows.count - 1 {
                let divider = SettingsRowDivider()
                stack.addArrangedSubview(divider)
                divider.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            }
        }
        self.init(
            symbolName: symbolName,
            title: title,
            accentColor: accentColor,
            trailingAccessory: trailingAccessory,
            content: stack
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("不支持从 nib 构造")
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.cornerRadius = SettingsTheme.cardRadius
        layer?.cornerCurve = .continuous
        layer?.backgroundColor = SettingsTheme.cardBackground.cgColor
        layer?.borderWidth = 1
        layer?.borderColor = SettingsTheme.cardBorder.cgColor

        let isDark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = isDark ? 0.22 : 0.045
        layer?.shadowRadius = isDark ? 6 : 5
        layer?.shadowOffset = CGSize(width: 0, height: -1.5)
    }

    private func buildLayout() {
        let header = NSStackView()
        header.orientation = .horizontal
        header.spacing = 7
        header.alignment = .centerY

        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
        icon.contentTintColor = accentColor ?? SettingsTheme.accent
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 12.5, weight: .semibold)

        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 12.5, weight: .semibold)
        label.textColor = .secondaryLabelColor

        header.addArrangedSubview(icon)
        header.addArrangedSubview(label)

        if let trailingAccessory {
            let spacer = NSView()
            spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
            header.addArrangedSubview(spacer)
            header.addArrangedSubview(trailingAccessory)
        }

        let headerDivider = SettingsRowDivider()

        let stack = NSStackView(views: [header, headerDivider, content])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = SettingsTheme.innerGap
        stack.setCustomSpacing(10, after: header)
        stack.setCustomSpacing(12, after: headerDivider)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        let pad = SettingsTheme.cardPadding
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: pad),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -pad),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -pad),

            header.widthAnchor.constraint(equalTo: stack.widthAnchor),
            headerDivider.widthAnchor.constraint(equalTo: stack.widthAnchor),
            content.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
    }
}

// MARK: - 语义状态圆点胶囊

/// 带发光圆点与柔和语义色底的状态胶囊（用于系统权限状态与连接健康度展示）。
final class SettingsStatusPill: NSView {

    enum Tone {
        case success
        case warning
        case neutral

        var dotColor: NSColor {
            switch self {
            case .success: return AnShotTheme.success
            case .warning: return AnShotTheme.warning
            case .neutral: return .secondaryLabelColor
            }
        }

        var textColor: NSColor {
            switch self {
            case .success:
                return AnShotTheme.dynamic(
                    light: NSColor(srgbRed: 0.08, green: 0.50, blue: 0.28, alpha: 1),
                    dark: NSColor(srgbRed: 0.36, green: 0.88, blue: 0.56, alpha: 1)
                )
            case .warning:
                return AnShotTheme.dynamic(
                    light: NSColor(srgbRed: 0.72, green: 0.38, blue: 0.04, alpha: 1),
                    dark: NSColor(srgbRed: 1.0, green: 0.72, blue: 0.32, alpha: 1)
                )
            case .neutral:
                return .secondaryLabelColor
            }
        }

        var backgroundColor: NSColor {
            switch self {
            case .success:
                return AnShotTheme.dynamic(
                    light: NSColor(srgbRed: 0.14, green: 0.72, blue: 0.42, alpha: 0.13),
                    dark: NSColor(srgbRed: 0.18, green: 0.78, blue: 0.46, alpha: 0.18)
                )
            case .warning:
                return AnShotTheme.dynamic(
                    light: NSColor(srgbRed: 0.96, green: 0.58, blue: 0.12, alpha: 0.15),
                    dark: NSColor(srgbRed: 0.98, green: 0.62, blue: 0.16, alpha: 0.20)
                )
            case .neutral:
                return AnShotTheme.hoverSurface
            }
        }
    }

    private var tone: Tone = .neutral
    private let dotView = NSView()
    private let label = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true

        dotView.translatesAutoresizingMaskIntoConstraints = false
        dotView.wantsLayer = true
        dotView.layer?.cornerRadius = 3.25

        label.font = .systemFont(ofSize: 11.5, weight: .medium)
        label.translatesAutoresizingMaskIntoConstraints = false

        let row = NSStackView(views: [dotView, label])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 6
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)

        NSLayoutConstraint.activate([
            dotView.widthAnchor.constraint(equalToConstant: 6.5),
            dotView.heightAnchor.constraint(equalToConstant: 6.5),
            row.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 9),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("不支持从 nib 构造")
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.cornerRadius = bounds.height / 2
        layer?.backgroundColor = tone.backgroundColor.cgColor
        dotView.layer?.backgroundColor = tone.dotColor.cgColor
        label.textColor = tone.textColor
    }

    func render(text: String, tone: Tone) {
        self.tone = tone
        label.stringValue = text
        label.textColor = tone.textColor
        needsDisplay = true
        updateLayer()
    }
}

// MARK: - 可视化迷你桌面外观主题选择器

/// 3 张精致迷你桌面缩略图卡片（跟随系统双拼 / 浅色霜白 / 深色碳墨），点击即时切换主题。
final class SettingsAppearancePicker: NSView {

    var onSelect: ((AppAppearanceMode) -> Void)?

    private var cards: [AppAppearanceMode: AppearancePreviewCard] = [:]

    var selectedMode: AppAppearanceMode = .system {
        didSet {
            for (mode, card) in cards {
                card.isSelected = (mode == selectedMode)
            }
        }
    }

    init(selected: AppAppearanceMode) {
        self.selectedMode = selected
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.distribution = .fillEqually
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        for mode in AppAppearanceMode.allCases {
            let card = AppearancePreviewCard(mode: mode)
            card.isSelected = (mode == selected)
            card.onTap = { [weak self] in
                self?.selectedMode = mode
                self?.onSelect?(mode)
            }
            cards[mode] = card
            stack.addArrangedSubview(card)
        }

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("不支持从 nib 构造")
    }

    private final class AppearancePreviewCard: NSControl {
        let mode: AppAppearanceMode
        var onTap: (() -> Void)?

        var isSelected = false {
            didSet {
                if oldValue != isSelected { needsDisplay = true }
            }
        }

        private var isHovered = false {
            didSet {
                if oldValue != isHovered { needsDisplay = true }
            }
        }

        init(mode: AppAppearanceMode) {
            self.mode = mode
            super.init(frame: .zero)
            translatesAutoresizingMaskIntoConstraints = false
            heightAnchor.constraint(equalToConstant: 88).isActive = true
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("不支持从 nib 构造")
        }

        override var isFlipped: Bool { true }

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

        override func mouseDown(with event: NSEvent) {
            onTap?()
        }

        override func draw(_ dirtyRect: NSRect) {
            guard let ctx = NSGraphicsContext.current?.cgContext else { return }

            let previewRect = CGRect(x: 2, y: 2, width: bounds.width - 4, height: 60)
            let radius: CGFloat = 9

            // 绘制迷你窗口预览缩略图。
            ctx.saveGState()
            let clip = CGPath(roundedRect: previewRect, cornerWidth: radius, cornerHeight: radius, transform: nil)
            ctx.addPath(clip)
            ctx.clip()

            switch mode {
            case .light:
                drawMiniWindow(in: previewRect, isDark: false, ctx: ctx)
            case .dark:
                drawMiniWindow(in: previewRect, isDark: true, ctx: ctx)
            case .system:
                let leftHalf = CGRect(x: previewRect.minX, y: previewRect.minY, width: previewRect.width / 2, height: previewRect.height)
                let rightHalf = CGRect(x: previewRect.midX, y: previewRect.minY, width: previewRect.width / 2, height: previewRect.height)
                ctx.saveGState()
                ctx.clip(to: leftHalf)
                drawMiniWindow(in: previewRect, isDark: false, ctx: ctx)
                ctx.restoreGState()
                ctx.saveGState()
                ctx.clip(to: rightHalf)
                drawMiniWindow(in: previewRect, isDark: true, ctx: ctx)
                ctx.restoreGState()
                // 中央分隔细线。
                ctx.setStrokeColor(NSColor.labelColor.withAlphaComponent(0.16).cgColor)
                ctx.setLineWidth(1)
                ctx.move(to: CGPoint(x: previewRect.midX, y: previewRect.minY))
                ctx.addLine(to: CGPoint(x: previewRect.midX, y: previewRect.maxY))
                ctx.strokePath()
            }
            ctx.restoreGState()

            // 预览框边框（选中为 2pt 强调色边框）。
            let borderColor: NSColor
            let borderWidth: CGFloat
            if isSelected {
                borderColor = SettingsTheme.accent
                borderWidth = 2.0
            } else if isHovered {
                borderColor = NSColor.labelColor.withAlphaComponent(0.26)
                borderWidth = 1.2
            } else {
                borderColor = SettingsTheme.cardBorder
                borderWidth = 1.0
            }
            SettingsTheme.strokeRoundedRect(
                previewRect,
                radius: radius,
                color: borderColor,
                lineWidth: borderWidth,
                in: ctx
            )

            // 选中态右下角强调色勾选徽章。
            if isSelected {
                let d: CGFloat = 15
                let badge = CGRect(x: previewRect.maxX - d - 5, y: previewRect.maxY - d - 5, width: d, height: d)
                ctx.saveGState()
                ctx.setFillColor(SettingsTheme.accent.cgColor)
                ctx.fillEllipse(in: badge)
                ctx.setStrokeColor(NSColor.white.cgColor)
                ctx.setLineWidth(1.8)
                ctx.setLineCap(.round)
                ctx.setLineJoin(.round)
                ctx.move(to: CGPoint(x: badge.minX + 4, y: badge.midY + 0.2))
                ctx.addLine(to: CGPoint(x: badge.minX + 6.4, y: badge.midY + 2.7))
                ctx.addLine(to: CGPoint(x: badge.maxX - 3.8, y: badge.midY - 2.6))
                ctx.strokePath()
                ctx.restoreGState()
            }

            // 底部模式标题。
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 12, weight: isSelected ? .semibold : .regular),
                .foregroundColor: isSelected ? SettingsTheme.accent : NSColor.secondaryLabelColor,
            ]
            let title = NSAttributedString(string: mode.displayName, attributes: attrs)
            let size = title.size()
            title.draw(at: NSPoint(x: bounds.midX - size.width / 2, y: previewRect.maxY + 7))
        }

        private func drawMiniWindow(in rect: CGRect, isDark: Bool, ctx: CGContext) {
            let bg = isDark
                ? NSColor(srgbRed: 0.13, green: 0.14, blue: 0.17, alpha: 1)
                : NSColor(srgbRed: 0.94, green: 0.95, blue: 0.97, alpha: 1)
            let sidebar = isDark
                ? NSColor(srgbRed: 0.18, green: 0.19, blue: 0.23, alpha: 1)
                : NSColor(srgbRed: 0.88, green: 0.90, blue: 0.93, alpha: 1)
            let card = isDark
                ? NSColor(srgbRed: 0.22, green: 0.24, blue: 0.28, alpha: 1)
                : NSColor.white
            let line = isDark
                ? NSColor(white: 1, alpha: 0.16)
                : NSColor(white: 0, alpha: 0.10)

            ctx.setFillColor(bg.cgColor)
            ctx.fill(rect)

            // 迷你左侧毛玻璃侧栏。
            let sideW = rect.width * 0.28
            ctx.setFillColor(sidebar.cgColor)
            ctx.fill(CGRect(x: rect.minX, y: rect.minY, width: sideW, height: rect.height))

            // 迷你红黄绿窗口控制点。
            let dots: [(CGFloat, NSColor)] = [
                (8, NSColor(srgbRed: 1.0, green: 0.38, blue: 0.34, alpha: 0.9)),
                (14.5, NSColor(srgbRed: 1.0, green: 0.74, blue: 0.18, alpha: 0.9)),
                (21, NSColor(srgbRed: 0.18, green: 0.80, blue: 0.30, alpha: 0.9)),
            ]
            for (dx, color) in dots {
                ctx.setFillColor(color.cgColor)
                ctx.fillEllipse(in: CGRect(x: rect.minX + dx, y: rect.minY + 7, width: 4.2, height: 4.2))
            }

            // 迷你侧栏两段导航条。
            let accent = NSColor.controlAccentColor
            SettingsTheme.fillRoundedRect(
                CGRect(x: rect.minX + 7, y: rect.minY + 18, width: sideW - 14, height: 6),
                radius: 3, color: accent.withAlphaComponent(0.75), in: ctx
            )
            SettingsTheme.fillRoundedRect(
                CGRect(x: rect.minX + 7, y: rect.minY + 28, width: sideW - 18, height: 5),
                radius: 2.5, color: line, in: ctx
            )

            // 右侧两张迷你设置卡片。
            let cardX = rect.minX + sideW + 8
            let cardW = rect.width - sideW - 16
            SettingsTheme.fillRoundedRect(
                CGRect(x: cardX, y: rect.minY + 11, width: cardW, height: 18),
                radius: 4.5, color: card, in: ctx
            )
            SettingsTheme.fillRoundedRect(
                CGRect(x: cardX, y: rect.minY + 34, width: cardW, height: 18),
                radius: 4.5, color: card, in: ctx
            )
            // 迷你开关胶囊点缀。
            SettingsTheme.fillRoundedRect(
                CGRect(x: cardX + cardW - 18, y: rect.minY + 16, width: 13, height: 7),
                radius: 3.5, color: accent, in: ctx
            )
            SettingsTheme.fillRoundedRect(
                CGRect(x: cardX + 6, y: rect.minY + 18, width: cardW * 0.45, height: 4),
                radius: 2, color: line, in: ctx
            )
            SettingsTheme.fillRoundedRect(
                CGRect(x: cardX + 6, y: rect.minY + 41, width: cardW * 0.56, height: 4),
                radius: 2, color: line, in: ctx
            )
        }
    }
}

// MARK: - 工具栏快捷槽位胶囊切换网格

/// 精美的圆角胶囊开关网格，替代笨重原生多选框用于切换主工具栏扩展槽位显隐。
final class SettingsToolbarSlotChipGrid: NSView {

    var onToggle: ((String, Bool) -> Void)?
    private var chips: [String: SlotChipButton] = [:]

    init(
        catalog: [(id: String, title: String)],
        hiddenSlots: Set<String>
    ) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        let grid = NSStackView()
        grid.orientation = .vertical
        grid.alignment = .leading
        grid.spacing = 8
        grid.translatesAutoresizingMaskIntoConstraints = false
        addSubview(grid)

        let columns = 3
        let rowCount = (catalog.count + columns - 1) / columns
        for r in 0 ..< rowCount {
            let line = NSStackView()
            line.orientation = .horizontal
            line.distribution = .fillEqually
            line.spacing = 8
            line.translatesAutoresizingMaskIntoConstraints = false

            let start = r * columns
            let end = min(start + columns, catalog.count)
            for item in catalog[start ..< end] {
                let chip = SlotChipButton(slotID: item.id, title: item.title)
                chip.isSelectedSlot = !hiddenSlots.contains(item.id)
                chip.onToggle = { [weak self] isVisible in
                    self?.onToggle?(item.id, isVisible)
                }
                chips[item.id] = chip
                line.addArrangedSubview(chip)
            }
            // 不满 3 列时补隐形占位维持等宽。
            for _ in (end - start) ..< columns {
                let placeholder = NSView()
                placeholder.translatesAutoresizingMaskIntoConstraints = false
                line.addArrangedSubview(placeholder)
            }

            grid.addArrangedSubview(line)
            line.widthAnchor.constraint(equalTo: grid.widthAnchor).isActive = true
        }

        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: topAnchor),
            grid.leadingAnchor.constraint(equalTo: leadingAnchor),
            grid.trailingAnchor.constraint(equalTo: trailingAnchor),
            grid.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("不支持从 nib 构造")
    }

    func update(hiddenSlots: Set<String>) {
        for (id, chip) in chips {
            chip.isSelectedSlot = !hiddenSlots.contains(id)
        }
    }

    private final class SlotChipButton: NSControl {
        let slotID: String
        let titleText: String
        var onToggle: ((Bool) -> Void)?

        var isSelectedSlot = true {
            didSet {
                if oldValue != isSelectedSlot { needsDisplay = true }
            }
        }

        private var isHovered = false {
            didSet {
                if oldValue != isHovered { needsDisplay = true }
            }
        }

        init(slotID: String, title: String) {
            self.slotID = slotID
            self.titleText = title
            super.init(frame: .zero)
            translatesAutoresizingMaskIntoConstraints = false
            heightAnchor.constraint(equalToConstant: 32).isActive = true
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("不支持从 nib 构造")
        }

        override var isFlipped: Bool { true }

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

        override func mouseDown(with event: NSEvent) {
            isSelectedSlot.toggle()
            onToggle?(isSelectedSlot)
        }

        override func draw(_ dirtyRect: NSRect) {
            guard let ctx = NSGraphicsContext.current?.cgContext else { return }
            let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
            let radius: CGFloat = 8

            let bg: NSColor
            let border: NSColor
            if isSelectedSlot {
                bg = SettingsTheme.accentSoft.withAlphaComponent(isHovered ? 0.20 : 0.12)
                border = SettingsTheme.accent.withAlphaComponent(0.55)
            } else {
                bg = isHovered ? SettingsTheme.hoverSurface : SettingsTheme.insetBackground
                border = SettingsTheme.cardBorder
            }
            SettingsTheme.fillRoundedRect(rect, radius: radius, color: bg, in: ctx)
            SettingsTheme.strokeRoundedRect(rect, radius: radius, color: border, lineWidth: 1, in: ctx)

            // 左侧勾选圆徽章或空圆环。
            let d: CGFloat = 14
            let circle = CGRect(x: 10, y: bounds.midY - d / 2, width: d, height: d)
            ctx.saveGState()
            if isSelectedSlot {
                ctx.setFillColor(SettingsTheme.accent.cgColor)
                ctx.fillEllipse(in: circle)
                ctx.setStrokeColor(NSColor.white.cgColor)
                ctx.setLineWidth(1.6)
                ctx.setLineCap(.round)
                ctx.setLineJoin(.round)
                ctx.move(to: CGPoint(x: circle.minX + 3.6, y: circle.midY + 0.2))
                ctx.addLine(to: CGPoint(x: circle.minX + 6.0, y: circle.midY + 2.5))
                ctx.addLine(to: CGPoint(x: circle.maxX - 3.4, y: circle.midY - 2.4))
                ctx.strokePath()
            } else {
                ctx.setStrokeColor(NSColor.tertiaryLabelColor.cgColor)
                ctx.setLineWidth(1.2)
                ctx.strokeEllipse(in: circle.insetBy(dx: 0.6, dy: 0.6))
            }
            ctx.restoreGState()

            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 12.5, weight: isSelectedSlot ? .medium : .regular),
                .foregroundColor: isSelectedSlot ? NSColor.labelColor : NSColor.secondaryLabelColor,
            ]
            let attr = NSAttributedString(string: titleText, attributes: attrs)
            let size = attr.size()
            attr.draw(at: NSPoint(x: circle.maxX + 8, y: bounds.midY - size.height / 2))
        }
    }
}

// MARK: - 文件夹内嵌状态行

/// 现代单行文件夹内嵌表面：彩底图标徽章 + 目录名/缩写路径 + 右侧紧凑动作按钮。
final class SettingsFolderSurface: NSView {

    private let badgeView = FolderIconBadge()
    private let primaryLabel = NSTextField(labelWithString: "")
    private let pathLabel = NSTextField(labelWithString: "")

    let chooseButton = SettingsPushButton(title: "选择文件夹…", emphasis: .primary, target: nil, action: nil)
    let changeButton = SettingsPushButton(title: "更改…", target: nil, action: nil)
    let revealButton = SettingsPushButton(title: "在访达中打开", target: nil, action: nil)

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        buildLayout()
        render(folder: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("不支持从 nib 构造")
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.cornerRadius = SettingsTheme.surfaceRadius
        layer?.cornerCurve = .continuous
        layer?.backgroundColor = SettingsTheme.insetBackground.cgColor
        layer?.borderWidth = 1
        layer?.borderColor = SettingsTheme.cardBorder.cgColor
    }

    private func buildLayout() {
        primaryLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        primaryLabel.textColor = .labelColor
        primaryLabel.lineBreakMode = .byTruncatingMiddle

        pathLabel.font = .systemFont(ofSize: 11)
        pathLabel.textColor = .secondaryLabelColor
        pathLabel.lineBreakMode = .byTruncatingMiddle
        pathLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        pathLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 100).isActive = true

        let text = NSStackView(views: [primaryLabel, pathLabel])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 2
        text.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let buttons = NSStackView(views: [chooseButton, changeButton, revealButton])
        buttons.orientation = .horizontal
        buttons.spacing = 8
        buttons.alignment = .centerY

        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        spacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let row = NSStackView(views: [badgeView, text, spacer, buttons])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 12
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)

        NSLayoutConstraint.activate([
            badgeView.widthAnchor.constraint(equalToConstant: 34),
            badgeView.heightAnchor.constraint(equalToConstant: 34),

            row.topAnchor.constraint(equalTo: topAnchor, constant: 11),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -11),
        ])
    }

    var displayedPath: String { pathLabel.stringValue }
    var displayedPrimary: String { primaryLabel.stringValue }

    func render(folder: URL?) {
        guard let folder else {
            primaryLabel.stringValue = "尚未选择文件夹"
            pathLabel.stringValue = "选定后，截图会直接静默存进这个目录"
            badgeView.isActive = false
            chooseButton.isHidden = false
            changeButton.isHidden = true
            revealButton.isHidden = true
            return
        }

        primaryLabel.stringValue = folder.lastPathComponent
        pathLabel.stringValue = (folder.path as NSString).abbreviatingWithTildeInPath
        badgeView.isActive = true
        chooseButton.isHidden = true
        changeButton.isHidden = false
        revealButton.isHidden = false
    }

    private final class FolderIconBadge: NSView {
        var isActive = false {
            didSet { needsDisplay = true }
        }

        override var isFlipped: Bool { true }

        override func draw(_ dirtyRect: NSRect) {
            guard let ctx = NSGraphicsContext.current?.cgContext else { return }
            let color = isActive
                ? NSColor(srgbRed: 0.16, green: 0.72, blue: 0.48, alpha: 1)
                : NSColor.tertiaryLabelColor
            SettingsTheme.fillRoundedRect(
                bounds,
                radius: 8,
                color: color.withAlphaComponent(isActive ? 0.15 : 0.10),
                in: ctx
            )
            let config = NSImage.SymbolConfiguration(pointSize: 15, weight: .semibold)
                .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
            if let symbol = NSImage(systemSymbolName: "folder.fill", accessibilityDescription: nil)?
                .withSymbolConfiguration(config) {
                let s = symbol.size
                symbol.draw(in: NSRect(
                    x: bounds.midX - s.width / 2,
                    y: bounds.midY - s.height / 2,
                    width: s.width,
                    height: s.height
                ))
            }
        }
    }
}

// MARK: - 文本与密钥输入框外壳

/// 表单文本/密钥输入框的现代外壳：统一柔和内嵌底、细描边与强调色聚焦反馈。
final class SettingsFieldShell: NSView {

    let control: NSView
    private let accessory: NSView?

    private var isFocused = false {
        didSet {
            if oldValue != isFocused { needsDisplay = true }
        }
    }

    nonisolated(unsafe) private var beginObserver: NSObjectProtocol?
    nonisolated(unsafe) private var endObserver: NSObjectProtocol?

    private static let radius: CGFloat = 8
    private static let horizontalPadding: CGFloat = 10

    static let height: CGFloat = 30

    init(control: NSView, accessory: NSView? = nil) {
        self.control = control
        self.accessory = accessory
        super.init(frame: .zero)

        translatesAutoresizingMaskIntoConstraints = false
        control.translatesAutoresizingMaskIntoConstraints = false
        addSubview(control)

        var constraints: [NSLayoutConstraint] = [
            heightAnchor.constraint(equalToConstant: Self.height),
            control.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.horizontalPadding),
            control.centerYAnchor.constraint(equalTo: centerYAnchor),
        ]

        if let accessory {
            accessory.translatesAutoresizingMaskIntoConstraints = false
            addSubview(accessory)
            constraints += [
                accessory.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -5),
                accessory.centerYAnchor.constraint(equalTo: centerYAnchor),
                control.trailingAnchor.constraint(equalTo: accessory.leadingAnchor, constant: -4),
            ]
        } else {
            constraints.append(
                control.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.horizontalPadding)
            )
        }
        NSLayoutConstraint.activate(constraints)

        if let field = control as? NSTextField {
            beginObserver = NotificationCenter.default.addObserver(
                forName: NSControl.textDidBeginEditingNotification,
                object: field,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.isFocused = true }
            }
            endObserver = NotificationCenter.default.addObserver(
                forName: NSControl.textDidEndEditingNotification,
                object: field,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.isFocused = false }
            }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("不支持从 nib 构造")
    }

    deinit {
        if let beginObserver { NotificationCenter.default.removeObserver(beginObserver) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }

        SettingsTheme.fillRoundedRect(
            bounds,
            radius: Self.radius,
            color: SettingsTheme.insetBackground,
            in: context
        )
        SettingsTheme.strokeRoundedRect(
            bounds,
            radius: Self.radius,
            color: isFocused
                ? SettingsTheme.accent.withAlphaComponent(0.75)
                : SettingsTheme.cardBorder,
            lineWidth: isFocused ? 1.5 : 1,
            in: context
        )
    }
}
