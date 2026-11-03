//
//  ScrollshotResultController.swift
//  AnShotUI
//
//  长截图完成后的结果窗口：等比缩略预览 + 像素尺寸 + 告警 + 保存/复制/钉住/编辑/关闭。
//
//  ── 为什么是一个独立的非激活面板 ──────────────────────────
//
//  长截图会话结束时，用户刚刚在别的应用里滚动页面；此时如果弹一个普通窗口，
//  AppKit 会激活本应用并把键盘焦点抢过来，用户滚到一半的页面就失去焦点。
//  所以用 `NSPanel` + `.nonactivatingPanel` + `becomesKeyOnlyIfNeeded`：
//  窗口浮在普通窗口之上、按钮可点，但点击不会激活 anShot、也不会抢走按键。
//
//  ── 为什么预览必须自己算尺寸 ──────────────────────────────
//
//  长图的像素高度可以到几万（契约允许的上限就是内存约束本身）。
//  `NSImage(cgImage:)` 不传 size 时会按 1:1 像素尺寸登记图像，视图层再按窗口
//  大小缩放——等于让 AppKit 拿着整幅位图去参与布局和绘制。这里先用
//  `CGImage.width/height`（不解码像素）算出缩略后的显示尺寸，再交给
//  `NSImage(cgImage:size:)`，视图只按这个尺寸排版。整幅 `CGImage` 仍由调用方
//  持有，控制器只在窗口存活期间借用。
//
//  ── 关闭语义 ──────────────────────────────────────────────
//
//  `onClose` 是调用方释放会话状态（以及历史记录里那条临时结果）的唯一信号，
//  因此必须**只调用一次**：无论是点「关闭」、点标题栏红叉，还是调用方自己
//  `close()`，都收敛到同一个幂等出口。同时把预览图与 `Actions` 一并置空——
//  `NSImage` 会持有整幅 `CGImage`，只置空自己的引用并不足以释放长图；
//  闭包也可能间接捕获图像。
//
//  保存/复制/钉住/编辑只负责回调，**不自行关闭窗口**：这些动作之后要不要留在
//  屏幕上（例如编辑要回到标注界面，失败要留在原窗口重试）只有调用方知道。
//

import AppKit

@MainActor
final class ScrollshotResultController: NSObject, NSWindowDelegate {

    /// 结果窗口上的出口。
    ///
    /// 每个回调都带 `CGImage`：控制器不复用调用方的图，调用方不必再去别处取。
    struct Actions {
        var onSave: (CGImage) -> Void
        var onCopy: (CGImage) -> Void
        var onPin: (CGImage) -> Void
        var onEdit: ((CGImage) -> Void)?
        var onClose: () -> Void
    }

    /// 尺寸常量集中在此，避免同一组留白在约束里散落成不同的魔数。
    private enum Layout {
        /// 内容四周留白。
        static let margin: CGFloat = 18
        /// 内容宽度的下限：按钮行需要约 330pt，太窄会把中文按钮挤成两行。
        static let minimumWidth: CGFloat = 360
        /// 预览区上限（点）。再大就会在小屏上超出可见区。
        static let maximumPreviewWidth: CGFloat = 560
        static let maximumPreviewHeight: CGFloat = 420
        static let previewCornerRadius: CGFloat = 6
        /// 预览、尺寸、告警之间的间距。
        static let sectionSpacing: CGFloat = 10
        static let buttonSpacing: CGFloat = 8
        /// 动作按钮与「关闭」之间的额外间距：两者语义不同，贴太近容易误点。
        static let actionToCloseSpacing: CGFloat = 18
    }

    /// 当前持有的整幅长图。关闭时置空——见文件头的释放说明。
    private var image: CGImage?
    /// 置空后按钮不会再回调，避免窗口已关还在触发保存。
    private var actions: Actions?
    private var panel: NSPanel?
    private let previewView = NSImageView()
    /// `onClose` 的幂等闸门。
    private var didNotifyClose = false

    /// 窗口是否仍在屏幕上（诊断与调用方去重用）。
    var isVisible: Bool { panel?.isVisible ?? false }

    init(image: CGImage, warnings: [String], actions: Actions) {
        self.image = image
        self.actions = actions
        super.init()
        configurePanel(image: image, warnings: warnings)
    }

