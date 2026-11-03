//
//  WindowPickerController.swift
//  AnShotUI
//
//  按窗口挑选截图/录制目标的选择器。
//
//  ── 它只做「选」────────────────────────────────────────────
//
//  这里不截图、不构造捕获范围、不决定截完去哪：那些属于调用方的流程。
//  选择器只把「哪一个窗口」（windowID + 应用名 + 标题 + 全局 frame）
//  交出去，调用方拿着 windowID 走现有的捕获路径。
//
//  ── 为什么不用激活窗口的模态弹窗 ──────────────────────────
//
//  截图工具的窗口选择常常由热键唤起。如果这里调用 `NSApp.activate`，
//  用户当前正在操作的应用会失去前台状态，选完还要再切回去。
//  因此面板使用 `.nonactivatingPanel`：可以成为键盘焦点（搜索框要能输入），
//  但不激活本应用。
//
//  ── 枚举是异步的 ──────────────────────────────────────────
//
//  `SCShareableContent` 每次枚举要跨进程取窗口列表，耗时取决于窗口数量。
//  在 `show()` 里同步等待会让面板晚出现，用户会以为热键没生效。
//  所以先显示「正在读取窗口…」的空态，后台枚举完成后替换成列表。
//

import AnShotCapture
import AppKit
import CoreGraphics

@MainActor
final class WindowPickerController: NSObject, NSWindowDelegate {

    /// 用户选中的窗口。
    ///
    /// `frame` 是全局左上原点**点**坐标，与 `SCWindow.frame` / `DetectedWindow.frame`
    /// 同一坐标系；调用方直接拿它做覆盖层定位或捕获范围，不需要再翻转 Y。
    struct Choice {
        var windowID: CGWindowID
        var appName: String
        var title: String
        var frame: CGRect
    }

    /// 用户确认选择。
    private let onChoose: (Choice) -> Void
    /// 用户取消（按钮、Esc 或关闭窗口）。
    private let onCancel: () -> Void

    /// 列表中的一行。
    private struct Row {
        let windowID: CGWindowID
        let appName: String
        /// 原样保留窗口标题；空标题的展示文案由视图层补，避免把占位符
        /// 当成真实标题传给调用方。
        let title: String
        let frame: CGRect

        func matches(_ query: String) -> Bool {
            let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
            return appName.range(of: query, options: options) != nil
                || title.range(of: query, options: options) != nil
        }
    }

    /// 面板当前处于哪种状态。列表为空时要区分「还在读」「没权限」
    /// 「读取失败」「真的没有窗口」——这四种情况的后续操作完全不同。
    private enum Phase {
        case loading
        case loaded
        case permissionDenied
        case failed(String)
    }

    private let panel: NSPanel
    private let searchField = NSSearchField()
    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private let countLabel = NSTextField(labelWithString: "")
    private let chooseButton = NSButton(title: "选择", target: nil, action: nil)
    private let cancelButton = NSButton(title: "取消", target: nil, action: nil)

    private let emptyStack = NSStackView()
    private let spinner = NSProgressIndicator()
    private let emptyTitleLabel = NSTextField(labelWithString: "")
    private let emptyDetailLabel = NSTextField(wrappingLabelWithString: "")
    private let openSettingsButton = NSButton(title: "打开系统设置", target: nil, action: nil)
    private let retryButton = NSButton(title: "重新读取", target: nil, action: nil)

    private var phase: Phase = .loading
    private var allWindows: [Row] = []
    private var visibleWindows: [Row] = []
    private var loadTask: Task<Void, Never>?

    /// 结束标记：选择和取消只能有一个生效。
    ///
    /// 关闭按钮与「取消」按钮走的是两条路径（`windowWillClose` / 按钮回调），
    /// 没有这个标记就会回调两次；对调用方而言，第二次「取消」可能把刚建立的
    /// 截图会话又拆掉。
    private var didFinish = false

