//
//  SessionExporter.swift
//  AnShotUI
//
//  会话导出：把当前编辑状态变成剪贴板内容或磁盘上的 PNG。
//
//  为什么单独成一个类型而不是塞进 OverlayController：
//  控制器管的是「窗口与会话的生命周期」，导出管的是「从状态到一幅图」，
//  两者的失败模式、可测方式都不同。混在一起会让控制器继续膨胀，
//  而导出恰恰是最需要独立验证的一环——存错图是静默失败。
//

import AnShotCore
import AppKit
import UniformTypeIdentifiers

@MainActor
enum SessionExporter {
    // MARK: - 导出前的收尾

    /// 结束所有进行中的编辑，必须在合成之前调用。
    ///
    /// `model.md` §8 的硬性要求：导出前不得静默丢弃草稿。
    /// - 正在输入的文字**按提交处理**：用户按回车导出时，
    ///   输入框里那段字就是他要的，丢掉才是数据丢失；
    /// - 尚未落笔的拖拽草稿**丢弃**：它是一笔没画完的线，
    ///   没有任何内容可以保留（此时鼠标通常还没松开，用户按的是键盘）。
    static func finishEditing(_ editor: AnnotationEditorState, scaleFactor: CGFloat) {
        if editor.isEditingText {
            editor.commitTextDraft(scaleFactor: scaleFactor)
        }
        if editor.hasDraft {
            editor.discardDraft()
        }
    }

    // MARK: - 合成

    /// 合成当前会话的导出图。
    ///
    /// 合成走 `Exporter.compose`，也就是覆盖层显示所用的同一条渲染路径——
    /// 这是 `model.md` §8 的要求，避免「看到的」与「存下来的」不一致。
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

    /// 拷贝到系统剪贴板。
    ///
    /// PNG 立即写入；TIFF **按需生成**（见 `LazyTIFFProvider`）。
    ///
    /// - Parameter pasteboard: 目标剪贴板。只有测试会传入私有剪贴板，避免碰用户的系统剪贴板。
    @discardableResult
    static func copyToPasteboard(_ image: CGImage, to pasteboard: NSPasteboard = .general) -> Bool {
        guard let png = Exporter.pngData(from: image) else {
            return false
        }

        // 再放一份 TIFF。
        // 截图的标准载体是 PNG，但一部分原生应用（文本/演示类）只认 TIFF，
        // 只给 PNG 会导致「在那些应用里粘不出来」这种看起来像 bug 的现象。
        //
        // 但不能在这里当场编码：TIFF 不压缩，一张 5K 截图就是 60MB 以上，
        // 加上位图转换，会在主线程上把「按 ⌘C」卡出明显的停顿——而绝大多数粘贴
        // 目标只读 PNG。改为声明「我能提供 TIFF」，真有应用来要时再生成。
        let item = NSPasteboardItem()
        item.setData(png, forType: .png)
        let provider = LazyTIFFProvider(png: png)
        item.setDataProvider(provider, forTypes: [.tiff])

        pasteboard.clearContents()
        guard pasteboard.writeObjects([item]) else {
            return false
        }
        // 剪贴板不保证持有数据提供者，由这里保活到它被告知「用完了」为止。
        LazyTIFFProvider.current = provider
        return true
    }

    // MARK: - 保存

    /// 保存的结果。
    ///
    /// 为什么不用 `URL?`：`nil` 无法区分「用户取消」与「写盘失败」，
    /// 而这两者的后续处理完全不同——取消应当静默地留在会话里，
    /// 失败必须把原因告诉用户，否则用户会以为图已经存好了。
    enum SaveOutcome {
        /// 已写入该 URL。
        case saved(URL)
        /// 用户主动取消，什么都没发生。
        case cancelled
        /// 写入失败。associated value 是给用户看的中文原因。
        case failed(String)
    }

    /// 按当前设置保存。
    ///
    /// - Parameter destination: 设置里选择的保存位置。
    static func save(
        _ image: CGImage,
        suggestedName: String,
        destination: SaveDestination
    ) -> SaveOutcome {
        switch destination {
        case .ask:
            return saveWithPanel(image, suggestedName: suggestedName)
        case .folder(let folder):
            return saveToFolder(image, suggestedName: suggestedName, folder: folder)
        }
    }

