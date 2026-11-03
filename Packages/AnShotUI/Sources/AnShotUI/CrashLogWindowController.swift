//
//  CrashLogWindowController.swift
//  AnShotUI
//
//  「崩溃日志」窗口：把 `CrashLogStore` 索引出来的系统报告摊给用户看。
//
//  ── 为什么要给用户看原始报告 ────────────────────────────────
//
//  崩溃报告是**事后证据**：真正有用的信息常常是「哪个线程、哪一帧、
//  什么异常码」，这些无法用一句话概括。窗口因此分成两半：左边用短句
//  帮用户定位「是哪一天、哪个版本、什么类型的崩溃」，右边原样显示文件，
//  让需要细节的人（比如提 issue 时）能直接复制。
//
//  ── 为什么没有「清空」 ──────────────────────────────────────
//
//  这些文件属于 macOS 的诊断数据，不是 anShot 的私有缓存。删掉会让
//  用户在其他诊断工具里也丢失同一份证据，而且系统本来就会自行清理。
//  所以窗口只提供「刷新 / 在访达中显示 / 复制详情 / 关闭」，没有任何
//  修改或删除入口。
//
//  ── 视觉 ────────────────────────────────────────────────────
//
//  菜单栏程序没有主界面，这个窗口是用户偶尔打开的「诊断页」。背景、
//  卡片、按钮全部取 `SettingsTheme`：与设置窗口同一套明暗层次，避免
//  出现第三个视觉体系。列表选中态也刻意不用系统蓝，而用 `accentSoft`
//  加一圈细描边，与设置里的选中语言一致。
//

import AnShotCore
import AppKit

@MainActor
final class CrashLogWindowController: NSObject {

    /// 单例：窗口关闭后再次从菜单打开时，复用同一个控制器，避免
    /// 每次点击都新建一个 NSWindow 和整棵视图树（本应用「空闲期零窗口」，
    /// 不需要靠重建来释放内存）。
    static let shared = CrashLogWindowController()

    /// 列表最多展示多少份。50 份足够覆盖「最近几次崩溃」，又不会让
    /// 一次刷新去读上百个文件。
    private static let limit = 50

    private static let emptyMessage =
        "没有找到崩溃日志。anShot 运行正常，或者系统尚未生成报告。"
    private static let noSelectionMessage =
        "选择左侧的一条报告查看详情。"

    private let window: NSWindow
    private let tableView = NSTableView()
    private let detailTextView = NSTextView()
    private let emptyListLabel = NSTextField(wrappingLabelWithString: "")
    private let detailPlaceholderLabel = NSTextField(wrappingLabelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private let revealButton = SettingsPushButton(
        title: "在访达中显示",
        target: nil,
        action: nil
    )
    private let copyButton = SettingsPushButton(
        title: "复制详情",
        target: nil,
        action: nil
    )

    private var entries: [CrashLogEntry] = []

    /// 列表时间统一到秒：崩溃报告的时间点本身就是证据的一部分，
    /// 用相对时间（「3 天前」）反而让人无法与报告原文对照。
    private let dateFormatter = DateFormatter()

    private override init() {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 860, height: 600),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )

        super.init()

        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss"

        window.title = "崩溃日志"
        // 由本对象持有并在关闭后复用：交给 AppKit 自动释放会与单例打架。
        window.isReleasedWhenClosed = false
        // 用户可能一边看报告一边切到浏览器提 issue，窗口不能因此消失。
        window.hidesOnDeactivate = false
        window.minSize = NSSize(width: 720, height: 480)
        window.backgroundColor = SettingsTheme.windowBackground
        window.contentView = makeContentView()
        window.center()

