//
//  TextMetrics.swift
//  AnShotCore
//
//  字体度量：显示侧（输入控件）与渲染侧（CoreText）必须共用同一来源。
//
//  单独成文件的理由：字号在界面上是**点**、在模型里是**像素**，
//  二者靠 scaleFactor 换算；而文字的落点由**基线**决定，
//  「文字左上角 → 基线起点」的偏移来自字体自身的 ascent。
//  两边各算一次必然错位——P6 首次实现就踩了这个坑
//  （输入框里的字与提交后画出来的字不一样大，且基线偏了一个 ascent）。
//

import CoreGraphics
import CoreText
import Foundation

/// 字体度量与构造。
///
/// 本类型中所有长度都以**像素**为单位，与 `FontDescriptor.size` 一致。
/// 界面若用点单位显示，需在调用前后自行换算。
public enum TextMetrics {

    /// 用字体描述构造 CoreText 字体。
    ///
    /// 渲染与度量共用这一个构造路径：只要构造一致，
    /// 输入时看到的行高与提交后画出来的行高就一致。
    /// 对于系统字体占位名 `.AppleSystemUIFont`，使用公开 API
    /// `CTFontCreateUIFontForLanguage(.system, ...)` 再叠加字重与斜体 trait，
    /// 消除 CoreText 私有字体名告警并避免回退至衬线体。
    public static func font(for descriptor: FontDescriptor) -> CTFont {
        let size = CGFloat(descriptor.size)
        let weightTrait = normalizedWeight(descriptor.weight)

        if descriptor.family == ".AppleSystemUIFont" || descriptor.family.isEmpty {
            let baseFont = CTFontCreateUIFontForLanguage(.system, size, nil)
                ?? CTFontCreateWithName("HelveticaNeue" as CFString, size, nil)

            let traits: [CFString: Any] = [
                kCTFontWeightTrait: weightTrait,
                kCTFontSlantTrait: descriptor.italic ? 1.0 : 0.0,
            ]
            let attributes: [CFString: Any] = [
                kCTFontTraitsAttribute: traits as CFDictionary,
            ]
            let fontDescriptor = CTFontDescriptorCreateWithAttributes(attributes as CFDictionary)
            var resolved = CTFontCreateCopyWithAttributes(baseFont, size, nil, fontDescriptor)

            if descriptor.italic {
                let symbolic = CTFontGetSymbolicTraits(resolved)
                if !symbolic.contains(.traitItalic) {
                    if let italicCopy = CTFontCreateCopyWithSymbolicTraits(
                        resolved,
                        size,
                        nil,
                        .traitItalic,
                        .traitItalic
                    ) {
                        resolved = italicCopy
                    } else {
                        // 部分系统字重缺少独立斜体字形，采用约 14° 剪切矩阵实现一致斜体外观。
                        var slant = CGAffineTransform(a: 1, b: 0, c: 0.25, d: 1, tx: 0, ty: 0)
                        resolved = CTFontCreateCopyWithAttributes(resolved, size, &slant, nil)
                    }
                }
            }
            return resolved
        }

        let traits: [CFString: Any] = [
            kCTFontWeightTrait: weightTrait,
            kCTFontSlantTrait: descriptor.italic ? 1.0 : 0.0,
        ]
        let attributes: [CFString: Any] = [
            kCTFontFamilyNameAttribute: descriptor.family,
            kCTFontSizeAttribute: descriptor.size,
            kCTFontTraitsAttribute: traits as CFDictionary,
        ]
        let fontDescriptor = CTFontDescriptorCreateWithAttributes(attributes as CFDictionary)
        return CTFontCreateWithFontDescriptor(fontDescriptor, size, nil)
    }

    /// 统一排版行结果，供渲染侧与命中测试共用，确保末尾换行与断行高度严格一致。
    internal struct LaidOutLine {
        let line: CTLine?
        let width: Double
        let ascent: Double
        let descent: Double
        let leading: Double

        var height: Double {
            ascent + descent + leading
        }
    }

