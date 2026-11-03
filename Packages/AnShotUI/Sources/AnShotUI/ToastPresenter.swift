//
//  ToastPresenter.swift
//  AnShotUI
//
//  轻提示：屏幕底部居中的深色胶囊，一行文案 + 可选的右侧小按钮。
//
//  ── 与 `PinNotice` 的分工 ────────────────────────────────────
//
//  `PinNotice` 是「钉住流程内的纯文字公告」，文案与停留时长都固定；
//  本类型是**全局操作反馈**（已复制 / 已保存 / 已加入历史），
//  需要动作按钮、可由调用方指定屏幕与时长、可被显式关闭。两者窗口纪律
//  相同（非激活、不抢焦点、不可被捕获），但状态模型不同，故不合并。
//
//  ── 为什么按钮要单独待在一个窗口里 ───────────────────────────
//
//  `NSWindow.ignoresMouseEvents` 是**窗口级**开关，AppKit 没有「某个视图
//  鼠标穿透给其它 App」的等价能力：只要胶囊窗口接收鼠标，胶囊矩形内的
//  每一次点击都会被本应用吃掉。而提示多数时候只是通知，没理由把屏幕底部
//  一条 36pt 高的区域从桌面交互里挖走 1.8 秒。
//
//  因此胶囊窗口**永远** `ignoresMouseEvents = true`，真正可点的动作按钮
//  放进一个贴合在胶囊右上角、同样非激活的小窗口。鼠标只有落在按钮上才会
//  被拦住；其余部分直接到达下面的应用。代价是两个窗口必须一起摆放、
//  一起收起，所以状态集中在本类型的静态变量里。
//
//  ── 为什么计时用 Timer 而不是 `Task.sleep` ─────────────────
//
//  新消息要**立刻**接管：旧消息的计时必须能同步取消，否则旧延时到点会把
//  刚出现的新提示关掉。`Timer.invalidate()` 提供了这个同步取消点。
//  定时器挂在 `RunLoop.main` 的 `.common` 模式：截图/录制期间鼠标可能正处在
//  事件追踪循环里，默认模式的定时器要等追踪结束才触发，提示会滞留不走。
//
//  ── 生命周期 ───────────────────────────────────────────────
//
//  所有静态状态在 `dismiss()` 里一次性清空（窗口、定时器、回调）。
//  回调闭包常强引用控制器/面板，提示消失后继续持有它们就是泄漏。
//

import AppKit

/// 全局轻提示。同一时刻至多显示一条。
@MainActor
public final class ToastPresenter {

    // MARK: - 公开接口

    /// 显示一条提示；已有提示会被替换，计时重新开始。
    ///
    /// - Parameters:
    ///   - message: 单行文案，过长时截断（最大宽度见 `maximumTextWidth`）。
    ///   - screen: 期望出现的屏幕；传 `nil` 时用鼠标所在屏。
    ///   - duration: 自动关闭的秒数；`<= 0` 表示保持到下一次 `show`/`dismiss`。
    ///   - actionTitle: 右侧按钮标题。与 `action` 同时给出时才显示按钮。
    ///   - action: 点击按钮（或兜底的可点击胶囊）后执行；提示会先关闭。
    public static func show(
        _ message: String,
        on screen: NSScreen? = nil,
        duration: TimeInterval = 1.8,
        actionTitle: String? = nil,
        action: (() -> Void)? = nil
    ) {
        // 先拆旧的：旧回调不能在新提示上被触发，旧计时也不能再关新窗口。
        dismiss()

        let targetScreen = screen ?? screenUnderMouse()
        // 完全没有屏幕（远程会话刚断开等）时仍需一个落点，否则窗口坐标是 NaN。
        let screenFrame = targetScreen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)

        let messageFont = NSFont.systemFont(ofSize: 13, weight: .medium)
        let messageSize = (message as NSString).size(withAttributes: [.font: messageFont])
        let messageHeight = ceil(messageSize.height)

