//
//  ImageScaling.swift
//  AnShotAutomation
//
//  截图的下采样。
//
//  ── 为什么必须有这一步 ───────────────────────────────────────
//
//  一次全屏 Retina 截图是 2940×1912 量级。它以 PNG 编码、
//  再以 base64 进入 MCP 响应时，传输量与模型的图像 token 都会很大，
//  而「看界面调布局」这类用途并不需要每个像素都原样保留。
//
//  因此默认给长边设一个上限。关键约束：**只在超限时缩放**，
//  且必须等比——非等比缩放会让界面元素变形，反而误导调试判断。
//
//  ── 为什么缩放失败要抛错而不是回退原图 ───────────────────────
//
//  曾有一版在重绘失败时 `?? image` 静默返回超限的原图。那让
//  「输出不会超过 max_size」这条契约静默失效：调用方按上限安排
//  了 token 预算、或按上限判断了图像可信度，却拿到一张大得多的图，
//  而且**没有任何迹象表明发生过回退**。
//  失败就说失败，把决定权交回调用方。
//

import CoreGraphics
import Foundation

/// 下采样错误。
public enum ImageScalingError: Error {
    /// 重绘失败（通常是内存不足）。
    ///
    /// 带上源与目标尺寸：这是判断「是不是尺寸太大导致的」的唯一线索。
    case scaleFailed(source: String, target: String)
}

extension ImageScalingError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .scaleFailed(let source, let target):
            return "图像缩放失败（\(source) → \(target)）。"
                + "通常是内存不足；可改用更小的区域或调整 max_size。"
        }
    }
}

/// 图像缩放工具。
public enum ImageScaling {

    /// 长边默认上限（像素）。
    ///
    /// 2560 的取值理由：足以看清 Retina 屏上的正文与控件边界，
    /// 又明显低于 6K 屏的全尺寸（6016×3384），
    /// 把单张图的数据量压到可接受范围。调用方可显式覆盖。
    public static let defaultMaxLongEdge = 2560

    /// 按长边上限等比缩小。
    ///
    /// - Parameters:
    ///   - image: 原图。
    ///   - maxLongEdge: 长边像素上限。`<= 0` 表示不缩放。
    /// - Returns: 缩放后的图；未超限时**原样返回同一个对象**（不复制像素）。
    /// - Throws: `ImageScalingError.scaleFailed`
    public static func downscale(
        _ image: CGImage,
        maxLongEdge: Int
    ) throws -> CGImage {
        guard maxLongEdge > 0 else { return image }

        let sourceWidth = CGFloat(image.width)
        let sourceHeight = CGFloat(image.height)
        guard sourceWidth > 0, sourceHeight > 0 else { return image }

        let longEdge = max(sourceWidth, sourceHeight)
        let limit = CGFloat(maxLongEdge)
        // 未超限：直接返回原对象，避免一次无意义的重绘与内存拷贝
        guard longEdge > limit else { return image }

        let ratio = limit / longEdge
        let targetWidth = max(1, Int((sourceWidth * ratio).rounded()))
        let targetHeight = max(1, Int((sourceHeight * ratio).rounded()))

        guard let scaled = resize(image, width: targetWidth, height: targetHeight) else {
            throw ImageScalingError.scaleFailed(
                source: "\(image.width)×\(image.height)",
                target: "\(targetWidth)×\(targetHeight)"
            )
        }

        return scaled
    }

    /// 缩放到指定像素尺寸。
    ///
    /// 用 `CGContext` 而非 `CGImageSource` 的缩略图选项：
    /// 后者需要先把图编码成数据流，而这里的图已在内存中，多此一举。
    ///
    /// - Returns: 失败时返回 nil，由调用方决定如何上报。
    public static func resize(
        _ image: CGImage,
        width: Int,
        height: Int
    ) -> CGImage? {
        guard width > 0, height > 0 else { return nil }

        // 用 sRGB 而非 `image.colorSpace`：截图可能带 Display P3 等广色域，
        // 直接沿用会把色彩空间信息一并带进编码结果，而这里的目标是
        // 「给模型看的图」，统一到 sRGB 可避免不同屏幕间颜色不一致。
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else {
            return nil
        }

        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue
        ) else {
            return nil
        }

        // .high：调试用图的重点是「看得清字与边界」，插值质量不该省
        context.interpolationQuality = .high
        context.draw(
            image,
            in: CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height))
        )

        return context.makeImage()
    }
}
