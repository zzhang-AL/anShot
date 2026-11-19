//
//  HistoryPreviewPanel.swift
//  AnShotUI
//
//  历史记录预览（Phase 5.3 精修）：
//    - 顶部快捷操作栏（复制 ⌘C / 编辑 / 访达 / 关闭）；
//    - 后台异步解码大图与 GIF 动画（带 generation 防切行乱序，主线程零卡顿）；
//    - 超长图自动切换为适应宽度可滚动 `NSScrollView`，支持上下滚轮检视细节；
//    - 智能左右摆位（优先历史窗左侧，空间不足自动切右侧，均不足则居中）。
//

import AnShotCore
import AppKit
import AVFoundation
import AVKit
import ImageIO

/// 预览窗口：空格/ESC 关闭，`⌘C` 快速复制当前预览条目。
private final class HistoryPreviewWindow: NSWindow {

    var onDismissKey: (() -> Void)?
    var onCopyKey: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 49, 53: onDismissKey?()
        default: super.keyDown(with: event)
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags == .command, event.charactersIgnoringModifiers?.lowercased() == "c" {
            onCopyKey?()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

/// 顶对齐滚动文档视图（长图自顶向下滚动）。
private final class PreviewFlippedDocumentView: NSView {
    override var isFlipped: Bool { true }
}

/// 历史记录预览窗口。
@MainActor
final class HistoryPreviewPanel: NSObject, NSWindowDelegate {

    var onClose: (() -> Void)?
    var onCopy: ((HistoryEntry) -> Void)?
    var onEdit: ((HistoryEntry) -> Void)?
    var onReveal: ((HistoryEntry) -> Void)?

    private static let defaultSize = CGSize(width: 780, height: 620)
    private static let topInset: CGFloat = 28 + SettingsTheme.margin

    private let window: HistoryPreviewWindow
    private let header = SettingsHeaderView(
        symbolName: "eye",
        title: "预览",
        subtitle: "空格或 ESC 关闭 · ⌘C 复制"
    )
    private let copyButton = SettingsPushButton(title: "复制", emphasis: .primary, target: nil, action: nil)
    private let editButton = SettingsPushButton(title: "编辑", target: nil, action: nil)
    private let revealButton = SettingsPushButton(title: "访达", target: nil, action: nil)
    private let closeButton = SettingsPushButton(title: "关闭", target: nil, action: nil)

    private let imageSurface = HistorySurfaceView(style: .inset)
    private let infoSurface = HistorySurfaceView(style: .card)
    private let imageView = NSImageView()
    private let longImageScrollView = NSScrollView()
    private let longImageDocumentView = PreviewFlippedDocumentView()
    private let longImageView = NSImageView()
    private let playerView = AVPlayerView()
    private let placeholderSymbol = NSImageView()
    private let placeholderLabel = NSTextField(labelWithString: "")
    private let placeholderStack = NSStackView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let infoLabel = NSTextField(wrappingLabelWithString: "")

    private var currentEntry: HistoryEntry?
    private var isOpen = false
    private var loadGeneration: UInt64 = 0
    private var loadTask: Task<Void, Never>?

    override init() {
        window = HistoryPreviewWindow(
            contentRect: CGRect(origin: .zero, size: Self.defaultSize),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        super.init()

        window.isReleasedWhenClosed = false
        window.title = "预览"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.backgroundColor = SettingsTheme.windowBackground
        window.isMovableByWindowBackground = true
        window.minSize = CGSize(width: 480, height: 360)
        window.sharingType = .none
        window.delegate = self
        window.onDismissKey = { [weak self] in self?.close() }
        window.onCopyKey = { [weak self] in self?.copyTapped() }

        copyButton.target = self
        copyButton.action = #selector(copyTapped)
        copyButton.toolTip = "复制当前内容（⌘C）"

        editButton.target = self
        editButton.action = #selector(editTapped)
        editButton.toolTip = "在标注编辑器中打开"

        revealButton.target = self
        revealButton.action = #selector(revealTapped)
        revealButton.toolTip = "在访达中显示原文件"

        closeButton.target = self
        closeButton.action = #selector(closeTapped)
        closeButton.toolTip = "关闭预览（空格或 ESC）"

        window.contentView = makeContentView()
    }

    var isVisible: Bool { window.isVisible }

    /// 智能计算预览窗口落点（优先历史窗左侧 → 右侧 → 居中），暴露为内部静态纯函数供单元测试覆盖。
    static func preferredOrigin(
        panelSize: CGSize,
        anchorFrame: CGRect?,
        visibleFrame: CGRect,
        gap: CGFloat = 12
    ) -> CGPoint {
        if let anchor = anchorFrame {
            let y = min(
                max(anchor.midY - panelSize.height / 2, visibleFrame.minY + gap),
                max(visibleFrame.minY + gap, visibleFrame.maxY - panelSize.height - gap)
            )
            // 1. 优先历史窗左侧
            let leftX = anchor.minX - panelSize.width - gap
            if leftX >= visibleFrame.minX + gap {
                return CGPoint(x: leftX, y: y)
            }
            // 2. 左侧不够时切历史窗右侧
            let rightX = anchor.maxX + gap
            if rightX + panelSize.width <= visibleFrame.maxX - gap {
                return CGPoint(x: rightX, y: y)
            }
        }
        return CGPoint(
            x: visibleFrame.midX - panelSize.width / 2,
            y: visibleFrame.midY - panelSize.height / 2
        )
    }

    // MARK: - 显示

    func show(
        _ entry: HistoryEntry,
        thumbnail: NSImage?,
        relativeTo anchor: NSWindow?,
        makeKey: Bool = true
    ) {
        currentEntry = entry
        let isPresent = entry.isFilePresent
        let isRecording = entry.kind == .recording
        let wasOpen = isOpen

        nameLabel.stringValue = entry.isCached ? "缓存副本" : entry.fileURL.lastPathComponent
        window.title = "预览 · \(entry.kind.displayName)"

        copyButton.isEnabled = isPresent && onCopy != nil
        editButton.isHidden = isRecording
        editButton.isEnabled = isPresent && !isRecording && onEdit != nil
        revealButton.isEnabled = isPresent && onReveal != nil

        releaseContent()
        imageView.isHidden = true
        longImageScrollView.isHidden = true
        playerView.isHidden = true
        placeholderSymbol.image = nil
        placeholderLabel.stringValue = ""
        placeholderStack.isHidden = false

        loadGeneration &+= 1
        let gen = loadGeneration

        if isRecording {
            if !isPresent {
                placeholderSymbol.image = NSImage(systemSymbolName: "video.fill", accessibilityDescription: "录屏")
                placeholderLabel.stringValue = "录屏文件已移走"
            } else if entry.fileURL.pathExtension.lowercased() == "gif" {
                placeholderSymbol.image = NSImage(systemSymbolName: "photo.stack", accessibilityDescription: "GIF")
                placeholderLabel.stringValue = "正在加载 GIF 动画…"
                let url = entry.fileURL
                loadTask = Task { @MainActor [weak self] in
                    let data = await Task.detached(priority: .userInitiated) {
                        try? Data(contentsOf: url)
                    }.value
                    guard let self, self.loadGeneration == gen, !Task.isCancelled else { return }
                    if let data, let gifImage = NSImage(data: data) {
                        self.imageView.animates = true
                        self.imageView.image = gifImage
                        self.imageView.isHidden = false
                        self.placeholderStack.isHidden = true
                    } else {
                        self.placeholderSymbol.image = NSImage(systemSymbolName: "video.fill", accessibilityDescription: "GIF")
                        self.placeholderLabel.stringValue = "无法读取 GIF 文件"
                    }
                }
            } else {
                let player = AVPlayer(url: entry.fileURL)
                playerView.player = player
                playerView.isHidden = false
                placeholderStack.isHidden = true
                player.play()
            }
        } else if !isPresent {
            if let thumbnail {
                imageView.image = thumbnail
                imageView.isHidden = false
                placeholderStack.isHidden = true
            } else {
                placeholderSymbol.image = NSImage(systemSymbolName: "photo", accessibilityDescription: "图片")
                placeholderLabel.stringValue = "文件已移走"
            }
        } else {
            // 先用缩略图即时占位，后台异步全精度解码大图/长图，杜绝主线程卡顿。
            if let thumbnail {
                imageView.image = thumbnail
                imageView.isHidden = false
                placeholderStack.isHidden = true
            } else {
                placeholderSymbol.image = NSImage(systemSymbolName: "photo", accessibilityDescription: "图片")
                placeholderLabel.stringValue = "正在加载原图…"
            }
            let isLongImage = entry.kind == .longScreenshot
                || (entry.pixelWidth > 0 && Double(entry.pixelHeight) / Double(entry.pixelWidth) > 1.65)
            let url = entry.fileURL
            let maxPixel = isLongImage ? 6000 : 2400
            loadTask = Task { @MainActor [weak self] in
                let cgImage = await Task.detached(priority: .userInitiated) {
                    Self.loadPreviewCGImage(at: url, maxPixelSize: maxPixel)
                }.value
                guard let self, self.loadGeneration == gen, !Task.isCancelled else { return }
                if let cgImage {
                    let nsImage = NSImage(
                        cgImage: cgImage,
                        size: NSSize(width: CGFloat(cgImage.width), height: CGFloat(cgImage.height))
                    )
                    if isLongImage && Double(cgImage.height) / Double(max(1, cgImage.width)) > 1.65 {
                        self.presentLongScrollableImage(nsImage, pixelWidth: cgImage.width, pixelHeight: cgImage.height)
                    } else {
                        self.longImageScrollView.isHidden = true
                        self.imageView.image = nsImage
                        self.imageView.isHidden = false
                    }
                    self.placeholderStack.isHidden = true
                } else if thumbnail == nil {
                    self.placeholderSymbol.image = NSImage(systemSymbolName: "photo", accessibilityDescription: "图片")
                    self.placeholderLabel.stringValue = "无法读取图片"
                }
            }
        }

        infoLabel.stringValue = Self.infoText(for: entry, isPresent: isPresent)
        infoLabel.textColor = isPresent ? .secondaryLabelColor : .systemOrange

        isOpen = true
        ForegroundPolicyCoordinator.acquire("historyPreview")
        if !wasOpen {
            position(relativeTo: anchor)
        }
        if makeKey {
            window.makeKeyAndOrderFront(nil)
        } else {
            window.orderFront(nil)
        }
    }

    private func presentLongScrollableImage(_ image: NSImage, pixelWidth: Int, pixelHeight: Int) {
        imageView.isHidden = true
        longImageScrollView.isHidden = false
        imageSurface.layoutSubtreeIfNeeded()
        let viewportW = max(240, longImageScrollView.contentView.bounds.width - 8)
        let aspect = CGFloat(pixelHeight) / CGFloat(max(1, pixelWidth))
        let displayW = viewportW
        let displayH = max(longImageScrollView.contentView.bounds.height, displayW * aspect)
        longImageDocumentView.frame = CGRect(x: 0, y: 0, width: displayW, height: displayH)
        longImageView.frame = longImageDocumentView.bounds
        longImageView.image = image
        longImageScrollView.contentView.scroll(to: .zero)
        longImageScrollView.reflectScrolledClipView(longImageScrollView.contentView)
    }

    func close() {
        guard isOpen else { return }
        isOpen = false
        window.orderOut(nil)
        releaseContent()
        ForegroundPolicyCoordinator.release("historyPreview")
        onClose?()
    }

    private func releaseContent() {
        loadTask?.cancel()
        loadTask = nil
        playerView.player?.pause()
        playerView.player = nil
        imageView.animates = false
        imageView.image = nil
        longImageView.image = nil
        placeholderSymbol.image = nil
    }

    // MARK: - 布局

    private func makeContentView() -> NSView {
        let content = HistoryWindowBackgroundView(frame: CGRect(origin: .zero, size: Self.defaultSize))
        content.autoresizingMask = [.width, .height]

        imageView.imageScaling = .scaleProportionallyDown
        imageView.imageAlignment = .alignCenter
        imageView.imageFrameStyle = .none
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.isHidden = true
        imageSurface.addSubview(imageView)

        longImageScrollView.hasVerticalScroller = true
        longImageScrollView.hasHorizontalScroller = false
        longImageScrollView.autohidesScrollers = true
        longImageScrollView.drawsBackground = false
        longImageScrollView.borderType = .noBorder
        longImageScrollView.translatesAutoresizingMaskIntoConstraints = false
        longImageScrollView.isHidden = true
        longImageView.imageScaling = .scaleProportionallyUpOrDown
        longImageView.imageFrameStyle = .none
        longImageDocumentView.addSubview(longImageView)
        longImageScrollView.documentView = longImageDocumentView
        imageSurface.addSubview(longImageScrollView)

        playerView.controlsStyle = .inline
        playerView.translatesAutoresizingMaskIntoConstraints = false
        playerView.isHidden = true
        imageSurface.addSubview(playerView)

        placeholderSymbol.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 44, weight: .light)
        placeholderSymbol.contentTintColor = .secondaryLabelColor

        placeholderLabel.font = .systemFont(ofSize: 12)
        placeholderLabel.textColor = .secondaryLabelColor
        placeholderLabel.alignment = .center
        placeholderLabel.lineBreakMode = .byTruncatingMiddle

        placeholderStack.orientation = .vertical
        placeholderStack.alignment = .centerX
        placeholderStack.spacing = 8
        placeholderStack.translatesAutoresizingMaskIntoConstraints = false
        placeholderStack.addArrangedSubview(placeholderSymbol)
        placeholderStack.addArrangedSubview(placeholderLabel)
        imageSurface.addSubview(placeholderStack)

        NSLayoutConstraint.activate([
            imageView.topAnchor.constraint(equalTo: imageSurface.topAnchor, constant: 12),
            imageView.leadingAnchor.constraint(equalTo: imageSurface.leadingAnchor, constant: 12),
            imageView.trailingAnchor.constraint(equalTo: imageSurface.trailingAnchor, constant: -12),
            imageView.bottomAnchor.constraint(equalTo: imageSurface.bottomAnchor, constant: -12),

            longImageScrollView.topAnchor.constraint(equalTo: imageSurface.topAnchor, constant: 12),
            longImageScrollView.leadingAnchor.constraint(equalTo: imageSurface.leadingAnchor, constant: 12),
            longImageScrollView.trailingAnchor.constraint(equalTo: imageSurface.trailingAnchor, constant: -12),
            longImageScrollView.bottomAnchor.constraint(equalTo: imageSurface.bottomAnchor, constant: -12),

            playerView.topAnchor.constraint(equalTo: imageSurface.topAnchor, constant: 12),
            playerView.leadingAnchor.constraint(equalTo: imageSurface.leadingAnchor, constant: 12),
            playerView.trailingAnchor.constraint(equalTo: imageSurface.trailingAnchor, constant: -12),
            playerView.bottomAnchor.constraint(equalTo: imageSurface.bottomAnchor, constant: -12),

            placeholderStack.centerXAnchor.constraint(equalTo: imageSurface.centerXAnchor),
            placeholderStack.centerYAnchor.constraint(equalTo: imageSurface.centerYAnchor),
            placeholderStack.leadingAnchor.constraint(greaterThanOrEqualTo: imageSurface.leadingAnchor, constant: 16),
            placeholderStack.trailingAnchor.constraint(lessThanOrEqualTo: imageSurface.trailingAnchor, constant: -16),
        ])

        nameLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        nameLabel.textColor = .labelColor
        nameLabel.lineBreakMode = .byTruncatingMiddle
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        infoLabel.font = .systemFont(ofSize: 11)
        infoLabel.textColor = .secondaryLabelColor
        infoLabel.maximumNumberOfLines = 3
        infoLabel.lineBreakMode = .byTruncatingTail
        infoLabel.setContentCompressionResistancePriority(.defaultLow, for: .vertical)

        let infoStack = NSStackView(views: [nameLabel, infoLabel])
        infoStack.orientation = .vertical
        infoStack.alignment = .leading
        infoStack.spacing = 6
        infoStack.translatesAutoresizingMaskIntoConstraints = false
        infoSurface.addSubview(infoStack)
        NSLayoutConstraint.activate([
            infoStack.topAnchor.constraint(equalTo: infoSurface.topAnchor, constant: 14),
            infoStack.leadingAnchor.constraint(equalTo: infoSurface.leadingAnchor, constant: 14),
            infoStack.trailingAnchor.constraint(equalTo: infoSurface.trailingAnchor, constant: -14),
            infoStack.bottomAnchor.constraint(equalTo: infoSurface.bottomAnchor, constant: -14),
            nameLabel.widthAnchor.constraint(equalTo: infoStack.widthAnchor),
            infoLabel.widthAnchor.constraint(equalTo: infoStack.widthAnchor),
        ])

        let actionBar = NSStackView(views: [copyButton, editButton, revealButton, closeButton])
        actionBar.orientation = .horizontal
        actionBar.alignment = .centerY
        actionBar.spacing = 6
        actionBar.translatesAutoresizingMaskIntoConstraints = false

        for view in [header, actionBar, imageSurface, infoSurface] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }

        let margin = SettingsTheme.margin
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: content.topAnchor, constant: Self.topInset),
            header.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: margin),
            header.trailingAnchor.constraint(lessThanOrEqualTo: actionBar.leadingAnchor, constant: -12),

