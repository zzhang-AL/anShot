//
//  HistoryPanel.swift
//  AnShotUI
//
//  历史记录窗口（契约 §5：与设置/欢迎页同一套视觉语言）。
//
//  ── 这次重做改了什么 ──────────────────────────────────────
//
//  旧实现是一个独立深色浮层：强制 `darkAqua`、系统蓝选中行、系统小按钮。
//  它和设置窗口并排时像两个不同应用的界面。这里换成设置窗口的组件体系：
//
//      * 窗口是标准可缩放窗口，隐藏标题、透明标题栏、内容铺满整窗；
//      * 背景用 `SettingsTheme.windowBackground`，内容边距 24；
//      * 页头复用 `SettingsHeaderView`，工具条与每个条目都是圆角卡片；
//      * 选中态只用 `accentSoft` 底 + `accent` 细描边，不再出现系统蓝。
//
//  ── 它不是什么 ────────────────────────────────────────────
//
//  它不是相册：历史记录只**引用**用户保存过的文件（契约 §1），所以这里
//  只显示缩略图、来源、时间、尺寸，以及源文件是否还在。源文件被移走时
//  条目照常列出、只是标注「文件已移走」——用户整理自己的文件夹是正常
//  操作，不该表现为列表报错。
//
//  ── 为什么用 StackView 而不是 NSTableView ────────────────
//
//  条目上限是 200，每行是「缩略图 + 三行文字 + 六个图标按钮」。
//  为此实现一整套 dataSource/delegate 与自定义 cell 的复杂度远超收益。
//
//  ── 刷新为什么不是每次全量重建 ───────────────────────────
//
//  搜索是逐键触发的。200 条时若每敲一个字符都拆掉并重建 200 个行视图，
//  峰值是上千个视图的创建与布局，输入会明显发涩。这里先比较「可见条目
//  的 id 序列」：序列没变（例如又保存了一张但当前过滤结果不变）就原地
//  更新已有行，序列变了才重建。每个条目的磁盘存在性只查一次，行操作
//  用下标 O(1) 取条目，不在行里做 `firstIndex`——避免 200 条时退化成 O(n²)。
//

import AnShotCore
import AppKit

/// 缩略图生成。
enum HistoryThumbnail {

    /// 把全尺寸图缩成小尺寸 PNG。
    ///
    /// - Parameters:
    ///   - image: 全尺寸图。
    ///   - maxWidth: 缩略图的最大宽度（逻辑点）。
    ///   - scale: 屏幕缩放，用于在该尺寸下仍然清晰。
    /// - Returns: PNG 数据；失败返回 nil（调用方退化为占位图标）。
    static func makePNG(from image: CGImage, maxWidth: CGFloat = 180, scale: CGFloat = 2) -> Data? {
        guard image.width > 0, image.height > 0 else { return nil }
        let ratio = min(1, maxWidth / CGFloat(image.width))
        let width = max(1, Int((CGFloat(image.width) * ratio * scale).rounded()))
        let height = max(1, Int((CGFloat(image.height) * ratio * scale).rounded()))
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil, width: width, height: height,
                  bitsPerComponent: 8, bytesPerRow: 0,
                  space: colorSpace,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let scaled = context.makeImage() else { return nil }
        return Exporter.pngData(from: scaled)
    }
}

// MARK: - 共享视觉层

/// 窗口底色。
///
/// 与设置窗口的 `SettingsBackgroundView` 同一做法：`updateLayer()` 在每次
/// 外观变化后重新解析动态色，避免把浅色模式的白固定进 layer。
final class HistoryWindowBackgroundView: NSView {

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        // `wantsUpdateLayer` 只在 layer-backed 时生效；少了这一行，
        // `updateLayer()` 里对背景的赋值会被静默丢弃。
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("不支持从 nib 构造")
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = SettingsTheme.windowBackground.cgColor
    }
}

/// 纯色圆角表面：历史页与预览页共用的卡片底。
///
/// `.card` 是设置页的卡片（cardBackground + 极细描边）；
/// `.inset` 是「卡片里面的内嵌面」（图片预览的衬底），与
/// `SettingsFolderSurface` 同一层明度。
final class HistorySurfaceView: NSView {

    enum Style {
        case card
        case inset
    }

    private let style: Style
    private let radius: CGFloat

    init(style: Style = .card, radius: CGFloat = SettingsTheme.cardRadius) {
        self.style = style
        self.radius = radius
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("不支持从 nib 构造")
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.cornerRadius = radius
        layer?.cornerCurve = .continuous
        switch style {
        case .card:
            layer?.backgroundColor = SettingsTheme.cardBackground.cgColor
            layer?.borderWidth = 1
            layer?.borderColor = SettingsTheme.cardBorder.cgColor
        case .inset:
            layer?.backgroundColor = SettingsTheme.insetBackground.cgColor
            layer?.borderWidth = 0
            layer?.borderColor = nil
        }
    }
}

// MARK: - 行内组件

/// 行内的缩略图。
///
/// 不用 `NSImageView`：它的 `.scaleProportionallyUpOrDown` 会留黑边（等比
/// 缩放但不裁切），96×64 的框里出现两条空白会把整行的节奏打断。这里按
/// 「等比放大到填满、再裁掉溢出」绘制，缩略图永远是完整的一块画面。
private final class HistoryThumbnailView: NSView {

    var image: NSImage? {
        didSet { needsDisplay = true }
    }

    /// 没有缩略图时的占位符号（按条目类型区分）。
    var fallbackSymbolName: String = "photo" {
        didSet { needsDisplay = true }
    }

    private static let radius: CGFloat = 8

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }

        // 底：即使图片带透明通道，也能看出缩略图的边界。
        SettingsTheme.fillRoundedRect(
            bounds,
            radius: Self.radius,
            color: SettingsTheme.insetBackground,
            in: context
        )

        context.saveGState()
        context.addPath(CGPath(
            roundedRect: bounds,
            cornerWidth: Self.radius,
            cornerHeight: Self.radius,
            transform: nil
        ))
        context.clip()

        if let image, image.size.width > 0, image.size.height > 0 {
            let scale = max(bounds.width / image.size.width, bounds.height / image.size.height)
            let size = NSSize(
                width: image.size.width * scale,
                height: image.size.height * scale
            )
            let rect = NSRect(
                x: bounds.midX - size.width / 2,
                y: bounds.midY - size.height / 2,
                width: size.width,
                height: size.height
            )
            image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
        } else if let symbol = Self.symbol(named: fallbackSymbolName) {
            let size = symbol.size
            symbol.draw(in: NSRect(
                x: bounds.midX - size.width / 2,
                y: bounds.midY - size.height / 2,
                width: size.width,
                height: size.height
            ))
        }

        context.restoreGState()
    }

    private static func symbol(named name: String) -> NSImage? {
        let configuration = NSImage.SymbolConfiguration(pointSize: 22, weight: .regular)
            .applying(NSImage.SymbolConfiguration(hierarchicalColor: NSColor.tertiaryLabelColor))
        return NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration)
    }
}

