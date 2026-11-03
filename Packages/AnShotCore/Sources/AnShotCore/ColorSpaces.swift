//
//  ColorSpaces.swift
//  AnShotCore
//
//  HSV ↔ sRGB 互转。
//
//  单独放 AnShotCore 的理由：这是纯计算，可以脱离界面单测；
//  而取色器、色相条、色卡都要用它，散在视图里既没法测也容易不一致。
//
//  取值约定：
//  - 色相 h ∈ [0, 360)，饱和度 s ∈ [0, 1]，明度 v ∈ [0, 1]
//  - RGB 分量与 `RGBAColor` 一致：非预乘 sRGB，0...1
//

import Foundation

/// HSV 颜色分量。
public struct HSVColor: Equatable, Sendable {
    /// 色相，单位度，范围 `[0, 360)`。
    public var hue: Double
    /// 饱和度，`0...1`。
    public var saturation: Double
    /// 明度，`0...1`。
    public var value: Double

    public init(hue: Double, saturation: Double, value: Double) {
        self.hue = hue
        self.saturation = saturation
        self.value = value
    }
}

extension RGBAColor {
    /// 转为 HSV。
    public var hsv: HSVColor {
        let maxComponent = max(r, max(g, b))
        let minComponent = min(r, min(g, b))
        let delta = maxComponent - minComponent

        var hue: Double = 0
        if delta > 0 {
            if maxComponent == r {
                hue = 60 * (((g - b) / delta).truncatingRemainder(dividingBy: 6))
            } else if maxComponent == g {
                hue = 60 * (((b - r) / delta) + 2)
            } else {
                hue = 60 * (((r - g) / delta) + 4)
            }
        }
        if hue < 0 {
            hue += 360
        }

        let saturation = maxComponent == 0 ? 0 : delta / maxComponent
        return HSVColor(hue: hue, saturation: saturation, value: maxComponent)
    }

    /// 由 HSV 构造（保留给定透明度）。
    ///
    /// 明度与饱和度都为 0 时返回纯黑/纯白，此时色相无意义但会被保留在调用方，
    /// 这样拖动明度条回到有彩色时不会跳色。
    public init(hsv: HSVColor, alpha: Double = 1) {
        let hue = hsv.hue.truncatingRemainder(dividingBy: 360)
        let normalizedHue = hue < 0 ? hue + 360 : hue
        let saturation = min(max(hsv.saturation, 0), 1)
        let value = min(max(hsv.value, 0), 1)

        let chroma = value * saturation
        let secondary = chroma * (1 - abs((normalizedHue / 60).truncatingRemainder(dividingBy: 2) - 1))
        let offset = value - chroma

        let base: (Double, Double, Double)
        switch normalizedHue {
        case 0 ..< 60: base = (chroma, secondary, 0)
        case 60 ..< 120: base = (secondary, chroma, 0)
        case 120 ..< 180: base = (0, chroma, secondary)
        case 180 ..< 240: base = (0, secondary, chroma)
        case 240 ..< 300: base = (secondary, 0, chroma)
        default: base = (chroma, 0, secondary)
        }

        self.init(
            r: base.0 + offset,
            g: base.1 + offset,
            b: base.2 + offset,
            a: alpha
        )
    }

    /// 十六进制字符串（`RRGGBB`，不含 `#`）。
    public var hexString: String {
        func component(_ value: Double) -> Int {
            Int((min(max(value, 0), 1) * 255).rounded())
        }
        return String(
            format: "%02X%02X%02X",
            component(r),
            component(g),
            component(b)
        )
    }

    /// 由十六进制字符串构造。
    ///
    /// 容错：允许带或不带 `#`、允许大小写、允许 3 位缩写（`F0A` → `FF00AA`）。
    /// 解析失败返回 `nil`，由调用方决定是回退还是提示——**不要在输入过程中强制格式化**，
    /// 那会把光标顶掉、也没法输入中间的半成品（例如只打了 `#`）。
    public init?(hexString: String) {
        var text = hexString.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if text.hasPrefix("#") {
            text.removeFirst()
        }
        guard !text.isEmpty else { return nil }

        // 3 位缩写逐位展开。
        if text.count == 3 {
            text = text.map { "\($0)\($0)" }.joined()
        }
        guard text.count == 6, let value = UInt32(text, radix: 16) else {
            return nil
        }

        self.init(
            r: Double((value >> 16) & 0xFF) / 255,
            g: Double((value >> 8) & 0xFF) / 255,
            b: Double(value & 0xFF) / 255,
            a: 1
        )
    }
}