        // 只有「标题 + 回调」齐全才显示按钮：只有标题的按钮点了什么也不会发生。
        let trimmedTitle = actionTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
        let usableTitle = (action != nil && trimmedTitle?.isEmpty == false) ? trimmedTitle : nil

        let buttonFont = NSFont.systemFont(ofSize: 12, weight: .semibold)
        let buttonTitleSize = usableTitle.map {
            ($0 as NSString).size(withAttributes: [.font: buttonFont])
        } ?? .zero
        let buttonSize = CGSize(
            width: ceil(buttonTitleSize.width) + buttonHorizontalPadding * 2,
            height: ceil(buttonTitleSize.height) + buttonVerticalPadding * 2
        )
        let buttonAreaWidth = usableTitle == nil ? 0 : buttonGap + buttonSize.width

        let capsuleHeight = max(minimumCapsuleHeight, messageHeight + verticalPadding * 2)
        let maxCapsuleWidth = max(minimumAvailableWidth, screenFrame.width - screenInset * 2)
        let maxTextWidth = max(1, min(maximumTextWidth, maxCapsuleWidth - horizontalPadding * 2 - buttonAreaWidth))
        let textWidth = max(1, min(ceil(messageSize.width), maxTextWidth))
        let capsuleWidth = horizontalPadding * 2 + textWidth + buttonAreaWidth

        let origin = CGPoint(
            x: screenFrame.midX - capsuleWidth / 2,
            y: screenFrame.minY + bottomInset
        )

