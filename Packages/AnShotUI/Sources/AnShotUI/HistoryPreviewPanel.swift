//
//  HistoryPreviewPanel.swift
//  AnShotUI
//
//  历史记录预览（契约 §5：空格预览，与设置/欢迎页同一套视觉语言）。
//
//  ── 为什么自己做一个窗口而不是 QuickLook ──────────────────
//
//  `QLPreviewPanel` 是共享的单例，会抢键盘、激活应用，而且对「录屏」只有
//  一个播放器外壳——历史窗口需要的是「看一眼这张图画了什么、这条是什么
//  文件」，而不是另一个应用级预览器。自己做一个小窗口，打开/关闭都
//  不会打断用户手头的工作。
//
//  ── 为什么用 ImageIO 缩略而不是 NSImage(contentsOf:) ─────
//
//  预览窗口最多显示两千像素；把一张 6K 长截图整幅解码进内存，只为了把它
//  缩到窗口大小，峰值内存与解码时间都不划算。`CGImageSource` 能直接在解码
//  阶段降采样，代价与目标尺寸相关，而不是与源图尺寸相关。
//
//  ── 视觉 ─────────────────────────────────────────────────
//
//  与历史窗口、设置窗口同一套：透明标题栏 + 隐藏标题 + `SettingsTheme`
//  背景与卡片、内容页头、24 边距。旧版的黑底 + 系统小按钮已经移除。
//

import AnShotCore
import AppKit
import ImageIO

/// 预览窗口：空格或 ESC 关闭。
///
/// 与历史窗口一样，按键放在窗口层；输入框等控件成为第一响应者时不会
/// 冒泡到这里，因此不会误关。
private final class HistoryPreviewWindow: NSWindow {

    var onDismissKey: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 49, 53: onDismissKey?()
        default: super.keyDown(with: event)
        }
    }
}

/// 历史记录预览窗口。
@MainActor
final class HistoryPreviewPanel: NSObject, NSWindowDelegate {

    /// 关闭后回调（无论是按钮、ESC 还是标题栏红点）。
    var onClose: (() -> Void)?

    private static let defaultSize = CGSize(width: 760, height: 600)

    /// 内容顶部留出的交通灯空间（理由同 `HistoryPanel.topInset`）。
    private static let topInset: CGFloat = 28 + SettingsTheme.margin

    private let window: HistoryPreviewWindow
    private let header = SettingsHeaderView(
        symbolName: "eye",
        title: "预览",
        subtitle: "空格或 ESC 关闭"
    )
    private let closeButton = SettingsPushButton(title: "关闭", target: nil, action: nil)
    private let imageSurface = HistorySurfaceView(style: .inset)
    private let infoSurface = HistorySurfaceView(style: .card)
    private let imageView = NSImageView()
    private let placeholderSymbol = NSImageView()
    private let placeholderLabel = NSTextField(labelWithString: "")
    private let placeholderStack = NSStackView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let infoLabel = NSTextField(wrappingLabelWithString: "")

    /// 防止 `close()` 与 `windowWillClose` 重复回调。
    private var isOpen = false

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
        window.minSize = CGSize(width: 420, height: 320)
        // 预览里可能是用户的隐私内容，不能被截进任何截图/录屏。
        window.sharingType = .none
        window.delegate = self
        window.onDismissKey = { [weak self] in self?.close() }

        closeButton.target = self
        closeButton.action = #selector(closeTapped)
        closeButton.toolTip = "关闭预览（空格或 ESC）"