            actionBar.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            actionBar.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -margin),

            imageSurface.topAnchor.constraint(equalTo: header.bottomAnchor, constant: SettingsTheme.cardGap),
            imageSurface.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: margin),
            imageSurface.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -margin),

            infoSurface.topAnchor.constraint(equalTo: imageSurface.bottomAnchor, constant: 12),
            infoSurface.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: margin),
            infoSurface.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -margin),
            infoSurface.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -margin),
        ])
        return content
    }

    private func position(relativeTo anchor: NSWindow?) {
        let size = window.frame.size
        let screen = anchor?.screen ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        let origin = Self.preferredOrigin(
            panelSize: size,
            anchorFrame: (anchor?.isVisible == true) ? anchor?.frame : nil,
            visibleFrame: visible
        )
        window.setFrameOrigin(origin)
    }

    // MARK: - 文案

    private static let infoDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()

    private static func infoText(for entry: HistoryEntry, isPresent: Bool) -> String {
        var header = "\(entry.kind.displayName) · \(entry.pixelWidth) × \(entry.pixelHeight)"
        let ext = entry.fileURL.pathExtension.uppercased()
        if !ext.isEmpty {
            header += " · \(ext)"
        }
        if let size = fileSizeText(for: entry) {
            header += " · \(size)"
        }
        if !isPresent {
            header += " · 文件已移走"
        }

        var second = infoDateFormatter.string(from: entry.createdAt)
        if let source = sourceText(for: entry) {
            second += " · \(source)"
        }

        let location = entry.isCached
            ? "历史缓存副本"
            : (entry.filePath as NSString).abbreviatingWithTildeInPath
        return [header, second, location].joined(separator: "\n")
    }

    private static func sourceText(for entry: HistoryEntry) -> String? {
        var parts: [String] = []
        if let app = entry.source?.appName?.trimmingCharacters(in: .whitespacesAndNewlines),
           !app.isEmpty {
            parts.append(app)
        }
        if let title = entry.source?.windowTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
           !title.isEmpty {
            parts.append(title)
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private static func fileSizeText(for entry: HistoryEntry) -> String? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: entry.filePath),
              let size = attributes[.size] as? NSNumber else { return nil }
        return ByteCountFormatter.string(fromByteCount: size.int64Value, countStyle: .file)
    }

    private nonisolated static func loadPreviewCGImage(at url: URL, maxPixelSize: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    // MARK: - 动作

    @objc private func copyTapped() {
        guard let entry = currentEntry, entry.isFilePresent else { return }
        onCopy?(entry)
    }

    @objc private func editTapped() {
        guard let entry = currentEntry, entry.isFilePresent, entry.kind != .recording else { return }
        onEdit?(entry)
    }

    @objc private func revealTapped() {
        guard let entry = currentEntry, entry.isFilePresent else { return }
        onReveal?(entry)
    }

    @objc private func closeTapped() {
        close()
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        guard isOpen else { return }
        isOpen = false
        releaseContent()
        ForegroundPolicyCoordinator.release("historyPreview")
        onClose?()
    }
}
