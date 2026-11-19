//
//  SessionExporter.swift
//  AnShotUI
//
//  会话导出：把当前编辑状态变成剪贴板内容或磁盘上的 PNG / JPEG / HEIC / WebP。
//
//  Phase 5.1 升级：
//    - 全面支持 PNG / JPEG / HEIC / 纯 Swift 无损 WebP 多格式编码与 Retina 物理 DPI；
//    - `NSSavePanel` 挂载格式选择与质量滑块 AccessoryView，切换格式即时联动文件名后缀；
//    - PNG 落盘与剪贴板接入 MIT `oxipng -o 4 --strip safe` 两阶段后台无损精压；
//    - 剪贴板按需 TIFF 支持通过设置开关按需启闭（默认开启）；
//    - 固定目录失效时在交互路径自动降级弹出保存面板，确保永不丢图。
//

import AnShotCapture
import AnShotCore
import AppKit
import UniformTypeIdentifiers

@MainActor
enum SessionExporter {
    // MARK: - 导出前的收尾

    static func finishEditing(_ editor: AnnotationEditorState, scaleFactor: CGFloat) {
        if editor.isEditingText {
            editor.commitTextDraft(scaleFactor: scaleFactor)
        }
        if editor.hasDraft {
            editor.discardDraft()
        }
    }

    // MARK: - 合成

    static func compose(
        editor: AnnotationEditorState,
        backdrop: CGImage,
        scaleFactor: CGFloat
    ) -> CGImage? {
        finishEditing(editor, scaleFactor: scaleFactor)
        return Exporter.compose(
            backdrop: backdrop,
            selection: editor.selection,
            annotations: editor.annotations
        )
    }

    // MARK: - 剪贴板

    struct PasteboardCopyResult {
        let pngData: Data
        let didCopy: Bool
    }

    /// 拷贝到系统剪贴板，并把**编码好的 PNG**一起交还给调用方。
    ///
    /// - Parameters:
    ///   - image: 待复制图像。
    ///   - backingScale: 屏幕物理缩放系数（2x Retina 写 144 DPI）。
    ///   - includeLazyTIFF: 是否附带按需 TIFF 兼容老应用（默认开启，可由设置关闭以降低第三方剪贴板工具内存尖峰）。
    ///   - enableLosslessOptimization: 是否在后台触发 MIT `oxipng` 精压并在 `changeCount` 未变时回写剪贴板。
    ///   - pasteboard: 目标剪贴板（测试注入私有剪贴板避免污染系统剪贴板）。
    static func copyToPasteboardWithPNG(
        _ image: CGImage,
        backingScale: CGFloat = 1.0,
        includeLazyTIFF: Bool = true,
        enableLosslessOptimization: Bool = false,
        to pasteboard: NSPasteboard = .general
    ) -> PasteboardCopyResult? {
        guard let png = Exporter.pngData(from: image, backingScale: backingScale) else {
            return nil
        }

        let item = NSPasteboardItem()
        item.setData(png, forType: .png)
        var provider: LazyTIFFProvider?
        if includeLazyTIFF {
            let lazy = LazyTIFFProvider(png: png)
            item.setDataProvider(lazy, forTypes: [.tiff])
            provider = lazy
        }

        pasteboard.clearContents()
        guard pasteboard.writeObjects([item]) else {
            return PasteboardCopyResult(pngData: png, didCopy: false)
        }
        LazyTIFFProvider.current = provider

        // Phase 1：后台两阶段精压（仅当剪贴板期间未被用户改写才静默替换为更小无损 PNG）。
        if enableLosslessOptimization, PNGOptimizer.locateExecutable() != nil {
            let expectedChangeCount = pasteboard.changeCount
            let isGeneral = (pasteboard === NSPasteboard.general)
            if isGeneral {
                Task.detached(priority: .utility) {
                    guard let optimized = PNGOptimizer.optimizeData(png) else { return }
                    await MainActor.run {
                        let pb = NSPasteboard.general
                        guard pb.changeCount == expectedChangeCount else { return }
                        let replacement = NSPasteboardItem()
                        replacement.setData(optimized, forType: .png)
                        var replacementProvider: LazyTIFFProvider?
                        if includeLazyTIFF {
                            let lazy = LazyTIFFProvider(png: optimized)
                            replacement.setDataProvider(lazy, forTypes: [.tiff])
                            replacementProvider = lazy
                        }
                        pb.clearContents()
                        if pb.writeObjects([replacement]) {
                            LazyTIFFProvider.current = replacementProvider
                        }
                    }
                }
            }
        }

        return PasteboardCopyResult(pngData: png, didCopy: true)
    }

