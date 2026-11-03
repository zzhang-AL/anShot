//
//  OCRResultPanel.swift
//  AnShotUI
//
//  OCR 结果面板：显示识别出的文字，可选中、可复制。
//
//  ── 为什么是可选择的文本视图 ──────────────────────────────
//
//  用户识别文字的目的几乎总是「拿走一部分」：摘一句、抄一个编号、复制一段代码。
//  只给一个「全部复制」按钮会把最常见的用法变成两次操作（全选 → 自己删）。
//  所以主区域用 `NSTextView`，全选/部分选择/复制都用系统习惯。
//
//  ── 位置 ──────────────────────────────────────────────────
//
//  与进度浮层同理：它不能盖住选区（用户可能还要对着原文核对），
//  因此优先放在选区右侧，右侧不够再放左侧，最后退回下方。
//

import AnShotCore
import AppKit

/// 识别结果面板。
@MainActor
final class OCRResultPanel: NSObject, NSWindowDelegate {

    private let panel: NSPanel
    private let textView: NSTextView
    private let statusLabel: NSTextField
    private let copyButton = NSButton(title: "复制全部", target: nil, action: nil)
    private let translateButton = NSButton(title: "翻译", target: nil, action: nil)
    private let languagePopUp = NSPopUpButton(frame: .zero, pullsDown: false)

    /// 进行中／出错时的浮层，盖在文本区上。
    ///
    /// 存在的理由：面板在「还没结果」时如果是一片空白，用户看到的就是一个
    /// 空窗口——与「点了根本没反应」没有区别。识别在冷启动时要十几秒
    /// （见 `TextRecognizer.prewarm` 的实测），这段等待必须看得见。
    private let statusOverlay = NSView()
    private let progressIndicator = NSProgressIndicator()
    private let overlayLabel = NSTextField(labelWithString: "")

    /// 目标语言候选。源语言由本机检测得出，用户只选方向。
    private static let targetLanguages: [(title: String, identifier: String)] = [
        ("译成英文", "en-US"),
        ("译成中文", "zh-Hans"),
        ("译成日文", "ja-JP"),
    ]

    /// 用户点了「复制全部」。
    var onCopyAll: ((String) -> Void)?
    /// 用户点了「翻译」。参数是目标语言标识。
    var onTranslate: ((String) -> Void)?
    /// 用户在语言下拉里改了目标语言。
    var onTargetLanguageChanged: ((String) -> Void)?
    /// 面板关闭。
    var onClose: (() -> Void)?

    var isVisible: Bool { panel.isVisible }

    /// 面板当前显示的文字（诊断读取）。
    var text: String { textView.string }

    /// 是否正在显示「识别中」（诊断读取）。
    var isLoadingForDiagnostics: Bool {
        !statusOverlay.isHidden && progressIndicator.isHidden == false
    }

    private static let size = CGSize(width: 380, height: 260)

    /// 面板四周留白（文本区、状态文字、控件行共用同一套边距）。
    private static let margin: CGFloat = 12

    /// 文本区与浮层的背景色。深色浮层上白字的对比度才够。
    private static let textBackground = NSColor(white: 0.12, alpha: 1)