    /// 统一执行多行文字排版（支持限定宽度断行与显式换行，且统一末尾换行高度）。
    internal static func layoutLines(
        text: String,
        font: FontDescriptor,
        maxWidth: Double?,
        foregroundColor: CGColor? = nil
    ) -> (ctFont: CTFont, ascent: Double, lines: [LaidOutLine]) {
        let ctFont = self.font(for: font)
        let fontAscent = Double(CTFontGetAscent(ctFont))
        let fontDescent = Double(CTFontGetDescent(ctFont))
        let fontLeading = Double(CTFontGetLeading(ctFont))
        let emptyLine = LaidOutLine(
            line: nil,
            width: 0,
            ascent: fontAscent,
            descent: fontDescent,
            leading: fontLeading
        )

        guard !text.isEmpty else {
            return (ctFont, fontAscent, [])
        }

        var attributes: [NSAttributedString.Key: Any] = [
            kCTFontAttributeName as NSAttributedString.Key: ctFont,
        ]
        if let foregroundColor {
            attributes[kCTForegroundColorAttributeName as NSAttributedString.Key] = foregroundColor
        }

        var result: [LaidOutLine] = []

        if let maxWidth, maxWidth > 0 {
            let attributed = NSAttributedString(string: text, attributes: attributes)
            let typesetter = CTTypesetterCreateWithAttributedString(attributed)
            var index = 0
            while index < attributed.length {
                let count = CTTypesetterSuggestLineBreak(typesetter, index, maxWidth)
                guard count > 0 else { break }
                let line = CTTypesetterCreateLine(
                    typesetter,
                    CFRange(location: index, length: count)
                )
                result.append(measureLine(line))
                index += count
            }
            // CTTypesetter 对末尾换行符不会生成额外的空行，显式补足空行高度，
            // 使带 maxWidth 与不带 maxWidth 路径在末尾换行时的包围盒高度保持一致。
            if text.hasSuffix("\n") || text.hasSuffix("\r") {
                result.append(emptyLine)
            }
        } else {
            for fragment in text.split(separator: "\n", omittingEmptySubsequences: false) {
                if fragment.isEmpty {
                    result.append(emptyLine)
                    continue
                }
                let attributed = NSAttributedString(string: String(fragment), attributes: attributes)
                let line = CTLineCreateWithAttributedString(attributed)
                result.append(measureLine(line))
            }
        }

        return (ctFont, fontAscent, result)
    }

    private static func measureLine(_ line: CTLine) -> LaidOutLine {
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        var leading: CGFloat = 0
        let width = CTLineGetTypographicBounds(line, &ascent, &descent, &leading)
        return LaidOutLine(
            line: line,
            width: Double(width),
            ascent: Double(ascent),
            descent: Double(descent),
            leading: Double(leading)
        )
    }

    /// 单行行高：ascent + descent + leading（像素）。
    public static func lineHeight(for descriptor: FontDescriptor) -> Double {
        let ctFont = font(for: descriptor)
        return Double(
            CTFontGetAscent(ctFont) + CTFontGetDescent(ctFont) + CTFontGetLeading(ctFont)
        )
    }

    /// ascent（像素）：基线到文字顶端。
    public static func ascent(for descriptor: FontDescriptor) -> Double {
        Double(CTFontGetAscent(font(for: descriptor)))
    }

    /// 由「文字左上角」求模型要求的**基线起点**。
    ///
    /// 模型约定 `.text` 的 origin 是基线左端（见 `model.md`），
    /// 而交互上用户点击得到的是文字左上角，这里做唯一一次换算，
    /// 视图侧不再自己加偏移。
    public static func baselineOrigin(
        forTopLeft topLeft: PixelPoint,
        font: FontDescriptor
    ) -> PixelPoint {
        PixelPoint(x: topLeft.x, y: topLeft.y + ascent(for: font))
    }

    /// 把 CoreText 的粗细数值映射到 weight trait。
    private static func normalizedWeight(_ weight: Int) -> Double {
        let table: [(weight: Int, trait: Double)] = [
            (100, -0.80), (200, -0.60), (300, -0.40), (400, 0.00), (500, 0.23),
            (600, 0.30), (700, 0.40), (800, 0.56), (900, 0.62),
        ]
        let clamped = min(max(weight, 100), 900)
        return table.min { abs($0.weight - clamped) < abs($1.weight - clamped) }?.trait ?? 0
    }
}