/// 类型徽标。
///
/// 刻意不用彩色：设置窗口的层次全靠明度，一枚蓝/紫/红的胶囊会立刻变成
/// 整页唯一的色块，比旧版的系统蓝选中行好不了多少。类型靠图标与文字区分。
private final class HistoryKindBadge: NSView {

    private let iconView = NSImageView()
    private let label = NSTextField(labelWithString: "")

    init(kind: HistoryEntryKind) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        setContentHuggingPriority(.required, for: .horizontal)

        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.contentTintColor = .secondaryLabelColor
        iconView.imageScaling = .scaleProportionallyDown

        label.font = .systemFont(ofSize: 10, weight: .semibold)
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false

        addSubview(iconView)
        addSubview(label)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 18),
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 10),
            iconView.heightAnchor.constraint(equalToConstant: 10),

            label.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 4),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -7),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        render(kind: kind)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("不支持从 nib 构造")
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.cornerRadius = 5
        layer?.cornerCurve = .continuous
        layer?.backgroundColor = SettingsTheme.insetBackground.cgColor
    }

    /// 行被复用时只换内容，不重建视图。
    func render(kind: HistoryEntryKind) {
        label.stringValue = kind.displayName
        let configuration = NSImage.SymbolConfiguration(pointSize: 9, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(hierarchicalColor: NSColor.secondaryLabelColor))
        iconView.image = NSImage(
            systemSymbolName: Self.symbolName(for: kind),
            accessibilityDescription: nil
        )?.withSymbolConfiguration(configuration)
    }

    private static func symbolName(for kind: HistoryEntryKind) -> String {
        switch kind {
        case .screenshot: return "camera"
        case .longScreenshot: return "scroll"
        case .recording: return "video"
        }
    }
}

/// 行内的操作图标。
///
/// 不复用 `SettingsAccessoryButton`：那个按钮固定用次要文字色，而收藏需要
/// 「已收藏 = 强调色实心星」。这里保持同一套形制（无边框、悬停浮出淡底、
/// 按下加深），只把着色暴露出来。
private final class HistoryActionButton: NSButton {

    let actionKind: HistoryRowAction

    var symbolName: String {
        didSet {
            if oldValue != symbolName { needsDisplay = true }
        }
    }

    /// 图标颜色。收藏状态变化时由行更新。
    var tint: NSColor = .secondaryLabelColor {
        didSet { needsDisplay = true }
    }

    private var isHovered = false {
        didSet {
            if oldValue != isHovered { needsDisplay = true }
        }
    }

    private static let side: CGFloat = 24
    private static let radius: CGFloat = 5

    init(action: HistoryRowAction, symbolName: String) {
        self.actionKind = action
        self.symbolName = symbolName
        super.init(frame: .zero)

        isBordered = false
        bezelStyle = .regularSquare
        setButtonType(.momentaryChange)
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

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        ))
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }

        if isEnabled, isHovered || isHighlighted {
            SettingsTheme.fillRoundedRect(
                bounds,
                radius: Self.radius,
                color: NSColor.labelColor.withAlphaComponent(isHighlighted ? 0.14 : 0.07),
                in: context
            )
        }

        // 禁用的操作仍然占位：图标消失会让右边缘的按钮列左右跳动。
        let color = isEnabled ? tint : tint.withAlphaComponent(0.32)
        let configuration = NSImage.SymbolConfiguration(pointSize: 12, weight: .regular)
            .applying(NSImage.SymbolConfiguration(hierarchicalColor: color))
        guard let symbol = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration) else {
            return
        }
        let size = symbol.size
        symbol.draw(in: NSRect(
            x: bounds.midX - size.width / 2,
            y: bounds.midY - size.height / 2,
            width: size.width,
            height: size.height
        ))
    }
}

/// 行内可触发的操作。由行通过一个闭包转发给面板，避免每行挂六个回调。
private enum HistoryRowAction: Hashable {
    case copy
    case edit
    case pin
    case reveal
    case delete
    case favorite
}

/// 一行历史记录。
///
/// 单独成类为了三件事：整行可点（标签不该吃掉双击）、行内按键
/// （空格预览 / 回车编辑）不依赖面板级快捷键，以及刷新时可以原地复用。
private final class HistoryRowView: NSView {

    /// 面板的闭包是否接上了。行只负责显示，不判断业务是否可用。
    struct Availability {
        var copy = false
        var edit = false
        var pin = false
        var reveal = false
        var delete = false
        var favorite = false
    }

    private(set) var entryID: UUID
    private(set) var rowIndex: Int

    var availability = Availability() {
        didSet { updateActionAvailability() }
    }

    var onClick: ((Int) -> Void)?
    var onDoubleClick: ((Int) -> Void)?
    var onSpace: (() -> Void)?
    var onReturn: (() -> Void)?
    var onEscape: (() -> Void)?
    var onAction: ((HistoryRowAction, Int) -> Void)?

    private(set) var isSelected = false
    private var isPresent = true
    private var isHovered = false
    private var isPressed = false
    private var trackingArea: NSTrackingArea?

    private let thumbView = HistoryThumbnailView()
    private let badge: HistoryKindBadge
    private let sourceLabel = NSTextField(labelWithString: "")
    private let fileLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let timeLabel = NSTextField(labelWithString: "")
    private var actionButtons: [HistoryRowAction: HistoryActionButton] = [:]
    private static let rowHeight: CGFloat = 92

    init(entry: HistoryEntry, rowIndex: Int) {
        self.entryID = entry.id
        self.rowIndex = rowIndex
        self.badge = HistoryKindBadge(kind: entry.kind)
        super.init(frame: .zero)

        translatesAutoresizingMaskIntoConstraints = false
        thumbView.translatesAutoresizingMaskIntoConstraints = false

        configureLabels()
        let actions = buildActions()
        for view in [thumbView, badge, sourceLabel, fileLabel, detailLabel, timeLabel, actions] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Self.rowHeight),

            thumbView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            thumbView.centerYAnchor.constraint(equalTo: centerYAnchor),
            thumbView.widthAnchor.constraint(equalToConstant: 96),
            thumbView.heightAnchor.constraint(equalToConstant: 64),

            actions.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            actions.centerYAnchor.constraint(equalTo: centerYAnchor),