        revealButton.target = self
        revealButton.action = #selector(revealSelectedReport)
        copyButton.target = self
        copyButton.action = #selector(copySelectedDetails)
    }

    /// 诊断用：窗口当前是否可见。
    var isVisible: Bool { window.isVisible }

    // MARK: - 显示

    func show() {
        // 每次打开都重新扫描：用户可能刚复现了一次崩溃，或者在别的
        // 诊断工具里把报告移进了 Retired。
        refresh()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        // 列表拿到键盘焦点后可以用上下键逐条查看，复制详情不必先点行。
        window.makeFirstResponder(tableView)
    }

    func close() {
        window.close()
    }

    // MARK: - 刷新

    private func refresh() {
        let previousID = selectedEntry?.id
        entries = CrashLogStore.reports(limit: Self.limit)
        tableView.reloadData()

        if entries.isEmpty {
            statusLabel.stringValue = "系统报告目录里没有 anShot 的记录"
        } else {
            statusLabel.stringValue = "最近 \(entries.count) 份报告（最多 \(Self.limit) 份）"
        }

        emptyListLabel.isHidden = !entries.isEmpty

        if let previousID,
           let index = entries.firstIndex(where: { $0.id == previousID }) {
            tableView.selectRowIndexes(
                IndexSet(integer: index),
                byExtendingSelection: false
            )
            updateDetail()
        } else if entries.isEmpty {
            tableView.deselectAll(nil)
            showDetailPlaceholder(Self.emptyMessage)
        } else {
            tableView.selectRowIndexes(
                IndexSet(integer: 0),
                byExtendingSelection: false
            )
            updateDetail()
        }

        updateActionState()
    }

    private var selectedEntry: CrashLogEntry? {
        let row = tableView.selectedRow
        guard row >= 0, row < entries.count else { return nil }
        return entries[row]
    }

    private func updateDetail() {
        guard let entry = selectedEntry else {
            showDetailPlaceholder(
                entries.isEmpty ? Self.emptyMessage : Self.noSelectionMessage
            )
            updateActionState()
            return
        }

        detailPlaceholderLabel.isHidden = true
        detailTextView.string = CrashLogStore.details(for: entry)
        detailTextView.scrollRangeToVisible(NSRange(location: 0, length: 0))
        updateActionState()
    }

    private func showDetailPlaceholder(_ text: String) {
        detailTextView.string = ""
        detailPlaceholderLabel.stringValue = text
        detailPlaceholderLabel.isHidden = false
    }

    private func updateActionState() {
        let hasSelection = selectedEntry != nil
        revealButton.isEnabled = hasSelection
        copyButton.isEnabled = hasSelection && !detailTextView.string.isEmpty
        // 自绘按钮不读 `isEnabled` 改变文字颜色；用透明度给出「不可按」
        // 的反馈，否则用户会以为按钮坏了。
        revealButton.alphaValue = revealButton.isEnabled ? 1 : 0.45
        copyButton.alphaValue = copyButton.isEnabled ? 1 : 0.45
    }

    // MARK: - 布局

    private func makeContentView() -> NSView {
        let root = CrashLogBackgroundView()

        let header = SettingsHeaderView(
            symbolName: "exclamationmark.triangle",
            title: "崩溃日志",
            subtitle: "查看 anShot 在系统中留下的崩溃报告。只读取系统日志，不会改动或删除任何文件。"
        )
        header.translatesAutoresizingMaskIntoConstraints = false

        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let refreshButton = SettingsPushButton(
            title: "刷新",
            emphasis: .primary,
            target: self,
            action: #selector(refreshTapped)
        )
        let closeButton = SettingsPushButton(
            title: "关闭",
            target: self,
            action: #selector(closeTapped)
        )

        // 左侧状态、右侧动作：动作的视觉重量固定，状态文字随窗口变窄
        // 先被截断，不会把按钮挤出窗口。
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        spacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let toolbar = NSStackView(views: [
            statusLabel,
            spacer,
            refreshButton,
            revealButton,
            copyButton,
            closeButton,
        ])
        toolbar.orientation = .horizontal
        toolbar.alignment = .centerY
        toolbar.spacing = 8
        toolbar.translatesAutoresizingMaskIntoConstraints = false

        let listPane = CrashLogPaneView(
            symbolName: "list.bullet.rectangle",
            title: "报告列表",
            content: makeListContent()
        )
        let detailPane = CrashLogPaneView(
            symbolName: "doc.plaintext",
            title: "详情",
            content: makeDetailContent()
        )

        root.addSubview(header)
        root.addSubview(toolbar)
        root.addSubview(listPane)
        root.addSubview(detailPane)

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: root.topAnchor, constant: SettingsTheme.margin),
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: SettingsTheme.margin),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -SettingsTheme.margin),

            toolbar.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 14),
            toolbar.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: SettingsTheme.margin),
            toolbar.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -SettingsTheme.margin),

            listPane.topAnchor.constraint(equalTo: toolbar.bottomAnchor, constant: 12),
            listPane.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: SettingsTheme.margin),
            listPane.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -SettingsTheme.margin),
            // 左侧列表固定宽度：报告摘要的阅读宽度不需要随窗口无限变宽，
            // 把增长留给右侧原文，长行的横向滚动也更少。
            listPane.widthAnchor.constraint(equalToConstant: 336),

            detailPane.topAnchor.constraint(equalTo: listPane.topAnchor),
            detailPane.leadingAnchor.constraint(equalTo: listPane.trailingAnchor, constant: 14),
            detailPane.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -SettingsTheme.margin),
            detailPane.bottomAnchor.constraint(equalTo: listPane.bottomAnchor),
        ])

        return root
    }

    private func makeListContent() -> NSView {
        let container = NSView()

        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder

        // 单列表格：列宽随卡片宽度变化，不为每列单独调宽度。
        tableView.headerView = nil
        tableView.backgroundColor = .clear
        tableView.rowHeight = 64
        tableView.intercellSpacing = NSSize(width: 0, height: 4)
        tableView.selectionHighlightStyle = .regular
        tableView.style = .plain
        tableView.allowsEmptySelection = true
        tableView.allowsMultipleSelection = false
        tableView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        tableView.autoresizingMask = [.width]
        tableView.gridStyleMask = []
        tableView.delegate = self
        tableView.dataSource = self

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("entry"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        scrollView.documentView = tableView

        emptyListLabel.stringValue = Self.emptyMessage
        emptyListLabel.font = .systemFont(ofSize: 12)
        emptyListLabel.textColor = .secondaryLabelColor
        emptyListLabel.alignment = .center
        emptyListLabel.maximumNumberOfLines = 0
        emptyListLabel.isHidden = true
        emptyListLabel.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(scrollView)
        container.addSubview(emptyListLabel)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: container.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),

            emptyListLabel.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            emptyListLabel.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            emptyListLabel.widthAnchor.constraint(
                lessThanOrEqualTo: container.widthAnchor,
                constant: -32
            ),
        ])

        return container
    }

    private func makeDetailContent() -> NSView {
        let container = NSView()

        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder

        detailTextView.isEditable = false
        detailTextView.isSelectable = true
        detailTextView.isRichText = false
        detailTextView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        detailTextView.textColor = .labelColor
        detailTextView.drawsBackground = false
        detailTextView.textContainerInset = NSSize(width: 10, height: 10)
        // 给一个初始尺寸：NSScrollView 只按 documentView 当前 frame 排版，
        // 零尺寸会让首次打开时空文本视图没有可点击/可滚动的区域。
        detailTextView.frame = NSRect(x: 0, y: 0, width: 480, height: 480)
        detailTextView.minSize = .zero
        detailTextView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        detailTextView.isVerticallyResizable = true
        detailTextView.isHorizontallyResizable = true
        detailTextView.autoresizingMask = [.width]
        detailTextView.textContainer?.containerSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        // 崩溃报告里的长线程栈不应被强制换行：横向滚动比「每行断成几截」
        // 更容易让人对照原文。
        detailTextView.textContainer?.widthTracksTextView = false
        scrollView.documentView = detailTextView

        detailPlaceholderLabel.font = .systemFont(ofSize: 12)
        detailPlaceholderLabel.textColor = .secondaryLabelColor
        detailPlaceholderLabel.alignment = .center
        detailPlaceholderLabel.maximumNumberOfLines = 0
        detailPlaceholderLabel.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(scrollView)
        container.addSubview(detailPlaceholderLabel)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: container.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),

            detailPlaceholderLabel.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            detailPlaceholderLabel.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            detailPlaceholderLabel.widthAnchor.constraint(
                lessThanOrEqualTo: container.widthAnchor,
                constant: -40
            ),
        ])

        return container
    }

    // MARK: - 动作

    @objc private func refreshTapped() {
        refresh()
    }

    @objc private func revealSelectedReport() {
        guard let entry = selectedEntry else { return }

        // 文件还在时直接选中它；已被系统清理时退而打开目录，
        // 至少让用户知道这些报告存放在哪里。
        if FileManager.default.fileExists(atPath: entry.url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([entry.url])
        } else {
            NSWorkspace.shared.open(entry.url.deletingLastPathComponent())
        }
    }

    @objc private func copySelectedDetails() {
        let text = detailTextView.string
        guard !text.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    @objc private func closeTapped() {
        close()
    }

    private func versionText(for entry: CrashLogEntry) -> String {
        switch (entry.appVersion, entry.buildVersion) {
        case let (app?, build?):
            return "\(app) (\(build))"
        case let (app?, nil):
            return app
        case let (nil, build?):
            return "build \(build)"
        case (nil, nil):
            return "版本未知"
        }
    }
}

