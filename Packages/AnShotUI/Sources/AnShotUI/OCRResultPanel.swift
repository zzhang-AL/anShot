//
//  OCRResultPanel.swift
//  AnShotUI
//
//  独立的 OCR 与翻译悬浮面板：
//    - 脱离截图覆盖层生命周期，支持缩放（≥ 400×300）、跟随系统浅/深主题、置顶切换；
//    - 顶部集成 OCR 语言即时切换、无损段落软换行合并与二维码/条码结果卡片；
//    - 原文区支持直接编辑与 `⌘Enter` 重译、`⇧⌘C` 智能复制、`Esc`/`⌘W` 关闭；
//    - 支持自动/手动源语言与 7 语种目标语言持久化记忆。
//

import AnShotCore
import AppKit

/// 支持 `Esc`/`⌘W`/`⌘Enter`/`⇧⌘C` 快捷键的独立悬浮面板。
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
        // ⌘Enter 立即重译当前文本
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

/// 跟随系统明暗语义色动态刷新的纯色背景视图。
private final class OCRDynamicSurfaceView: NSView {
    private let colorProvider: () -> NSColor
    private let cornerRadius: CGFloat
    private let borderColorProvider: (() -> NSColor)?

    init(
        cornerRadius: CGFloat = 0,
        borderColor: (() -> NSColor)? = nil,
        backgroundColor: @escaping () -> NSColor
    ) {
        self.cornerRadius = cornerRadius
        self.borderColorProvider = borderColor
        self.colorProvider = backgroundColor
        super.init(frame: .zero)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("不支持从 nib 构造")
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = colorProvider().cgColor
        layer?.cornerRadius = cornerRadius
        if let borderColorProvider {
            layer?.borderWidth = 1
            layer?.borderColor = borderColorProvider().cgColor
        } else {
            layer?.borderWidth = 0
            layer?.borderColor = nil
        }
    }
}

/// 独立的 OCR 识别与翻译浮窗。
@MainActor
final class OCRResultPanel: NSObject, NSWindowDelegate, NSTextViewDelegate {

    /// 文本展示模式。
    enum DisplayMode: Int, CaseIterable {
        case original = 0
        case translation = 1
        case bilingual = 2
    }

    private let panel: OCRFloatingPanel
    private let textView: NSTextView
    private let statusLabel: NSTextField

    // 顶部工具条控件
    private let ocrLanguageLabel = NSTextField(labelWithString: "识别语言")
    private let ocrLanguagePopUp = NSPopUpButton(frame: .zero, pullsDown: false)
    private let mergeLineBreaksButton = NSButton(checkboxWithTitle: "合并换行", target: nil, action: nil)
    private let pinOnTopButton = NSButton(frame: .zero)

    // 二维码 / 条码卡片容器
    private let barcodeStackView = NSStackView()
    private var displayedBarcodes: [BarcodeItem] = []

    // 中下部展示模式与翻译控制
    private let modeControl = NSSegmentedControl(
        labels: ["原文", "译文", "双语"],
        trackingMode: .selectOne,
        target: nil,
        action: nil
    )
    private let sourceLanguagePopUp = NSPopUpButton(frame: .zero, pullsDown: false)
    private let arrowLabel = NSTextField(labelWithString: "→")
    private let languagePopUp = NSPopUpButton(frame: .zero, pullsDown: false)
    private let translateButton = NSButton(title: "翻译", target: nil, action: nil)
    private let copyButton = NSButton(title: "复制全部", target: nil, action: nil)

    /// 最近一次完整 OCR 结果（用于无损切换逐行 / 合并换行与保留行结构）。
    private var lastOCRResult: OCRResult?
    /// 纯文本划词输入或原始逐行文本。
    private var rawOriginalText = ""
    /// 用户手工修订后的原文；未编辑时为 `nil`。
    private var editedOriginalText: String?
    private var translationResult: TranslationResult?
    private var displayMode: DisplayMode = .original
    /// 是否正在以代码更新 `textView.string`，避免把程序写入误记为用户编辑。
    private var isProgrammaticallyUpdatingText = false
    /// 是否处于纯文本模式（如 `⌥D` 划词翻译），纯文本模式隐藏 OCR 识别语言下拉。
    private var isTextOnlyMode = false

    /// 浮窗是否置顶（默认开启 `.floating`，点击右上角图钉可降为 `.normal`）。
    private(set) var isAlwaysOnTop = true

