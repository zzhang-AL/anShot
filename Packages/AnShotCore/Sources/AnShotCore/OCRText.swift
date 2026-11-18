//
//  OCRText.swift
//  AnShotCore
//
//  OCR 结果模型与坐标转换。
//
//  ── 契约点名的最高易错点 ──────────────────────────────────
//
//  Vision 的 `boundingBox` 是**归一化坐标（0–1）、原点左下**；
//  本项目模型统一是**像素坐标、原点左上**。两者在**两个维度上都不同**：
//  既要乘尺寸，又要翻 y。只做其中一步，文字框就会整体上下错位。
//
//  转换**只在这里发生一次**：模块之外只见到像素坐标（契约 §4.2）。
//  识别侧的代码不允许自己算包围盒。
//

import CoreGraphics
import Foundation

/// 识别出的一行文字。
public struct OCRTextLine: Equatable, Sendable {

    /// 首选识别文本。
    public let text: String

    /// 备选识别结果（用于用户纠正）。
    public let candidates: [String]

    /// 置信度 `0...1`。
    public let confidence: Double

    /// 包围盒：**像素坐标、原点左上**（模型坐标系，非 Vision 坐标系）。
    public let boundingBox: PixelRect

    public init(text: String, candidates: [String], confidence: Double, boundingBox: PixelRect) {
        self.text = text
        self.candidates = candidates
        self.confidence = confidence
        self.boundingBox = boundingBox
    }
}

/// 一次 OCR 的结果。
public struct OCRResult: Equatable, Sendable {

    /// 按阅读顺序（上→下，左→右）排序的文本行。
    public let lines: [OCRTextLine]

    /// 识别时的图像像素尺寸——**包围盒的参照系**，必须随结果一同保存。
    public let imagePixelSize: PixelSize

    /// 这份包围盒有多可信。
    ///
    /// 默认 `.precise`，因此既有调用点（全部基于 Apple Vision）行为不变；
    /// 云端 provider 显式传 `.unavailable`，此时每行的 `boundingBox` 恒为零矩形。
    /// 消费方**必须**先看这个字段再决定能不能把坐标用于对齐
    /// （理由见 `OCRProvider.swift` 的文件头）。
    public let coordinateCapability: OCRCoordinateCapability

    public init(
        lines: [OCRTextLine],
        imagePixelSize: PixelSize,
        coordinateCapability: OCRCoordinateCapability = .precise
    ) {
        self.lines = lines
        self.imagePixelSize = imagePixelSize
        self.coordinateCapability = coordinateCapability
    }

    /// 纯文本（按行拼接），供复制/导出。
    public var plainText: String {
        lines.map(\.text).joined(separator: "\n")
    }

    public var isEmpty: Bool { lines.isEmpty }

    /// 按阅读顺序排序：先上后下（`midY` 小的在前），同一行内先左后右。
    ///
    /// Vision 返回的顺序不保证是阅读顺序；不排的话复制出来的文字会是乱的。
    /// 同一行的判定用两阶段锚定行带聚类，避免两两比较器在多栏阶梯框上
    /// 违反严格弱序传递性造成随机错序。
    public static func readingOrder(_ lines: [OCRTextLine]) -> [OCRTextLine] {
        guard lines.count > 1 else { return lines }

        // 第一阶段：按文本框纵向中心升序排列，次关键字为水平起点，确保比较关系严格弱序。
        let sortedByVerticalCenter = lines.sorted { lhs, rhs in
            let lhsMidY = lhs.boundingBox.origin.y + lhs.boundingBox.size.height * 0.5
            let rhsMidY = rhs.boundingBox.origin.y + rhs.boundingBox.size.height * 0.5
            if lhsMidY != rhsMidY {
                return lhsMidY < rhsMidY
            }
            if lhs.boundingBox.origin.x != rhs.boundingBox.origin.x {
                return lhs.boundingBox.origin.x < rhs.boundingBox.origin.x
            }
            return lhs.boundingBox.origin.y < rhs.boundingBox.origin.y
        }

        // 第二阶段：线性扫描聚类为锚定行带，避免后续成员拉偏锚点产生传递漂移。
        struct RowBand {
            let anchor: PixelRect
            var items: [OCRTextLine]
        }

        var bands: [RowBand] = []
        bands.reserveCapacity(sortedByVerticalCenter.count)
        for line in sortedByVerticalCenter {
            if let lastIndex = bands.indices.last,
               overlapsVertically(bands[lastIndex].anchor, line.boundingBox) {
                bands[lastIndex].items.append(line)
            } else {
                bands.append(RowBand(anchor: line.boundingBox, items: [line]))
            }
        }

        // 行带间按顺序输出，行带内严格按水平起点升序排列。
        var ordered: [OCRTextLine] = []
        ordered.reserveCapacity(lines.count)
        for band in bands {
            if band.items.count == 1 {
                ordered.append(band.items[0])
            } else {
                ordered.append(contentsOf: band.items.sorted { lhs, rhs in
                    if lhs.boundingBox.origin.x != rhs.boundingBox.origin.x {
                        return lhs.boundingBox.origin.x < rhs.boundingBox.origin.x
                    }
                    return lhs.boundingBox.origin.y < rhs.boundingBox.origin.y
                })
            }
        }
        return ordered
    }

    /// 两个包围盒在纵向是否属于同一行。
    private static func overlapsVertically(_ a: PixelRect, _ b: PixelRect) -> Bool {
        let aTop = a.origin.y
        let aBottom = a.origin.y + a.size.height
        let bTop = b.origin.y
        let bBottom = b.origin.y + b.size.height
        let overlap = min(aBottom, bBottom) - max(aTop, bTop)
        return overlap > min(a.size.height, b.size.height) * 0.5
    }
}

/// Vision 坐标 → 模型坐标。
public enum OCRCoordinateConversion {

    /// 把 Vision 的归一化包围盒（**原点左下**）转成模型像素矩形（**原点左上**）。
    ///
    /// ```
    /// pixelX   = normX × imageWidth
    /// pixelW   = normW × imageWidth
    /// pixelH   = normH × imageHeight
    /// pixelTop = (1 − normY − normH) × imageHeight     ← 翻转在这一项里
    /// ```
    ///
    /// - Parameters:
    ///   - normalized: Vision 给出的归一化包围盒（原点左下）。
    ///   - imagePixelSize: 识别时的图像像素尺寸。
    public static func pixelRect(normalized: CGRect, imagePixelSize: PixelSize) -> PixelRect {
        let width = imagePixelSize.width
        let height = imagePixelSize.height
        // Vision 用 CGFloat，模型用 Double，这里显式转换一次。
        let x = Double(normalized.origin.x) * width
        // 归一化 y 是**底边**到图像底部的距离；左上原点下要算的是顶边的位置。
        let top = (1 - Double(normalized.origin.y) - Double(normalized.size.height)) * height
        return PixelRect(
            origin: PixelPoint(x: x, y: top),
            size: PixelSize(
                width: Double(normalized.size.width) * width,
                height: Double(normalized.size.height) * height
            )
        )
    }
}
