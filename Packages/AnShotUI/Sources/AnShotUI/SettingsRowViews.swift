//
//  SettingsRowViews.swift
//  AnShotUI
//
//  设置窗口的行视图：分组标题、页头、字段行、控件行、开关行。
//
//  行是「标签 + 控件」的组合，负责把设置项排成可读的一列。
//  容器由 `SettingsContainerViews` 提供，设计令牌见 `SettingsTheme.swift`。
//
//  注：`HeaderIconTile` 是 private，只被同在本文件的 `SettingsHeaderView`
//  使用——拆分组时必须保持同文件，否则 private 不可见。
//
import AppKit

/// 卡片外的三级标题（比卡片内标题更弱）。
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

// MARK: - 页头

/// 窗口顶部：强调色图标块 + 标题 + 一句说明。
///
/// 页头的作用是先把「这是什么窗口、能做什么」讲清楚，
/// 后面的卡片才不需要靠猜来理解。
final class SettingsHeaderView: NSView {

    init(symbolName: String, title: String, subtitle: String) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        let tile = HeaderIconTile(symbolName: symbolName)
        tile.translatesAutoresizingMaskIntoConstraints = false

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 17, weight: .semibold)
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
        row.spacing = 14
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)

        NSLayoutConstraint.activate([
            tile.widthAnchor.constraint(equalToConstant: 44),
            tile.heightAnchor.constraint(equalToConstant: 44),

            row.topAnchor.constraint(equalTo: topAnchor),
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("不支持从 nib 构造")
    }
}

/// 页头左侧的圆角图标块。
private final class HeaderIconTile: NSView {

    private let imageView = NSImageView()

    init(symbolName: String) {
        super.init(frame: .zero)
        wantsLayer = true
        imageView.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
        imageView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 21, weight: .medium)
        imageView.contentTintColor = SettingsTheme.onAccent
        imageView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(imageView)
        NSLayoutConstraint.activate([
            imageView.centerXAnchor.constraint(equalTo: centerXAnchor),
            imageView.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("不支持从 nib 构造")
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.cornerRadius = 11
        layer?.cornerCurve = .continuous
        // 强调色块：整窗口唯一的高饱和区域，用来锚定视觉重心。
        layer?.backgroundColor = SettingsTheme.accent.cgColor
    }
}

// MARK: - 文件夹内嵌面

/// 设置里的一行「标签 + 输入框」。
///
/// 背景、圆角、描边与聚焦态全部由 `SettingsFieldShell` 提供，输入框自己
/// 关掉系统外观（bezel / focus ring）——两层外观叠在一起，
/// 系统那层会带来整窗唯一的一处彩色，与「无彩色、靠明度分层」的体系冲突。
final class SettingsFieldRow: NSView {

    /// 输入控件。`isSecure` 为真时它是 `NSSecureTextField`。
    let field: NSTextField

    /// 密钥行的显示/隐藏按钮；非密钥行为 nil。
    private(set) var revealButton: SettingsAccessoryButton?

    /// 内容当前是否**明文可见**。非密钥行恒为 true。
    private(set) var isContentVisible = true

    /// 是否是密钥行。
    ///
    /// 隐藏态拒绝粘贴的依据（见 `SettingsViewController.control(_:textView:doCommandBy:)`）。
    var isSecret: Bool { revealButton != nil }

    private static let labelWidth: CGFloat = 108

    /// - Parameters:
    ///   - label: 左侧标签。
    ///   - placeholder: 输入框占位文字。
    ///   - isSecure: 是否按密钥处理（密文回显 + 显示/隐藏切换）。
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
        labelField.font = .systemFont(ofSize: 13)
        labelField.textColor = .secondaryLabelColor
        labelField.alignment = .right
        labelField.translatesAutoresizingMaskIntoConstraints = false

        let shell: SettingsFieldShell
        if isSecure {
            let button = SettingsAccessoryButton(symbolName: "eye.slash", target: nil, action: nil)
            button.target = self
            button.action = #selector(toggleSecretVisibility)
            revealButton = button
            shell = SettingsFieldShell(control: textField, accessory: button)
            // 一律从**隐藏**开始：密钥不该因为上次看过明文就一直明着摊在屏幕上。
            setContentVisible(false)
        } else {
            shell = SettingsFieldShell(control: textField)
        }