    /// 进行中 / 出错时的遮罩浮层。
    private let statusOverlay = OCRDynamicSurfaceView(cornerRadius: 6) { .textBackgroundColor }
    private let progressIndicator = NSProgressIndicator()
    private let overlayLabel = NSTextField(labelWithString: "")

    /// 源语言候选（自动检测 + 7 语种）。
    private static var sourceLanguages: [(id: String?, name: String)] {
        TranslationLanguage.commonSourceLanguages
    }

    /// 目标语言候选（7 语种）。
    private static var targetLanguages: [(id: String, name: String)] {
        TranslationLanguage.commonTargetLanguages
    }

    /// 用户点击「复制全部」或触发 `⇧⌘C`。
    var onCopyAll: ((String) -> Void)?
    /// 用户点击「翻译」或按 `⌘Enter`。参数为（源语言可选、目标语言）。
    var onTranslate: ((String?, String) -> Void)?
    /// 用户切换目标语言或源语言。
    var onTargetLanguageChanged: ((String?, String) -> Void)?
    /// 用户在浮窗内切换 OCR 识别语言（由控制器按缓存源图即时重识别）。
    var onOCRLanguageChanged: ((OCRLanguagePreference) -> Void)?
    /// 用户切换「合并换行」状态。
    var onMergeLineBreaksChanged: ((Bool) -> Void)?
    /// 面板关闭。
    var onClose: (() -> Void)?

    var isVisible: Bool { panel.isVisible }

    /// 面板当前显示的文字（诊断与测试读取）。
    var text: String { textView.string }

    /// 当前是否开启「合并换行」。
    var isMergeLineBreaksEnabled: Bool { mergeLineBreaksButton.state == .on }

    /// 当前识别到的二维码/条码列表（供测试与外部校验）。
    var currentBarcodes: [BarcodeItem] { displayedBarcodes }

    /// 是否正在显示「识别中」（诊断读取）。
    var isLoadingForDiagnostics: Bool {
        !statusOverlay.isHidden && !progressIndicator.isHidden
    }

    /// 默认初始窗口尺寸与最小可缩放尺寸。
    static let defaultSize = CGSize(width: 460, height: 340)
    static let minimumSize = CGSize(width: 400, height: 300)
    private static let margin: CGFloat = 12