// MARK: - 列表数据源

extension CrashLogWindowController: NSTableViewDataSource, NSTableViewDelegate {

    func numberOfRows(in tableView: NSTableView) -> Int {
        entries.count
    }

    func tableView(
        _ tableView: NSTableView,
        viewFor tableColumn: NSTableColumn?,
        row: Int
    ) -> NSView? {
        guard row >= 0, row < entries.count else { return nil }

        let identifier = NSUserInterfaceItemIdentifier("CrashLogCell")
        let cell: CrashLogCellView
        if let reused = tableView.makeView(withIdentifier: identifier, owner: self)
            as? CrashLogCellView {
            cell = reused
        } else {
            cell = CrashLogCellView()
            cell.identifier = identifier
        }

        let entry = entries[row]
        cell.configure(
            dateText: dateFormatter.string(from: entry.date),
            versionText: versionText(for: entry),
            kind: entry.kind,
            summary: entry.summary
        )
        return cell
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        CrashLogRowView()
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        updateDetail()
    }
}

// MARK: - 行内容

/// 一条报告的单元格：时间 / 版本 / 类型一行，摘要两行。
///
/// 用 `NSTableCellView` 而不是在 `viewFor` 里拼临时视图：
/// 表格滚动时会复用，复用能避免每次滚动都新建一组文本字段。
private final class CrashLogCellView: NSTableCellView {

