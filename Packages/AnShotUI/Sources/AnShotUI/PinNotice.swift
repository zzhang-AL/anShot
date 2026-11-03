//
//  PinNotice.swift
//  AnShotUI
//
//  固定截图的非模态提示（「已达上限」「已隐藏全部固定截图」）。
//
//  ── 为什么不用 NSAlert ────────────────────────────────────
//
//  它出现的两个时刻都**不能被打断**：
//
//    1. 用户刚点「钉住」但被上限挡下——他要么继续标注，要么去关掉几张再回来；
//    2. 用户刚按下「隐藏全部」热键——他的下一个动作通常就是去看屏幕。
//
//  `runModal` 会把这两个流程都截成两段：一个模态框等着被点掉，
//  而屏幕上真正发生变化的东西在它后面。
//
//  所以这里只「说一句就走」：不接管焦点、不接受键盘、不挡鼠标，到点自己消失。
//

import AppKit

@MainActor
final class PinNotice {

    /// 提示停留时长。够读完一行中文，又不至于挡着用户接下来要做的事。
    private static let duration: TimeInterval = 2.6

    /// 距屏幕可见区底部的距离。放在下方是为了不压住刚钉出来的图
    ///（Pin 的默认落点偏上）。
    private static let bottomInset: CGFloat = 96

    private var panel: NSPanel?
    private var dismissTask: Task<Void, Never>?

    /// 显示一条提示。重复调用会替换上一条，不排队。
    ///
    /// 不排队是有意的：连续两次触发「已达上限」时，用户需要看到的是
    /// 最后那次的状态，而不是两条先后弹出的公告。
    func show(_ text: String) {
        dismissTask?.cancel()
        dismissTask = nil
        panel?.orderOut(nil)
        panel = nil

        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = .white
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        // 长文案（含上限数字）也不能被截断。
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1

        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.78).cgColor
        container.layer?.cornerRadius = 10
        container.addSubview(label)

        // 限制最大宽度：一行过长的文案会横跨整屏，反而更难读。
        let maxWidth: CGFloat = 420
        let widthConstraint = label.widthAnchor.constraint(lessThanOrEqualToConstant: maxWidth)
        widthConstraint.priority = .defaultHigh

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 18),
            label.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -18),
            label.topAnchor.constraint(equalTo: container.topAnchor, constant: 10),
            label.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -10),
            widthConstraint,
        ])

        let size = container.fittingSize
        let screen = NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let origin = CGPoint(
            x: screen.midX - size.width / 2,
            y: screen.minY + Self.bottomInset
        )

        let notice = NSPanel(
            contentRect: CGRect(origin: origin, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        // 与本项目其它窗口同一条纪律：ARC 下让 `close()` 释放窗口会过度释放。
        notice.isReleasedWhenClosed = false
        notice.isOpaque = false
        notice.backgroundColor = .clear
        notice.hasShadow = true
        notice.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
        // 提示可能在截图会话中出现（钉住被上限挡下），而截图覆盖层是
        // `.screenSaver`：层级必须比它再高一层，否则这句提示会被盖住，
        // 用户只听到一声提示音却看不到原因。取色器面板同理。
        notice.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        // 提示只是「说一句就走」，不应出现在任何屏幕捕获里
        // （用户下一张截图不该带上这条浮层）。
        notice.sharingType = .none
        // 关键：提示绝不能挡住鼠标——它出现的时刻用户正准备去点别的东西。
        notice.ignoresMouseEvents = true
        notice.contentView = container
        notice.orderFrontRegardless()
        panel = notice

        dismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.duration))
            guard !Task.isCancelled else { return }
            self?.panel?.orderOut(nil)
            self?.panel = nil
        }
    }
}
