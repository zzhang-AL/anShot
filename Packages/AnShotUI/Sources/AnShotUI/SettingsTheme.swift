//
//  SettingsTheme.swift
//  AnShotUI
//
//  设置窗口的设计令牌（颜色、间距、圆角、尺寸），以及整套自绘组件的设计总纲。
//
//  ── 为什么自己画 ──────────────────────────────────────────────
//
//  系统默认控件的「形制」是对的（键盘可达、辅助功能、深浅模式都免费），
//  但它们只提供功能，不提供**层次**：两列标签加一排控件堆在一起，
//  读者需要用眼睛逐个解析哪里是分组、哪里是说明。
//
//  这里的做法是保留原生控件承担交互（`NSButton` 子类、`NSTextField`），
//  只把**容器与背景**换成自绘的圆角卡片。这样既拿到设计感，
//  又不丢掉原生控件已经解决掉的那些问题。
//
//  ── 动态色的陷阱 ──────────────────────────────────────────────
//
//  `NSColor.cgColor` 会把动态色**立刻解析**成当前外观的固定值。
//  一旦赋给 `CALayer`，之后切换深浅模式它不会自己变——
//  这正是「深色模式下白底白字」这类 bug 的来源。
//  因此凡是给 layer 上色的视图一律走 `wantsUpdateLayer` + `updateLayer()`：
//  后者在每次外观变化后的重绘时机被调用，拿到的始终是当前外观的值。
//
//  ── 本目录的组织 ──────────────────────────────────────────────
//
//  设置窗口的组件按职责拆成五个文件（曾同在一个 1600+ 行的
//  `SettingsComponents.swift` 里）：
//
//      SettingsTheme.swift             设计令牌（本文件）
//      SettingsContainerViews.swift    容器：卡片、分组表面、字段外壳
//      SettingsRowViews.swift          行：分组标题、页头、字段行、开关行
//      SettingsButtonStyles.swift      按钮：选项卡、侧栏项、主要按钮
//      SettingsNavigation.swift        导航模型：页面清单、主菜单
//
//  全部组件都从本文件取值，视觉常量不得散落到组件里。
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

