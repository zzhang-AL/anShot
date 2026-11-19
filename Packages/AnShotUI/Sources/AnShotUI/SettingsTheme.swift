//
//  SettingsTheme.swift
//  AnShotUI
//
//  anShot 全域设计系统令牌（现代 macOS 毛玻璃 + 精致语义色层次）。
//
//  ── 动态色的纪律 ──────────────────────────────────────────────
//  凡是给 CALayer 赋色的视图一律走 `wantsUpdateLayer` + `updateLayer()`，
//  确保浅色 / 深色外观切换时实时重新解析动态色，绝不在 `init` 中冻结 `.cgColor`。
//
import AppKit

/// 全应用外观模式（契约 `ux-polish/model.md` §4.2：`settings.appearanceMode`）。
public enum AppAppearanceMode: String, CaseIterable, Sendable {
    case system = "system"
    case light = "light"
    case dark = "dark"

    @MainActor
    public var displayName: String {
        switch self {
        case .system: return L("appearance.system", fallback: "跟随系统")
        case .light: return L("appearance.light", fallback: "浅色")
        case .dark: return L("appearance.dark", fallback: "深色")
        }
    }

    /// 对应的 `NSAppearance`；`.system` 返回 `nil` 让系统接管动态浅/深外观。
    public var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }
}

/// 保留旧名兼容所有既有设置组件引用。
typealias SettingsTheme = AnShotTheme

/// anShot 全域设计系统令牌与通用外观调度器。
enum AnShotTheme {

    // ── 全局外观切换 ──

    @MainActor
    static func apply(appearanceMode: AppAppearanceMode) {
        guard let app = NSApp else { return }
        app.appearance = appearanceMode.nsAppearance
        for window in app.windows {
            window.invalidateShadow()
            window.contentView?.needsDisplay = true
        }
    }

    // ── 尺寸与比例 ──

    /// 分组卡片圆角（与 macOS Sequoia 原生设置对齐）。
    static let cardRadius: CGFloat = 12
    /// 选项卡片圆角。
    static let optionRadius: CGFloat = 10
    /// 内嵌表面圆角。
    static let surfaceRadius: CGFloat = 9
    /// 键帽圆角。
    static let keycapRadius: CGFloat = 5
    /// 浮窗与弹出面板圆角。
    static let floatingRadius: CGFloat = 12

    /// 侧边栏宽度（容纳搜索框与 8 个带彩色徽章的分类页）。
    static let sidebarWidth: CGFloat = 204
    /// 内容区初始宽度（不含侧边栏）。
    static let contentWidth: CGFloat = 596
    /// 设置窗口默认初始总宽度（800pt，且支持自由缩放）。
    static let windowWidth: CGFloat = sidebarWidth + contentWidth
    /// 设置窗口默认初始高度（620pt，支持自由缩放）。
    static let windowHeight: CGFloat = 620
    /// 设置窗口最小可缩尺寸。
    static let windowMinSize = NSSize(width: 720, height: 520)
    /// 内容区外边距。
    static let margin: CGFloat = 24
    /// 卡片内边距（横向与纵向）。
    static let cardPadding: CGFloat = 16
    /// 同一卡片内行间间距。
    static let innerGap: CGFloat = 11
    /// 卡片之间垂直间距。
    static let cardGap: CGFloat = 16

    /// 键帽高度。
    static let keycapHeight: CGFloat = 22

    /// 表单文本输入框最大宽度。
    static let maxFieldWidth: CGFloat = 320

    // ── 现代 macOS 语义色体系 ──

    /// 主强调色：跟随用户 macOS 系统强调色（默认苹果蓝），用于选中态、激活徽章与主按钮。
    static var accent: NSColor { .controlAccentColor }

    /// 强调色块上的高对比前景色。
    static var onAccent: NSColor { .white }

    /// 强调色柔和底（用于侧边栏选中、选项卡片选中与胶囊微底）。
    static var accentSoft: NSColor {
        dynamic(
            light: NSColor.controlAccentColor.withAlphaComponent(0.11),
            dark: NSColor.controlAccentColor.withAlphaComponent(0.20)
        )
    }

    /// 窗口内容区底色：浅色柔和云灰、深色深邃炭黑，保证卡片清晰浮起。
    static var windowBackground: NSColor {
        dynamic(
            light: NSColor(srgbRed: 0.955, green: 0.960, blue: 0.972, alpha: 1),
            dark: NSColor(srgbRed: 0.105, green: 0.112, blue: 0.126, alpha: 1)
        )
    }

    /// 卡片背景：浅色纯白、深色温润抬升碳灰。
    static var cardBackground: NSColor {
        dynamic(
            light: NSColor(srgbRed: 1.0, green: 1.0, blue: 1.0, alpha: 1),
            dark: NSColor(srgbRed: 0.158, green: 0.166, blue: 0.184, alpha: 1)
        )
    }