        let capsule = ToastCapsuleView(frame: CGRect(x: 0, y: 0, width: capsuleWidth, height: capsuleHeight))
        capsule.wantsLayer = true
        // 深色胶囊：0.82 的黑既能压住浅色壁纸，又能透出一点背景，不致像一块黑板。
        capsule.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.82).cgColor
        // 全圆角 = 胶囊形状；半径取高度一半。
        capsule.layer?.cornerRadius = capsuleHeight / 2
        // 细白描边把胶囊从深色桌面上「抠」出来，否则暗背景下边界会糊掉。
        capsule.layer?.borderWidth = 1
        capsule.layer?.borderColor = NSColor.white.withAlphaComponent(0.08).cgColor

        let label = NSTextField(labelWithString: message)
        label.font = messageFont
        label.textColor = .white
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.isSelectable = false
        label.frame = CGRect(
            x: horizontalPadding,
            y: (capsuleHeight - messageHeight) / 2,
            width: textWidth,
            height: messageHeight
        )
        capsule.addSubview(label)

        // 给了回调却没给按钮标题时，退化成「整个胶囊可点」：否则这个回调永远没机会执行。
        let capsuleHandlesClick = action != nil && usableTitle == nil
        if capsuleHandlesClick, let action {
            capsule.onClick = {
                ToastPresenter.dismiss()
                action()
            }
        }

        let panel = ToastPanel(
            contentRect: CGRect(x: origin.x, y: origin.y, width: capsuleWidth, height: capsuleHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        configure(panel)
        panel.hasShadow = true
        // 关键：胶囊本身永不接收鼠标；有按钮时由下面的按钮窗口负责点击。
        panel.ignoresMouseEvents = !capsuleHandlesClick
        panel.contentView = capsule

        var buttonPanel: ToastButtonPanel?
        if usableTitle != nil, let action {
            let relay = ToastActionRelay {
                // 先关提示再回调：回调往往接着弹窗或开新流程，
                // 此时旧提示还挂在屏幕上会挡住接下来要看的东西。
                ToastPresenter.dismiss()
                action()
            }

            let button = makeActionButton(title: usableTitle ?? "", font: buttonFont, target: relay)
            button.frame = CGRect(origin: .zero, size: buttonSize)

            let buttonFrame = CGRect(
                x: capsuleWidth - horizontalPadding - buttonSize.width,
                y: (capsuleHeight - buttonSize.height) / 2,
                width: buttonSize.width,
                height: buttonSize.height
            )
            let panelForButton = ToastButtonPanel(
                contentRect: CGRect(
                    x: origin.x + buttonFrame.minX,
                    y: origin.y + buttonFrame.minY,
                    width: buttonSize.width,
                    height: buttonSize.height
                ),
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            configure(panelForButton)
            // 阴影只由胶囊那层出，按钮窗口再投一次会在边缘叠出脏边。
            panelForButton.hasShadow = false
            panelForButton.ignoresMouseEvents = false
            panelForButton.contentView = button

            buttonPanel = panelForButton
            // 按钮窗口必须活到点击发生，而 NSControl.target 不持有目标对象。
            self.buttonRelay = relay
        }

        self.panel = panel
        self.buttonPanel = buttonPanel

        // 先胶囊后按钮：同层级下后 order 的在上，按钮才能盖住胶囊右上角。
        panel.orderFrontRegardless()
        buttonPanel?.orderFrontRegardless()

        if duration > 0 {
            // `.common` 模式见文件头：避免鼠标追踪期间延时被推迟。
            let timer = Timer(timeInterval: duration, repeats: false) { _ in
                MainActor.assumeIsolated {
                    ToastPresenter.dismiss()
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            dismissTimer = timer
        }
    }

    /// 立即关闭当前提示（没有提示时无副作用）。
    public static func dismiss() {
        dismissTimer?.invalidate()
        dismissTimer = nil

        panel?.orderOut(nil)
        buttonPanel?.orderOut(nil)
        panel = nil
        buttonPanel = nil
        // 回调可能强引用调用方对象；提示已消失，这个引用也该断掉。
        buttonRelay = nil
    }

    // MARK: - 静态状态

    /// 当前胶囊窗口（`nil` 表示没有提示）。
    private static var panel: ToastPanel?
    /// 动作按钮所在的独立窗口；无按钮时为 `nil`。
    private static var buttonPanel: ToastButtonPanel?
    private static var dismissTimer: Timer?
    /// 按钮的 target 不被 `NSControl` 持有，必须由这里保活。
    private static var buttonRelay: ToastActionRelay?

    /// 提示层级。与截图覆盖层（`.screenSaver`）的其它浮层同为 +1：
    /// 提示经常紧跟在截图/录制动作之后出现，挂在覆盖层下面就等于没显示。
    private static let toastLevel = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)

    /// 距屏幕可用区域底边的距离（`visibleFrame` 已排除 Dock，不会压到 Dock 上）。
    private static let bottomInset: CGFloat = 72
    /// 胶囊内文字左右留白。
    private static let horizontalPadding: CGFloat = 18
    private static let verticalPadding: CGFloat = 10
    /// 一行中文超过这个宽度就该截断：横跨半屏的胶囊反而更难读。
    private static let maximumTextWidth: CGFloat = 420
    /// 胶囊与屏幕左右边缘至少留这么多，避免贴边。
    private static let screenInset: CGFloat = 24
    /// 与 13pt 字号配对的胶囊最小高度（纯数字/英文文案时也保持胶囊形状）。
    private static let minimumCapsuleHeight: CGFloat = 36
    /// 屏幕再窄也要给文案留出可读宽度；低于这个值就没必要继续压缩胶囊。
    private static let minimumAvailableWidth: CGFloat = 120
    private static let buttonGap: CGFloat = 14
    private static let buttonHorizontalPadding: CGFloat = 10
    private static let buttonVerticalPadding: CGFloat = 4

    /// 纯静态类型，不提供实例。
    private init() {}

    // MARK: - 内部实现

    /// 默认屏幕：鼠标所在的屏。多显示器下用户刚操作的就是这块屏。
    private static func screenUnderMouse() -> NSScreen? {
        let location = NSEvent.mouseLocation
        if let hovered = NSScreen.screens.first(where: { $0.frame.contains(location) }) {
            return hovered
        }
        // 鼠标恰好在屏幕之间的缝隙：退回 `NSScreen.main`（当前活动窗口所在屏），
        // 再不行取第一块屏。
        return NSScreen.main ?? NSScreen.screens.first
    }

    /// 两个窗口共用的配置：非激活、悬浮于覆盖层之上、不可被屏幕捕获。
    private static func configure(_ window: NSPanel) {
        window.level = toastLevel
        window.isOpaque = false
        window.backgroundColor = .clear
        window.isReleasedWhenClosed = false
        window.hidesOnDeactivate = false
        // 系统默认的出现动画有可见延迟，提示要「立刻看见」。
        window.animationBehavior = .none
        window.isMovable = false
        window.isMovableByWindowBackground = false
        // 全空间可见、不参与 Exposé 的空间变换、不进入 Cmd+Tab/窗口循环。
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        // 提示不该出现在用户下一张截图或别人的录屏里。
        window.sharingType = .none
    }

    private static func makeActionButton(title: String, font: NSFont, target: ToastActionRelay) -> NSButton {
        let button = ToastActionButton(title: title, target: target, action: #selector(ToastActionRelay.fire))
        // 无边框 + 自绘背景：系统的 bordered 样式在深色胶囊上会显得笨重，
        // 而 `.inline` 圆角按钮是浅色主题的样式。
        button.isBordered = false
        button.focusRingType = .none
        button.setButtonType(.momentaryPushIn)
        button.wantsLayer = true
        button.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.18).cgColor
        button.layer?.cornerRadius = 6
        // 标题用 attributed 明确给白字：胶囊是深色，系统按钮的默认标题色在
        // 非 key 窗口里会退成灰色，读起来像禁用。
        button.attributedTitle = NSAttributedString(
            string: title,
            attributes: [.font: font, .foregroundColor: NSColor.white]
        )
        button.alignment = .center
        return button
    }
}

// MARK: - 窗口与视图

/// 胶囊窗口：不可成为 key/main，否则点击按钮时会把提示变成焦点窗口。
private final class ToastPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// 动作按钮窗口：只覆盖按钮那一小块，是「有 action 时仅按钮可点」的载体。
private final class ToastButtonPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// 胶囊内容视图。整块可点只在「有回调但没有按钮标题」的兜底路径下启用。
private final class ToastCapsuleView: NSView {
    /// 兜底点击回调；只在「有回调但没有按钮标题」时设置。
    /// 类型标注 `@MainActor` 是因为闭包会直接调用主线程上的提示关闭逻辑。
    var onClick: (@MainActor () -> Void)?

    override func hitTest(_ point: NSPoint) -> NSView? {
        // 不接管时返回 nil，配合窗口的 ignoresMouseEvents 让点击直接穿透。
        guard onClick != nil, bounds.contains(point) else { return nil }
        // 不给文字标签接管机会：兜底路径下点文案也应触发回调。
        return self
    }

    override func mouseDown(with event: NSEvent) {
        onClick?()
    }
}

/// 动作按钮。它待在一个**永远不是 key** 的小面板里，所以：
/// 1. 必须接受首次点击——否则第一次点击会被当作「激活窗口」，动作不触发；
/// 2. 用小手光标说明这里可点（胶囊其余部分都是穿透的，不提示的话用户不会去试）。
private final class ToastActionButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }
}

/// 按钮的 target。`NSControl` 不持有 target，实例由 `ToastPresenter` 静态持有。
@MainActor
private final class ToastActionRelay: NSObject {
    private let handler: @MainActor () -> Void

    init(handler: @escaping @MainActor () -> Void) {
        self.handler = handler
    }

    @objc func fire() {
        // 回调里会 dismiss()，而 dismiss 会清空静态引用（本对象唯一的强引用）。
        // 显式延长生命周期，避免方法还没返回对象就被释放。
        withExtendedLifetime(self) {
            handler()
        }
    }
}