    private let dateLabel = NSTextField(labelWithString: "")
    private let versionLabel = NSTextField(labelWithString: "")
    private let summaryLabel = NSTextField(wrappingLabelWithString: "")
    private let kindBadge = CrashLogKindBadge()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        buildLayout()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("不支持从 nib 构造")
    }

    func configure(
        dateText: String,
        versionText: String,
        kind: String,
        summary: String
    ) {
        dateLabel.stringValue = dateText
        versionLabel.stringValue = versionText
        kindBadge.setKind(kind)
        summaryLabel.stringValue = summary
        // 悬停提示给出完整摘要：列表只有两行，长终止原因会被截断。
        toolTip = summary
    }

    private func buildLayout() {
        dateLabel.font = .systemFont(ofSize: 12, weight: .medium)
        dateLabel.textColor = .labelColor
        dateLabel.lineBreakMode = .byTruncatingTail

        versionLabel.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        versionLabel.textColor = .secondaryLabelColor
        versionLabel.lineBreakMode = .byTruncatingTail
        versionLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        summaryLabel.font = .systemFont(ofSize: 11)
        summaryLabel.textColor = .secondaryLabelColor
        summaryLabel.lineBreakMode = .byTruncatingTail
        summaryLabel.maximumNumberOfLines = 2

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        spacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let topRow = NSStackView(views: [dateLabel, versionLabel, spacer, kindBadge])
        topRow.orientation = .horizontal
        topRow.alignment = .centerY
        topRow.spacing = 8

        let stack = NSStackView(views: [topRow, summaryLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 3
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),

            // 竖向 stack 的 arranged view 不会自动撑满宽度；显式拉满，
            // 摘要才能在正确的宽度上截断，类型徽标才能贴右。
            topRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            summaryLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
    }
}