    /// 调用方必须持有本控制器：`NSPanel.delegate` 是 weak 引用，
    /// 控制器被释放后面板的回调就再也不会到达。
    init(onChoose: @escaping (Choice) -> Void, onCancel: @escaping () -> Void) {
        self.onChoose = onChoose
        self.onCancel = onCancel
        panel = NSPanel(
            contentRect: CGRect(x: 0, y: 0, width: 560, height: 480),
            styleMask: [.titled, .closable, .nonactivatingPanel, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        super.init()
        configureWindow()
        panel.contentView = makeContentView()
    }

    /// 显示选择器。
    ///
    /// 重复调用不会再建一个面板：已经有窗口在屏幕上时，把它提到前面即可，
    /// 否则用户按两次热键会看到两个互相独立的列表。
    func show() {
        if panel.isVisible {
            panel.makeKeyAndOrderFront(nil)
            panel.makeFirstResponder(searchField)
            return
        }

        didFinish = false
        searchField.stringValue = ""
        allWindows = []
        visibleWindows = []
        tableView.reloadData()
        phase = .loading
        updateFooter()
        updateEmptyState()

        positionOnMouseScreen()
        // 只让面板成为 key，不调用 `NSApp.activate`：搜索框需要键盘输入，
        // 但用户原来的前台应用不应因为一次选择而失去焦点。
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(searchField)

        loadWindows()
    }

    // MARK: - 窗口配置

    private func configureWindow() {
        panel.title = "选择窗口"
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isRestorable = false
        panel.isMovableByWindowBackground = false
        panel.tabbingMode = .disallowed
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.delegate = self
        // 这个面板只有「选一个窗口」一个用途，最小化/缩放没有意义。
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
    }

    // MARK: - 视图

    private func makeContentView() -> NSView {
        let content = NSView(frame: CGRect(x: 0, y: 0, width: 560, height: 480))

        searchField.placeholderString = "搜索应用或窗口名称"
        searchField.delegate = self
        searchField.sendsWholeSearchString = false
        searchField.sendsSearchStringImmediately = true
        searchField.setAccessibilityLabel("搜索窗口")

        tableView.dataSource = self
        tableView.delegate = self
        tableView.rowHeight = 26
        tableView.intercellSpacing = NSSize(width: 6, height: 2)
        tableView.allowsMultipleSelection = false
        tableView.allowsEmptySelection = true
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.backgroundColor = .clear
        tableView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        tableView.target = self
        tableView.doubleAction = #selector(handleDoubleClick)
        tableView.setAccessibilityLabel("窗口列表")

        let appColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("app"))
        appColumn.title = "应用"
        appColumn.width = 170
        appColumn.minWidth = 120
        let titleColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("title"))
        titleColumn.title = "窗口"
        titleColumn.width = 340
        titleColumn.minWidth = 180
        tableView.addTableColumn(appColumn)
        tableView.addTableColumn(titleColumn)

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder

        countLabel.font = .systemFont(ofSize: 11)
        countLabel.textColor = .secondaryLabelColor

        chooseButton.bezelStyle = .rounded
        chooseButton.target = self
        chooseButton.action = #selector(chooseTapped)
        chooseButton.keyEquivalent = "\r"
        chooseButton.isEnabled = false

        cancelButton.bezelStyle = .rounded
        cancelButton.target = self
        cancelButton.action = #selector(cancelTapped)
        cancelButton.keyEquivalent = "\u{1b}"

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false

        emptyTitleLabel.font = .systemFont(ofSize: 13, weight: .medium)
        emptyTitleLabel.alignment = .center
        emptyDetailLabel.font = .systemFont(ofSize: 11)
        emptyDetailLabel.textColor = .secondaryLabelColor
        emptyDetailLabel.alignment = .center
        emptyDetailLabel.maximumNumberOfLines = 3
        // 面板宽度固定，直接给出换行宽度：否则 wrapping label 会按单行
        // 计算固有宽度，在 Auto Layout 下撑出可视区。
        emptyDetailLabel.preferredMaxLayoutWidth = 480

        openSettingsButton.bezelStyle = .rounded
        openSettingsButton.target = self
        openSettingsButton.action = #selector(openScreenRecordingSettings)
        retryButton.bezelStyle = .rounded
        retryButton.target = self
        retryButton.action = #selector(retryTapped)

        let emptyButtons = NSStackView(views: [openSettingsButton, retryButton])
        emptyButtons.orientation = .horizontal
        emptyButtons.spacing = 8

        emptyStack.orientation = .vertical
        emptyStack.alignment = .centerX
        emptyStack.spacing = 8
        for view in [spinner, emptyTitleLabel, emptyDetailLabel, emptyButtons] {
            emptyStack.addArrangedSubview(view)
        }

        let footer = NSView()
        let separator = NSBox()
        separator.boxType = .separator

        for view in [searchField, scrollView, emptyStack, footer] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        for view in [separator, countLabel, cancelButton, chooseButton] {
            view.translatesAutoresizingMaskIntoConstraints = false
            footer.addSubview(view)
        }

        NSLayoutConstraint.activate([
            searchField.topAnchor.constraint(equalTo: content.topAnchor, constant: 14),
            searchField.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),
            searchField.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -14),

            scrollView.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 10),
            scrollView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: footer.topAnchor),

            emptyStack.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            emptyStack.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
            emptyStack.leadingAnchor.constraint(
                greaterThanOrEqualTo: content.leadingAnchor, constant: 24
            ),
            emptyStack.trailingAnchor.constraint(
                lessThanOrEqualTo: content.trailingAnchor, constant: -24
            ),

            footer.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            footer.heightAnchor.constraint(equalToConstant: 48),

            separator.topAnchor.constraint(equalTo: footer.topAnchor),
            separator.leadingAnchor.constraint(equalTo: footer.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: footer.trailingAnchor),

            countLabel.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
            countLabel.leadingAnchor.constraint(equalTo: footer.leadingAnchor, constant: 16),

            chooseButton.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
            chooseButton.trailingAnchor.constraint(equalTo: footer.trailingAnchor, constant: -14),
            chooseButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 76),

            cancelButton.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
            cancelButton.trailingAnchor.constraint(equalTo: chooseButton.leadingAnchor, constant: -8),
            cancelButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 76),
        ])

        // 初始进入 loading，空态先显示出来，避免第一帧闪一片空白。
        updateEmptyState()
        return content
    }

    // MARK: - 载入

    private func loadWindows() {
        loadTask?.cancel()
        allWindows = []
        visibleWindows = []
        tableView.reloadData()
        phase = .loading
        applyFilter()

        // NSScreen 只能在主线程读；先把标识取出来，再进入异步枚举。
        let displayIDs = Self.currentDisplayIDs()

        loadTask = Task { [weak self] in
            guard let self, !Task.isCancelled else { return }

            // 先 preflight 而不是直接调用 ScreenCaptureKit：
            // 没有权限时 SCShareableContent 只会抛一个笼统的错误，用户看到的
            // 是「读取失败」；这里能明确告诉他是权限问题以及去哪儿开。
            // 刻意不调用 `CGRequestScreenCaptureAccess()`：那会弹系统对话框，
            // 在用户只是打开选择器、还没决定要不要授权时过于打扰。
            guard CGPreflightScreenCaptureAccess() else {
                self.phase = .permissionDenied
                self.applyFilter()
                return
            }

            guard !displayIDs.isEmpty else {
                self.phase = .failed("找不到可用的显示器")
                self.applyFilter()
                return
            }

            let detector = SystemElementDetector()
            var collected: [DetectedWindow] = []
            var seen = Set<CGWindowID>()
            var firstError: Error?

            for displayID in displayIDs {
                if Task.isCancelled { return }
                do {
                    let windows = try await detector.windows(onDisplay: displayID)
                    if Task.isCancelled { return }
                    // 跨屏窗口会在多个显示器上各出现一次，按 windowID 去重；
                    // 保留第一次出现的顺序，后续再统一排序。
                    for window in windows where seen.insert(window.windowID).inserted {
                        collected.append(window)
                    }
                } catch {
                    if firstError == nil {
                        firstError = error
                    }
                }
            }

            if Task.isCancelled { return }

            // 只要有一块屏幕枚举成功，就展示那部分结果；
            // 只有一块窗口都拿不到时才把错误抛给用户。
            if collected.isEmpty, let firstError {
                self.handle(loadFailure: firstError)
                return
            }
            self.apply(windows: collected)
        }
    }

    private func apply(windows: [DetectedWindow]) {
        guard !Task.isCancelled else { return }
        allWindows = windows.map { window in
            Row(
                windowID: window.windowID,
                appName: window.applicationName ?? "未知应用",
                title: window.title ?? "",
                frame: window.frame
            )
        }.sorted(by: Self.ascending)

        phase = .loaded
        applyFilter()
    }

    private func handle(loadFailure error: Error) {
        if let detection = error as? DetectionError {
            switch detection {
            case .shareableContentUnavailable:
                phase = .permissionDenied
            case .displayUnavailable:
                phase = .failed(detection.localizedDescription)
            }
        } else {
            phase = .failed(error.localizedDescription)
        }
        applyFilter()
    }

    private static func ascending(_ lhs: Row, _ rhs: Row) -> Bool {
        let appOrder = lhs.appName.localizedStandardCompare(rhs.appName)
        if appOrder != .orderedSame {
            return appOrder == .orderedAscending
        }
        let titleOrder = lhs.title.localizedStandardCompare(rhs.title)
        if titleOrder != .orderedSame {
            return titleOrder == .orderedAscending
        }
        return lhs.windowID < rhs.windowID
    }

    /// 当前所有显示器的 `CGDirectDisplayID`。
    ///
    /// AppKit 不直接暴露这个标识，只能从 `deviceDescription` 取；
    /// 取不到标识的屏幕跳过——没有它就无法调用 `windows(onDisplay:)`。
    private static func currentDisplayIDs() -> [CGDirectDisplayID] {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        return NSScreen.screens.compactMap { screen in
            (screen.deviceDescription[key] as? NSNumber).map {
                CGDirectDisplayID($0.uint32Value)
            }
        }
    }

    // MARK: - 过滤与状态

    private func applyFilter() {
        let previousID: CGWindowID? = {
            let index = tableView.selectedRow
            guard index >= 0, index < visibleWindows.count else { return nil }
            return visibleWindows[index].windowID
        }()

        let query = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if query.isEmpty {
            visibleWindows = allWindows
        } else {
            visibleWindows = allWindows.filter { $0.matches(query) }
        }

        tableView.reloadData()
        if let previousID,
           let index = visibleWindows.firstIndex(where: { $0.windowID == previousID }) {
            tableView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        } else if tableView.selectedRow >= 0 {
            tableView.deselectAll(nil)
        }

        updateFooter()
        updateEmptyState()
    }

    private func updateFooter() {
        let query = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)

        switch phase {
        case .loading:
            countLabel.stringValue = "正在读取…"
        case .permissionDenied, .failed:
            countLabel.stringValue = "无法读取"
        case .loaded:
            if allWindows.isEmpty {
                countLabel.stringValue = "共 0 个窗口"
            } else if query.isEmpty {
                countLabel.stringValue = "共 \(allWindows.count) 个窗口"
            } else {
                countLabel.stringValue = "匹配 \(visibleWindows.count) / \(allWindows.count) 个窗口"
            }
        }

        let hasSelection = tableView.selectedRow >= 0
            && tableView.selectedRow < visibleWindows.count
        chooseButton.isEnabled = hasSelection && isLoaded
    }

    private var isLoaded: Bool {
        if case .loaded = phase { return true }
        return false
    }

    private func updateEmptyState() {
        spinner.stopAnimation(nil)
        spinner.isHidden = true
        openSettingsButton.isHidden = true
        retryButton.isHidden = true

        var showsOverlay = true
        switch phase {
        case .loading:
            spinner.isHidden = false
            spinner.startAnimation(nil)
            emptyTitleLabel.stringValue = "正在读取窗口…"
            emptyDetailLabel.stringValue = "正在枚举屏幕上的窗口"

        case .permissionDenied:
            emptyTitleLabel.stringValue = "无法读取窗口列表"
            emptyDetailLabel.stringValue = """
                窗口枚举需要「屏幕录制」权限。请在系统设置中允许 anShot，\
                然后重新打开本面板（必要时重新启动 anShot）。
                """
            openSettingsButton.isHidden = false
            retryButton.isHidden = false

        case let .failed(message):
            emptyTitleLabel.stringValue = "无法读取窗口列表"
            emptyDetailLabel.stringValue = message
            retryButton.isHidden = false

        case .loaded:
            if allWindows.isEmpty {
                emptyTitleLabel.stringValue = "没有找到可选择的窗口"
                emptyDetailLabel.stringValue = "请先打开需要选择的窗口，或切换到对应的桌面再试。"
            } else if visibleWindows.isEmpty {
                emptyTitleLabel.stringValue = "没有匹配的窗口"
                emptyDetailLabel.stringValue = "换个关键词试试，或清空搜索框。"
            } else {
                showsOverlay = false
            }
        }

        scrollView.isHidden = showsOverlay
        emptyStack.isHidden = !showsOverlay
    }

    // MARK: - 定位

    private func positionOnMouseScreen() {
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: {
            NSMouseInRect(mouse, $0.frame, false)
        }) ?? NSScreen.main else {
            return
        }

        let visible = screen.visibleFrame
        let size = panel.frame.size
        panel.setFrameOrigin(CGPoint(
            x: (visible.midX - size.width / 2).rounded(),
            y: (visible.midY - size.height / 2).rounded()
        ))
    }

    // MARK: - 结束

    private func finish(with row: Row) {
        guard !didFinish else { return }
        didFinish = true
        loadTask?.cancel()
        panel.orderOut(nil)
        onChoose(Choice(
            windowID: row.windowID,
            appName: row.appName,
            title: row.title,
            frame: row.frame
        ))
    }

    private func finishCancel() {
        guard !didFinish else { return }
        didFinish = true
        loadTask?.cancel()
        panel.orderOut(nil)
        onCancel()
    }

    private func chooseSelectedOrFirst() {
        guard !visibleWindows.isEmpty else { return }
        let index = tableView.selectedRow >= 0
            && tableView.selectedRow < visibleWindows.count
            ? tableView.selectedRow
            : 0
        finish(with: visibleWindows[index])
    }

    @objc private func chooseTapped() {
        chooseSelectedOrFirst()
    }

    @objc private func cancelTapped() {
        finishCancel()
    }

    @objc private func retryTapped() {
        loadWindows()
    }

    @objc private func openScreenRecordingSettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
        ) else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    @objc private func handleDoubleClick() {
        let index = tableView.clickedRow
        guard index >= 0, index < visibleWindows.count else { return }
        finish(with: visibleWindows[index])
    }
}

