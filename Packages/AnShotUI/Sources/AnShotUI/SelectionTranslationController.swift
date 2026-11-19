//
//  SelectionTranslationController.swift
//  AnShotUI
//
//  划词翻译（⌥D）与可选悬浮「译」小按钮控制器。
//
//  ── 安全与隐私红线 ────────────────────────────────────────────
//
//  1. 仅使用辅助功能 API（AXUIElement）读取当前聚焦控件的选中文本，
//     **严禁**模拟 ⌘C 污染用户剪贴板；
//  2. 显式识别并过滤密码输入框（`AXSecureTextField` 或含 `Secure`/`Password` 子角色），
//     绝不读取或弹出翻译按钮。
//

import AnShotCapture
import AnShotCore
import AppKit
import ApplicationServices

private let logger = AnShotLog.translation

/// 基于辅助功能 API 读取当前应用选中文本的工具（纯静态方法，便于单元测试校验安全规则）。
@MainActor
enum SelectionTextReader {

    /// 划词读取结果。
    enum ReadResult: Equatable {
        /// 成功读到非空选中文本。
        case text(String)
        /// 尚未授予辅助功能权限。
        case noPermission
        /// 当前焦点为密码框或安全输入控件，已主动屏蔽。
        case sensitiveField
        /// 未选中任何非空文本。
        case empty
    }

    /// 判定 AX 角色 / 子角色是否为密码或敏感安全输入控件。
    static func isSensitiveRole(_ role: String?, subrole: String?) -> Bool {
        let candidates = [role, subrole].compactMap { $0?.lowercased() }
        for value in candidates {
            if value == "axsecuretextfield"
                || value.contains("secure")
                || value.contains("password") {
                return true
            }
        }
        return false
    }

    /// 读取当前系统聚焦控件中的选中文本（不模拟 ⌘C，不触碰剪贴板）。
    static func readFocusedSelectedText() -> ReadResult {
        guard AXIsProcessTrusted() else {
            return .noPermission
        }
        let systemWide = AXUIElementCreateSystemWide()
        var focusedValue: CFTypeRef?
        let focusStatus = AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedUIElementAttribute as CFString,
            &focusedValue
        )
        guard focusStatus == .success, let focusedValue else {
            return .empty
        }
        // CoreFoundation 类型强制桥接为 AXUIElement。
        guard CFGetTypeID(focusedValue) == AXUIElementGetTypeID() else {
            return .empty
        }
        let element = unsafeDowncast(focusedValue, to: AXUIElement.self)

        let role = copyStringAttribute(kAXRoleAttribute as CFString, from: element)
        let subrole = copyStringAttribute(kAXSubroleAttribute as CFString, from: element)
        if isSensitiveRole(role, subrole: subrole) {
            return .sensitiveField
        }

        if let direct = copyStringAttribute(kAXSelectedTextAttribute as CFString, from: element) {
            let trimmed = direct.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return .text(trimmed)
            }
        }

        // 部分富文本/编辑器控件只暴露 `AXSelectedTextRange` 而不直接填 `AXSelectedText`。
        if let ranged = copySelectedTextViaRange(from: element) {
            let trimmed = ranged.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return .text(trimmed)
            }
        }
        return .empty
    }

    private static func copyStringAttribute(_ attribute: CFString, from element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
              let string = value as? String else {
            return nil
        }
        return string
    }

    private static func copySelectedTextViaRange(from element: AXUIElement) -> String? {
        var rangeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            &rangeValue
        ) == .success, let rangeValue else {
            return nil
        }
        var textValue: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element,
            kAXStringForRangeParameterizedAttribute as CFString,
            rangeValue,
            &textValue
        ) == .success, let text = textValue as? String else {
            return nil
        }
        return text
    }
}

/// 划词翻译与可选悬浮「译」小按钮控制器。
@MainActor
final class SelectionTranslationController {

    private let settings: AppSettings
    private let onTranslateText: (String, CGRect) -> Void
    private let onRequestAccessibilityPermission: () -> Void

    nonisolated(unsafe) private var mouseDownMonitor: Any?
    nonisolated(unsafe) private var mouseUpMonitor: Any?
    private var mouseDownLocation: CGPoint?
    private var probeTask: Task<Void, Never>?
    private var hideButtonTask: Task<Void, Never>?

    private lazy var floatingButtonPanel = SelectionTranslateBubblePanel()
    private var pendingFloatingText: String?
    private var pendingAnchorRect: CGRect = .zero

    init(
        settings: AppSettings,
        onTranslateText: @escaping (String, CGRect) -> Void,
        onRequestAccessibilityPermission: @escaping () -> Void
    ) {
        self.settings = settings
        self.onTranslateText = onTranslateText
        self.onRequestAccessibilityPermission = onRequestAccessibilityPermission
        refreshFloatingMonitor()
    }

    deinit {
        if let mouseDownMonitor { NSEvent.removeMonitor(mouseDownMonitor) }
        if let mouseUpMonitor { NSEvent.removeMonitor(mouseUpMonitor) }
    }

    /// 响应全局热键 `⌥D`：立刻读取选中文本并弹出独立翻译浮窗。
    func triggerSelectionTranslate() {
        hideFloatingButton()
        let result = SelectionTextReader.readFocusedSelectedText()
        let mouse = NSEvent.mouseLocation
        let anchorRect = CGRect(x: mouse.x - 16, y: mouse.y - 16, width: 32, height: 32)

        switch result {
        case .text(let text):
            logger.notice("划词翻译触发：\(text.count, privacy: .public) 字符")
            onTranslateText(text, anchorRect)
        case .noPermission:
            NSSound.beep()
            ToastPresenter.show(
                "划词翻译需要辅助功能权限",
                actionTitle: "去授权"
            ) { [weak self] in
                self?.onRequestAccessibilityPermission()
            }
        case .sensitiveField:
            NSSound.beep()
            ToastPresenter.show("出于安全保护，密码输入框不支持划词翻译")
        case .empty:
            NSSound.beep()
            ToastPresenter.show("未检测到选中的文字，请先拖选文字后按 \(settings.selectionTranslateShortcut.displayName)")
        }
    }

