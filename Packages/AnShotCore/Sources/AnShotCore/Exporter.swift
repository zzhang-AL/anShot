import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// 导出错误。
public enum ExportError: Error, LocalizedError, Equatable {
    /// 合成失败（选区非法、上下文创建失败等）。
    case renderFailed
    /// 编码为 PNG 失败。
    case encodingFailed
    /// 写文件失败。
    case writeFailed(String)

    public var errorDescription: String? {
        switch self {
        case .renderFailed:
            return "无法生成图像：选区无效或渲染失败"
        case .encodingFailed:
            return "无法编码为 PNG"
        case let .writeFailed(path):
            return "无法写入文件：\(path)"
        }
    }
}

/// 导出器：把「底图 + 标注」合成为可直接保存或拷贝的图像。
///
/// 职责边界很清楚——**它不产生任何新的绘制语义**。
/// 合成一律走 `AnnotationRenderer.render(backdrop:selection:annotations:)`，
/// 也就是覆盖层显示用的同一个函数（`model.md` §8 的硬性要求）。
/// 显示与导出各写一套渲染，迟早会出现「屏幕上看到的和存下来的不一样」，
/// 而且那种偏差极难被发现。
///
/// 单位与对齐规则同样由渲染器统一负责（向外取整、整数像素落位、sRGB、不透明），
/// 本类型只负责编码与落盘。
public enum Exporter {
    // MARK: - 合成

    /// 把当前编辑状态合成为导出图。
    ///
    /// - Parameters:
    ///   - backdrop: 冻结的底图（像素坐标）
    ///   - selection: 选区（底图像素坐标，可为小数——渲染器会向外取整）
    ///   - annotations: 标注序列，数组索引即 z 序
    /// - Returns: 合成结果；参数非法或渲染失败时返回 `nil`
    public static func compose(
        backdrop: CGImage,
        selection: PixelRect,
        annotations: [Annotation],
        preservesAlpha: Bool = true
    ) -> CGImage? {
        AnnotationRenderer.render(
            backdrop: backdrop,
            selection: selection,
            annotations: annotations,
            preservesAlpha: preservesAlpha
        )
    }

    // MARK: - 编码

    /// 构造携带屏幕原生 Retina 物理分辨率的 PNG 编码属性（`72 × backingScale` DPI 及 `pHYs`）。
    ///
    /// 缺失该元数据时，macOS 预览、备忘录、浏览器等会回落为 72 DPI，
    /// 将 2x Retina 截图按 200% 线性插值放大显示导致发虚。
    public static func pngProperties(backingScale: CGFloat) -> CFDictionary {
        let scale = max(1.0, backingScale)
        let dpi = 72.0 * scale
        let ppm = Int((dpi / 0.0254).rounded())
        return [
            kCGImagePropertyDPIWidth: dpi,
            kCGImagePropertyDPIHeight: dpi,
            kCGImagePropertyTIFFDictionary: [
                kCGImagePropertyTIFFXResolution: dpi,
                kCGImagePropertyTIFFYResolution: dpi,
                kCGImagePropertyTIFFResolutionUnit: 2,
            ],
            kCGImagePropertyPNGDictionary: [
                kCGImagePropertyPNGXPixelsPerMeter: ppm,
                kCGImagePropertyPNGYPixelsPerMeter: ppm,
            ],
        ] as CFDictionary
    }

    /// 编码为 PNG 数据（供剪贴板使用）。
    public static func pngData(from image: CGImage, backingScale: CGFloat = 1.0) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            return nil
        }

        CGImageDestinationAddImage(destination, image, pngProperties(backingScale: backingScale))
        guard CGImageDestinationFinalize(destination) else {
            return nil
        }

        return data as Data
    }

    /// 直接写 PNG 文件。
    ///
    /// 用 `CGImageDestinationCreateWithURL` 而不是先编码成 `Data` 再写：
    /// 后者会同时持有一份完整的 PNG 字节流，在 6K 图上是不必要的一笔内存。
    public static func writePNG(_ image: CGImage, to url: URL, backingScale: CGFloat = 1.0) throws {
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            throw ExportError.encodingFailed
        }

        CGImageDestinationAddImage(destination, image, pngProperties(backingScale: backingScale))
        guard CGImageDestinationFinalize(destination) else {
            throw ExportError.writeFailed(url.path)
        }
    }

    // MARK: - 一步到位

    /// 合成并写 PNG。
    public static func writePNG(
        backdrop: CGImage,
        selection: PixelRect,
        annotations: [Annotation],
        to url: URL,
        backingScale: CGFloat = 1.0,
        preservesAlpha: Bool = true
    ) throws {
        guard let image = compose(
            backdrop: backdrop,
            selection: selection,
            annotations: annotations,
            preservesAlpha: preservesAlpha
        ) else {
            throw ExportError.renderFailed
        }

        try writePNG(image, to: url, backingScale: backingScale)
    }

    /// 合成并编码 PNG 数据。
    public static func pngData(
        backdrop: CGImage,
        selection: PixelRect,
        annotations: [Annotation],
        backingScale: CGFloat = 1.0,
        preservesAlpha: Bool = true
    ) throws -> Data {
        guard let image = compose(
            backdrop: backdrop,
            selection: selection,
            annotations: annotations,
            preservesAlpha: preservesAlpha
        ) else {
            throw ExportError.renderFailed
        }

        guard let data = pngData(from: image, backingScale: backingScale) else {
            throw ExportError.encodingFailed
        }

        return data
    }

    // MARK: - 文件名

    /// 保护静态 `DateFormatter` 的互斥锁，保证多线程安全复用。
    private static let fileNameFormatterLock = NSLock()
    private static let fileNameFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH-mm-ss"
        return formatter
    }()

    /// 生成默认文件名，例如 `截图 2026-09-12 18-30-05.png`。
    ///
    /// 用 `-` 而不是 `:`：macOS 上文件名里的 `:` 在 Finder 中会显示成 `/`。
    public static func defaultFileName(at date: Date = Date()) -> String {
        let formatted = fileNameFormatterLock.withLock {
            fileNameFormatter.string(from: date)
        }
        return "截图 \(formatted).png"
    }
}