        // 首选宽度用 .defaultHigh：窗口变窄时它可以被打断，
        // 而不是让整个布局报冲突。
        let preferredWidth = shell.widthAnchor.constraint(equalToConstant: SettingsTheme.maxFieldWidth)
        preferredWidth.priority = .defaultHigh
        addSubview(labelField)
        addSubview(shell)

        NSLayoutConstraint.activate([
            // 高度由外壳决定：它的内边距与圆角是一体的，
            // 行高另写一个常数迟早会和外壳对不上。
            labelField.leadingAnchor.constraint(equalTo: leadingAnchor),
            labelField.centerYAnchor.constraint(equalTo: centerYAnchor),
            labelField.widthAnchor.constraint(equalToConstant: Self.labelWidth),

            shell.leadingAnchor.constraint(equalTo: labelField.trailingAnchor, constant: 10),
            // 宽度取「首选值 + 上限」两条约束（理由见 SettingsTheme.maxFieldWidth）：
            //   只写上上限的话，控件会塌到最小尺寸——Auto Layout 没有任何依据
            //   把它撑到那个上限（实测会变成一个小方块）。
            preferredWidth,
            shell.widthAnchor.constraint(lessThanOrEqualToConstant: SettingsTheme.maxFieldWidth),
            shell.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            shell.topAnchor.constraint(equalTo: topAnchor),
            shell.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    /// 切换明文/密文回显。
    ///
    /// ── 为什么是替换 cell，而不是改 `echosBullets` ──────────
    ///
    /// `NSSecureTextFieldCell.echosBullets = false` 看起来正是为这件事准备的，
    /// 但**实测不生效**：字段会渲染成一片空白——既不是明文，也不是圆点
    ///（见隔离测试：默认密文 / echosBullets=false / 换 cell 三组对照）。
    /// 遮蔽行为不只由这个开关决定。因此改成替换 cell，由 cell 的类型决定回显方式。
    ///
    /// 代价是 cell 一换，内容和样式都不跟随，必须显式搬过去——
    /// 这也是下面要把外观参数集中到 `configure(_:)` 的原因：
    /// 分散写的话，「显示一次再隐藏回去」就会悄悄丢掉字体设置。
    func setContentVisible(_ visible: Bool) {
        isContentVisible = visible

        if isSecret {
            // 编辑过程中替换 cell 会让 field editor 与旧 cell 脱钩，
            // 先让窗口交出第一响应者，把正在输入的内容提交掉。
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

    /// cell 的统一外观。与输入框外壳配套：不要系统边框、背景与聚焦环。
    ///
    /// 这几个属性都住在 **cell** 上，所以每次新建 cell 都要重新设一遍。
    /// `focusRingType` 最容易被漏掉：它是系统蓝的聚焦环，而密钥行切一次显隐
    /// 就会换一个 cell——漏设之后，圆点框聚焦时会冒出一圈与整窗「无彩色」
    /// 体系冲突的蓝环（而其它字段看不出来，因为它们从不换 cell）。
    ///
    /// 写成泛型是为了**消除调用点的强转**：曾经返回 `NSTextFieldCell`，
    /// 于是 `NSSecureTextFieldCell` 的调用方必须写
    /// `configure(…) as! NSSecureTextFieldCell`——一个纯属类型系统缺陷的强转。
    /// 泛型化后 T 由实参推断，零强转，且行为完全等价。
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

/// 设置里的一行「标签 + 任意控件」。
///
/// 与 `SettingsFieldRow` 分开而不是合并成一个类：文本行要把 `field` 暴露给
/// 调用方（读写值、设 delegate），而通用行没有这个概念——
/// 合成一个类只会让 `field` 变成「有时有、有时没有」。
final class SettingsControlRow: NSView {

    let shell: SettingsFieldShell

    private static let labelWidth: CGFloat = 108

    init(label: String, control: NSView) {
        shell = SettingsFieldShell(control: control)

        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        let labelField = NSTextField(labelWithString: label)
        labelField.font = .systemFont(ofSize: 13)
        labelField.textColor = .secondaryLabelColor
        labelField.alignment = .right
        labelField.translatesAutoresizingMaskIntoConstraints = false

        // 首选宽度用 .defaultHigh：窗口变窄时它可以被打断，
        // 而不是让整个布局报冲突。
        let preferredWidth = shell.widthAnchor.constraint(equalToConstant: SettingsTheme.maxFieldWidth)
        preferredWidth.priority = .defaultHigh

        addSubview(labelField)
        addSubview(shell)

        NSLayoutConstraint.activate([
            labelField.leadingAnchor.constraint(equalTo: leadingAnchor),
            labelField.centerYAnchor.constraint(equalTo: centerYAnchor),
            labelField.widthAnchor.constraint(equalToConstant: Self.labelWidth),

            shell.leadingAnchor.constraint(equalTo: labelField.trailingAnchor, constant: 10),
            // 宽度取「首选值 + 上限」两条约束（理由见 SettingsTheme.maxFieldWidth）：
            //   只写上上限的话，控件会塌到最小尺寸——Auto Layout 没有任何依据
            //   把它撑到那个上限（实测会变成一个小方块）。
            preferredWidth,
            shell.widthAnchor.constraint(lessThanOrEqualToConstant: SettingsTheme.maxFieldWidth),
            shell.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            shell.topAnchor.constraint(equalTo: topAnchor),
            shell.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("不支持从 nib 构造")
    }
}

// MARK: - 开关行

/// 一行「标题 + 说明 + 开关」。
///
/// 与 `SettingsOptionButton` 的分工：那个表达**单选**（一组互斥选项，
/// 所以它长得像卡片）；这个表达**独立的开关**。用单选按钮表达开关，
/// 用户会以为旁边还应该有别的选项。
///
/// 用系统 `NSSwitch` 而不自绘：「开/关」已经有系统级的视觉与交互约定
/// （包括键盘切换与无障碍语义），重画一个只会让这一处与整机所有开关不一致。
final class SettingsToggleRow: NSView {

    /// 开关本身。调用方直接绑 `target`/`action`。
    ///
    /// 不在这里做一层转发：转发要多一个 `perform`，而 `SettingsFolderSurface`
    /// 已经确立了「暴露子控件给调用方绑定」的先例，保持一致更省事。
    let toggle = NSSwitch()

    private let subtitleLabel: NSTextField
    private let noticeLabel: NSTextField

    /// 开关当前状态。
    var isOn: Bool {
        get { toggle.state == .on }
        set { toggle.state = newValue ? .on : .off }
    }

    init(title: String, subtitle: String?) {
        subtitleLabel = NSTextField(labelWithString: subtitle ?? "")
        subtitleLabel.font = .systemFont(ofSize: 11)
        subtitleLabel.textColor = .tertiaryLabelColor
        subtitleLabel.lineBreakMode = .byWordWrapping
        subtitleLabel.maximumNumberOfLines = 2
        subtitleLabel.isHidden = subtitle == nil

        noticeLabel = NSTextField(labelWithString: "")
        // 提示行默认空且隐藏：只在真的有事要告诉用户时才占位置。
        noticeLabel.font = .systemFont(ofSize: 11)
        noticeLabel.textColor = .secondaryLabelColor
        noticeLabel.lineBreakMode = .byWordWrapping
        noticeLabel.maximumNumberOfLines = 3
        noticeLabel.isHidden = true

        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 13)
        titleLabel.textColor = SettingsTheme.sectionLabel
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        toggle.translatesAutoresizingMaskIntoConstraints = false
        toggle.controlSize = .small

        // 标题行：标题靠左、开关靠右。用一条柔性占位把两者推到两端——
        // 直接靠 `distribution` 做不到（那会同时拉伸标题）。
        let titleRow = NSStackView(views: [titleLabel, NSView(), toggle])
        titleRow.orientation = .horizontal
        titleRow.alignment = .centerY
        titleRow.spacing = 8
        titleRow.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [titleRow, subtitleLabel, noticeLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false

        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            titleRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            subtitleLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            noticeLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("不支持从 nib 构造")
    }

    /// 设置状态提示；传 nil 清除。
    ///
    /// 隐藏而不只是清空文本：空标签仍会占掉 `spacing`，
    /// 让卡片底部凭空多出一段空白。
    func setNotice(_ text: String?) {
        noticeLabel.stringValue = text ?? ""
        noticeLabel.isHidden = text == nil
    }

    /// 供诊断读取的提示文本（空串表示无提示）。
    var noticeTextForDiagnostics: String { noticeLabel.stringValue }
}