/// 类型徽标（IPS / CRASH）。
///
/// 用一个极小的圆角底块而不是彩色标签：整窗不使用色相，
/// 类型只需要一个可扫读的形态差异，不需要再引入第二种强调色。
private final class CrashLogKindBadge: NSView {

    private let label = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true

        label.font = .systemFont(ofSize: 9, weight: .semibold)
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 5),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -5),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 1),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -1),
        ])

        setContentHuggingPriority(.required, for: .horizontal)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("不支持从 nib 构造")
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.cornerRadius = 4
        layer?.cornerCurve = .continuous
        layer?.backgroundColor = SettingsTheme.insetBackground.cgColor
    }

    func setKind(_ kind: String) {
        label.stringValue = kind.uppercased()
    }
}

/// 列表行：选中态用设置窗口的「淡强调底 + 细描边」，
/// 而不是系统蓝填充，避免整窗出现一处与主题无关的彩色。
private final class CrashLogRowView: NSTableRowView {

    /// 选中行仍按普通背景样式绘制文字。
    ///
    /// 默认的 `.emphasized` 会把文字切成白色（系统蓝选中态的前景色），
    /// 而我们的选中底是浅灰 `accentSoft`——白字落在浅灰上几乎不可读。
    /// 关掉强调样式，行内 `labelColor` 才能保持深色。
    override var interiorBackgroundStyle: NSView.BackgroundStyle { .normal }

    override func drawBackground(in dirtyRect: NSRect) {
        // 卡片本身提供底色；行不再画交替色，保持平面。
    }

    override func drawSelection(in dirtyRect: NSRect) {
        guard isSelected, let context = NSGraphicsContext.current?.cgContext else {
            return
        }
        let rect = bounds.insetBy(dx: 2, dy: 2)
        SettingsTheme.fillRoundedRect(
            rect,
            radius: 8,
            color: SettingsTheme.accentSoft,
            in: context
        )
        SettingsTheme.strokeRoundedRect(
            rect,
            radius: 8,
            color: SettingsTheme.accent.withAlphaComponent(0.28),
            lineWidth: 1,
            in: context
        )
    }
}

// MARK: - 卡片

/// 窗口内的卡片：与 `SettingsCardView` 同一套外观，但把内容区钉死到
/// 卡片底部。
///
/// 为什么不用 `SettingsCardView`：它的内容高度由内部 stack 决定，
/// 把 `NSScrollView` 放进去时没有确定的高度来源，列表/详情会在
/// 不同系统版本上塌成零高。这里把「标题 + 可伸缩内容」的约束写死，
/// 窗口缩放时内容始终填满剩余空间。
private final class CrashLogPaneView: NSView {

    private let content: NSView

    init(symbolName: String, title: String, content: NSView) {
        self.content = content
        super.init(frame: .zero)

        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true

        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
        icon.contentTintColor = SettingsTheme.accent
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
        icon.translatesAutoresizingMaskIntoConstraints = false

        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        label.textColor = SettingsTheme.sectionLabel

        let header = NSStackView(views: [icon, label])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 8
        header.translatesAutoresizingMaskIntoConstraints = false

        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(header)
        addSubview(content)

        let padding = SettingsTheme.cardPadding
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: topAnchor, constant: padding),
            header.leadingAnchor.constraint(equalTo: leadingAnchor, constant: padding),
            header.trailingAnchor.constraint(
                lessThanOrEqualTo: trailingAnchor,
                constant: -padding
            ),

            content.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 10),
            // 内容左右留 12 而不是 18：表格行的选中底和滚动条需要一点
            // 呼吸空间，但不需要与标题缩进严格对齐。
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            content.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
        ])
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
    }
}

// MARK: - 背景

/// 窗口底色。动态色必须走 `updateLayer()` 才会在切换深浅模式时重绘
/// （与 `SettingsTheme` 的约定一致）。
private final class CrashLogBackgroundView: NSView {

    init() {
        super.init(frame: .zero)
        // `wantsUpdateLayer` 只在 layer-backed 视图上生效；少了这一行，
        // updateLayer 里的赋值会被静默丢弃，窗口会是一片默认白。
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
