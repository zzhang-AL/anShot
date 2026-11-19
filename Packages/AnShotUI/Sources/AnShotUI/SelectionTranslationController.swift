//
//  SelectionTranslationController.swift
//  AnShotUI
//
//  划词翻译（⌥D）与可选悬浮「翻译」胶囊控制器。
//
//  ── 安全与隐私红线 ────────────────────────────────────────────
//
//  1. 仅使用辅助功能 API（AXUIElement）读取当前聚焦控件的选中文本，
//     **严禁**模拟 ⌘C 污染用户剪贴板；
//  2. 在焦点控件及父级回溯链上均显式识别并拦截密码输入框
//     （`AXSecureTextField` 或含 `Secure`/`Password` 角色/子角色），绝不读取或弹出翻译胶囊。
//

import AnShotCapture
import AnShotCore
import AppKit
import ApplicationServices

private let logger = AnShotLog.translation

/// 基于辅助功能 API 读取当前前台应用选中文本的工具（纯静态方法，便于单元测试校验安全规则）。
@MainActor
enum SelectionTextReader {

    /// AX 查询单次超时（秒），避免慢响应 Electron / 浏览器进程拖慢主线程。
    private static let axTimeoutSeconds: Float = 0.2
    /// 沿 `kAXParentAttribute` 向上回溯的最大层级（兼容浏览器 DOM / 富文本容器）。
    private static let maxParentDepth = 6
    /// 单次划词读取的安全字符上限。
    private static let maxSelectionLength = 4000

    /// 划词读取结果。
    enum ReadResult: Equatable {
        /// 成功读到非空选中文本。
        case text(String)
        /// 尚未授予辅助功能权限。
        case noPermission
        /// 当前焦点位于密码框或安全输入控件，已主动屏蔽。
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

    /// 读取当前前台应用聚焦控件中的选中文本（优先前台 App AX + 6 层父级回溯 + 0.2s 超时，绝不触碰剪贴板）。
    static func readFocusedSelectedText(excludingOwnProcess: Bool = true) -> ReadResult {
        guard AXIsProcessTrusted() else {
            return .noPermission
        }

        let ownPID = ProcessInfo.processInfo.processIdentifier
        let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        if excludingOwnProcess, let frontPID, frontPID == ownPID {
            return .empty
        }

        guard let focusedElement = copyFocusedElement(frontmostPID: frontPID) else {
            return .empty
        }

        // 沿父链最多向上回溯 6 层：先校验密码安全红线，再依次尝试直接选中文本与 Range 切片。
        var current: AXUIElement? = focusedElement
        for _ in 0..<maxParentDepth {
            guard let element = current else { break }
            AXUIElementSetMessagingTimeout(element, axTimeoutSeconds)

            let role = copyStringAttribute(kAXRoleAttribute as CFString, from: element)
            let subrole = copyStringAttribute(kAXSubroleAttribute as CFString, from: element)
            if isSensitiveRole(role, subrole: subrole) {
                return .sensitiveField
            }

            if let direct = copyStringAttribute(kAXSelectedTextAttribute as CFString, from: element),
               let normalized = normalizeSelectedText(direct) {
                return .text(normalized)
            }

            if let ranged = copySelectedTextViaRange(from: element),
               let normalized = normalizeSelectedText(ranged) {
                return .text(normalized)
            }

            current = copyParentElement(of: element)
        }

        return .empty
    }

    /// 清洗并裁剪选区文本，空白串返回 `nil`。
    static func normalizeSelectedText(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.count > maxSelectionLength {
            return String(trimmed.prefix(maxSelectionLength))
        }
        return trimmed
    }

    private static func copyFocusedElement(frontmostPID: pid_t?) -> AXUIElement? {
        // 1. 优先查前台应用的聚焦元素（Chrome / Electron / IDE 下远比 SystemWide 稳定）。
        if let pid = frontmostPID {
            let appElement = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(appElement, axTimeoutSeconds)
            if let focused = copyElementAttribute(kAXFocusedUIElementAttribute as CFString, from: appElement) {
                return focused
            }
        }
        // 2. 兜底查 SystemWide 聚焦元素。
        let systemWide = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(systemWide, axTimeoutSeconds)
        return copyElementAttribute(kAXFocusedUIElementAttribute as CFString, from: systemWide)
    }