// MARK: - NSWindowDelegate

extension WindowPickerController {
    func windowWillClose(_ notification: Notification) {
        guard let closed = notification.object as? NSPanel, closed === panel else { return }
        // 关闭按钮走的是这条路径；和「取消」共用同一个收尾，避免重复回调。
        finishCancel()
    }
}

// MARK: - 列表数据

extension WindowPickerController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        visibleWindows.count
    }

    func tableView(
        _ tableView: NSTableView,
        viewFor tableColumn: NSTableColumn?,
        row: Int
    ) -> NSView? {
        guard let tableColumn, row >= 0, row < visibleWindows.count else {
            return nil
        }

        let window = visibleWindows[row]
        let cell = reusableCell(identifier: tableColumn.identifier)
        if tableColumn.identifier.rawValue == "app" {
            cell.textField?.stringValue = window.appName
            cell.textField?.textColor = .labelColor
        } else {
            cell.textField?.stringValue = window.title.isEmpty ? "（无标题）" : window.title
            cell.textField?.textColor = .secondaryLabelColor
        }
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        updateFooter()
    }

    /// 复用或新建一个只有单行文字的单元格。
    ///
    /// 两个列各有自己的 identifier，因此字体/颜色不会在复用中串到另一列。
    private func reusableCell(identifier: NSUserInterfaceItemIdentifier) -> NSTableCellView {
        if let reused = tableView.makeView(withIdentifier: identifier, owner: self)
            as? NSTableCellView {
            return reused
        }

        let cell = NSTableCellView()
        cell.identifier = identifier
        let field = NSTextField(labelWithString: "")
        field.translatesAutoresizingMaskIntoConstraints = false
        field.font = .systemFont(ofSize: 12)
        field.lineBreakMode = .byTruncatingTail
        cell.addSubview(field)
        cell.textField = field
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
            field.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }
}