    override init() {
        panel = OCRFloatingPanel(
            contentRect: CGRect(origin: .zero, size: Self.defaultSize),
            styleMask: [.titled, .closable, .resizable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        panel.title = "识别与翻译"
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.minSize = Self.minimumSize
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        textView = NSTextView(frame: .zero)
        textView.isEditable = true
        textView.isSelectable = true
        textView.drawsBackground = true
        textView.backgroundColor = .textBackgroundColor
        textView.textColor = .labelColor
        textView.insertionPointColor = .controlAccentColor
        textView.font = .systemFont(ofSize: 13)
        textView.isRichText = false
        textView.allowsUndo = true
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
        textView.textContainerInset = NSSize(width: 6, height: 8)

        statusLabel = NSTextField(labelWithString: "")
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail

        super.init()
        panel.delegate = self
        panel.isReleasedWhenClosed = false
        textView.delegate = self

        panel.onCloseShortcut = { [weak self] in self?.hide() }
        panel.onRetranslateShortcut = { [weak self] in self?.triggerRetranslateShortcut() }
        panel.onSmartCopyShortcut = { [weak self] in self?.triggerSmartCopy() }

        buildContentView()
    }

    private func buildContentView() {
        let content = NSView(frame: CGRect(origin: .zero, size: Self.defaultSize))

        // ── 顶部工具条：OCR 语言 + 合并换行 + 置顶切换 ─────────
        ocrLanguageLabel.font = .systemFont(ofSize: 11)
        ocrLanguageLabel.textColor = .secondaryLabelColor
        ocrLanguageLabel.translatesAutoresizingMaskIntoConstraints = false

        ocrLanguagePopUp.controlSize = .small
        ocrLanguagePopUp.addItems(withTitles: OCRLanguagePreference.allCases.map(\.displayName))
        ocrLanguagePopUp.target = self
        ocrLanguagePopUp.action = #selector(handleOCRLanguageChanged)
        ocrLanguagePopUp.translatesAutoresizingMaskIntoConstraints = false

        mergeLineBreaksButton.controlSize = .small
        mergeLineBreaksButton.font = .systemFont(ofSize: 11)
        mergeLineBreaksButton.target = self
        mergeLineBreaksButton.action = #selector(handleMergeLineBreaksToggled)
        mergeLineBreaksButton.toolTip = "无损合并段内软换行（再点恢复逐行）"
        mergeLineBreaksButton.translatesAutoresizingMaskIntoConstraints = false

        pinOnTopButton.bezelStyle = .recessed
        pinOnTopButton.isBordered = true
        pinOnTopButton.controlSize = .small
        pinOnTopButton.target = self
        pinOnTopButton.action = #selector(handleToggleAlwaysOnTop)
        pinOnTopButton.translatesAutoresizingMaskIntoConstraints = false
        refreshPinOnTopButton()

        let topSpacer = NSView()
        topSpacer.translatesAutoresizingMaskIntoConstraints = false
        topSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let topBar = NSStackView(views: [
            ocrLanguageLabel,
            ocrLanguagePopUp,
            mergeLineBreaksButton,
            topSpacer,
            pinOnTopButton,
        ])
        topBar.orientation = .horizontal
        topBar.alignment = .centerY
        topBar.spacing = 8
        topBar.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(topBar)

        // ── 二维码 / 条码卡片栈（有码时自动展开） ─────────────
        barcodeStackView.orientation = .vertical
        barcodeStackView.alignment = .leading
        barcodeStackView.spacing = 6
        barcodeStackView.isHidden = true
        barcodeStackView.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(barcodeStackView)

        // ── 正文文本滚动容器 ─────────────────────────────────
        let scrollContainer = OCRDynamicSurfaceView(
            cornerRadius: 6,
            borderColor: { .separatorColor },
            backgroundColor: { .textBackgroundColor }
        )
        scrollContainer.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(scrollContainer)

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.documentView = textView
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsetsZero
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scrollContainer.addSubview(scroll)

        // 状态遮罩浮层覆盖在文本区之上
        statusOverlay.isHidden = true
        statusOverlay.translatesAutoresizingMaskIntoConstraints = false
        scrollContainer.addSubview(statusOverlay)

        progressIndicator.style = .spinning
        progressIndicator.controlSize = .small
        progressIndicator.isIndeterminate = true
        progressIndicator.translatesAutoresizingMaskIntoConstraints = false
        statusOverlay.addSubview(progressIndicator)

        overlayLabel.alignment = .center
        overlayLabel.font = .systemFont(ofSize: 12)
        overlayLabel.textColor = .secondaryLabelColor
        overlayLabel.lineBreakMode = .byWordWrapping
        overlayLabel.maximumNumberOfLines = 0
        overlayLabel.preferredMaxLayoutWidth = Self.minimumSize.width - Self.margin * 2 - 32
        overlayLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        overlayLabel.translatesAutoresizingMaskIntoConstraints = false
        statusOverlay.addSubview(overlayLabel)

        // ── 状态栏 + 原文/译文/双语模式切换 ───────────────────
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        modeControl.controlSize = .mini
        modeControl.selectedSegment = DisplayMode.original.rawValue
        modeControl.setEnabled(false, forSegment: DisplayMode.translation.rawValue)
        modeControl.setEnabled(false, forSegment: DisplayMode.bilingual.rawValue)
        modeControl.target = self
        modeControl.action = #selector(handleDisplayModeChanged(_:))
        modeControl.translatesAutoresizingMaskIntoConstraints = false

        let statusSpacer = NSView()
        statusSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let statusRow = NSStackView(views: [statusLabel, statusSpacer, modeControl])
        statusRow.orientation = .horizontal
        statusRow.alignment = .centerY
        statusRow.spacing = 8
        statusRow.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(statusRow)

        // ── 底部翻译与复制控制行 ─────────────────────────────
        sourceLanguagePopUp.controlSize = .small
        sourceLanguagePopUp.addItems(withTitles: Self.sourceLanguages.map(\.name))
        sourceLanguagePopUp.target = self
        sourceLanguagePopUp.action = #selector(handleTranslationLanguageChanged)
        sourceLanguagePopUp.toolTip = "源语言（默认自动检测）"
        sourceLanguagePopUp.translatesAutoresizingMaskIntoConstraints = false

        arrowLabel.font = .systemFont(ofSize: 11, weight: .medium)
        arrowLabel.textColor = .secondaryLabelColor
        arrowLabel.translatesAutoresizingMaskIntoConstraints = false

        languagePopUp.controlSize = .small
        languagePopUp.addItems(withTitles: Self.targetLanguages.map(\.name))
        languagePopUp.target = self
        languagePopUp.action = #selector(handleTranslationLanguageChanged)
        languagePopUp.toolTip = "目标语言"
        languagePopUp.translatesAutoresizingMaskIntoConstraints = false

        translateButton.bezelStyle = .rounded
        translateButton.controlSize = .small
        translateButton.keyEquivalent = ""
        translateButton.target = self
        translateButton.action = #selector(handleTranslate)
        translateButton.toolTip = "翻译当前文本（⌘↩）"
        translateButton.translatesAutoresizingMaskIntoConstraints = false

        copyButton.bezelStyle = .rounded
        copyButton.controlSize = .small
        copyButton.target = self
        copyButton.action = #selector(handleCopy)
        copyButton.toolTip = "复制当前展示文本（⇧⌘C 智能复制译文优先）"
        copyButton.translatesAutoresizingMaskIntoConstraints = false

        let bottomSpacer = NSView()
        bottomSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let controlRow = NSStackView(views: [
            sourceLanguagePopUp,
            arrowLabel,
            languagePopUp,
            bottomSpacer,
            translateButton,
            copyButton,
        ])
        controlRow.orientation = .horizontal
        controlRow.alignment = .centerY
        controlRow.spacing = 6
        controlRow.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(controlRow)

        // 主纵栈：顶部工具条 → 二维码卡片（隐藏时自动折叠不占位） → 正文区 → 状态栏 → 控制行
        let mainStack = NSStackView(views: [
            topBar,
            barcodeStackView,
            scrollContainer,
            statusRow,
            controlRow,
        ])
        mainStack.orientation = .vertical
        mainStack.alignment = .leading
        mainStack.spacing = 8
        mainStack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(mainStack)

        scrollContainer.setContentHuggingPriority(.defaultLow, for: .vertical)
        scrollContainer.setContentCompressionResistancePriority(.defaultLow, for: .vertical)

        NSLayoutConstraint.activate([
            mainStack.topAnchor.constraint(equalTo: content.topAnchor, constant: Self.margin),
            mainStack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: Self.margin),
            mainStack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -Self.margin),
            mainStack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -Self.margin),

            topBar.widthAnchor.constraint(equalTo: mainStack.widthAnchor),
            barcodeStackView.widthAnchor.constraint(equalTo: mainStack.widthAnchor),
            scrollContainer.widthAnchor.constraint(equalTo: mainStack.widthAnchor),
            scrollContainer.heightAnchor.constraint(greaterThanOrEqualToConstant: 120),
            statusRow.widthAnchor.constraint(equalTo: mainStack.widthAnchor),
            controlRow.widthAnchor.constraint(equalTo: mainStack.widthAnchor),

            ocrLanguagePopUp.widthAnchor.constraint(greaterThanOrEqualToConstant: 88),
            pinOnTopButton.widthAnchor.constraint(equalToConstant: 26),
            pinOnTopButton.heightAnchor.constraint(equalToConstant: 22),

            sourceLanguagePopUp.widthAnchor.constraint(lessThanOrEqualToConstant: 96),
            languagePopUp.widthAnchor.constraint(lessThanOrEqualToConstant: 96),
            translateButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 56),
            copyButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 74),