    private static func copyParentElement(of element: AXUIElement) -> AXUIElement? {
        copyElementAttribute(kAXParentAttribute as CFString, from: element)
    }

    private static func copyElementAttribute(_ attribute: CFString, from element: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
              let value,
              CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return nil
        }
        return unsafeDowncast(value, to: AXUIElement.self)
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

/// 划词翻译（`⌥D`）与可选悬浮「翻译」胶囊控制器。
@MainActor
final class SelectionTranslationController {

    private let settings: AppSettings
    private let onTranslateText: (String, CGRect) -> Void
    private let onRequestAccessibilityPermission: () -> Void

    nonisolated(unsafe) private var globalMonitor: Any?
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
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
    }

    /// 响应全局热键 `⌥D` 或菜单项：立刻读取选中文本并弹出独立翻译浮窗。
    func triggerSelectionTranslate() {
        hideFloatingButton()
        let result = SelectionTextReader.readFocusedSelectedText(excludingOwnProcess: false)
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
            ToastPresenter.show(
                "请先选中文字后按 \(settings.selectionTranslateShortcut.displayName)，或用 \(settings.ocrAutoTranslateShortcut.displayName) 框选翻译"
            )
        }
    }

    /// 根据设置开关安装或卸载全局鼠标拖选监听（默认关闭，仅用户显式开启时运行）。
    func refreshFloatingMonitor(isDiagnosticRun: Bool = false) {
        let shouldMonitor = settings.selectionTranslateFloatingButton && !isDiagnosticRun
        if shouldMonitor {
            installMonitorsIfNeeded()
        } else {
            removeMonitors()
            hideFloatingButton()
        }
    }

    private func installMonitorsIfNeeded() {
        guard globalMonitor == nil else { return }
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .leftMouseUp, .keyDown, .scrollWheel]
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            let eventType = event.type
            let location = NSEvent.mouseLocation
            let clickCount = (eventType == .leftMouseUp) ? event.clickCount : 0
            Task { @MainActor [weak self] in
                guard let self else { return }
                switch eventType {
                case .leftMouseDown:
                    self.handleGlobalMouseDown(at: location)
                case .leftMouseUp:
                    self.handleGlobalMouseUp(at: location, clickCount: clickCount)
                case .keyDown, .scrollWheel:
                    self.hideFloatingButton()
                default:
                    break
                }
            }
        }
        logger.notice("划词悬浮翻译胶囊监听已启用")
    }

    private func removeMonitors() {
        probeTask?.cancel()
        probeTask = nil
        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
            self.globalMonitor = nil
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
        // 仅在拖选位移 > 6pt 或双击/三击选词时探测，避免普通单击频繁轮询 AX。
        guard distance > 6 || clickCount >= 2 else { return }

        probeTask?.cancel()
        probeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(90))
            guard let self, !Task.isCancelled else { return }
            let result = SelectionTextReader.readFocusedSelectedText(excludingOwnProcess: true)
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
            try? await Task.sleep(for: .milliseconds(4500))
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

// MARK: - 现代划词悬浮「翻译」胶囊面板

/// 现代无焦点划词悬浮胶囊面板（`[译文图标 翻译]`，点击不抢占前台窗口焦点即可直达翻译）。
@MainActor
final class SelectionTranslateBubblePanel: NSPanel {

    var onClick: (() -> Void)?

    static let bubbleSize = CGSize(width: 82, height: 32)
    private let pillView: SelectionTranslatePillView

    init() {
        pillView = SelectionTranslatePillView(frame: CGRect(origin: .zero, size: Self.bubbleSize))
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
        appearance = nil
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .transient]