// MARK: - 搜索

extension WindowPickerController: NSSearchFieldDelegate {
    func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSSearchField, field === searchField else {
            return
        }
        applyFilter()
    }

    /// 在搜索框里按 ↓ 把焦点交给列表，按回车直接确认当前/第一条结果。
    ///
    /// 不实现这两个键的话，用户搜完必须伸手去拿鼠标：搜索框会吃掉方向键，
    /// 而默认按钮在搜索框有焦点时也不会响应回车。
    func control(
        _ control: NSControl,
        textView: NSTextView,
        doCommandBy commandSelector: Selector
    ) -> Bool {
        guard control === searchField else { return false }

        if commandSelector == #selector(NSResponder.moveDown(_:)) {
            guard !visibleWindows.isEmpty else { return true }
            panel.makeFirstResponder(tableView)
            let target = tableView.selectedRow >= 0 ? tableView.selectedRow : 0
            tableView.selectRowIndexes(IndexSet(integer: target), byExtendingSelection: false)
            tableView.scrollRowToVisible(target)
            return true
        }

        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            // 空搜索框、无选中时回车不做任何事：面板刚打开时按回车的意图
            // 通常是「确认搜索」，而不是「抓第一个窗口」。
            let hasSelection = tableView.selectedRow >= 0
                && tableView.selectedRow < visibleWindows.count
            let query = searchField.stringValue
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if hasSelection || !query.isEmpty {
                chooseSelectedOrFirst()
            }
            return true
        }

        return false
    }
}