    /// 拷贝到系统剪贴板。
    @discardableResult
    static func copyToPasteboard(
        _ image: CGImage,
        backingScale: CGFloat = 1.0,
        includeLazyTIFF: Bool = true,
        enableLosslessOptimization: Bool = false,
        to pasteboard: NSPasteboard = .general
    ) -> Bool {
        copyToPasteboardWithPNG(
            image,
            backingScale: backingScale,
            includeLazyTIFF: includeLazyTIFF,
            enableLosslessOptimization: enableLosslessOptimization,
            to: pasteboard
        )?.didCopy ?? false
    }

    // MARK: - 保存

    enum SaveOutcome {
        case saved(URL)
        case cancelled
        case failed(String)
    }

    /// 将建议文件名中的扩展名替换为指定格式对应的扩展名。
    static func filename(_ suggestedName: String, for format: ImageFormat) -> String {
        let ns = suggestedName as NSString
        let base = ns.deletingPathExtension
        let stem = base.isEmpty ? suggestedName : base
        return "\(stem).\(format.fileExtension)"
    }

    /// 按当前设置保存（支持 PNG / JPEG / HEIC / WebP、后台 MIT `oxipng` 精压与目录失效降级弹窗）。
    static func save(
        _ image: CGImage,
        suggestedName: String,
        destination: SaveDestination,
        backingScale: CGFloat = 1.0,
        formatOption: ExportFormatOption = .png,
        quality: Double = 0.88,
        enablePNGOptimization: Bool = false,
        fallbackToPanelWhenFolderMissing: Bool = false
    ) -> SaveOutcome {
        switch destination {
        case .ask:
            return saveWithPanel(
                image,
                suggestedName: suggestedName,
                backingScale: backingScale,
                initialFormat: formatOption,
                initialQuality: quality,
                enablePNGOptimization: enablePNGOptimization
            )
        case .folder(let folder):
            let outcome = saveToFolder(
                image,
                suggestedName: suggestedName,
                folder: folder,
                backingScale: backingScale,
                formatOption: formatOption,
                quality: quality,
                enablePNGOptimization: enablePNGOptimization
            )
            if case .failed = outcome, fallbackToPanelWhenFolderMissing {
                var isDir: ObjCBool = false
                let folderValid = FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDir) && isDir.boolValue
                if !folderValid {
                    return saveWithPanel(
                        image,
                        suggestedName: suggestedName,
                        backingScale: backingScale,
                        initialFormat: formatOption,
                        initialQuality: quality,
                        enablePNGOptimization: enablePNGOptimization
                    )
                }
            }
            return outcome
        }
    }

    /// 弹出保存面板（挂载多格式与质量 AccessoryView）并写入目标文件。
    static func saveWithPanel(
        _ image: CGImage,
        suggestedName: String,
        backingScale: CGFloat = 1.0,
        initialFormat: ExportFormatOption = .png,
        initialQuality: Double = 0.88,
        enablePNGOptimization: Bool = false
    ) -> SaveOutcome {
        let initialResolved = ImageEncoding.effectiveFormat(
            for: image,
            requested: initialFormat.imageFormat(quality: initialQuality)
        )
        let panel = NSSavePanel()
        panel.nameFieldStringValue = filename(suggestedName, for: initialResolved)
        panel.allowedContentTypes = [initialResolved.utType]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.title = "保存截图"

        let accessory = SavePanelFormatAccessoryView(
            initialFormat: initialFormat,
            initialQuality: initialQuality,
            onSelectionChanged: { [weak panel] option, quality in
                guard let panel else { return }
                let resolved = ImageEncoding.effectiveFormat(
                    for: image,
                    requested: option.imageFormat(quality: quality)
                )
                panel.allowedContentTypes = [resolved.utType]
                panel.nameFieldStringValue = Self.filename(panel.nameFieldStringValue, for: resolved)
            }
        )
        panel.accessoryView = accessory

        NSApp.activate(ignoringOtherApps: true)

        guard panel.runModal() == .OK, let url = panel.url else {
            return .cancelled
        }

        let chosenFormat = ImageEncoding.effectiveFormat(
            for: image,
            requested: accessory.selectedFormat.imageFormat(quality: accessory.selectedQuality)
        )

        do {
            try writeEncoded(
                image,
                to: url,
                format: chosenFormat,
                backingScale: backingScale,
                enablePNGOptimization: enablePNGOptimization
            )
            return .saved(url)
        } catch {
            return .failed("无法写入文件：\(url.path)")
        }
    }

    /// 直接写入固定文件夹（原子占位不覆盖，超 16384px WebP 自动降级 PNG）。
    private static func saveToFolder(
        _ image: CGImage,
        suggestedName: String,
        folder: URL,
        backingScale: CGFloat = 1.0,
        formatOption: ExportFormatOption = .png,
        quality: Double = 0.88,
        enablePNGOptimization: Bool = false
    ) -> SaveOutcome {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return .failed("保存文件夹不存在或已被移动：\(folder.path)")
        }

        let effective = ImageEncoding.effectiveFormat(
            for: image,
            requested: formatOption.imageFormat(quality: quality)
        )
        let targetName = filename(suggestedName, for: effective)
        let url = reserveUniqueURL(in: folder, fileName: targetName)
        guard let url else {
            return .failed("无法在所选文件夹中创建文件：\(folder.path)")
        }
        do {
            try writeEncoded(
                image,
                to: url,
                format: effective,
                backingScale: backingScale,
                enablePNGOptimization: enablePNGOptimization
            )
            return .saved(url)
        } catch {
            try? FileManager.default.removeItem(at: url)
            return .failed("无法写入文件：\(url.path)")
        }
    }

    /// 统一落盘入口：PNG 同步写出后可选调度后台 `oxipng` 无损精压，其余格式经 `ImageEncoding` 写出。
    private static func writeEncoded(
        _ image: CGImage,
        to url: URL,
        format: ImageFormat,
        backingScale: CGFloat,
        enablePNGOptimization: Bool
    ) throws {
        if case .png = format {
            try Exporter.writePNG(image, to: url, backingScale: backingScale)
            PNGOptimizer.scheduleBackgroundOptimization(for: url, enabled: enablePNGOptimization)
        } else {
            try ImageEncoding.write(image, to: url, format: format, backingScale: backingScale)
        }
    }

    /// 直接写入指定路径（诊断专用）。
    static func save(_ image: CGImage, to url: URL, backingScale: CGFloat = 1.0) throws {
        try Exporter.writePNG(image, to: url, backingScale: backingScale)
    }

    private static func reserveUniqueURL(in folder: URL, fileName: String) -> URL? {
        let desired = folder.appendingPathComponent(fileName)
        for attempt in 0...OutputPath.maximumAttempts {
            let url = OutputPath.candidate(for: desired, attempt: attempt)
            let descriptor = open(url.path, O_CREAT | O_EXCL | O_WRONLY, 0o644)
            if descriptor >= 0 {
                close(descriptor)
                return url
            }
            if errno != EEXIST {
                return nil
            }
        }
        return nil
    }
}