    /// 侧边栏降级底色（运行时叠加 `NSVisualEffectView(.sidebar)` 毛玻璃）。
    static var sidebarBackground: NSColor {
        dynamic(
            light: NSColor(srgbRed: 0.922, green: 0.930, blue: 0.946, alpha: 1),
            dark: NSColor(srgbRed: 0.128, green: 0.135, blue: 0.150, alpha: 1)
        )
    }

    /// 侧边栏与内容区之间的极细竖向分割线。
    static var sidebarDivider: NSColor {
        dynamic(
            light: NSColor(white: 0, alpha: 0.08),
            dark: NSColor(white: 1, alpha: 0.08)
        )
    }

    /// 内嵌表面（文件夹行、输入框底、按键胶囊底）。
    static var insetBackground: NSColor {
        dynamic(
            light: NSColor(srgbRed: 0.952, green: 0.958, blue: 0.970, alpha: 1),
            dark: NSColor(srgbRed: 0.205, green: 0.214, blue: 0.236, alpha: 1)
        )
    }

    /// 悬停微亮表面。
    static var hoverSurface: NSColor {
        dynamic(
            light: NSColor(white: 0, alpha: 0.045),
            dark: NSColor(white: 1, alpha: 0.065)
        )
    }

    /// 卡片细描边。
    static var cardBorder: NSColor {
        dynamic(
            light: NSColor(white: 0, alpha: 0.075),
            dark: NSColor(white: 1, alpha: 0.095)
        )
    }

    /// 卡片内部行与行之间的极细内缩分隔线。
    static var rowSeparator: NSColor {
        dynamic(
            light: NSColor(white: 0, alpha: 0.065),
            dark: NSColor(white: 1, alpha: 0.075)
        )
    }

    /// 键帽表面。
    static var keycapBackground: NSColor {
        dynamic(
            light: NSColor(white: 1.0, alpha: 1),
            dark: NSColor(srgbRed: 0.255, green: 0.266, blue: 0.292, alpha: 1)
        )
    }

    /// 键帽边框与底部立体微边。
    static var keycapEdge: NSColor {
        dynamic(
            light: NSColor(white: 0, alpha: 0.16),
            dark: NSColor(white: 1, alpha: 0.16)
        )
    }

    /// 分组标题颜色。
    static var sectionLabel: NSColor { .labelColor }

    /// 语义状态色（危险 / 警告 / 成功）。
    static var danger: NSColor { .systemRed }
    static var warning: NSColor { .systemOrange }
    static var success: NSColor { .systemGreen }

    /// 浮窗与控制胶囊表面色。
    static var floatingSurface: NSColor {
        dynamic(
            light: NSColor(white: 0.98, alpha: 0.95),
            dark: NSColor(white: 0.14, alpha: 0.94)
        )
    }

    /// 浮窗细描边。
    static var floatingBorder: NSColor {
        dynamic(
            light: NSColor(white: 0, alpha: 0.10),
            dark: NSColor(white: 1, alpha: 0.14)
        )
    }

    /// 图像预览衬底。
    static var previewCanvasBackground: NSColor {
        dynamic(
            light: NSColor(white: 0.91, alpha: 1),
            dark: NSColor(white: 0.16, alpha: 1)
        )
    }

    // ── 绘制辅助 ──