    override init() {
        panel = NSPanel(
            contentRect: CGRect(origin: .zero, size: Self.size),
            styleMask: [.titled, .closable, .nonactivatingPanel, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        panel.title = "识别的文字"
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.appearance = NSAppearance(named: .darkAqua)

        textView = NSTextView(frame: .zero)
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = true
        textView.backgroundColor = Self.textBackground
        textView.textColor = .white
        textView.font = .systemFont(ofSize: 12)
        textView.isRichText = false
        // ── 让文本容器真正「无限高」 ─────────────────────────────
        // 不设这几项，text container 的高度会被锁在视图高度上：文本一旦超过
        // 可视高度，绘制区域与滚动位置就对不上，表现为**第一行被吃掉**、
        // 而底部留一大块空白。
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(
            width: 0,
            height: CGFloat.greatestFiniteMagnitude
        )
        // 内边距：默认 0 时首行紧贴边框，看起来就像被裁掉了一截。
        textView.textContainerInset = NSSize(width: 2, height: 6)

        statusLabel = NSTextField(labelWithString: "")
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = NSColor.white.withAlphaComponent(0.6)
        statusLabel.lineBreakMode = .byTruncatingTail

        super.init()
        panel.delegate = self
        panel.isReleasedWhenClosed = false

        let content = NSView(frame: CGRect(origin: .zero, size: Self.size))

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = true
        scroll.backgroundColor = Self.textBackground
        scroll.documentView = textView
        // macOS 11+ 默认会根据标题栏/工具栏自动加 contentInsets；在无工具栏的
        // 浮层里它只会白占顶部空间，把第一行挤出可视区。
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
        scroll.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(scroll)

        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(statusLabel)

        // 浮层驾在文本区之上（同组视图里后加的在上层）。
        statusOverlay.wantsLayer = true
        statusOverlay.layer?.backgroundColor = Self.textBackground.cgColor
        statusOverlay.isHidden = true
        statusOverlay.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(statusOverlay)

        progressIndicator.style = .spinning
        progressIndicator.controlSize = .small
        progressIndicator.isIndeterminate = true
        progressIndicator.translatesAutoresizingMaskIntoConstraints = false
        statusOverlay.addSubview(progressIndicator)

        overlayLabel.alignment = .center
        overlayLabel.font = .systemFont(ofSize: 12)
        overlayLabel.textColor = NSColor.white.withAlphaComponent(0.78)
        // 必须能换行：失败信息往往很长（HTTP 状态码 + 服务端原文），
        // 截断会正好把最关键的原因切掉。
        overlayLabel.lineBreakMode = .byWordWrapping
        overlayLabel.maximumNumberOfLines = 0
        // 换行标签必须给出「换行后按多宽算」——否则它的固有尺寸按单行计，
        // 一条长错误信息会把整个窗口横向顶开（诊断里量到宽度从 380 变成 656）。
        overlayLabel.preferredMaxLayoutWidth = Self.size.width - Self.margin * 2 - 32
        // 宁可被约束压缩，也不允许用固有宽度去顶开父视图。
        overlayLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        overlayLabel.translatesAutoresizingMaskIntoConstraints = false
        statusOverlay.addSubview(overlayLabel)

        copyButton.bezelStyle = .rounded
        copyButton.controlSize = .small
        copyButton.target = self
        copyButton.action = #selector(handleCopy)
        copyButton.translatesAutoresizingMaskIntoConstraints = false

        translateButton.bezelStyle = .rounded
        translateButton.controlSize = .small
        translateButton.target = self
        translateButton.action = #selector(handleTranslate)
        translateButton.translatesAutoresizingMaskIntoConstraints = false

        languagePopUp.controlSize = .small
        languagePopUp.addItems(withTitles: Self.targetLanguages.map(\.title))
        languagePopUp.target = self
        languagePopUp.action = #selector(handleTargetLanguageChanged)
        languagePopUp.translatesAutoresizingMaskIntoConstraints = false

        let controlRow = NSView()
        controlRow.translatesAutoresizingMaskIntoConstraints = false
        for control in [languagePopUp, translateButton, copyButton] {
            controlRow.addSubview(control)
        }
        content.addSubview(controlRow)

        // ── 布局 ────────────────────────────────────────────
        // 三段竖向排列：控件行（底）、状态文字（中）、文本区（占满剩余）。
        // 状态文字**单独占一行**：它原本与控件行同层且宽 200，
        // 正好盖在下拉框（x 108…202）上面，两者必然重叠。
        NSLayoutConstraint.activate([
            controlRow.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: Self.margin),
            controlRow.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -Self.margin),
            controlRow.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -Self.margin),
            controlRow.heightAnchor.constraint(equalToConstant: 28),

            languagePopUp.leadingAnchor.constraint(equalTo: controlRow.leadingAnchor),
            languagePopUp.centerYAnchor.constraint(equalTo: controlRow.centerYAnchor),
            languagePopUp.widthAnchor.constraint(equalToConstant: 94),

            translateButton.leadingAnchor.constraint(equalTo: languagePopUp.trailingAnchor, constant: 8),
            translateButton.centerYAnchor.constraint(equalTo: controlRow.centerYAnchor),
            translateButton.widthAnchor.constraint(equalToConstant: 62),

            copyButton.trailingAnchor.constraint(equalTo: controlRow.trailingAnchor),
            copyButton.centerYAnchor.constraint(equalTo: controlRow.centerYAnchor),
            copyButton.widthAnchor.constraint(equalToConstant: 76),

            statusLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: Self.margin),
            statusLabel.trailingAnchor.constraint(
                lessThanOrEqualTo: content.trailingAnchor,
                constant: -Self.margin
            ),
            statusLabel.bottomAnchor.constraint(equalTo: controlRow.topAnchor, constant: -6),

            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: Self.margin),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -Self.margin),
            scroll.topAnchor.constraint(equalTo: content.topAnchor, constant: Self.margin),
            scroll.bottomAnchor.constraint(equalTo: statusLabel.topAnchor, constant: -6),

            statusOverlay.leadingAnchor.constraint(equalTo: scroll.leadingAnchor),
            statusOverlay.trailingAnchor.constraint(equalTo: scroll.trailingAnchor),
            statusOverlay.topAnchor.constraint(equalTo: scroll.topAnchor),
            statusOverlay.bottomAnchor.constraint(equalTo: scroll.bottomAnchor),

            // 文字垂直居中，转轮固定吊在它上方：加载时是「转轮 + 文字」，
            // 报错时（转轮隐藏）文字自然落回正中，不需要两套约束。
            overlayLabel.centerXAnchor.constraint(equalTo: statusOverlay.centerXAnchor),
            overlayLabel.centerYAnchor.constraint(equalTo: statusOverlay.centerYAnchor),
            overlayLabel.leadingAnchor.constraint(equalTo: statusOverlay.leadingAnchor, constant: 16),
            overlayLabel.trailingAnchor.constraint(equalTo: statusOverlay.trailingAnchor, constant: -16),

            progressIndicator.centerXAnchor.constraint(equalTo: statusOverlay.centerXAnchor),
            progressIndicator.bottomAnchor.constraint(equalTo: overlayLabel.topAnchor, constant: -12),
        ])

        panel.contentView = content
    }

    /// 识别中：立即把面板摆出来并显示进行中状态。
    ///
    /// 调用时机是**捕获之前**——它存在的全部意义就是让这段等待看得见，
    /// 等结果回来再显示就失去作用了。
    func showLoading(near selectionScreenRect: CGRect) {
        isTranslating = false
        textView.string = ""
        statusLabel.stringValue = ""
        setOverlay(message: "正在识别文字…", spinning: true)
        copyButton.isEnabled = false
        refreshTranslationControls(hasLines: false)
        present(near: selectionScreenRect)
    }

    /// 识别失败：面板留在原地换成错误说明。
    ///
    /// 不直接关掉面板：面板本身就是「这里刚刚发生了什么」的载体，
    /// 关掉之后用户只能看到一个消散的窗口，反而要自己猜是不是没点到。
    func showError(_ message: String, near selectionScreenRect: CGRect) {
        textView.string = ""
        statusLabel.stringValue = ""
        setOverlay(message: message, spinning: false)
        copyButton.isEnabled = false
        refreshTranslationControls(hasLines: false)
        present(near: selectionScreenRect)
    }

    /// 显示结果。
    func show(result: OCRResult, near selectionScreenRect: CGRect) {
        setOverlay(message: nil, spinning: false)
        let lines = result.lines
        setText(lines.map(\.text).joined(separator: "\n"))
        statusLabel.stringValue = Self.statusText(for: result)
        copyButton.isEnabled = !lines.isEmpty
        refreshTranslationControls(hasLines: !lines.isEmpty)
        present(near: selectionScreenRect)
    }

    /// 状态栏文案。
    ///
    /// 只报行数。曾在 `precise` 下追过「平均置信度」，但那个数字对使用者没有
    /// 决策价值：识别错了也不会因为看到 0.93 就知道该重做，反而暗示“分数高就是质量好”。
    private static func statusText(for result: OCRResult) -> String {
        let lines = result.lines
        guard !lines.isEmpty else { return "没有识别到文字" }
        return "\(lines.count) 行"
    }

    /// 把面板摆到不遮住选区的位置并显示。
    private func present(near selectionScreenRect: CGRect) {
        let screen = NSScreen.screens.first { $0.frame.intersects(selectionScreenRect) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let gap: CGFloat = 12

        // 优先右侧，其次左侧，最后下方——都不盖住选区。
        var x = selectionScreenRect.maxX + gap
        if x + Self.size.width > visible.maxX - gap {
            x = selectionScreenRect.minX - Self.size.width - gap
        }
        if x < visible.minX + gap {
            x = min(max(visible.minX + gap, selectionScreenRect.minX),
                    visible.maxX - Self.size.width - gap)
        }
        let y = min(
            max(visible.minY + gap, selectionScreenRect.maxY - Self.size.height),
            visible.maxY - Self.size.height - gap
        )
        panel.setFrame(CGRect(origin: CGPoint(x: x, y: y), size: Self.size), display: true)
        panel.orderFrontRegardless()
    }

    /// 设置文本并把视图滚回顶部。
    ///
    /// `NSTextView` 在 `string` 赋值后会跟着插入点滚到末尾。识别结果应该从
    /// 第一行开始读，而不是一打开就停在最后一行。
    private func setText(_ text: String) {
        textView.string = text
        textView.scrollRangeToVisible(NSRange(location: 0, length: 0))
    }

    /// 切换浮层状态（`message` 为 nil 表示隐藏）。
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

    /// 显示译文。
    ///
    /// 未翻译的行显示**原文**而不是留空：契约要求单行失败不影响整体，
    /// 界面上就该表现为「这段里夹着几句原文」，而不是凭空少了几行。
    func showTranslation(_ result: TranslationResult) {
        setText(result.segments.map(\.displayText).joined(separator: "\n"))
        if result.isEntirelyUntranslated {
            statusLabel.stringValue = "翻译不可用，已保留原文"
        } else if result.isPartiallyTranslated {
            statusLabel.stringValue = "已翻译 \(result.translatedCount)/\(result.segments.count) 行 · 未翻译的行保留原文"
        } else {
            statusLabel.stringValue = "已翻译 \(result.translatedCount) 行"
        }
        translateButton.isEnabled = true
    }

    /// 翻译没有发生时的**可见**反馈。
    ///
    /// 只 beep 是不够的：用户听到一声响却不知道原因，只会以为功能坏了。
    /// 原因必须落在面板上——那是唯一能让用户知道「下一步该做什么」的地方。
    func showTranslationUnavailable(_ availability: TranslationAvailability) {
        statusLabel.stringValue = availability.explanation
        applyTranslationAvailability(availability)
    }

    /// 翻译不可用时把入口置灰并说明原因。
    /// 最近一次的可用性，由调用方注入。
    ///
    /// 面板不自己判断：它不知道当前选的是本机还是云端 provider，
    /// 也不该去读设置——那是 `OverlayController` 的职责。
    private var translationAvailability: TranslationAvailability = .unknown
    private var isTranslating = false

    func applyTranslationAvailability(_ availability: TranslationAvailability) {
        translationAvailability = availability
        refreshTranslationControls(hasLines: !textView.string.isEmpty)
    }

    func setTranslating(_ translating: Bool) {
        isTranslating = translating
        if translating {
            statusLabel.stringValue = "正在翻译…"
        } else if statusLabel.stringValue == "正在翻译…" {
            statusLabel.stringValue = "翻译已取消，已保留当前文字"
        }
        refreshTranslationControls(hasLines: !textView.string.isEmpty)
    }

    func hide() {
        // 不在这里停下来的话，被隐藏的转圈动画会一直在后台跑。
        statusOverlay.isHidden = true
        progressIndicator.stopAnimation(nil)
        panel.orderOut(nil)
        onClose?()
    }

    func windowWillClose(_ notification: Notification) {
        hide()
    }

    /// 当前选中的目标语言。
    var selectedTargetLanguage: String {
        let index = languagePopUp.indexOfSelectedItem
        guard index >= 0, index < Self.targetLanguages.count else {
            return Self.targetLanguages[0].identifier
        }
        return Self.targetLanguages[index].identifier
    }

    // MARK: - 诊断

    var debugTranslateEnabledForDiagnostics: Bool { translateButton.isEnabled }
    var debugLanguagePopUpEnabledForDiagnostics: Bool { languagePopUp.isEnabled }
    var windowForDiagnostics: NSWindow { panel }

    private func refreshTranslationControls(hasLines: Bool) {
        // 用**外部注入**的可用性，不在这里重新判断：面板不知道当前选的是
        // 本机还是云端 provider，只有调用方知道。
        let availability = translationAvailability
        let enabled = availability.isAvailable && hasLines && !isTranslating
        translateButton.isEnabled = enabled
        // 某个语言方向不可用时，仍需让用户换一个方向。
        languagePopUp.isEnabled = hasLines
        translateButton.toolTip = availability.explanation
    }

    @objc private func handleTranslate() {
        onTranslate?(selectedTargetLanguage)
    }

    /// 换目标语言要**重新判定可用性**。
    ///
    /// 可用性是「源语言 → 目标语言」的函数：同一段原文，译成英文可能被判定为
    /// 「无需翻译」，译成中文却完全可用。不重算的话，用户会把目标语言改好，
    /// 然后对着一个仍然灰着的按钮——而那正是本次修复要消掉的现象。
    @objc private func handleTargetLanguageChanged() {
        onTargetLanguageChanged?(selectedTargetLanguage)
    }

    @objc private func handleCopy() {
        onCopyAll?(textView.string)
    }
}

