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
final class ScrollshotLogWindowController: NSObject {

    private let panel: NSPanel
    private let textView = NSTextView()
    private let scrollView = NSScrollView()
    private let summaryLabel = NSTextField(labelWithString: "")

    override init() {
        panel = NSPanel(
            contentRect: CGRect(x: 0, y: 0, width: 900, height: 540),
            styleMask: [.titled, .closable, .resizable, .nonactivatingPanel, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        super.init()

        panel.isReleasedWhenClosed = false
        panel.title = "长截图日志"
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary]
        panel.isMovableByWindowBackground = false
        panel.minSize = CGSize(width: 680, height: 320)
        panel.contentView = makeContentView()
    }

    var isVisible: Bool { panel.isVisible }

    /// 诊断用：当前显示的文本（含标题行）。
    var textForDiagnostics: String { textView.string }

    // MARK: - 显示

    func show() {
        refresh()
        repositionIfNeeded()
        panel.orderFrontRegardless()
    }

    func hide() {
        panel.orderOut(nil)
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
        let content = NSView(frame: CGRect(x: 0, y: 0, width: 900, height: 540))

        summaryLabel.font = .systemFont(ofSize: 11)
        summaryLabel.textColor = .secondaryLabelColor
        summaryLabel.frame = CGRect(x: 14, y: 508, width: 560, height: 18)
        summaryLabel.autoresizingMask = [.width, .minYMargin]
        content.addSubview(summaryLabel)

        let refreshButton = makeButton("刷新", #selector(refreshTapped))
        refreshButton.frame = CGRect(x: 588, y: 503, width: 68, height: 26)
        refreshButton.autoresizingMask = [.minXMargin, .minYMargin]
        content.addSubview(refreshButton)

        let copyButton = makeButton("复制全部", #selector(copyTapped))
        copyButton.frame = CGRect(x: 662, y: 503, width: 76, height: 26)
        copyButton.autoresizingMask = [.minXMargin, .minYMargin]
        content.addSubview(copyButton)

        let exportButton = makeButton("导出…", #selector(exportTapped))
        exportButton.frame = CGRect(x: 744, y: 503, width: 68, height: 26)
        exportButton.autoresizingMask = [.minXMargin, .minYMargin]
        content.addSubview(exportButton)

        let clearButton = makeButton("清空", #selector(clearTapped))
        clearButton.frame = CGRect(x: 818, y: 503, width: 68, height: 26)
        clearButton.autoresizingMask = [.minXMargin, .minYMargin]
        content.addSubview(clearButton)

        // 等宽 + 不换行（横向可滚）：列对齐是这张表能被快速扫读的前提。
        textView.isEditable = false
        textView.isSelectable = true
        textView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        textView.textColor = .textColor
        textView.drawsBackground = true
        textView.backgroundColor = NSColor.black.withAlphaComponent(0.35)
        textView.textContainerInset = NSSize(width: 10, height: 8)
        textView.isHorizontallyResizable = true
        textView.textContainer?.widthTracksTextView = false

        scrollView.frame = CGRect(x: 14, y: 14, width: 872, height: 482)
        scrollView.autoresizingMask = [.width, .height]
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.documentView = textView
        content.addSubview(scrollView)

        return content
    }

    private func makeButton(_ title: String, _ action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        button.controlSize = .small
        return button
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
        pasteboard.setString(textView.string, forType: .string)
    }

    @objc private func exportTapped() {
        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = [.plainText]
        savePanel.nameFieldStringValue = "anshot-scrollshot-log.txt"
        savePanel.canCreateDirectories = true
        savePanel.begin { [weak self] response in
            guard response == .OK, let url = savePanel.url, let self else { return }
            do {
                try self.textView.string.write(to: url, atomically: true, encoding: .utf8)
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