            scroll.leadingAnchor.constraint(equalTo: scrollContainer.leadingAnchor, constant: 1),
            scroll.trailingAnchor.constraint(equalTo: scrollContainer.trailingAnchor, constant: -1),
            scroll.topAnchor.constraint(equalTo: scrollContainer.topAnchor, constant: 1),
            scroll.bottomAnchor.constraint(equalTo: scrollContainer.bottomAnchor, constant: -1),

            statusOverlay.leadingAnchor.constraint(equalTo: scrollContainer.leadingAnchor, constant: 1),
            statusOverlay.trailingAnchor.constraint(equalTo: scrollContainer.trailingAnchor, constant: -1),
            statusOverlay.topAnchor.constraint(equalTo: scrollContainer.topAnchor, constant: 1),
            statusOverlay.bottomAnchor.constraint(equalTo: scrollContainer.bottomAnchor, constant: -1),

            overlayLabel.centerXAnchor.constraint(equalTo: statusOverlay.centerXAnchor),
            overlayLabel.centerYAnchor.constraint(equalTo: statusOverlay.centerYAnchor),
            overlayLabel.leadingAnchor.constraint(equalTo: statusOverlay.leadingAnchor, constant: 16),
            overlayLabel.trailingAnchor.constraint(equalTo: statusOverlay.trailingAnchor, constant: -16),