/// 系统翻译的版本闸门。
///
/// 台阶是 **macOS 26.0** 而不是框架自身的 15.0：`TranslationSession` 唯一能在
/// 无 SwiftUI 视图环境里构造的初始化器标记为 26.0+（编译期实测）。
/// 把判断集中在这里，界面各处就不必各自写 `#available` 并逐渐写歪。
/// 打开结果面板时的翻译入口状态。
enum TranslationSupport {

    /// 粗判，只用来决定按钮**初始**是否可点。
    ///
    /// 刻意保持同步且不联网：打开面板的瞬间不该为了一件「可能根本不点」的事
    /// 去等一次异步查询。精确判定（语言对是否受支持、语言包装没装、密钥是不是
    /// 真的能用）留给用户真正按下按钮的那一刻——那时等待是合理的。
    static func availability(
        for strategy: TranslationStrategy,
        isCloudConfigured: Bool
    ) -> TranslationAvailability {
        switch strategy {
        case .automatic:
            // 云端就绪就直接可用；没配则兜底是本机，可用性完全取决于系统版本。
            if isCloudConfigured { return .available }
            return localGate()
        case .appleTranslation:
            return localGate()
        case .openAICompatible, .claude:
            guard let kind = strategy.explicitKind else { return .available }
            return isCloudConfigured ? .available : .notConfigured(provider: kind.displayName)
        }
    }

    /// 本机翻译的系统版本台阶。
    private static func localGate() -> TranslationAvailability {
        if #available(macOS 26.0, *) { return .available }
        return .requiresNewerSystem(
            required: TranslationProviderKind.appleTranslation.requiredSystemVersion ?? "macOS 26.0"
        )
    }
}
