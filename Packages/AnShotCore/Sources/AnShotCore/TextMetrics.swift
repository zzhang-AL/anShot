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
    public static func font(for descriptor: FontDescriptor) -> CTFont {
        let traits: [CFString: Any] = [
            kCTFontWeightTrait: normalizedWeight(descriptor.weight),
            kCTFontSlantTrait: descriptor.italic ? 1.0 : 0.0,
        ]
        let attributes: [CFString: Any] = [
            kCTFontFamilyNameAttribute: descriptor.family,
            kCTFontSizeAttribute: descriptor.size,
            kCTFontTraitsAttribute: traits as CFDictionary,
        ]
        let fontDescriptor = CTFontDescriptorCreateWithAttributes(attributes as CFDictionary)
        return CTFontCreateWithFontDescriptor(fontDescriptor, descriptor.size, nil)
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
