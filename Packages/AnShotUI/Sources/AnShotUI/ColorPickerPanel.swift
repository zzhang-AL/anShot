//
//  ColorPickerPanel.swift
//  AnShotUI
//
//  承载自绘取色器的非激活面板。
//
//  ── 为什么不复用系统 NSColorPanel ─────────────────────────
//
//  它是全局共享窗口，默认 `hidesOnDeactivate = true`；
//  本应用是无 Dock 图标的菜单栏辅助程序、始终不是活跃应用，
//  于是它一显示就自我隐藏（`isVisible` 仍为 true，窗口却已被 order out）。
//  改用自有面板后，这些共享状态与外观问题都不存在了。
//
//  ── 关键点：不激活应用 ≠ 收不到键盘 ──────────────────────
//
//  `.nonactivatingPanel` 保证点它不会让 anShot 变成活跃应用
//  （覆盖层要维持「不抢焦点」的承诺），
//  而 `canBecomeKey = true` 让它仍能拿到键盘焦点——
//  Hex 输入框因此可以正常打字，包括中文输入法。
//

import AppKit

/// 取色器的圆角深色背板。
private final class ColorPickerBackgroundView: NSView {
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }

        // 与工具栏同一套深色浮层语言：半透明黑、细白描边、圆角。
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = CGPath(
            roundedRect: rect,
            cornerWidth: 12,
            cornerHeight: 12,
            transform: nil
        )

        context.saveGState()
        context.setFillColor(NSColor.black.withAlphaComponent(0.88).cgColor)
        context.addPath(path)
        context.fillPath()
        context.setStrokeColor(NSColor.white.withAlphaComponent(0.12).cgColor)
        context.setLineWidth(1)
        context.addPath(path)
        context.strokePath()
        context.restoreGState()
    }
}

/// 取色器面板。
final class ColorPickerPanel: NSPanel {

    let pickerView: ColorPickerView

    /// 内容四周留给背板圆角的留白。
    static let padding: CGFloat = 10

    init() {
        let contentSize = ColorPickerView.preferredSize
        pickerView = ColorPickerView(
            frame: CGRect(origin: .zero, size: contentSize)
        )

        let outerSize = CGSize(
            width: contentSize.width + Self.padding * 2,
            height: contentSize.height + Self.padding * 2
        )

        super.init(
            contentRect: CGRect(origin: .zero, size: outerSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = true
        // 需要键盘输入十六进制，所以不能是「仅必要时才成为 key」。
        becomesKeyOnlyIfNeeded = false
        // 与覆盖层同一层级之上，保证不被遮住。
        level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isReleasedWhenClosed = false
        // 面板不参与「关闭窗口即退出」之类的默认行为。
        isMovableByWindowBackground = false

        let background = ColorPickerBackgroundView(
            frame: CGRect(origin: .zero, size: outerSize)
        )
        pickerView.frame = CGRect(
            x: Self.padding,
            y: Self.padding,
            width: contentSize.width,
            height: contentSize.height
        )
        background.addSubview(pickerView)
        contentView = background
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