            badge.leadingAnchor.constraint(equalTo: thumbView.trailingAnchor, constant: 12),
            badge.topAnchor.constraint(equalTo: topAnchor, constant: 15),

            sourceLabel.leadingAnchor.constraint(equalTo: badge.trailingAnchor, constant: 8),
            sourceLabel.centerYAnchor.constraint(equalTo: badge.centerYAnchor),
            sourceLabel.trailingAnchor.constraint(lessThanOrEqualTo: actions.leadingAnchor, constant: -12),

            fileLabel.leadingAnchor.constraint(equalTo: badge.leadingAnchor),
            fileLabel.topAnchor.constraint(equalTo: badge.bottomAnchor, constant: 6),
            fileLabel.trailingAnchor.constraint(lessThanOrEqualTo: timeLabel.leadingAnchor, constant: -12),

            timeLabel.trailingAnchor.constraint(equalTo: actions.leadingAnchor, constant: -12),
            timeLabel.centerYAnchor.constraint(equalTo: fileLabel.centerYAnchor),

            detailLabel.leadingAnchor.constraint(equalTo: badge.leadingAnchor),
            detailLabel.topAnchor.constraint(equalTo: fileLabel.bottomAnchor, constant: 4),
            detailLabel.trailingAnchor.constraint(lessThanOrEqualTo: actions.leadingAnchor, constant: -12),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("不支持从 nib 构造")
    }

    private func configureLabels() {
        sourceLabel.font = .systemFont(ofSize: 12, weight: .medium)
        sourceLabel.lineBreakMode = .byTruncatingTail
        sourceLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        fileLabel.font = .systemFont(ofSize: 11)
        fileLabel.textColor = .secondaryLabelColor
        fileLabel.lineBreakMode = .byTruncatingTail
        fileLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        detailLabel.font = .systemFont(ofSize: 11)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.lineBreakMode = .byTruncatingTail
        detailLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        timeLabel.font = .systemFont(ofSize: 11)
        timeLabel.textColor = .tertiaryLabelColor
        timeLabel.alignment = .right
        timeLabel.setContentHuggingPriority(.required, for: .horizontal)
        timeLabel.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
    }

    private func buildActions() -> NSStackView {
        let actions = NSStackView()
        actions.orientation = .horizontal
        actions.alignment = .centerY
        actions.spacing = 2
        actions.setContentHuggingPriority(.required, for: .horizontal)

        let descriptors: [(HistoryRowAction, String)] = [
            (.copy, "doc.on.doc"),
            (.edit, "pencil"),
            (.pin, "pin"),
            (.reveal, "folder"),
            (.delete, "trash"),
            (.favorite, "star"),
        ]
        for (action, symbol) in descriptors {
            let button = HistoryActionButton(action: action, symbolName: symbol)
            button.target = self
            button.action = #selector(actionTapped(_:))
            actionButtons[action] = button
            actions.addArrangedSubview(button)
        }
        return actions
    }

    /// 把一条记录写进行里的控件。
    ///
    /// 参数都由面板算好：行不做磁盘查询，也不读 store。这样刷新时面板能
    /// 保证「同一份存在性结论」被摘要、行禁用状态与预览共同使用。
    func configure(
        entry: HistoryEntry,
        rowIndex: Int,
        isPresent: Bool,
        thumbnail: NSImage?,
        isSelected: Bool
    ) {
        self.entryID = entry.id
        self.rowIndex = rowIndex
        self.isPresent = isPresent
        self.isSelected = isSelected

        badge.render(kind: entry.kind)
        thumbView.fallbackSymbolName = Self.thumbnailSymbol(for: entry.kind)
        thumbView.image = thumbnail

        let source = HistoryText.source(for: entry)
        sourceLabel.stringValue = source
        sourceLabel.textColor = entry.source == nil ? .tertiaryLabelColor : .labelColor

        fileLabel.stringValue = HistoryText.fileName(for: entry)
        detailLabel.stringValue = HistoryText.detail(for: entry, isPresent: isPresent)
        detailLabel.textColor = isPresent ? .secondaryLabelColor : .systemOrange
        timeLabel.stringValue = HistoryText.time(for: entry)

        setFavorite(entry.isFavorite)
        updateActionAvailability()
        updateToolTips(for: entry)
        setAccessibilityLabel(
            "\(entry.kind.displayName)，\(source)，\(HistoryText.fileName(for: entry))"
        )
        needsDisplay = true
    }

    func setSelected(_ selected: Bool) {
        guard isSelected != selected else { return }
        isSelected = selected
        needsDisplay = true
    }

    func setFavorite(_ favorite: Bool) {
        guard let button = actionButtons[.favorite] else { return }
        button.symbolName = favorite ? "star.fill" : "star"
        button.tint = favorite ? SettingsTheme.accent : .secondaryLabelColor
        button.toolTip = favorite ? "取消收藏" : "收藏"
    }

    private func updateActionAvailability() {
        actionButtons[.copy]?.isEnabled = isPresent && availability.copy
        actionButtons[.edit]?.isEnabled = isPresent && availability.edit
        actionButtons[.pin]?.isEnabled = isPresent && availability.pin
        actionButtons[.reveal]?.isEnabled = isPresent && availability.reveal
        actionButtons[.delete]?.isEnabled = availability.delete
        actionButtons[.favorite]?.isEnabled = availability.favorite
    }

    private func updateToolTips(for entry: HistoryEntry) {
        let isRecording = entry.kind == .recording
        actionButtons[.copy]?.toolTip = isPresent
            ? (isRecording ? "复制录屏文件" : "复制图片")
            : "源文件已不在原位置，无法复制"
        actionButtons[.edit]?.toolTip = isPresent
            ? "在标注编辑器中重新打开"
            : "源文件已不在原位置，无法编辑"
        actionButtons[.pin]?.toolTip = isPresent
            ? "把这张图钉在屏幕上"
            : "源文件已不在原位置，无法钉住"
        actionButtons[.reveal]?.toolTip = isPresent
            ? "在访达中显示"
            : "源文件已不在原位置，无法显示"
        actionButtons[.delete]?.toolTip = "从历史中移除（不会删除已经保存的文件）"
    }

    private static func thumbnailSymbol(for kind: HistoryEntryKind) -> String {
        switch kind {
        case .screenshot: return "photo"
        case .longScreenshot: return "doc.plaintext"
        case .recording: return "video"
        }
    }

    // MARK: 绘制

    override var isOpaque: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }

        // 选中态是契约指定的 accentSoft + accent 描边：整页不出现系统蓝，
        // 与设置窗口的「无彩色」体系一致。
        if isSelected {
            SettingsTheme.fillRoundedRect(
                bounds,
                radius: SettingsTheme.cardRadius,
                color: SettingsTheme.accentSoft,
                in: context
            )
            // 选中行也接受悬停/按下的反馈：底不变，叠一层极淡的前景色。
            if isHovered || isPressed {
                SettingsTheme.fillRoundedRect(
                    bounds,
                    radius: SettingsTheme.cardRadius,
                    color: NSColor.labelColor.withAlphaComponent(isPressed ? 0.06 : 0.03),
                    in: context
                )
            }
        } else if isPressed {
            SettingsTheme.fillRoundedRect(
                bounds,
                radius: SettingsTheme.cardRadius,
                color: NSColor.labelColor.withAlphaComponent(0.10),
                in: context
            )
        } else if isHovered {
            SettingsTheme.fillRoundedRect(
                bounds,
                radius: SettingsTheme.cardRadius,
                color: NSColor.labelColor.withAlphaComponent(0.045),
                in: context
            )
        } else {
            SettingsTheme.fillRoundedRect(
                bounds,
                radius: SettingsTheme.cardRadius,
                color: SettingsTheme.cardBackground,
                in: context
            )
        }

        SettingsTheme.strokeRoundedRect(
            bounds,
            radius: SettingsTheme.cardRadius,
            color: isSelected ? SettingsTheme.accent : SettingsTheme.cardBorder,
            lineWidth: 1,
            in: context
        )
    }

    // MARK: 交互

    // 按钮自己处理点击；标签、缩略图与空白都交回整行，否则点文字选不中行，
    // 双击标签也不会触发行编辑。
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        return hit is NSButton ? hit : self
    }

    override var acceptsFirstResponder: Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
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
        isPressed = false
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        isPressed = true
        needsDisplay = true
        onClick?(rowIndex)
        if event.clickCount == 2 {
            onDoubleClick?(rowIndex)
        }
    }

    override func mouseUp(with event: NSEvent) {
        isPressed = false
        needsDisplay = true
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 49: onSpace?()
        case 36, 76: onReturn?()
        case 53: onEscape?()
        default: super.keyDown(with: event)
        }
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    @objc private func actionTapped(_ sender: NSButton) {
        guard let button = sender as? HistoryActionButton else { return }
        onAction?(button.actionKind, rowIndex)
    }
}