/// anShot 全域设计系统令牌与通用外观调度器（一统设置、历史、窗口选择、结果窗、欢迎/更新/崩溃日志与浮层）。
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

    // ── 尺寸 ──

    /// 卡片圆角。14pt 与 macOS 13+ 系统设置的分组观感接近。
    static let cardRadius: CGFloat = 14
    /// 选项按钮圆角。
    static let optionRadius: CGFloat = 10
    /// 文件夹内嵌面的圆角。
    static let surfaceRadius: CGFloat = 10
    /// 键帽圆角。
    static let keycapRadius: CGFloat = 5
    /// 浮窗与弹出面板圆角。
    static let floatingRadius: CGFloat = 12

    /// 侧边栏宽度（容纳实时搜索框与 7 个分类页）。
    static let sidebarWidth: CGFloat = 192
    /// 内容区初始宽度（不含侧边栏）。
    static let contentWidth: CGFloat = 588
    /// 设置窗口默认初始总宽度（780pt，且支持自由缩放）。
    static let windowWidth: CGFloat = sidebarWidth + contentWidth
    /// 设置窗口默认初始高度（600pt，支持自由缩放）。
    static let windowHeight: CGFloat = 600
    /// 设置窗口最小可缩尺寸。
    static let windowMinSize = NSSize(width: 680, height: 500)
    /// 窗口外边距。
    static let margin: CGFloat = 24
    /// 卡片内边距。
    static let cardPadding: CGFloat = 18
    /// 同一组内元素间距。
    static let innerGap: CGFloat = 12
    /// 卡片之间间距。
    static let cardGap: CGFloat = 16

    /// 键帽高度。
    static let keycapHeight: CGFloat = 26

    /// 表单控件最大宽度。
    static let maxFieldWidth: CGFloat = 320

    // ── 颜色 ──
    //
    // 整窗不使用任何彩色强调。整套层次靠**明度**和**描边**建立，
    // 有两个具体好处：深浅模式下都天然成立（不需要维护两套色相），
    // 而且不会与截图内容本身的颜色打架——设置窗口周围永远是用户自己的屏幕。

    /// 强调色：不用色相，用前景色本身。
    /// 浅色模式下是近黑，深色模式下是近白，对比度总是最高。
    static var accent: NSColor { .labelColor }

    /// 强调块上的前景色，与 `accent` 互为反色。
    static var onAccent: NSColor { .windowBackgroundColor }

    /// 窗口底色。比卡片低一档，让卡片能「浮起」。
    ///
    /// 用显式的明暗两套值而**不是** `windowBackgroundColor`：
    /// 后者在不同 macOS 版本上解析出的实际值不一样
    ///（实测在 macOS 27 浅色下就是纯白），一旦它为白，
    /// 白卡片贴在白底上，整套层次就消失了。
    ///
    /// 这里要的是一个**确定的**对比度，而不是「系统认为合适的」。
    static var windowBackground: NSColor {
        dynamic(light: NSColor(white: 0.93, alpha: 1), dark: NSColor(white: 0.12, alpha: 1))
    }

    /// 卡片背景。
    static var cardBackground: NSColor {
        dynamic(light: .white, dark: NSColor(white: 0.20, alpha: 1))
    }

    /// 侧边栏底色。
    ///
    /// 与内容区只差一档明度：侧边栏是导航，不该抢内容区的注意力；
    /// 而明度差本身已经能划出边界，不必再加一条分隔线。
    static var sidebarBackground: NSColor {
        dynamic(light: NSColor(white: 0.905, alpha: 1), dark: NSColor(white: 0.155, alpha: 1))
    }

    /// 内嵌表面（文件夹行）：比卡片再低一档，表示「在卡片里面」。
    static var insetBackground: NSColor {
        dynamic(light: NSColor(white: 0.955, alpha: 1), dark: NSColor(white: 0.26, alpha: 1))
    }

    /// 卡片描边。极细的一条，用来在浅色模式下勾出卡片边界。
    static var cardBorder: NSColor {
        dynamic(
            light: NSColor(white: 0, alpha: 0.07),
            dark: NSColor(white: 1, alpha: 0.09)
        )
    }

    /// 选中项的淡背景。用前景色的低透明度而非彩色，
    /// 这样选中态与未选中态只在明度上拉开差距。
    static var accentSoft: NSColor {
        NSColor.labelColor.withAlphaComponent(0.07)
    }

    /// 键帽表面。
    static var keycapBackground: NSColor {
        dynamic(light: .white, dark: NSColor(white: 0.28, alpha: 1))
    }

    /// 键帽底边（模拟键帽的厚度）。
    static var keycapEdge: NSColor {
        dynamic(
            light: NSColor(white: 0, alpha: 0.18),
            dark: NSColor(white: 0, alpha: 0.45)
        )
    }

    /// 分组标题的次要色。
    static var sectionLabel: NSColor { .secondaryLabelColor }

    /// 语义状态色（危险/警告/成功），统一用于录屏取消确认、权限状态与 Toast 图标。
    static var danger: NSColor { .systemRed }
    static var warning: NSColor { .systemOrange }
    static var success: NSColor { .systemGreen }

    /// 浮窗与控制胶囊表面色（浅/深双态半透明高对比）。
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

    /// 图像预览衬底（自动随浅/深主题更新，绝不在 `init` 冻结 `.cgColor`）。
    static var previewCanvasBackground: NSColor {
        dynamic(
            light: NSColor(white: 0.91, alpha: 1),
            dark: NSColor(white: 0.16, alpha: 1)
        )
    }

    // ── 绘制辅助 ──

    /// 动态色构造器。
    ///
    /// - Parameter light / dark: 两种外观下的固定色。
    static func dynamic(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        }
    }

    /// 填充圆角矩形。
    ///
    /// 用 `CGPath` 而不是 `NSBezierPath(cgPath:)`——后者是 macOS 14.0+，
    /// 会超出本项目的 13.0 基线。这与 `AnnotationToolbarView` 的约定一致。
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