    /// 弹出保存面板并写入 PNG。
    static func saveWithPanel(_ image: CGImage, suggestedName: String) -> SaveOutcome {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedName
        panel.allowedContentTypes = [.png]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.title = "保存截图"

        // 本应用是无 Dock 图标的辅助程序，默认不是活跃应用。
        // 不激活的话系统面板会出现在后台、用户看不到却以为「按了没反应」。
        NSApp.activate(ignoringOtherApps: true)

        guard panel.runModal() == .OK, let url = panel.url else {
            return .cancelled
        }

        do {
            try Exporter.writePNG(image, to: url)
            return .saved(url)
        } catch {
            return .failed("无法写入文件：\(url.path)")
        }
    }

    /// 直接写入固定文件夹。
    private static func saveToFolder(
        _ image: CGImage,
        suggestedName: String,
        folder: URL
    ) -> SaveOutcome {
        // 目录可能在设置之后被删除或改名——用户是在访达里选的它，
        // 而访达不受本应用控制。这类失效必须在写入之前查出来，
        // 否则拿到的错误码无法翻译成用户看得懂的说明。
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return .failed("保存文件夹不存在或已被移动：\(folder.path)")
        }

        let url = reserveUniqueURL(in: folder, fileName: suggestedName)
        guard let url else {
            return .failed("无法在所选文件夹中创建文件：\(folder.path)")
        }
        do {
            try Exporter.writePNG(image, to: url)
            return .saved(url)
        } catch {
            // 写入失败要把占位文件清掉，否则会在用户目录里留下一个 0 字节垃圾。
            try? FileManager.default.removeItem(at: url)
            return .failed("无法写入文件：\(url.path)")
        }
    }

    /// 直接写入指定路径。
    ///
    /// 诊断专用：绕开需要人工点击的保存面板，只验证写入路径本身。
    static func save(_ image: CGImage, to url: URL) throws {
        try Exporter.writePNG(image, to: url)
    }

    /// 在目标目录里以**独占方式**占一个文件名，返回可写的 URL。
    ///
    /// 为什么不是「先查存在性、再写入」：那是一个 check-then-write 竞态。
    /// 两次操作之间另一个进程可以建出同名文件，于是我们的写入把它覆盖掉——
    /// 而命名冲突处理存在的全部意义就是「不覆盖」。
    /// `O_EXCL` 让「检查」与「占用」成为同一个原子操作。
    ///
    /// 冲突时依次尝试 `截图 2026-09-12 18-30-05-2.png`、`-3`……
    /// （命名规则与录制产物、自动化截图共用 `OutputPath.candidate`，同一目录里只有一种风格。）
    ///
    /// 为什么不直接覆盖：默认文件名的时间戳精度只到秒，同一秒内连拍两张
    /// 完全可能（热键双击、自动化脚本）。静默覆盖等于丢数据，
    /// 而截图往往是「已经过去了就补不回来」的内容。
    private static func reserveUniqueURL(in folder: URL, fileName: String) -> URL? {
        let desired = folder.appendingPathComponent(fileName)

        // 上限是防御性的：一千次同名说明目录状态异常，
        // 继续循环只会让界面卡住。
        for attempt in 0...OutputPath.maximumAttempts {
            let url = OutputPath.candidate(for: desired, attempt: attempt)
            let descriptor = open(url.path, O_CREAT | O_EXCL | O_WRONLY, 0o644)
            if descriptor >= 0 {
                close(descriptor)
                return url
            }
            // 不是「已存在」就说明是权限之类的硬失败，
            // 换个名字试下去不会变好。
            if errno != EEXIST {
                return nil
            }
        }
        return nil
    }
}

// MARK: - 按需 TIFF

/// 剪贴板 TIFF 的按需提供者。
///
/// 持有的是**已编码的 PNG**，而不是全尺寸位图：PNG 本来就已放进剪贴板，
/// 体量是压缩后的；全尺寸位图则不得在会话之外长驻（M3-6 存储契约，
/// 唯一合法的长驻点是 Pin）。真有应用来要 TIFF 时，从 PNG 解码再转。
///
/// 应用退出前 AppKit 会向尚未兑现的提供者索取数据，所以退出后照样能粘贴。
@MainActor
private final class LazyTIFFProvider: NSObject, NSPasteboardItemDataProvider {

    /// 当前剪贴板上那份数据的提供者。新的一次拷贝会替换它。
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

    /// 剪贴板已被别的内容取代：不再需要保活。
    ///
    /// 不假定回调线程：切回主 actor 再改共享的保活引用。
    nonisolated func pasteboardFinishedWithDataProvider(_ pasteboard: NSPasteboard) {
        Task { @MainActor in
            if Self.current === self {
                Self.current = nil
            }
        }
    }
}