// MARK: - 保存面板格式与质量附件视图

@MainActor
private final class SavePanelFormatAccessoryView: NSView {
    private let formatPopup = NSPopUpButton()
    private let qualityTitle = NSTextField(labelWithString: "质量")
    private let qualitySlider = NSSlider(value: 0.88, minValue: 0.1, maxValue: 1.0, target: nil, action: nil)
    private let qualityValueLabel = NSTextField(labelWithString: "88%")
    private let onSelectionChanged: (ExportFormatOption, Double) -> Void

    var selectedFormat: ExportFormatOption {
        let index = max(0, min(ExportFormatOption.allCases.count - 1, formatPopup.indexOfSelectedItem))
        return ExportFormatOption.allCases[index]
    }

    var selectedQuality: Double {
        min(1.0, max(0.1, qualitySlider.doubleValue))
    }

    init(
        initialFormat: ExportFormatOption,
        initialQuality: Double,
        onSelectionChanged: @escaping (ExportFormatOption, Double) -> Void
    ) {
        self.onSelectionChanged = onSelectionChanged
        super.init(frame: NSRect(x: 0, y: 0, width: 380, height: 48))

        let formatLabel = NSTextField(labelWithString: "格式")
        formatLabel.font = .systemFont(ofSize: 12, weight: .medium)
        formatLabel.textColor = .secondaryLabelColor

        for option in ExportFormatOption.allCases {
            formatPopup.addItem(withTitle: option.displayName)
        }
        if let idx = ExportFormatOption.allCases.firstIndex(of: initialFormat) {
            formatPopup.selectItem(at: idx)
        }
        formatPopup.target = self
        formatPopup.action = #selector(formatChanged)

        qualityTitle.font = .systemFont(ofSize: 12, weight: .medium)
        qualityTitle.textColor = .secondaryLabelColor

        qualitySlider.doubleValue = min(1.0, max(0.1, initialQuality))
        qualitySlider.isContinuous = true
        qualitySlider.target = self
        qualitySlider.action = #selector(qualityChanged)

        qualityValueLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        qualityValueLabel.textColor = .secondaryLabelColor

        let row = NSStackView(views: [formatLabel, formatPopup, qualityTitle, qualitySlider, qualityValueLabel])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)

        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            row.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -16),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
            qualitySlider.widthAnchor.constraint(equalToConstant: 96),
            qualityValueLabel.widthAnchor.constraint(equalToConstant: 36),
        ])

        refreshQualityControls()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("不支持从 nib 构造")
    }

    private func refreshQualityControls() {
        let supports = selectedFormat.supportsQuality
        qualityTitle.isHidden = !supports
        qualitySlider.isHidden = !supports
        qualityValueLabel.isHidden = !supports
        qualityValueLabel.stringValue = "\(Int((selectedQuality * 100).rounded()))%"
    }

    @objc private func formatChanged() {
        refreshQualityControls()
        onSelectionChanged(selectedFormat, selectedQuality)
    }

    @objc private func qualityChanged() {
        refreshQualityControls()
        onSelectionChanged(selectedFormat, selectedQuality)
    }
}

// MARK: - 按需 TIFF

@MainActor
private final class LazyTIFFProvider: NSObject, NSPasteboardItemDataProvider {

    static var current: LazyTIFFProvider?

    private let png: Data

    init(png: Data) {
        self.png = png
    }

    nonisolated func pasteboard(
        _ pasteboard: NSPasteboard?,
        item: NSPasteboardItem,
        provideDataForType type: NSPasteboard.PasteboardType
    ) {
        guard type == .tiff,
              let tiff = NSBitmapImageRep(data: png)?.tiffRepresentation else {
            return
        }
        item.setData(tiff, forType: .tiff)
    }

    nonisolated func pasteboardFinishedWithDataProvider(_ pasteboard: NSPasteboard) {
        Task { @MainActor in
            if Self.current === self {
                Self.current = nil
            }
        }
    }
}
