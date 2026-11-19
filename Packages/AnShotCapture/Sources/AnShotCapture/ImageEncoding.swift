//
//  ImageEncoding.swift
//  AnShotCapture
//
//  图像的落盘编码。使用 ImageIO（CGImageDestination），不引入第三方编码器。
//
//  资源纪律：编码过程由 ImageIO 管理中间缓冲，本模块不预先构造
//  完整像素缓冲再交给编码器——那是「用两份内存做一件事」。
//

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// 支持的图像输出格式。
public enum ImageFormat: Sendable {
    case png
    case jpeg(quality: CGFloat)
    case heic(quality: CGFloat)

    /// 对应的 UTType 标识符。
    var utType: UTType {
        switch self {
        case .png:            return .png
        case .jpeg:           return .jpeg
        case .heic:           return .heic
        }
    }

    /// 默认的文件扩展名。
    public var fileExtension: String {
        switch self {
        case .png:            return "png"
        case .jpeg:           return "jpg"
        case .heic:           return "heic"
        }
    }

    /// 构造带 Retina 物理分辨率元数据的编码选项。
    func properties(backingScale: CGFloat) -> CFDictionary {
        let scale = max(1.0, backingScale)
        let dpi = 72.0 * scale
        let ppm = Int((dpi / 0.0254).rounded())
        let tiffResolution: [CFString: Any] = [
            kCGImagePropertyTIFFXResolution: dpi,
            kCGImagePropertyTIFFYResolution: dpi,
            kCGImagePropertyTIFFResolutionUnit: 2,
        ]
        switch self {
        case .png:
            return [
                kCGImagePropertyDPIWidth: dpi,
                kCGImagePropertyDPIHeight: dpi,
                kCGImagePropertyTIFFDictionary: tiffResolution,
                kCGImagePropertyPNGDictionary: [
                    kCGImagePropertyPNGXPixelsPerMeter: ppm,
                    kCGImagePropertyPNGYPixelsPerMeter: ppm,
                ],
            ] as CFDictionary
        case .jpeg(let quality):
            let roundedDPI = Int(dpi.rounded())
            return [
                kCGImageDestinationLossyCompressionQuality: quality,
                kCGImagePropertyDPIWidth: dpi,
                kCGImagePropertyDPIHeight: dpi,
                kCGImagePropertyTIFFDictionary: tiffResolution,
                kCGImagePropertyJFIFDictionary: [
                    kCGImagePropertyJFIFXDensity: roundedDPI,
                    kCGImagePropertyJFIFYDensity: roundedDPI,
                    kCGImagePropertyJFIFDensityUnit: 1,
                ],
            ] as CFDictionary
        case .heic(let quality):
            return [
                kCGImageDestinationLossyCompressionQuality: quality,
                kCGImagePropertyDPIWidth: dpi,
                kCGImagePropertyDPIHeight: dpi,
                kCGImagePropertyTIFFDictionary: tiffResolution,
            ] as CFDictionary
        }
    }
}

/// 图像编码错误。
public enum ImageEncodingError: Error, Sendable {
    /// 无法创建编码目标（格式不被支持或参数非法）。
    case cannotCreateDestination(ImageFormat)
    /// 最终写入失败（通常是磁盘问题）。
    case finalizeFailed
}

extension ImageEncodingError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .cannotCreateDestination: return "无法创建图像编码目标"
        case .finalizeFailed:          return "图像写入失败"
        }
    }
}

/// 图像编码工具。
public enum ImageEncoding {

    /// 把 `CGImage` 编码为指定格式的数据。
    ///
    /// - Parameters:
    ///   - image: 待编码图像。
    ///   - format: 输出格式。
    ///   - backingScale: 屏幕物理缩放系数（2x Retina 屏写入 144 DPI）。
    /// - Returns: 编码后的数据。
    public static func data(
        from image: CGImage,
        format: ImageFormat,
        backingScale: CGFloat = 1.0
    ) throws -> Data {
        let buffer = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            buffer,
            format.utType.identifier as CFString,
            1,
            nil
        ) else {
            throw ImageEncodingError.cannotCreateDestination(format)
        }

        CGImageDestinationAddImage(destination, image, format.properties(backingScale: backingScale))

        guard CGImageDestinationFinalize(destination) else {
            throw ImageEncodingError.finalizeFailed
        }

        return buffer as Data
    }

    /// 把 `CGImage` 写入文件。
    ///
    /// 采用「先编码到内存再整体写入」还是「直接写入 URL」取决于是否有后续用途：
    /// 需要同时复制到剪贴板时用 `data(from:format:)` 复用同一份编码结果，
    /// 仅需落盘时用此方法避免多一份内存占用。
    public static func write(
        _ image: CGImage,
        to url: URL,
        format: ImageFormat,
        backingScale: CGFloat = 1.0
    ) throws {
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL,
            format.utType.identifier as CFString,
            1,
            nil
        ) else {
            throw ImageEncodingError.cannotCreateDestination(format)
        }

        CGImageDestinationAddImage(destination, image, format.properties(backingScale: backingScale))

        guard CGImageDestinationFinalize(destination) else {
            throw ImageEncodingError.finalizeFailed
        }
    }
}