            progressIndicator.centerXAnchor.constraint(equalTo: statusOverlay.centerXAnchor),
            progressIndicator.bottomAnchor.constraint(equalTo: overlayLabel.topAnchor, constant: -12),
        ])

        panel.contentView = content
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
        mergeLineBreaksButton.state = mergeLineBreaks ? .on : .off
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
        let symbol = isAlwaysOnTop ? "pin.fill" : "pin"
        let tip = isAlwaysOnTop ? "已置顶（点击取消置顶）" : "未置顶（点击置顶）"
        pinOnTopButton.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)
        pinOnTopButton.imagePosition = .imageOnly
        pinOnTopButton.state = isAlwaysOnTop ? .on : .off
        pinOnTopButton.toolTip = tip
        pinOnTopButton.contentTintColor = isAlwaysOnTop ? .controlAccentColor : .secondaryLabelColor
    }

    private func setTextOnlyMode(_ textOnly: Bool) {
        isTextOnlyMode = textOnly
        ocrLanguageLabel.isHidden = textOnly
        ocrLanguagePopUp.isHidden = textOnly
        panel.title = textOnly ? "划词翻译" : "识别与翻译"
    }

    // MARK: - 展示入口

    /// 识别中：立即弹出独立浮窗并展示加载状态。
    func showLoading(near selectionScreenRect: CGRect, message: String = "正在识别文字…") {
        setTextOnlyMode(false)
        isTranslating = false
        lastOCRResult = nil
        rawOriginalText = ""
        editedOriginalText = nil
        translationResult = nil
        updateBarcodeCards([])
        resetDisplayModeControl()
        setText("")
        statusLabel.stringValue = ""
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
        updateBarcodeCards([])
        resetDisplayModeControl()
        setText("")
        statusLabel.stringValue = ""
        setOverlay(message: message, spinning: false)
        copyButton.isEnabled = false
        refreshTranslationControls(hasLines: false)
        present(near: selectionScreenRect)
    }

    /// 展示完整 OCR 识别结果（含二维码/条码卡片与可编辑文本）。
    func show(result: OCRResult, near selectionScreenRect: CGRect) {
        setTextOnlyMode(false)
        setOverlay(message: nil, spinning: false)
        lastOCRResult = result
        rawOriginalText = result.plainText
        editedOriginalText = nil
        translationResult = nil
        updateBarcodeCards(result.barcodes)
        resetDisplayModeControl()
        refreshDisplayedText()
        statusLabel.stringValue = Self.statusText(for: result)
        let hasText = !currentEditableOriginalText.isEmpty
        copyButton.isEnabled = hasText
        refreshTranslationControls(hasLines: hasText)
        present(near: selectionScreenRect)
    }

    /// 展示纯文本划词输入（例如 `⌥D` 划词翻译），预填原文并准备翻译。
    func showSourceText(_ text: String, near anchorScreenRect: CGRect) {
        setTextOnlyMode(true)
        setOverlay(message: nil, spinning: false)
        lastOCRResult = nil
        rawOriginalText = text
        editedOriginalText = nil
        translationResult = nil
        updateBarcodeCards([])
        resetDisplayModeControl()
        refreshDisplayedText()
        let lineCount = text.components(separatedBy: .newlines).filter { !$0.isEmpty }.count
        statusLabel.stringValue = lineCount > 0 ? "已选取 \(lineCount) 行 · 可编辑后按 ⌘↩ 重译" : ""
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
        // 未编辑且未合并换行且持有原始 OCRResult：原样沿用保留包围盒信息。
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
        mergeLineBreaksButton.state = enabled ? .on : .off
        // 若用户未手动改动文本，切换时立刻无损重排展示。
        if editedOriginalText == nil, displayMode == .original {
            refreshDisplayedText()
        }
        if notify {
            onMergeLineBreaksChanged?(enabled)
        }
    }

    /// 智能复制文本：译文存在时优先返回译文，否则返回当前展示文本。
    var smartCopyText: String {
        if let result = translationResult, !result.isEntirelyUntranslated {
            return result.segments.map(\.displayText).joined(separator: "\n")
        }
        return textView.string
    }

    private static func statusText(for result: OCRResult) -> String {
        let lineCount = result.lines.count
        let codeCount = result.barcodes.count
        if lineCount == 0 && codeCount == 0 {
            return "未识别到文字或二维码"
        }
        var parts: [String] = []
        if lineCount > 0 { parts.append("\(lineCount) 行文字") }
        if codeCount > 0 { parts.append("\(codeCount) 个二维码/条码") }
        return parts.joined(separator: " · ")
    }

    // MARK: - 二维码 / 条码卡片

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
        let card = OCRDynamicSurfaceView(
            cornerRadius: 6,
            borderColor: { .separatorColor },
            backgroundColor: { .controlBackgroundColor }
        )
        card.translatesAutoresizingMaskIntoConstraints = false

        let badge = NSTextField(labelWithString: Self.symbologyDisplayName(item.symbology))
        badge.font = .systemFont(ofSize: 10, weight: .semibold)
        badge.textColor = .controlAccentColor
        badge.setContentHuggingPriority(.required, for: .horizontal)
        badge.setContentCompressionResistancePriority(.required, for: .horizontal)

        let payloadLabel = NSTextField(labelWithString: item.payload)
        payloadLabel.font = .systemFont(ofSize: 12)
        payloadLabel.textColor = .labelColor
        payloadLabel.lineBreakMode = .byTruncatingMiddle
        payloadLabel.toolTip = item.payload
        payloadLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        payloadLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let copyBtn = NSButton(title: "复制", target: self, action: #selector(handleCopyBarcode(_:)))
        copyBtn.bezelStyle = .rounded
        copyBtn.controlSize = .mini
        copyBtn.tag = index

        var views: [NSView] = [badge, payloadLabel, copyBtn]
        if item.isWebURL {
            let openBtn = NSButton(title: "打开链接", target: self, action: #selector(handleOpenBarcodeURL(_:)))
            openBtn.bezelStyle = .rounded
            openBtn.controlSize = .mini
            openBtn.tag = index
            views.append(openBtn)
        }

        let row = NSStackView(views: views)
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 6
        row.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(row)

        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: card.topAnchor, constant: 6),
            row.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -6),
            row.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 8),
            row.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -8),
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
        // 如果窗口已可见且用户可能已拖动过它，仅刷新内容，避免把窗口强行拉回旧位置。
        if !panel.isVisible {
            let screen = NSScreen.screens.first { $0.frame.intersects(selectionScreenRect) } ?? NSScreen.main
            let visible = screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
            let desiredSize = CGSize(
                width: max(Self.defaultSize.width, panel.frame.width),
                height: max(Self.defaultSize.height, panel.frame.height)
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

    private func setText(_ text: String) {
        isProgrammaticallyUpdatingText = true
        textView.string = text
        isProgrammaticallyUpdatingText = false
        textView.scrollRangeToVisible(NSRange(location: 0, length: 0))
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

    // MARK: - 译文与模式切换

    /// 展示译文。
    func showTranslation(_ result: TranslationResult, diagnosticMessage: String? = nil) {
        translationResult = result
        modeControl.setEnabled(true, forSegment: DisplayMode.translation.rawValue)
        modeControl.setEnabled(true, forSegment: DisplayMode.bilingual.rawValue)
        displayMode = .translation
        modeControl.selectedSegment = DisplayMode.translation.rawValue
        refreshDisplayedText()

        let detail = diagnosticMessage?.trimmingCharacters(in: .whitespacesAndNewlines)
        if result.isEntirelyUntranslated {
            if let detail, !detail.isEmpty {
                statusLabel.stringValue = "翻译失败：\(detail)"
            } else {
                statusLabel.stringValue = "翻译不可用，已保留原文"
            }
        } else if result.isPartiallyTranslated {
            if let detail, !detail.isEmpty {
                statusLabel.stringValue = "已翻译 \(result.translatedCount)/\(result.segments.count) 行（\(detail)）"
            } else {
                statusLabel.stringValue = "已翻译 \(result.translatedCount)/\(result.segments.count) 行 · 未翻译的行保留原文"
            }
        } else {
            statusLabel.stringValue = "已翻译 \(result.translatedCount) 行"
        }
        refreshTranslationControls(hasLines: !currentEditableOriginalText.isEmpty)
    }

    private func resetDisplayModeControl() {
        displayMode = .original
        modeControl.selectedSegment = DisplayMode.original.rawValue
        modeControl.setEnabled(false, forSegment: DisplayMode.translation.rawValue)
        modeControl.setEnabled(false, forSegment: DisplayMode.bilingual.rawValue)
        textView.isEditable = true
    }

    private func refreshDisplayedText() {
        switch displayMode {
        case .original:
            textView.isEditable = true
            setText(currentEditableOriginalText)
        case .translation:
            textView.isEditable = false
            guard let result = translationResult else {
                setText(currentEditableOriginalText)
                return
            }
            setText(result.segments.map(\.displayText).joined(separator: "\n"))
        case .bilingual:
            textView.isEditable = false
            guard let result = translationResult else {
                setText(currentEditableOriginalText)
                return
            }
            let combined = result.segments.map { segment in
                if let translated = segment.translatedText,
                   !translated.isEmpty,
                   translated != segment.sourceText {
                    return "\(segment.sourceText)\n\(translated)"
                }
                return segment.sourceText
            }.joined(separator: "\n\n")
            setText(combined)
        }
    }

    // MARK: - NSTextViewDelegate

    func textDidChange(_ notification: Notification) {
        guard !isProgrammaticallyUpdatingText, displayMode == .original else { return }
        editedOriginalText = textView.string
        let hasText = !textView.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        copyButton.isEnabled = hasText
        refreshTranslationControls(hasLines: hasText)
    }

    // MARK: - 状态控制

    private var translationAvailability: TranslationAvailability = .unknown
    private var isTranslating = false

    func showTranslationUnavailable(_ availability: TranslationAvailability) {
        statusLabel.stringValue = availability.explanation
        applyTranslationAvailability(availability)
    }

    func applyTranslationAvailability(_ availability: TranslationAvailability) {
        translationAvailability = availability
        refreshTranslationControls(hasLines: !currentEditableOriginalText.isEmpty)
    }

    func setTranslating(_ translating: Bool) {
        isTranslating = translating
        if translating {
            statusLabel.stringValue = "正在翻译…"
        } else if statusLabel.stringValue == "正在翻译…" {
            statusLabel.stringValue = "翻译已取消，已保留当前文字"
        }
        refreshTranslationControls(hasLines: !currentEditableOriginalText.isEmpty)
    }

    func hide() {
        statusOverlay.isHidden = true
        progressIndicator.stopAnimation(nil)
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
    var windowForDiagnostics: NSWindow { panel }

    func selectDisplayModeForDiagnostics(_ mode: DisplayMode) {
        guard mode == .original || translationResult != nil else { return }
        displayMode = mode
        modeControl.selectedSegment = mode.rawValue
        refreshDisplayedText()
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

    @objc private func handleDisplayModeChanged(_ sender: NSSegmentedControl) {
        guard let mode = DisplayMode(rawValue: sender.selectedSegment) else { return }
        displayMode = mode
        refreshDisplayedText()
    }

    @objc private func handleOCRLanguageChanged() {
        onOCRLanguageChanged?(selectedOCRLanguage)
    }

    @objc private func handleMergeLineBreaksToggled() {
        let enabled = mergeLineBreaksButton.state == .on
        if editedOriginalText == nil, displayMode == .original {
            refreshDisplayedText()
        }
        onMergeLineBreaksChanged?(enabled)
    }

    @objc private func handleToggleAlwaysOnTop() {
        setAlwaysOnTop(!isAlwaysOnTop)
    }

    @objc private func handleTranslate() {
        onTranslate?(selectedSourceLanguage, selectedTargetLanguage)
    }

    @objc private func handleTranslationLanguageChanged() {
        onTargetLanguageChanged?(selectedSourceLanguage, selectedTargetLanguage)
    }

    @objc private func handleCopy() {
        onCopyAll?(textView.string)
    }

    private func triggerRetranslateShortcut() {
        guard !isTranslating, !currentEditableOriginalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            NSSound.beep()
            return
        }
        onTranslate?(selectedSourceLanguage, selectedTargetLanguage)
    }

    private func triggerSmartCopy() {
        let content = smartCopyText
        guard !content.isEmpty else {
            NSSound.beep()
            return
        }
        onCopyAll?(content)
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