    /// 根据设置开关安装或卸载全局鼠标拖选监听（默认关闭，仅用户显式开启时运行）。
    func refreshFloatingMonitor(isDiagnosticRun: Bool = false) {
        let shouldMonitor = settings.selectionTranslateFloatingButton && !isDiagnosticRun
        if shouldMonitor {
            installMouseMonitorsIfNeeded()
        } else {
            removeMouseMonitors()
            hideFloatingButton()
        }
    }

    private func installMouseMonitorsIfNeeded() {
        guard mouseDownMonitor == nil, mouseUpMonitor == nil else { return }
        mouseDownMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] _ in
            let location = NSEvent.mouseLocation
            Task { @MainActor [weak self] in
                self?.handleGlobalMouseDown(at: location)
            }
        }
        mouseUpMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp) { [weak self] event in
            let location = NSEvent.mouseLocation
            let clickCount = event.clickCount
            Task { @MainActor [weak self] in
                self?.handleGlobalMouseUp(at: location, clickCount: clickCount)
            }
        }
        logger.notice("划词悬浮按钮监听已启用")
    }

    private func removeMouseMonitors() {
        probeTask?.cancel()
        probeTask = nil
        if let mouseDownMonitor {
            NSEvent.removeMonitor(mouseDownMonitor)
            self.mouseDownMonitor = nil
        }
        if let mouseUpMonitor {
            NSEvent.removeMonitor(mouseUpMonitor)
            self.mouseUpMonitor = nil
        }
    }

    private func handleGlobalMouseDown(at location: CGPoint) {
        mouseDownLocation = location
        if floatingButtonPanel.isVisible && !floatingButtonPanel.frame.contains(location) {
            hideFloatingButton()
        }
    }

    private func handleGlobalMouseUp(at location: CGPoint, clickCount: Int) {
        guard settings.selectionTranslateFloatingButton else { return }
        let start = mouseDownLocation ?? location
        mouseDownLocation = nil
        let distance = hypot(location.x - start.x, location.y - start.y)
        // 仅在拖选位移 > 6pt 或双击选词时探测，避免普通单击频繁轮询 AX。
        guard distance > 6 || clickCount >= 2 else { return }

        probeTask?.cancel()
        probeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(90))
            guard let self, !Task.isCancelled else { return }
            let result = SelectionTextReader.readFocusedSelectedText()
            guard case .text(let text) = result, text.count >= 2 else {
                self.hideFloatingButton()
                return
            }
            self.showFloatingButton(for: text, near: location)
        }
    }

    private func showFloatingButton(for text: String, near mouseLocation: CGPoint) {
        pendingFloatingText = text
        pendingAnchorRect = CGRect(x: mouseLocation.x - 16, y: mouseLocation.y - 16, width: 32, height: 32)
        floatingButtonPanel.onClick = { [weak self] in
            guard let self, let text = self.pendingFloatingText else { return }
            let anchor = self.pendingAnchorRect
            self.hideFloatingButton()
            self.onTranslateText(text, anchor)
        }
        floatingButtonPanel.show(near: mouseLocation)

        hideButtonTask?.cancel()
        hideButtonTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard let self, !Task.isCancelled else { return }
            self.hideFloatingButton()
        }
    }

    private func hideFloatingButton() {
        hideButtonTask?.cancel()
        hideButtonTask = nil
        pendingFloatingText = nil
        floatingButtonPanel.hide()
    }
}

/// 极轻量的划词悬浮「译」小按钮面板。
@MainActor
private final class SelectionTranslateBubblePanel: NSPanel {

    var onClick: (() -> Void)?

    private let actionButton = NSButton(frame: .zero)
    private static let bubbleSize = CGSize(width: 28, height: 28)

    init() {
        super.init(
            contentRect: CGRect(origin: .zero, size: Self.bubbleSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isReleasedWhenClosed = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .floating
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]

        let container = BubbleContainerView(frame: CGRect(origin: .zero, size: Self.bubbleSize))
        actionButton.frame = container.bounds
        actionButton.title = "译"
        actionButton.font = .systemFont(ofSize: 12, weight: .semibold)
        actionButton.bezelStyle = .regularSquare
        actionButton.isBordered = false
        actionButton.contentTintColor = .labelColor
        actionButton.toolTip = "翻译选中文字"
        actionButton.target = self
        actionButton.action = #selector(handleClicked)
        container.addSubview(actionButton)
        contentView = container
    }

    func show(near mouseLocation: CGPoint) {
        let screen = NSScreen.screens.first { $0.frame.contains(mouseLocation) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        var x = mouseLocation.x + 10
        var y = mouseLocation.y - Self.bubbleSize.height - 10
        if x + Self.bubbleSize.width > visible.maxX - 6 {
            x = mouseLocation.x - Self.bubbleSize.width - 10
        }
        if y < visible.minY + 6 {
            y = mouseLocation.y + 12
        }
        setFrameOrigin(CGPoint(x: x, y: y))
        orderFrontRegardless()
    }

    func hide() {
        orderOut(nil)
    }

    @objc private func handleClicked() {
        onClick?()
    }
}

private final class BubbleContainerView: NSView {
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
        layer?.cornerRadius = 8
        layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.95).cgColor
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.cgColor
    }
}