        pillView.onClick = { [weak self] in
            self?.onClick?()
        }
        contentView = pillView
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func show(near mouseLocation: CGPoint) {
        let screen = NSScreen.screens.first { $0.frame.contains(mouseLocation) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        // 默认落在光标右上方偏离 10pt，不遮挡刚选中的文字行；空间不足则智能翻转。
        var x = mouseLocation.x + 10
        var y = mouseLocation.y + 12
        if x + Self.bubbleSize.width > visible.maxX - 8 {
            x = mouseLocation.x - Self.bubbleSize.width - 10
        }
        if y + Self.bubbleSize.height > visible.maxY - 8 {
            y = mouseLocation.y - Self.bubbleSize.height - 12
        }
        x = max(visible.minX + 8, min(x, visible.maxX - Self.bubbleSize.width - 8))
        y = max(visible.minY + 8, min(y, visible.maxY - Self.bubbleSize.height - 8))

        pillView.resetInteractionState()
        setFrameOrigin(CGPoint(x: x, y: y))
        orderFrontRegardless()
    }

    func hide() {
        orderOut(nil)
    }
}

/// 划词悬浮胶囊自绘内容视图：`acceptsFirstMouse = true`，支持悬停强调色微光与自适应深浅外观。
final class SelectionTranslatePillView: NSView {

    var onClick: (() -> Void)?

    /// 供离线渲染验收模拟悬停高亮态。
    var isHoveredForPreview: Bool = false {
        didSet {
            if oldValue != isHoveredForPreview {
                isHovered = isHoveredForPreview
            }
        }
    }

    private var isHovered = false {
        didSet { if oldValue != isHovered { needsDisplay = true } }
    }

    private var isPressed = false {
        didSet { if oldValue != isPressed { needsDisplay = true } }
    }

    private static let translationCoral = NSColor(srgbRed: 0.94, green: 0.34, blue: 0.42, alpha: 1)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        toolTip = "翻译选中文字"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("不支持从 nib 构造")
    }

    override var isFlipped: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func resetInteractionState() {
        isHovered = false
        isPressed = false
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self
        ))
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) {
        isHovered = false
        isPressed = false
    }

    override func mouseDown(with event: NSEvent) {
        isPressed = true
    }

    override func mouseUp(with event: NSEvent) {
        let inside = bounds.contains(convert(event.locationInWindow, from: nil))
        isPressed = false
        if inside {
            onClick?()
        }
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let radius = rect.height / 2

        let bg: NSColor
        let border: NSColor
        if isPressed {
            bg = AnShotTheme.accent.withAlphaComponent(0.22)
            border = AnShotTheme.accent.withAlphaComponent(0.55)
        } else if isHovered {
            bg = AnShotTheme.dynamic(
                light: NSColor(srgbRed: 0.99, green: 0.995, blue: 1.0, alpha: 0.98),
                dark: NSColor(srgbRed: 0.21, green: 0.22, blue: 0.25, alpha: 0.96)
            )
            border = Self.translationCoral.withAlphaComponent(0.52)
        } else {
            bg = AnShotTheme.floatingSurface
            border = AnShotTheme.floatingBorder
        }

        AnShotTheme.fillRoundedRect(rect, radius: radius, color: bg, in: ctx)
        AnShotTheme.strokeRoundedRect(rect, radius: radius, color: border, lineWidth: 1, in: ctx)

        // 左侧柔和珊瑚粉小圆徽 + 译文图标
        let iconTint = isHovered ? Self.translationCoral : Self.translationCoral.withAlphaComponent(0.92)
        let symConfig = NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [iconTint]))
        let icon = NSImage(systemSymbolName: "character.book.closed.fill", accessibilityDescription: "翻译")?
            .withSymbolConfiguration(symConfig)

        let textAttr = NSAttributedString(string: "翻译", attributes: [
            .font: NSFont.systemFont(ofSize: 12.5, weight: .semibold),
            .foregroundColor: NSColor.labelColor,
        ])
        let textSize = textAttr.size()
        let iconW = icon?.size.width ?? 0
        let gap: CGFloat = 5
        let totalW = iconW + gap + textSize.width
        var x = bounds.midX - totalW / 2

        if let icon {
            let s = icon.size
            icon.draw(in: CGRect(
                x: x,
                y: bounds.midY - s.height / 2,
                width: s.width,
                height: s.height
            ))
            x += s.width + gap
        }
        textAttr.draw(at: CGPoint(x: x, y: bounds.midY - textSize.height / 2))
    }
}