/// 历史窗口：把「空格预览 / ESC 关闭」放在窗口层处理。
///
/// 行与搜索框成为第一响应者时会先消费自己的按键；只有事件冒泡到窗口
/// 才走这里。这样在搜索框里按空格仍然是输入空格，不会误触预览。
private final class HistoryPanelWindow: NSWindow {

    var onSpace: (() -> Void)?
    var onEscape: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 49: onSpace?()
        case 53: onEscape?()
        default: super.keyDown(with: event)
        }
    }
}

/// 列表滚动视图的文档视图。
///
/// `NSScrollView` 的文档视图默认非 flipped：条目少、文档比视口矮时
/// 内容会贴着底部显示。这里翻转让列表始终从顶部开始。
private final class HistoryDocumentView: NSView {
    override var isFlipped: Bool { true }
}

// MARK: - 文案

/// 行与搜索共用的文案生成。
///
/// 集中在一处：搜索串与行内显示如果各拼一套，用户会看到「屏幕上写着
/// 文件名，但搜文件名搜不到」这类不一致。
///
/// 刻意不加 `@MainActor`：这是一个纯函数集合，输入 `HistoryEntry`
/// （`Sendable`），输出字符串。加隔离只会让调用方（行视图）多一层
/// actor 假设，而不带来任何保护。
private enum HistoryText {

    /// 缓存实例：`DateFormatter` 的构造代价远高于一次 `string(from:)`，
    /// 而整表重建时每行都要格式化一次。
    ///
    /// 只在主线程访问；`DateFormatter` 的读取本身也是线程安全的。
    ///
    /// 实测 Xcode 16 与 27 都已把它标成 `Sendable`，因此不需要
    /// `nonisolated(unsafe)`；加了反而会在严格并发检查下报「不必要」。
    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm:ss"
        return formatter
    }()

    static func time(for entry: HistoryEntry) -> String {
        dateFormatter.string(from: entry.createdAt)
    }

    static func source(for entry: HistoryEntry) -> String {
        var parts: [String] = []
        if let app = entry.source?.appName?.trimmingCharacters(in: .whitespacesAndNewlines),
           !app.isEmpty {
            parts.append(app)
        }
        if let title = entry.source?.windowTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
           !title.isEmpty {
            parts.append(title)
        }
        guard !parts.isEmpty else {
            // 旧索引与导入图没有来源；不要显示空行。
            return entry.kind == .recording ? "录屏文件" : "本地文件"
        }
        return parts.joined(separator: " · ")
    }

    /// 行内文件名：缓存副本不暴露 UUID。
    static func fileName(for entry: HistoryEntry) -> String {
        entry.isCached ? "缓存副本" : entry.fileURL.lastPathComponent
    }

    static func detail(for entry: HistoryEntry, isPresent: Bool) -> String {
        var parts = ["\(entry.pixelWidth) × \(entry.pixelHeight)"]
        if entry.kind == .recording {
            let ext = entry.fileURL.pathExtension.uppercased()
            parts.append(ext.isEmpty ? "录屏" : ext)
        }
        if !isPresent {
            parts.append("文件已移走")
        }
        return parts.joined(separator: " · ")
    }

    static func search(for entry: HistoryEntry) -> String {
        var parts: [String] = [
            entry.kind.displayName,
            entry.kind.rawValue,
            fileName(for: entry),
        ]
        if let app = entry.source?.appName { parts.append(app) }
        if let title = entry.source?.windowTitle { parts.append(title) }
        return parts.joined(separator: "\n").lowercased()
    }
}

// MARK: - 面板

/// 历史记录窗口。
@MainActor
final class HistoryPanel: NSObject, NSSearchFieldDelegate, NSWindowDelegate {

    // MARK: - 对外回调

    /// 用户在访达中显示某个条目。
    var onReveal: ((HistoryEntry) -> Void)?

    /// 用户要求把某个条目重新钉到屏幕上。
    ///
    /// 历史只存路径，重钉意味着**重新读盘**（见 `AppDelegate.pinFromHistory`），
    /// 因此这里只转发意图，不关心能不能读出来。
    var onPin: ((HistoryEntry) -> Void)?

    /// 用户要求一键清空。
    var onClear: (() -> Void)?

    /// 复制条目对应的图片/录屏文件。
    var onCopy: ((HistoryEntry) -> Void)?