    /// 动态色构造器。
    static func dynamic(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        }
    }

    /// 填充圆角矩形（兼容 macOS 13.0）。
    static func fillRoundedRect(
        _ rect: CGRect,
        radius: CGFloat,
        color: NSColor,
        in context: CGContext
    ) {
        context.saveGState()
        context.setFillColor(color.cgColor)
        context.addPath(CGPath(
            roundedRect: rect,
            cornerWidth: radius,
            cornerHeight: radius,
            transform: nil
        ))
        context.fillPath()
        context.restoreGState()
    }

    /// 描边圆角矩形。
    static func strokeRoundedRect(
        _ rect: CGRect,
        radius: CGFloat,
        color: NSColor,
        lineWidth: CGFloat,
        in context: CGContext
    ) {
        context.saveGState()
        context.setStrokeColor(color.cgColor)
        context.setLineWidth(lineWidth)
        context.addPath(CGPath(
            roundedRect: rect.insetBy(dx: lineWidth / 2, dy: lineWidth / 2),
            cornerWidth: radius,
            cornerHeight: radius,
            transform: nil
        ))
        context.strokePath()
        context.restoreGState()
    }

    /// 绘制现代 macOS 风格的彩色微光泽圆角图标徽章（用于侧边栏 22×22 与页头 40×40）。
    static func drawBadgeTile(
        in rect: CGRect,
        radius: CGFloat,
        baseColor: NSColor,
        symbolName: String,
        symbolPointSize: CGFloat,
        symbolWeight: NSFont.Weight = .semibold,
        in context: CGContext
    ) {
        let clipPath = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
        context.saveGState()
        context.addPath(clipPath)
        context.clip()

        let rgb = baseColor.usingColorSpace(.sRGB) ?? baseColor
        let topColor = NSColor(
            srgbRed: min(1, rgb.redComponent * 1.12 + 0.06),
            green: min(1, rgb.greenComponent * 1.12 + 0.06),
            blue: min(1, rgb.blueComponent * 1.12 + 0.06),
            alpha: 1
        )
        let bottomColor = NSColor(
            srgbRed: max(0, rgb.redComponent * 0.86),
            green: max(0, rgb.greenComponent * 0.86),
            blue: max(0, rgb.blueComponent * 0.86),
            alpha: 1
        )
        let colors = [topColor.cgColor, bottomColor.cgColor] as CFArray
        if let gradient = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: colors,
            locations: [0, 1]
        ) {
            context.drawLinearGradient(
                gradient,
                start: CGPoint(x: rect.midX, y: rect.minY),
                end: CGPoint(x: rect.midX, y: rect.maxY),
                options: []
            )
        } else {
            context.setFillColor(baseColor.cgColor)
            context.fill(rect)
        }

        // 顶部极细高光描边，塑造通透亚克力微立体感。
        context.setStrokeColor(NSColor.white.withAlphaComponent(0.26).cgColor)
        context.setLineWidth(1.0)
        context.addPath(CGPath(
            roundedRect: rect.insetBy(dx: 0.5, dy: 0.5),
            cornerWidth: max(1, radius - 0.5),
            cornerHeight: max(1, radius - 0.5),
            transform: nil
        ))
        context.strokePath()
        context.restoreGState()

        // 绘制居中纯白符号。
        let config = NSImage.SymbolConfiguration(pointSize: symbolPointSize, weight: symbolWeight)
            .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
        if let symbol = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(config) {
            let size = symbol.size
            symbol.draw(in: NSRect(
                x: rect.midX - size.width / 2,
                y: rect.midY - size.height / 2,
                width: size.width,
                height: size.height
            ))
        }
    }
}

// MARK: - 全域动态主题表面（自动响应浅/深外观切换）

/// 统一动态背景表面容器：所有窗口/面板背景与内嵌卡片共用，彻底消除在 `init` 中写死 `.cgColor` 的外观冻结。
final class ThemedSurfaceView: NSView {
    enum SurfaceKind {
        case windowBackground
        case card
        case inset
        case previewCanvas
        case floating(cornerRadius: CGFloat)
    }

    private let kind: SurfaceKind
    private let customCornerRadius: CGFloat?

    init(kind: SurfaceKind, cornerRadius: CGFloat? = nil, frame: NSRect = .zero) {
        self.kind = kind
        self.customCornerRadius = cornerRadius
        super.init(frame: frame)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("不支持从 nib 构造")
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        switch kind {
        case .windowBackground:
            layer?.backgroundColor = AnShotTheme.windowBackground.cgColor
            layer?.cornerRadius = customCornerRadius ?? 0
            layer?.borderWidth = 0
            layer?.borderColor = nil
        case .card:
            layer?.backgroundColor = AnShotTheme.cardBackground.cgColor
            layer?.cornerRadius = customCornerRadius ?? AnShotTheme.cardRadius
            layer?.cornerCurve = .continuous
            layer?.borderWidth = 1
            layer?.borderColor = AnShotTheme.cardBorder.cgColor
        case .inset:
            layer?.backgroundColor = AnShotTheme.insetBackground.cgColor
            layer?.cornerRadius = customCornerRadius ?? AnShotTheme.surfaceRadius
            layer?.cornerCurve = .continuous
            layer?.borderWidth = 0
            layer?.borderColor = nil
        case .previewCanvas:
            layer?.backgroundColor = AnShotTheme.previewCanvasBackground.cgColor
            layer?.cornerRadius = customCornerRadius ?? 6
            layer?.cornerCurve = .continuous
            layer?.borderWidth = 1
            layer?.borderColor = AnShotTheme.cardBorder.cgColor
            layer?.masksToBounds = true
        case .floating(let radius):
            layer?.backgroundColor = AnShotTheme.floatingSurface.cgColor
            layer?.cornerRadius = customCornerRadius ?? radius
            layer?.cornerCurve = .continuous
            layer?.borderWidth = 1
            layer?.borderColor = AnShotTheme.floatingBorder.cgColor
            layer?.masksToBounds = true
        }
    }
}
