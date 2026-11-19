//
//  SettingsRowViews.swift
//  AnShotUI
//
//  设置窗口的现代统一行规范：
//  - 页头：40×40 彩色微光泽渐变圆角徽章 + 大标题 + 优雅说明；
//  - 全部行组件严格遵守「左对齐标题/副标题 + 右对齐控件」的 macOS 原生分组秩序，
//    彻底消除旧版「右对齐标签 + 框套框」导致的视觉断裂。
//
import AppKit

/// 卡片外的三级标题。
final class SettingsSectionHeader: NSTextField {
    init(_ text: String) {
        super.init(frame: .zero)
        stringValue = text
        font = .systemFont(ofSize: 11, weight: .semibold)
        textColor = .tertiaryLabelColor
        isEditable = false
        isBordered = false
        drawsBackground = false
        isSelectable = false
        translatesAutoresizingMaskIntoConstraints = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("不支持从 nib 构造")
    }
}

// MARK: - 现代彩徽页头

/// 页面顶部：40×40 语义彩色微光泽圆角徽章 + 标题 + 说明。
final class SettingsHeaderView: NSView {

    init(
        symbolName: String,
        title: String,
        subtitle: String,
        badgeColor: NSColor = SettingsTheme.accent
    ) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        let tile = HeaderIconTile(symbolName: symbolName, badgeColor: badgeColor)
        tile.translatesAutoresizingMaskIntoConstraints = false

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 19, weight: .bold)
        titleLabel.textColor = .labelColor

        let subtitleLabel = NSTextField(labelWithString: subtitle)
        subtitleLabel.font = .systemFont(ofSize: 12)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.lineBreakMode = .byWordWrapping
        subtitleLabel.maximumNumberOfLines = 2

        let text = NSStackView(views: [titleLabel, subtitleLabel])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 2

        let row = NSStackView(views: [tile, text])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 13
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)

        NSLayoutConstraint.activate([
            tile.widthAnchor.constraint(equalToConstant: 40),
            tile.heightAnchor.constraint(equalToConstant: 40),

            row.topAnchor.constraint(equalTo: topAnchor),
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("不支持从 nib 构造")
    }
}

/// 页头左侧的彩色渐变圆角徽章（带微投影与顶部玻璃高光）。
private final class HeaderIconTile: NSView {

    private let symbolName: String
    private let badgeColor: NSColor

    init(symbolName: String, badgeColor: NSColor) {
        self.symbolName = symbolName
        self.badgeColor = badgeColor
        super.init(frame: .zero)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("不支持从 nib 构造")
    }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        SettingsTheme.drawBadgeTile(
            in: bounds,
            radius: 10.5,
            baseColor: badgeColor,
            symbolName: symbolName,
            symbolPointSize: 18,
            symbolWeight: .semibold,
            in: ctx
        )
    }
}

// MARK: - 文本与密钥输入行

/// 文本 / 密钥输入行：左侧整齐左对齐标签 + 右侧精致圆角输入外壳。
final class SettingsFieldRow: NSView {

    let field: NSTextField
    private(set) var revealButton: SettingsAccessoryButton?
    private(set) var isContentVisible = true
    var isSecret: Bool { revealButton != nil }

    private static let labelWidth: CGFloat = 96