    /// 在标注编辑器中重新打开。
    ///
    /// 面板只转发：能不能重建图像、录屏怎么处理，都由集成方决定。
    var onEdit: ((HistoryEntry) -> Void)?

    /// 从历史列表中移除这一条。
    ///
    /// 面板不自己改 `entries`：列表的真源是 store，删除后由集成方 refresh。
    var onDelete: ((HistoryEntry) -> Void)?

    /// 切换收藏。第二个参数是**切换后**的状态，避免集成方再去查 store。
    var onFavorite: ((HistoryEntry, Bool) -> Void)?

    // MARK: - 窗口与布局

    /// 标准窗口尺寸（契约 §5）。
    private static let defaultSize = CGSize(width: 720, height: 640)

    /// 内容顶部留出的交通灯空间。
    ///
    /// 隐藏标题后内容铺满整窗，交通灯仍然画在原来的位置。28 是标准标题栏
    /// 高度，再加 24 的页边距，页头才不会被红绿灯压住。
    private static let topInset: CGFloat = 28 + SettingsTheme.margin

    private let window: HistoryPanelWindow
    private let scrollView = NSScrollView()
    private let listStack = NSStackView()
    private let countLabel = NSTextField(labelWithString: "")
    private let hintLabel = NSTextField(labelWithString: "")
    private let emptyCard = HistorySurfaceView()
    private let emptyTitleLabel = NSTextField(labelWithString: "")
    private let emptySubtitleLabel = NSTextField(labelWithString: "")
    private let clearButton = SettingsPushButton(title: "清空", target: nil, action: nil)
    private let searchField = NSSearchField()
    private let kindFilter = NSPopUpButton(frame: .zero, pullsDown: false)

    /// 空格预览窗口。懒开懒关，预览关闭时释放图像。
    private let preview = HistoryPreviewPanel()

    // MARK: - 数据

    private var entries: [HistoryEntry] = []

    /// 过滤后的行 → `entries` 下标。行操作靠它 O(1) 取条目。
    private var visibleEntryIndices: [Int] = []

    /// 与 `visibleEntryIndices` 一一对应的行视图。
    private var rows: [HistoryRowView] = []

    /// 用 id 而不是下标记住选中项：过滤/刷新会改变下标，id 不会。
    private var selectedEntryID: UUID?

    /// 窗口正在关闭。
    ///
    /// 关窗时我们也会关掉预览，而预览的 `onClose` 会尝试把焦点还给历史窗口。
    /// 若不拦住，`makeKeyAndOrderFront` 会在 `windowWillClose` 期间把窗口
    /// 重新拉回前台——表现为「点了红点，窗口又闪回来」。
    private var isClosing = false

    /// 缩略图只用于屏上几十点，系统内存吃紧时允许回收。
    private let thumbnailCache = NSCache<NSString, NSImage>()

    /// 缩略图由 store 定位：面板不该自己拼目录（那会把存储布局复制成两处真相）。
    private let store: HistoryStore