    // MARK: - 显示 / 关闭

    /// 在指定屏幕居中显示；`screen` 为 nil 时用鼠标所在屏（多显示器下最不意外）。
    ///
    /// 用 `orderFrontRegardless` 而不是 `makeKeyAndOrderFront`：后者会尝试激活
    /// 应用。面板的 `becomesKeyOnlyIfNeeded` 让按钮点击也不需要键盘焦点。
    func show(on screen: NSScreen?) {
        guard image != nil, !didNotifyClose, let panel else { return }
        let targetScreen = screen ?? Self.screenUnderMouse() ?? NSScreen.main ?? NSScreen.screens.first
        if let visibleFrame = targetScreen?.visibleFrame {
            let size = panel.frame.size
            panel.setFrameOrigin(CGPoint(
                x: visibleFrame.midX - size.width / 2,
                y: visibleFrame.midY - size.height / 2
            ))
        }
        panel.orderFrontRegardless()
    }

    /// 关闭并释放图像。重复调用安全，`onClose` 最多触发一次。
    func close() {
        // 先摘掉 delegate：`close()` 会触发 `windowWillClose`，两条路径都收敛到
        // 下面的幂等出口，但先摘掉可以让「程序关闭」与「用户点红叉」分得更清楚。
        if let panel {
            self.panel = nil
            panel.delegate = nil
            panel.close()
        }
        releaseImage()
        notifyCloseOnce()
    }

    /// 用户点了标题栏红叉。
    func windowWillClose(_ notification: Notification) {
        panel = nil
        releaseImage()
        notifyCloseOnce()
    }

    // MARK: - 窗口