    init(label: String, placeholder: String = "", isSecure: Bool = false) {
        let textField: NSTextField = isSecure ? NSSecureTextField() : NSTextField()
        textField.placeholderString = placeholder
        textField.font = .systemFont(ofSize: 13)
        textField.textColor = .labelColor
        textField.isBezeled = false
        textField.drawsBackground = false
        textField.focusRingType = .none
        field = textField

        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        let labelField = NSTextField(labelWithString: label)
        labelField.font = .systemFont(ofSize: 13, weight: .medium)
        labelField.textColor = .labelColor
        labelField.alignment = .left
        labelField.translatesAutoresizingMaskIntoConstraints = false

        let shell: SettingsFieldShell
        if isSecure {
            let button = SettingsAccessoryButton(symbolName: "eye.slash", target: nil, action: nil)
            button.target = self
            button.action = #selector(toggleSecretVisibility)
            revealButton = button
            shell = SettingsFieldShell(control: textField, accessory: button)
            setContentVisible(false)
        } else {
            shell = SettingsFieldShell(control: textField)
        }

        addSubview(labelField)
        addSubview(shell)

        NSLayoutConstraint.activate([
            labelField.leadingAnchor.constraint(equalTo: leadingAnchor),
            labelField.centerYAnchor.constraint(equalTo: centerYAnchor),
            labelField.widthAnchor.constraint(equalToConstant: Self.labelWidth),

            shell.leadingAnchor.constraint(equalTo: labelField.trailingAnchor, constant: 12),
            shell.trailingAnchor.constraint(equalTo: trailingAnchor),
            shell.topAnchor.constraint(equalTo: topAnchor),
            shell.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    func setContentVisible(_ visible: Bool) {
        isContentVisible = visible

        if isSecret {
            if let window = field.window, window.firstResponder is NSTextView {
                window.makeFirstResponder(nil)
            }

            let value = field.stringValue
            field.cell = visible ? Self.makePlainCell() : Self.makeSecureCell()
            field.stringValue = value
            field.needsDisplay = true
        }

        revealButton?.symbolName = visible ? "eye" : "eye.slash"
        revealButton?.toolTip = visible ? "隐藏密钥" : "显示密钥"
    }

    private static func configure<T: NSTextFieldCell>(_ cell: T) -> T {
        cell.font = .systemFont(ofSize: 13)
        cell.textColor = .labelColor
        cell.isBezeled = false
        cell.drawsBackground = false
        cell.focusRingType = .none
        cell.isScrollable = true
        cell.isEditable = true
        cell.isSelectable = true
        cell.wraps = false
        cell.usesSingleLineMode = true
        cell.lineBreakMode = .byClipping
        return cell
    }

    private static func makeSecureCell() -> NSSecureTextFieldCell {
        configure(NSSecureTextFieldCell())
    }

    private static func makePlainCell() -> NSTextFieldCell {
        configure(NSTextFieldCell())
    }

    @objc private func toggleSecretVisibility() {
        setContentVisible(!isContentVisible)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("不支持从 nib 构造")
    }
}

// MARK: - 现代左文右控设置行（彻底告别框套框与左右错位）

/// 统一「左对齐标题/副标题 + 右对齐原生控件」行：
/// 不再用多余外壳包裹原生 `NSPopUpButton` / `NSSlider` / `NSStepper`，视觉清爽且与开关行严格共线。
final class SettingsControlRow: NSView {

    let control: NSView

    init(label: String, subtitle: String? = nil, control: NSView) {
        self.control = control
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        // 若传入的是原生下拉框，统一升级为干净原生风格（告别 `.inline` 配外灰框的双层套娃）。
        if let popUp = control as? NSPopUpButton {
            popUp.isBordered = true
            popUp.bezelStyle = .rounded
            popUp.controlSize = .regular
            popUp.font = .systemFont(ofSize: 13)
        }

        let titleLabel = NSTextField(labelWithString: label)
        titleLabel.font = .systemFont(ofSize: 13, weight: .medium)
        titleLabel.textColor = .labelColor
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        let textStack = NSStackView(views: [titleLabel])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 2
        textStack.translatesAutoresizingMaskIntoConstraints = false
        textStack.setContentHuggingPriority(.defaultLow, for: .horizontal)

        if let subtitle, !subtitle.isEmpty {
            let subLabel = NSTextField(wrappingLabelWithString: subtitle)
            subLabel.font = .systemFont(ofSize: 11.5)
            subLabel.textColor = .secondaryLabelColor
            subLabel.maximumNumberOfLines = 2
            textStack.addArrangedSubview(subLabel)
        }

        control.translatesAutoresizingMaskIntoConstraints = false
        control.setContentHuggingPriority(.required, for: .horizontal)

        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        spacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let row = NSStackView(views: [textStack, spacer, control])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 12
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)

        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: topAnchor, constant: 1),
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -1),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("不支持从 nib 构造")
    }
}

// MARK: - 开关行

/// 统一「左对齐主标题 + 说明 + 右侧系统开关」行，与 `SettingsControlRow` 严格对齐。
final class SettingsToggleRow: NSView {

    let toggle = NSSwitch()

    private let subtitleLabel: NSTextField
    private let noticeLabel: NSTextField

    var isOn: Bool {
        get { toggle.state == .on }
        set { toggle.state = newValue ? .on : .off }
    }

    init(title: String, subtitle: String?) {
        subtitleLabel = NSTextField(labelWithString: subtitle ?? "")
        subtitleLabel.font = .systemFont(ofSize: 11.5)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.lineBreakMode = .byWordWrapping
        subtitleLabel.maximumNumberOfLines = 2
        subtitleLabel.isHidden = subtitle == nil

        noticeLabel = NSTextField(labelWithString: "")
        noticeLabel.font = .systemFont(ofSize: 11)
        noticeLabel.textColor = AnShotTheme.warning
        noticeLabel.lineBreakMode = .byWordWrapping
        noticeLabel.maximumNumberOfLines = 3
        noticeLabel.isHidden = true

        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 13, weight: .medium)
        titleLabel.textColor = .labelColor
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        let leftStack = NSStackView(views: [titleLabel, subtitleLabel, noticeLabel])
        leftStack.orientation = .vertical
        leftStack.alignment = .leading
        leftStack.spacing = 2.5
        leftStack.translatesAutoresizingMaskIntoConstraints = false
        leftStack.setContentHuggingPriority(.defaultLow, for: .horizontal)
        leftStack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        toggle.translatesAutoresizingMaskIntoConstraints = false
        toggle.controlSize = .small
        toggle.setContentHuggingPriority(.required, for: .horizontal)
        toggle.setContentCompressionResistancePriority(.required, for: .horizontal)

        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        spacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let row = NSStackView(views: [leftStack, spacer, toggle])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 14
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)

        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: topAnchor, constant: 1),
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -1),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("不支持从 nib 构造")
    }

    func setNotice(_ text: String?) {
        noticeLabel.stringValue = text ?? ""
        noticeLabel.isHidden = text == nil
    }

    var noticeTextForDiagnostics: String { noticeLabel.stringValue }
}
