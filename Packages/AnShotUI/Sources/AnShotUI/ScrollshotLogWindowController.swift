//
//  ScrollshotLogWindowController.swift
//  AnShotUI
//
//  「长截图日志」窗口：把 `ScrollshotLogStore` 里的最近记录摊开给用户看。
//
//  ── 它要解决的具体场景 ────────────────────────────────────
//
//  用户拼完一张长图，发现中间某处内容跳了一下/少了一截。这时会话已经结束，
//  控制台里也没有他要找的东西。他需要的是一句话能回答：
//  「刚才那一次，是哪一帧、因为什么被丢/被贴错」。
//
//  所以窗口只做三件事：把逐帧结论列出来、让用户能复制、能存成文件发给别人。
//  不做过滤/搜索——记录只有几百行，异常行用 `!` 标在行首，
//  加一层过滤反而挡住了「前后几帧是什么样」这个最关键的上下文。
//

import AnShotCore
import AppKit

@MainActor
final class ScrollshotLogWindowController: NSObject, NSWindowDelegate {

    private let panel: NSPanel
    private let textView = NSTextView()
    private let scrollView = NSScrollView()
    private let summaryLabel = NSTextField(labelWithString: "")

    override init() {
        panel = NSPanel(
            contentRect: CGRect(x: 0, y: 0, width: 900, height: 540),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        super.init()

        panel.isReleasedWhenClosed = false
        panel.title = "长截图日志"
        panel.backgroundColor = SettingsTheme.windowBackground
        panel.hidesOnDeactivate = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary]
        panel.isMovableByWindowBackground = false
        panel.minSize = CGSize(width: 680, height: 320)
        panel.delegate = self
        panel.contentView = makeContentView()
    }

    var isVisible: Bool { panel.isVisible }

    /// 诊断用：当前显示的文本（含标题行）。
    var textForDiagnostics: String { textView.string }

    // MARK: - 显示

    func show() {
        ForegroundPolicyCoordinator.acquire("scrollshotLog")
        refresh()
        repositionIfNeeded()
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    func hide() {
        panel.orderOut(nil)
        ForegroundPolicyCoordinator.release("scrollshotLog")
    }

    func windowWillClose(_ notification: Notification) {
        ForegroundPolicyCoordinator.release("scrollshotLog")
    }

    /// 重新读一次 store。窗口未打开时也刷新（打开时立刻是最新内容）。
    func refresh() {
        let store = ScrollshotLogStore.shared
        let entries = store.entries
        let sessions = Set(entries.map(\.session)).count
        let problems = entries.filter(\.isProblem).count

        if entries.isEmpty {
            summaryLabel.stringValue = "暂无记录 —— 做一次长截图后回来查看"
        } else {
            summaryLabel.stringValue = String(
                format: "最近 %d 条 · %d 次会话 · %d 条异常（行首 ! 标记）",
                entries.count, sessions, problems
            )
        }

        textView.string = store.formattedText()
        // 默认滚到**最新**的一行：用户关心的是「刚才发生了什么」。
        textView.scrollToEndOfDocument(nil)
    }

    // MARK: - 内容

    private func makeContentView() -> NSView {
        let content = ScrollshotLogBackgroundView(frame: CGRect(x: 0, y: 0, width: 900, height: 540))
        content.autoresizingMask = [.width, .height]

        summaryLabel.font = .systemFont(ofSize: 11)
        summaryLabel.textColor = .secondaryLabelColor
        summaryLabel.lineBreakMode = .byTruncatingTail
        summaryLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let refreshButton = SettingsPushButton(title: "刷新", emphasis: .primary, target: self, action: #selector(refreshTapped))
        let copyButton = SettingsPushButton(title: "复制全部", target: self, action: #selector(copyTapped))
        let exportButton = SettingsPushButton(title: "导出…", target: self, action: #selector(exportTapped))
        let clearButton = SettingsPushButton(title: "清空", target: self, action: #selector(clearTapped))

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        spacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let toolbar = NSStackView(views: [summaryLabel, spacer, refreshButton, copyButton, exportButton, clearButton])
        toolbar.orientation = .horizontal
        toolbar.alignment = .centerY
        toolbar.spacing = 8
        toolbar.translatesAutoresizingMaskIntoConstraints = false

        // 等宽 + 不换行（横向可滚）：在自适应亮暗卡片表面内呈现日志表格。
        textView.isEditable = false
        textView.isSelectable = true
        textView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        textView.textColor = .labelColor
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 12, height: 10)
        textView.frame = NSRect(x: 0, y: 0, width: 840, height: 460)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = true
        textView.textContainer?.containerSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.textContainer?.widthTracksTextView = false

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.documentView = textView

        let card = HistorySurfaceView(style: .card)
        card.addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: card.topAnchor, constant: 6),
            scrollView.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 6),
            scrollView.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -6),
            scrollView.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -6),
        ])

        content.addSubview(toolbar)
        content.addSubview(card)

        let margin = SettingsTheme.margin
        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            toolbar.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: margin),
            toolbar.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -margin),

            card.topAnchor.constraint(equalTo: toolbar.bottomAnchor, constant: 12),
            card.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: margin),
            card.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -margin),
            card.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -margin),
        ])

        return content
    }

    /// 首次显示时放到主屏中上部：菜单栏展开后用户的视线在屏幕上方，
    /// 窗口出现在中部比居中更贴近「刚点完菜单」的视线落点。
    private func repositionIfNeeded() {
        guard !panel.isVisible, let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        let origin = CGPoint(
            x: visible.midX - panel.frame.width / 2,
            y: visible.midY - panel.frame.height / 2 + visible.height * 0.08
        )
        panel.setFrameOrigin(origin)
    }

    // MARK: - 动作

    @objc private func refreshTapped() {
        refresh()
    }

    @objc private func copyTapped() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let ok = pasteboard.setString(textView.string, forType: .string)
        ToastPresenter.show(ok ? "已复制长截图日志" : "复制失败")
    }

    @objc private func exportTapped() {
        // 菜单栏应用在导出模态面板前必须显式激活，防止面板被其他窗口遮挡。
        NSApp.activate(ignoringOtherApps: true)
        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = [.plainText]
        savePanel.nameFieldStringValue = "anshot-scrollshot-log.txt"
        savePanel.canCreateDirectories = true
        savePanel.begin { [weak self] response in
            guard response == .OK, let url = savePanel.url, let self else { return }
            do {
                try self.textView.string.write(to: url, atomically: true, encoding: .utf8)
                ToastPresenter.show("已导出长截图日志")
            } catch {
                let alert = NSAlert()
                alert.messageText = "导出失败"
                alert.informativeText = error.localizedDescription
                alert.alertStyle = .warning
                alert.runModal()
            }
        }
    }

    @objc private func clearTapped() {
        ScrollshotLogStore.shared.clear()
        refresh()
    }
}

/// 长截图日志窗口自适应背景视图。
private final class ScrollshotLogBackgroundView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
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