    init(store: HistoryStore) {
        self.store = store
        window = HistoryPanelWindow(
            contentRect: CGRect(
                origin: .zero,
                size: Self.defaultSize
            ),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        super.init()

        window.isReleasedWhenClosed = false
        window.title = "历史记录"
        // 与设置窗口一致：标题栏透明、标题隐藏、内容铺满整窗。
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.backgroundColor = SettingsTheme.windowBackground
        // 不指定 appearance：跟随系统深浅模式。旧版强制 darkAqua 是它
        // 与设置窗口始终不像的直接原因之一。
        window.isMovableByWindowBackground = true
        window.minSize = CGSize(width: 560, height: 460)
        window.onSpace = { [weak self] in self?.togglePreview() }
        window.onEscape = { [weak self] in self?.escapePressed() }
        window.delegate = self

        thumbnailCache.countLimit = 200

        configureSearchField()
        configureKindFilter()
        window.contentView = makeContentView()

        preview.onClose = { [weak self] in self?.restoreFocusAfterPreview() }
    }

    var isVisible: Bool { window.isVisible }

    // MARK: - 诊断

    var debugRowCountForDiagnostics: Int { rows.count }
    var debugPresentCountForDiagnostics: Int { entries.filter(\.isFilePresent).count }
    var debugMissingCountForDiagnostics: Int { entries.filter { !$0.isFilePresent }.count }
    var debugSummaryForDiagnostics: String { countLabel.stringValue }

    // MARK: - 显示

    /// 显示窗口。
    ///
    /// 每次打开都回到干净状态（无搜索、无筛选、选中第一行）：
    /// 上次关窗口前的过滤条件若留着，用户会以为历史丢了一半。
    func show(_ entries: [HistoryEntry]) {
        self.entries = entries
        selectedEntryID = nil
        searchField.stringValue = ""
        kindFilter.selectItem(at: 0)
        rebuildRows()

        repositionIfNeeded()
        // 标准窗口要成为 key 才能接收搜索输入与空格预览；菜单栏程序在被
        // 打开窗口时需要显式激活一次，否则窗口只是「浮上来」但没有焦点。
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        makeSelectedRowFirstResponder()
    }

    /// 刷新内容（条目变化后调用；窗口未打开时只更新数据）。
    func refresh(_ entries: [HistoryEntry]) {
        self.entries = entries
        guard window.isVisible else { return }
        rebuildRows()
        updateFirstResponderAfterRebuild()
    }

    func hide() {
        // 先藏历史窗口再关预览：预览关闭会尝试把焦点还给历史窗口，
        // 那时窗口已经不可见，回调自然变成空操作。
        window.orderOut(nil)
        preview.close()
    }

    // MARK: - 页头与工具条

    private func configureSearchField() {
        searchField.placeholderString = "搜索应用、窗口标题、文件名或类型"
        searchField.font = .systemFont(ofSize: 12)
        // 系统外观全部关掉：背景、圆角、描边与聚焦反馈由 `SettingsFieldShell`
        // 统一提供，否则搜索框会带着系统蓝聚焦环成为整页唯一的高饱和处。
        searchField.isBezeled = false
        searchField.drawsBackground = false
        searchField.focusRingType = .none
        // 用 delegate 而不是 target/action：逐键过滤与 NSSearchField 的
        // 「取消按钮清空」「ESC 清空」都走同一条文本变化路径，不会漏刷新。
        searchField.delegate = self
    }

    private func configureKindFilter() {
        kindFilter.controlSize = .regular
        kindFilter.addItem(withTitle: "全部")
        kindFilter.lastItem?.tag = 0
        for (offset, kind) in HistoryEntryKind.allCases.enumerated() {
            kindFilter.addItem(withTitle: kind.displayName)
            kindFilter.lastItem?.tag = offset + 1
        }
        // 与设置页的下拉一致：关掉系统外观，交给外壳统一高度与底色。
        kindFilter.isBordered = false
        kindFilter.bezelStyle = .inline
        kindFilter.font = .systemFont(ofSize: 12)
        kindFilter.target = self
        kindFilter.action = #selector(filterChanged)
        kindFilter.setContentHuggingPriority(.required, for: .horizontal)
    }

    private var selectedKind: HistoryEntryKind? {
        guard let tag = kindFilter.selectedItem?.tag, tag > 0 else { return nil }
        let offset = tag - 1
        guard HistoryEntryKind.allCases.indices.contains(offset) else { return nil }
        return HistoryEntryKind.allCases[offset]
    }

    private func makeContentView() -> NSView {
        let content = HistoryWindowBackgroundView(frame: CGRect(origin: .zero, size: Self.defaultSize))
        content.autoresizingMask = [.width, .height]

        let header = SettingsHeaderView(
            symbolName: "clock",
            title: "历史记录",
            subtitle: "最近的截图、长截图与录屏。单击复制，双击重新编辑。"
        )

        let toolbar = makeToolbarCard()

        listStack.orientation = .vertical
        listStack.alignment = .leading
        listStack.spacing = 10
        listStack.translatesAutoresizingMaskIntoConstraints = false

        let documentView = HistoryDocumentView()
        documentView.translatesAutoresizingMaskIntoConstraints = false
        documentView.addSubview(listStack)

        scrollView.documentView = documentView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.drawsBackground = false
        scrollView.backgroundColor = .clear
        scrollView.borderType = .noBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        configureEmptyCard()

        for view in [header, toolbar, scrollView, emptyCard] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }

        let margin = SettingsTheme.margin
        // 空列表时文档视图没有任何子视图撑高；给一个低优先级的「填满视口」，
        // 避免 Auto Layout 在 0 高度上欠定（有行时会被行的必需高度打断）。
        let fillHeight = documentView.heightAnchor.constraint(
            equalTo: scrollView.contentView.heightAnchor
        )
        fillHeight.priority = .defaultLow
        fillHeight.isActive = true

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: content.topAnchor, constant: Self.topInset),
            header.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: margin),
            // 页头宽度必须显式钉住：`SettingsHeaderView` 内部只有
            // 「行尾 <= 页头尾」的不等式，光靠它页头宽度是欠定的。
            header.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -margin),

            toolbar.topAnchor.constraint(equalTo: header.bottomAnchor, constant: SettingsTheme.cardGap),
            toolbar.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: margin),
            toolbar.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -margin),

            scrollView.topAnchor.constraint(equalTo: toolbar.bottomAnchor, constant: SettingsTheme.cardGap),
            scrollView.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: margin),
            scrollView.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -margin),
            scrollView.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -margin),

            documentView.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            documentView.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            documentView.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),

            listStack.topAnchor.constraint(equalTo: documentView.topAnchor),
            listStack.leadingAnchor.constraint(equalTo: documentView.leadingAnchor),
            listStack.trailingAnchor.constraint(equalTo: documentView.trailingAnchor),
            listStack.bottomAnchor.constraint(equalTo: documentView.bottomAnchor),
            emptyCard.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            emptyCard.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
            emptyCard.widthAnchor.constraint(equalToConstant: 360),
            emptyCard.leadingAnchor.constraint(greaterThanOrEqualTo: scrollView.leadingAnchor, constant: 24),
            emptyCard.trailingAnchor.constraint(lessThanOrEqualTo: scrollView.trailingAnchor, constant: -24),
        ])
        return content
    }

    /// 工具条卡片。
    ///
    /// 用卡片而不是裸控件条，是为了让搜索/筛选与下面的条目处在同一层
    /// 「表面」上；左右内边距取 `SettingsTheme.cardPadding`，与设置页
    /// 卡片内容严格对齐。卡片不另加标题行：工具条本身就是一行控件，
    /// 再加「筛选与搜索」只会白白吃掉一行高度，而列表才是主角。
    private func makeToolbarCard() -> HistorySurfaceView {
        let card = HistorySurfaceView(style: .card)

        clearButton.target = self
        clearButton.action = #selector(clearTapped)
        clearButton.toolTip = "清空历史列表、缩略图与历史缓存；不会删除你已经保存的文件"

        let searchShell = SettingsFieldShell(control: searchField)
        let filterShell = SettingsFieldShell(control: kindFilter)

        countLabel.font = .systemFont(ofSize: 11)
        countLabel.textColor = .secondaryLabelColor
        countLabel.lineBreakMode = .byTruncatingTail
        countLabel.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)

        hintLabel.font = .systemFont(ofSize: 11)
        hintLabel.textColor = .tertiaryLabelColor
        hintLabel.alignment = .right
        hintLabel.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)

        for view in [searchShell, filterShell, clearButton, countLabel, hintLabel] {
            view.translatesAutoresizingMaskIntoConstraints = false
            card.addSubview(view)
        }

        let pad = SettingsTheme.cardPadding
        NSLayoutConstraint.activate([
            searchShell.topAnchor.constraint(equalTo: card.topAnchor, constant: 14),
            searchShell.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: pad),

            filterShell.centerYAnchor.constraint(equalTo: searchShell.centerYAnchor),
            filterShell.trailingAnchor.constraint(equalTo: clearButton.leadingAnchor, constant: -8),
            filterShell.widthAnchor.constraint(equalToConstant: 112),
            searchShell.trailingAnchor.constraint(equalTo: filterShell.leadingAnchor, constant: -8),

            clearButton.centerYAnchor.constraint(equalTo: searchShell.centerYAnchor),
            clearButton.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -pad),

            countLabel.topAnchor.constraint(equalTo: searchShell.bottomAnchor, constant: 8),
            countLabel.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: pad),

            hintLabel.centerYAnchor.constraint(equalTo: countLabel.centerYAnchor),
            hintLabel.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -pad),
            hintLabel.leadingAnchor.constraint(greaterThanOrEqualTo: countLabel.trailingAnchor, constant: 12),

            countLabel.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -14),
        ])
        return card
    }

    private func configureEmptyCard() {
        emptyCard.isHidden = true

        emptyTitleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        emptyTitleLabel.textColor = .labelColor
        emptyTitleLabel.alignment = .center

        emptySubtitleLabel.font = .systemFont(ofSize: 11)
        emptySubtitleLabel.textColor = .secondaryLabelColor
        emptySubtitleLabel.alignment = .center
        emptySubtitleLabel.lineBreakMode = .byWordWrapping
        emptySubtitleLabel.maximumNumberOfLines = 2

        for view in [emptyTitleLabel, emptySubtitleLabel] {
            view.translatesAutoresizingMaskIntoConstraints = false
            emptyCard.addSubview(view)
        }

        NSLayoutConstraint.activate([
            emptyTitleLabel.topAnchor.constraint(equalTo: emptyCard.topAnchor, constant: 22),
            emptyTitleLabel.leadingAnchor.constraint(equalTo: emptyCard.leadingAnchor, constant: 24),
            emptyTitleLabel.trailingAnchor.constraint(equalTo: emptyCard.trailingAnchor, constant: -24),

            emptySubtitleLabel.topAnchor.constraint(equalTo: emptyTitleLabel.bottomAnchor, constant: 6),
            emptySubtitleLabel.leadingAnchor.constraint(equalTo: emptyCard.leadingAnchor, constant: 24),
            emptySubtitleLabel.trailingAnchor.constraint(equalTo: emptyCard.trailingAnchor, constant: -24),
            emptySubtitleLabel.bottomAnchor.constraint(equalTo: emptyCard.bottomAnchor, constant: -22),
        ])
    }

    // MARK: - 列表刷新

    private func rebuildRows() {
        let query = searchField.stringValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let kind = selectedKind

        // 每条只查一次磁盘：摘要、行禁用状态、预览都复用同一份结论。
        var presence = [Bool](repeating: false, count: entries.count)
        visibleEntryIndices.removeAll(keepingCapacity: true)
        for (index, entry) in entries.enumerated() {
            let isPresent = entry.isFilePresent
            presence[index] = isPresent
            guard kind == nil || entry.kind == kind else { continue }
            guard query.isEmpty || HistoryText.search(for: entry).contains(query) else { continue }
            visibleEntryIndices.append(index)
        }

        // 过滤后原选中项可能消失；下落第一行，保证空格总有预览目标。
        if let selectedEntryID,
           !visibleEntryIndices.contains(where: { entries[$0].id == selectedEntryID }) {
            self.selectedEntryID = nil
        }
        if selectedEntryID == nil, let first = visibleEntryIndices.first {
            selectedEntryID = entries[first].id
        }

        let desiredIDs = visibleEntryIndices.map { entries[$0].id }
        // 用显式的 tuple 参数：`Zip2Sequence` 的元素是一个二元组，
        // 闭包只有一个参数，不能写成 `$0 == $1`。
        let canReuse = rows.count == desiredIDs.count
            && zip(rows, desiredIDs).allSatisfy { pair in pair.0.entryID == pair.1 }

        if canReuse {
            // 序列没变：原地更新。搜索逐键触发时这条路径避免拆掉 200 个行视图。
            for (rowIndex, entryIndex) in visibleEntryIndices.enumerated() {
                let entry = entries[entryIndex]
                rows[rowIndex].configure(
                    entry: entry,
                    rowIndex: rowIndex,
                    isPresent: presence[entryIndex],
                    thumbnail: thumbnailImage(for: entry),
                    isSelected: entry.id == selectedEntryID
                )
            }
        } else {
            for view in listStack.arrangedSubviews {
                listStack.removeArrangedSubview(view)
                view.removeFromSuperview()
            }
            rows.removeAll(keepingCapacity: true)

            for (rowIndex, entryIndex) in visibleEntryIndices.enumerated() {
                let entry = entries[entryIndex]
                let row = makeRow(entry: entry, rowIndex: rowIndex, isPresent: presence[entryIndex])
                rows.append(row)
                listStack.addArrangedSubview(row)
                row.widthAnchor.constraint(equalTo: listStack.widthAnchor).isActive = true
            }

            // 序列变化（筛选、新增、删除）后回到顶部：用户刚改了条件，
            // 停在半截既看不到第一条，也看不出结果变少了。
            scrollView.contentView.scroll(to: .zero)
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }

        updateSummary(presence: presence)
        updateHint()
        updateEmptyState()
        // `SettingsPushButton` 自绘并且不处理禁用态，光设 `isEnabled` 会让人
        // 看到一个「亮着但点不动」的按钮；补一层透明度作为视觉禁用。
        clearButton.isEnabled = !entries.isEmpty
        clearButton.alphaValue = entries.isEmpty ? 0.45 : 1
    }

    private func makeRow(entry: HistoryEntry, rowIndex: Int, isPresent: Bool) -> HistoryRowView {
        let row = HistoryRowView(entry: entry, rowIndex: rowIndex)
        var availability = HistoryRowView.Availability()
        availability.copy = onCopy != nil
        availability.edit = onEdit != nil
        availability.pin = onPin != nil
        availability.reveal = onReveal != nil
        availability.delete = onDelete != nil
        availability.favorite = onFavorite != nil
        row.availability = availability
        row.configure(
            entry: entry,
            rowIndex: rowIndex,
            isPresent: isPresent,
            thumbnail: thumbnailImage(for: entry),
            isSelected: entry.id == selectedEntryID
        )
        row.onClick = { [weak self] index in self?.selectRow(index) }
        row.onDoubleClick = { [weak self] index in self?.editRow(index) }
        row.onSpace = { [weak self] in self?.togglePreview() }
        row.onReturn = { [weak self] in self?.editSelected() }
        row.onEscape = { [weak self] in self?.escapePressed() }
        row.onAction = { [weak self] action, index in self?.perform(action, rowIndex: index) }
        return row
    }

    private func updateSummary(presence: [Bool]) {
        guard !entries.isEmpty else {
            countLabel.stringValue = "共 0 条"
            return
        }
        let total = entries.count
        let shown = visibleEntryIndices.count
        let present = presence.lazy.filter { $0 }.count
        var text = shown == total ? "共 \(total) 条" : "显示 \(shown) / 共 \(total) 条"
        text += " · 可打开 \(present) 条"
        let missing = total - present
        if missing > 0 {
            text += " · 其余 \(missing) 条文件已移走"
        }
        countLabel.stringValue = text
    }

    private func updateHint() {
        var parts = ["空格预览"]
        if onEdit != nil {
            parts.append("双击编辑")
        }
        hintLabel.stringValue = parts.joined(separator: " · ")
    }

    private func updateEmptyState() {
        let isEmpty = visibleEntryIndices.isEmpty
        emptyCard.isHidden = !isEmpty
        guard isEmpty else { return }

        if entries.isEmpty {
            emptyTitleLabel.stringValue = "还没有历史记录"
            emptySubtitleLabel.stringValue = "截图、长截图或录屏完成后会自动出现在这里。"
        } else {
            emptyTitleLabel.stringValue = "没有匹配的记录"
            emptySubtitleLabel.stringValue = "换个关键词，或把类型筛选切回「全部」。"
        }
    }

    private func thumbnailImage(for entry: HistoryEntry) -> NSImage? {
        let key = entry.id.uuidString as NSString
        if let cached = thumbnailCache.object(forKey: key) { return cached }
        guard let url = store.thumbnailURL(for: entry),
              let image = NSImage(contentsOf: url) else { return nil }
        thumbnailCache.setObject(image, forKey: key)
        return image
    }

    // MARK: - 选择与定位

    private func entry(forRow rowIndex: Int) -> HistoryEntry? {
        guard rowIndex >= 0, rowIndex < visibleEntryIndices.count else { return nil }
        return entries[visibleEntryIndices[rowIndex]]
    }

    private var selectedEntry: HistoryEntry? {
        guard let selectedEntryID else { return nil }
        return entries.first { $0.id == selectedEntryID }
    }

    private var firstVisibleEntry: HistoryEntry? {
        guard let index = visibleEntryIndices.first else { return nil }
        return entries[index]
    }

    private func selectRow(_ rowIndex: Int) {
        guard let entry = entry(forRow: rowIndex) else { return }
        selectedEntryID = entry.id
        updateSelectionHighlight()
    }

    private func updateSelectionHighlight() {
        for row in rows {
            row.setSelected(row.entryID == selectedEntryID)
        }
    }

    private func focusSelectedRow() {
        guard window.isVisible, window.isKeyWindow else { return }
        makeSelectedRowFirstResponder()
    }

    private func makeSelectedRowFirstResponder() {
        guard window.isVisible, let selectedEntryID,
              let row = rows.first(where: { $0.entryID == selectedEntryID }) else { return }
        window.makeFirstResponder(row)
    }

    /// 预览关闭后把键盘交回历史窗口。
    ///
    /// 只有这里与 `show()` 会主动抢 key：后台刷新（例如又保存了一张截图）
    /// 不应把焦点从用户当前的应用里拽走。
    private func restoreFocusAfterPreview() {
        guard window.isVisible, !isClosing else { return }
        window.makeKeyAndOrderFront(nil)
        makeSelectedRowFirstResponder()
    }

    /// 重建后如果焦点原本在行上，把焦点接到新的选中行；
    /// 焦点在搜索框时不动（否则打字会中断）。
    private func updateFirstResponderAfterRebuild() {
        let responder = window.firstResponder
        guard responder is HistoryRowView || responder === window else { return }
        focusSelectedRow()
    }

    // MARK: - 键盘

    private func editSelected() {
        guard let entry = selectedEntry else { return }
        guard onEdit != nil, entry.isFilePresent else { return }
        onEdit?(entry)
    }

    private func editRow(_ rowIndex: Int) {
        guard let entry = entry(forRow: rowIndex) else { return }
        selectRow(rowIndex)
        guard onEdit != nil, entry.isFilePresent else { return }
        onEdit?(entry)
    }

    private func togglePreview() {
        if preview.isVisible {
            preview.close()
            return
        }
        // 没有选中项时（例如刚过滤完）把预览目标落到第一行，而不是沉默。
        if selectedEntry == nil, let first = firstVisibleEntry {
            selectedEntryID = first.id
            updateSelectionHighlight()
        }
        guard let entry = selectedEntry else { return }
        let thumbnail = thumbnailCache.object(forKey: entry.id.uuidString as NSString)
        preview.show(entry, thumbnail: thumbnail, relativeTo: window)
    }

    private func escapePressed() {
        if preview.isVisible {
            preview.close()
            return
        }
        if !searchField.stringValue.isEmpty {
            searchField.stringValue = ""
            rebuildRows()
            focusSelectedRow()
            return
        }
        hide()
    }

    private func repositionIfNeeded() {
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        let size = window.frame.size
        // 贴右边缘、垂直居中；窗口比可视区还大时（例如小屏 + 放大 UI），
        // 至少保证左上角在屏幕内，而不是整块跑到屏幕外。
        let x = max(
            visible.minX + SettingsTheme.margin,
            visible.maxX - size.width - SettingsTheme.margin
        )
        let y = min(
            max(visible.minY + SettingsTheme.margin, visible.midY - size.height / 2),
            visible.maxY - size.height - SettingsTheme.margin
        )
        window.setFrameOrigin(CGPoint(x: x, y: y))
    }

    // MARK: - 动作

    private func perform(_ action: HistoryRowAction, rowIndex: Int) {
        guard let entry = entry(forRow: rowIndex) else { return }
        switch action {
        case .copy:
            onCopy?(entry)
        case .edit:
            editRow(rowIndex)
        case .pin:
            onPin?(entry)
        case .reveal:
            onReveal?(entry)
        case .delete:
            onDelete?(entry)
        case .favorite:
            toggleFavorite(rowIndex: rowIndex, entry: entry)
        }
    }

    private func toggleFavorite(rowIndex: Int, entry: HistoryEntry) {
        guard validRowIndex(rowIndex), rowIndex < rows.count else { return }
        var updated = entry
        updated.isFavorite.toggle()
        // 本地数组先改：收藏是即时反馈，不该等集成方 refresh 回填。
        // 排序不变——与 store 一致，用户按时间找图时位置跳动比高亮更烦。
        entries[visibleEntryIndices[rowIndex]] = updated
        rows[rowIndex].setFavorite(updated.isFavorite)
        onFavorite?(updated, updated.isFavorite)
    }

    private func validRowIndex(_ rowIndex: Int) -> Bool {
        rowIndex >= 0 && rowIndex < visibleEntryIndices.count
    }

    /// 搜索框文本变化（含取消按钮与 ESC 清空）。
    func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSSearchField,
              field === searchField else { return }
        rebuildRows()
        updateFirstResponderAfterRebuild()
    }

    @objc private func filterChanged() {
        rebuildRows()
        updateFirstResponderAfterRebuild()
    }

    @objc private func clearTapped() {
        let alert = NSAlert()
        alert.messageText = "清空历史记录？"
        alert.informativeText = "只清除历史列表、缩略图与历史缓存副本，不会删除你已经保存的截图文件。"
        alert.addButton(withTitle: "清空")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        preview.close()
        onClear?()
    }

    // MARK: - NSWindowDelegate

    /// 用户点标题栏红点时不会走 `hide()`；这里补齐预览窗口的收尾。
    func windowWillClose(_ notification: Notification) {
        isClosing = true
        // 预览的 `onClose` 会尝试归还焦点；`isClosing` 让那次回交成为空操作。
        preview.close()
        isClosing = false
    }
}