        window.contentView = makeContentView()
    }

    var isVisible: Bool { window.isVisible }

    // MARK: - 显示

    /// 显示一条历史记录的预览。
    ///
    /// - Parameters:
    ///   - entry: 要预览的条目。
    ///   - thumbnail: 列表里已有的缩略图；原图读不出来时用它兜底。
    ///   - anchor: 历史窗口，用于把预览放在它左侧；不传则居中。
    func show(_ entry: HistoryEntry, thumbnail: NSImage?, relativeTo anchor: NSWindow?) {
        let isPresent = entry.isFilePresent
        let isRecording = entry.kind == .recording

        // 缓存条目的文件名是 UUID，显示出来没有信息量；用「缓存副本」代替。
        nameLabel.stringValue = entry.isCached ? "缓存副本" : entry.fileURL.lastPathComponent
        window.title = "预览 · \(entry.kind.displayName)"

        imageView.image = nil
        imageView.isHidden = true
        placeholderSymbol.image = nil
        placeholderLabel.stringValue = ""
        placeholderStack.isHidden = false

        if isRecording {
            // 录屏没有静态画面；给出明确标识，其余信息由底部信息卡片承担。
            placeholderSymbol.image = NSImage(
                systemSymbolName: "video.fill",
                accessibilityDescription: "录屏"
            )
            placeholderLabel.stringValue = isPresent ? "录屏文件" : "录屏文件已移走"
        } else if let image = Self.loadPreviewImage(at: entry.fileURL, maxPixelSize: 2000) {
            imageView.image = image
            imageView.isHidden = false
            placeholderStack.isHidden = true
        } else if let thumbnail {
            // 原图读不出来时退回列表缩略图：至少让用户确认这是哪一条。
            imageView.image = thumbnail
            imageView.isHidden = false
            placeholderStack.isHidden = true
        } else {
            placeholderSymbol.image = NSImage(
                systemSymbolName: "photo",
                accessibilityDescription: "图片"
            )
            placeholderLabel.stringValue = isPresent ? "无法读取图片" : "文件已移走"
        }

        infoLabel.stringValue = Self.infoText(for: entry, isPresent: isPresent)
        infoLabel.textColor = isPresent ? .secondaryLabelColor : .systemOrange

        isOpen = true
        position(relativeTo: anchor)
        window.makeKeyAndOrderFront(nil)
    }

    func close() {
        guard isOpen else { return }
        isOpen = false
        window.orderOut(nil)
        releaseContent()
        onClose?()
    }

    private func releaseContent() {
        // 大图预览可能是几十 MB；关闭即释放，不留给下一次打开当缓存。
        imageView.image = nil
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

        for view in [header, closeButton, imageSurface, infoSurface] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }

        let margin = SettingsTheme.margin
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: content.topAnchor, constant: Self.topInset),
            header.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: margin),
            // 宽度显式钉住（否则 `SettingsHeaderView` 内部的「<=」不等式
            // 会让页头宽度欠定），右端留给关闭按钮。
            header.trailingAnchor.constraint(equalTo: closeButton.leadingAnchor, constant: -16),

            closeButton.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            closeButton.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -margin),

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

        let origin: CGPoint
        if let anchor, anchor.isVisible {
            // 优先贴历史窗口左侧：两个窗口并排，列表仍然可见。
            let left = anchor.frame.minX - size.width - 12
            if left >= visible.minX + 12 {
                let y = anchor.frame.midY - size.height / 2
                origin = CGPoint(
                    x: left,
                    y: min(max(y, visible.minY + 12), visible.maxY - size.height - 12)
                )
            } else {
                origin = CGPoint(
                    x: visible.midX - size.width / 2,
                    y: visible.midY - size.height / 2
                )
            }
        } else {
            origin = CGPoint(
                x: visible.midX - size.width / 2,
                y: visible.midY - size.height / 2
            )
        }
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

        // 缓存副本的路径是 `<uuid>.png`，对用户没有意义；只说清它是副本。
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

    /// 解码阶段就降采样，峰值内存只与预览尺寸相关。
    private static func loadPreviewImage(at url: URL, maxPixelSize: Int) -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(
            source, 0, options as CFDictionary
        ) else { return nil }
        return NSImage(
            cgImage: image,
            size: NSSize(width: CGFloat(image.width), height: CGFloat(image.height))
        )
    }

    // MARK: - 动作

    @objc private func closeTapped() {
        close()
    }

    // MARK: - NSWindowDelegate

    /// 用户点标题栏红点时不会走 `close()`；这里补齐清理与回调。
    func windowWillClose(_ notification: Notification) {
        guard isOpen else { return }
        isOpen = false
        releaseContent()
        onClose?()
    }
}