    private func configurePanel(image: CGImage, warnings: [String]) {
        let previewSize = Self.previewSize(for: image)
        let contentWidth = max(Layout.minimumWidth, previewSize.width + Layout.margin * 2)

        let panel = NSPanel(
            contentRect: CGRect(x: 0, y: 0, width: contentWidth, height: 240),
            styleMask: [.titled, .closable, .nonactivatingPanel, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        self.panel = panel
        panel.title = "长截图结果"
        // ARC 下 `close()` 会因默认的 isReleasedWhenClosed 过度释放（项目内其它
        // 窗口都显式关掉，这里保持一致）。
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = true
        // 浮在普通窗口之上；长截图常发生在单个全屏窗口里，所以允许进入全屏空间。
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        // 点击按钮只把点击交给控件，不激活应用、不抢键盘焦点。
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.delegate = self

        let content = NSView()
        panel.contentView = content

        // Auto Layout 量高度需要先确定宽度：换行告警的固有高度随宽度变化。
        // 窗口的根内容视图尺寸由 AppKit 直接管理，不适合再挂固定宽度；
        // 因此所有内容放进一个宽度固定的 body，再由 body 量出真实高度。
        let body = NSView()
        body.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(body)
        NSLayoutConstraint.activate([
            body.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            body.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            body.topAnchor.constraint(equalTo: content.topAnchor),
            body.widthAnchor.constraint(equalToConstant: contentWidth),
            // 刻意**不**把 body 的底边钉到 content：body 的高度由内部内容
            // （换行告警等）决定，窗口再按这个高度定稿。若先钉底边，初始的
            // 窗口高度会反过来把内容压扁，量出来的高度就永远等于初始值。
        ])

        // ── 预览 ────────────────────────────────────────────
        // 外层容器负责圆角与浅灰底：透明区域或整片白色的长图，没有底色边界
        // 就看不出图像到哪儿结束。
        let previewContainer = NSView()
        previewContainer.wantsLayer = true
        previewContainer.layer?.backgroundColor = NSColor(calibratedWhite: 0.5, alpha: 0.12).cgColor
        previewContainer.layer?.cornerRadius = Layout.previewCornerRadius
        previewContainer.layer?.borderWidth = 1
        previewContainer.layer?.borderColor = NSColor.separatorColor.cgColor
        previewContainer.layer?.masksToBounds = true
        previewContainer.translatesAutoresizingMaskIntoConstraints = false
        body.addSubview(previewContainer)

        // size 传缩略尺寸：AppKit 按这个尺寸排版，而不是按整幅像素尺寸。
        previewView.image = NSImage(cgImage: image, size: previewSize)
        previewView.imageScaling = .scaleProportionallyUpOrDown
        previewView.imageFrameStyle = .none
        previewView.translatesAutoresizingMaskIntoConstraints = false
        previewContainer.addSubview(previewView)

        // ── 像素尺寸 ────────────────────────────────────────
        let pixelLabel = NSTextField(labelWithString: "\(image.width) × \(image.height) px")
        pixelLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        pixelLabel.textColor = .secondaryLabelColor
        pixelLabel.alignment = .center
        pixelLabel.translatesAutoresizingMaskIntoConstraints = false
        body.addSubview(pixelLabel)

        // ── 告警（有才显示）────────────────────────────────
        // 空告警不占一行：否则成功时窗口里会留下一块说不出理由的空白。
        let warningText = warnings
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .map { "• \($0)" }
            .joined(separator: "\n")

        var warningLabel: NSTextField?
        if !warningText.isEmpty {
            // 用换行标签：告警是自然语言句子，截断会正好切掉「所以这张图能不能用」。
            let label = NSTextField(wrappingLabelWithString: warningText)
            label.font = .systemFont(ofSize: 11)
            label.textColor = .systemOrange
            // 换行标签必须知道可用宽度，否则固有尺寸按单行计算，会把窗口顶宽。
            label.preferredMaxLayoutWidth = contentWidth - Layout.margin * 2
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            label.translatesAutoresizingMaskIntoConstraints = false
            body.addSubview(label)
            warningLabel = label
        }

        // ── 按钮行 ──────────────────────────────────────────
        let saveButton = Self.makeButton(title: "保存", target: self, action: #selector(handleSave))
        let copyButton = Self.makeButton(title: "复制", target: self, action: #selector(handleCopy))
        let pinButton = Self.makeButton(title: "钉住", target: self, action: #selector(handlePin))
        let closeButton = Self.makeButton(title: "关闭", target: self, action: #selector(handleClose))

        var buttons: [NSButton] = [saveButton, copyButton, pinButton]
        // `onEdit == nil` 时整颗按钮都不存在（不是禁用）：没有编辑入口时留一颗
        // 灰按钮，只会让用户反复点它来确认「为什么没用」。
        if actions?.onEdit != nil {
            buttons.append(Self.makeButton(title: "编辑", target: self, action: #selector(handleEdit)))
        }
        buttons.append(closeButton)

        let buttonRow = NSStackView(views: buttons)
        buttonRow.orientation = .horizontal
        buttonRow.alignment = .centerY
        buttonRow.spacing = Layout.buttonSpacing
        buttonRow.translatesAutoresizingMaskIntoConstraints = false
        body.addSubview(buttonRow)
        // 动作按钮与「关闭」之间留一道更明显的缝。
        if let lastAction = buttons.dropLast().last {
            buttonRow.setCustomSpacing(Layout.actionToCloseSpacing, after: lastAction)
        }

        // ── 布局 ────────────────────────────────────────────
        // 竖向链路固定为：预览 → 像素尺寸 → 告警 → 按钮行；每一段都接到
        // body 的对应边，Auto Layout 才能算出确定的高度。
        var constraints: [NSLayoutConstraint] = [
            previewContainer.topAnchor.constraint(equalTo: body.topAnchor, constant: Layout.margin),
            previewContainer.centerXAnchor.constraint(equalTo: body.centerXAnchor),
            previewContainer.widthAnchor.constraint(equalToConstant: previewSize.width),
            previewContainer.heightAnchor.constraint(equalToConstant: previewSize.height),

            previewView.leadingAnchor.constraint(equalTo: previewContainer.leadingAnchor),
            previewView.trailingAnchor.constraint(equalTo: previewContainer.trailingAnchor),
            previewView.topAnchor.constraint(equalTo: previewContainer.topAnchor),
            previewView.bottomAnchor.constraint(equalTo: previewContainer.bottomAnchor),

            pixelLabel.topAnchor.constraint(
                equalTo: previewContainer.bottomAnchor,
                constant: Layout.sectionSpacing
            ),
            pixelLabel.centerXAnchor.constraint(equalTo: body.centerXAnchor),
            pixelLabel.leadingAnchor.constraint(
                greaterThanOrEqualTo: body.leadingAnchor,
                constant: Layout.margin
            ),
            pixelLabel.trailingAnchor.constraint(
                lessThanOrEqualTo: body.trailingAnchor,
                constant: -Layout.margin
            ),
        ]

        let rowTopAnchor: NSLayoutYAxisAnchor
        if let warningLabel {
            constraints += [
                warningLabel.topAnchor.constraint(
                    equalTo: pixelLabel.bottomAnchor,
                    constant: Layout.sectionSpacing
                ),
                warningLabel.leadingAnchor.constraint(
                    equalTo: body.leadingAnchor,
                    constant: Layout.margin
                ),
                warningLabel.trailingAnchor.constraint(
                    equalTo: body.trailingAnchor,
                    constant: -Layout.margin
                ),
            ]
            rowTopAnchor = warningLabel.bottomAnchor
        } else {
            rowTopAnchor = pixelLabel.bottomAnchor
        }

        constraints += [
            buttonRow.topAnchor.constraint(equalTo: rowTopAnchor, constant: 14),
            buttonRow.trailingAnchor.constraint(
                equalTo: body.trailingAnchor,
                constant: -Layout.margin
            ),
            buttonRow.leadingAnchor.constraint(
                greaterThanOrEqualTo: body.leadingAnchor,
                constant: Layout.margin
            ),
            buttonRow.bottomAnchor.constraint(
                equalTo: body.bottomAnchor,
                constant: -Layout.margin
            ),
        ]
        NSLayoutConstraint.activate(constraints)

        // 高度由内容决定：窗口不提供固定高度，否则告警行数一变就会被裁掉。
        // body 的宽度是必需约束，因此 fittingSize 会先按该宽度完成换行，
        // 再给出确定的高度。
        content.layoutSubtreeIfNeeded()
        let fitting = body.fittingSize
        panel.setContentSize(CGSize(
            width: contentWidth,
            height: max(fitting.height.rounded(.up), 160)
        ))
    }

    private static func makeButton(title: String, target: AnyObject, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: target, action: action)
        button.bezelStyle = .rounded
        button.controlSize = .regular
        return button
    }

    /// 等比缩放，且只缩不放：小图放大只会变糊，还会让窗口尺寸失去参照。
    private static func previewSize(for image: CGImage) -> CGSize {
        let pixelWidth = CGFloat(image.width)
        let pixelHeight = CGFloat(image.height)
        guard pixelWidth > 0, pixelHeight > 0 else { return CGSize(width: 1, height: 1) }
        let fit = min(
            Layout.maximumPreviewWidth / pixelWidth,
            Layout.maximumPreviewHeight / pixelHeight
        )
        let scale = min(1, fit)
        return CGSize(
            width: max(1, (pixelWidth * scale).rounded(.down)),
            height: max(1, (pixelHeight * scale).rounded(.down))
        )
    }

    private static func screenUnderMouse() -> NSScreen? {
        let location = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(location) }
    }

    // MARK: - 释放与幂等回调

    /// 同时释放自己的整幅图引用与预览 `NSImage`。
    ///
    /// 后者必须一起清：`NSImage(cgImage:size:)` 持有同一个 `CGImage`，只置空
    /// `image` 并不会让长图位图离开内存。
    private func releaseImage() {
        image = nil
        previewView.image = nil
    }

    private func notifyCloseOnce() {
        guard !didNotifyClose else { return }
        didNotifyClose = true
        // 先取出闭包再清空 Actions：闭包可能捕获调用方状态，清空后不再持有。
        let callback = actions?.onClose
        actions = nil
        callback?()
    }

    // MARK: - 按钮

    @objc private func handleSave() {
        guard let image, let actions else { return }
        actions.onSave(image)
    }

    @objc private func handleCopy() {
        guard let image, let actions else { return }
        actions.onCopy(image)
    }

    @objc private func handlePin() {
        guard let image, let actions else { return }
        actions.onPin(image)
    }

    @objc private func handleEdit() {
        guard let image, let actions, let onEdit = actions.onEdit else { return }
        onEdit(image)
    }

    /// 「关闭」是窗口自己的事：它必须真正关闭，且只触发一次 `onClose`。
    @objc private func handleClose() {
        close()
    }
}
