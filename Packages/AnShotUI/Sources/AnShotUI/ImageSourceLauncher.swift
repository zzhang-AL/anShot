//
//  ImageSourceLauncher.swift
//  AnShotUI
//
//  外部图片的入口：文件面板、剪贴板、磁盘路径。
//
//  ── 为什么统一用 ImageIO ──────────────────────────────────
//
//  `NSImage(contentsOf:)` 会按当前显示环境做尺寸拟合与色彩转换，
//  拿到的像素与原文件不一定逐位一致；而对标注来说，底图一旦被重采样，
//  导出结果就再也回不到「用户选的那张图」。`CGImageSource` 直接给出
//  解码后的位图，颜色空间、alpha、尺寸都保持文件里的值。
//
//  同一个解码器也保证 HEIC / TIFF / JPEG 等格式的行为一致：
//  只要 ImageIO 能解，就能进来，不需要按后缀维护一张白名单。
//
//  ── 不修改源文件 ──────────────────────────────────────────
//
//  这里只读：不转码、不写回、不改元数据。用户可能选中「照片」里的原图，
//  任何写操作都会造成不可逆的损失。
//

import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

@MainActor
enum ImageSourceLauncher {

    /// 打开面板选一张图；返回图像与源 URL。
    ///
    /// 取消、选中的文件无法解码都返回 `nil`。这两者在这里不做区分：
    /// 调用方只关心「有没有得到可标注的图」，而失败原因（权限、损坏文件）
    /// 在文件面板里已经由系统给出反馈。
    static func chooseImage() -> (image: CGImage, url: URL)? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.resolvesAliases = true
        // 用 UTType 而不是后缀列表：HEIC / TIFF / JPEG / PNG 以及系统将来
        // 能解的新格式都自动包含，不需要在每次系统升级后补后缀。
        panel.allowedContentTypes = [.image]
        panel.prompt = "打开"
        panel.message = "选择要标注的图片"
        panel.directoryURL = FileManager.default
            .urls(for: .picturesDirectory, in: .userDomainMask)
            .first

        guard panel.runModal() == .OK, let url = panel.url else {
            return nil
        }
        guard let image = loadImage(at: url) else {
            return nil
        }
        return (image, url)
    }

    /// 从剪贴板取图。
    ///
    /// 先按「图像数据」读，再退回「文件 URL」：
    /// 在访达里复制文件时，剪贴板里只有 URL，没有图像数据；而在预览、
    /// 浏览器里复制位图时则相反。两条路都覆盖，才不会出现「同一个复制动作，
    /// 有时能贴有时不能贴」。
    static func imageFromPasteboard() -> CGImage? {
        let pasteboard = NSPasteboard.general

        // 按声明的 UTI 遍历，而不是写死 .png/.tiff：
        // 部分应用只提供 HEIC/JPEG 或动态的 public.image 承诺类型。
        for item in pasteboard.pasteboardItems ?? [] {
            for type in item.types {
                guard let utType = UTType(type.rawValue),
                      utType.conforms(to: .image),
                      let data = item.data(forType: type),
                      let image = decode(data) else {
                    continue
                }
                return image
            }
        }

        // 复制文件：读的是文件内容，不写回，因此与 loadImage 同一套保证。
        let options: [NSPasteboard.ReadingOptionKey: Any] = [
            .urlReadingFileURLsOnly: true,
        ]
        if let urls = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: options
        ) as? [URL], let url = urls.first, let image = loadImage(at: url) {
            return image
        }

        // 最后兜底：少数应用只注册了 NSImage（例如 PDF 预览）。
        // 走 NSImage 会经过 AppKit 的绘制路径，因此只在前两条都失败时使用。
        if let image = NSImage(pasteboard: pasteboard), let decoded = cgImage(from: image) {
            return decoded
        }
        return nil
    }

    /// 载入磁盘图片（不修改源文件）。
    ///
    /// - Parameter url: 任意图片文件；支持 ImageIO 能解的全部格式。
    /// - Returns: 解码后的位图；文件不存在、无权限或格式不支持时为 `nil`。
    static func loadImage(at url: URL) -> CGImage? {
        // 未启用沙箱时返回 false，没有副作用；一旦将来打开沙箱，
        // 从 NSOpenPanel 拿到的 URL 需要这段配平才能读。
        let didStartAccessing = url.startAccessingSecurityScopedResource()
        defer {
            if didStartAccessing {
                url.stopAccessingSecurityScopedResource()
            }
        }

        // `kCGImageSourceShouldCacheImmediately` 不能省：安全作用域的访问
        // 会在本函数返回时结束，而 ImageIO 默认是惰性解码——若把解码留到
        // 之后，读文件时权限已经收回，图像表现为空白或直接失败。
        let options = [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, options) else {
            return nil
        }
        return CGImageSourceCreateImageAtIndex(source, 0, options)
    }

    // MARK: - 解码

    /// 把剪贴板里的图像数据解码成位图。
    private static func decode(_ data: Data) -> CGImage? {
        let options = [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, options) else {
            return nil
        }
        return CGImageSourceCreateImageAtIndex(source, 0, options)
    }

    /// `NSImage` 兜底路径的位图转换。
    private static func cgImage(from image: NSImage) -> CGImage? {
        var proposed = CGRect(origin: .zero, size: image.size)
        guard proposed.width > 0, proposed.height > 0 else {
            return nil
        }
        return image.cgImage(forProposedRect: &proposed, context: nil, hints: nil)
    }
}
