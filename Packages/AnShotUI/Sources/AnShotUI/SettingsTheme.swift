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

enum SettingsTheme {

    // ── 尺寸 ──
    //
    // 这些是设计选择，不是 HIG 的强制值。它们的作用是让整窗口的
    // 节奏一致：同一个圆角半径、同一套间距，重复出现才成其为「语言」。

    /// 卡片圆角。14pt 与 macOS 13+ 系统设置的分组观感接近。
    static let cardRadius: CGFloat = 14
    /// 选项按钮圆角。
    static let optionRadius: CGFloat = 10
    /// 文件夹内嵌面的圆角。
    static let surfaceRadius: CGFloat = 10
    /// 键帽圆角。
    static let keycapRadius: CGFloat = 5

    /// 侧边栏宽度。
    ///
    /// 176pt 足够容下「文字识别」这样的最长项，又不至于让内容区显得拥挤。
    static let sidebarWidth: CGFloat = 176
    /// 内容区宽度（不含侧边栏）。
    static let contentWidth: CGFloat = 504
    /// 窗口总宽度。
    ///
    /// 固定宽度：设置窗口的尺寸应当稳定，否则选定文件夹后多出一行路径、
    /// 或切到另一页时高度不同，窗口就会跳一下。
    static let windowWidth: CGFloat = sidebarWidth + contentWidth

    /// 窗口高度（**固定**）。
    ///
    /// 取所有页面里最高的那一页，再留一点余量。原有各页内容高度：
    /// 通用 228 / 保存 345 / 翻译 266 / 文字识别 410；**关于页 524（最高）**。
    ///
    /// 2026-11-03：「关于」页加入三张卡片（版本与更新 / 崩溃日志 / 链接）。
    /// 按各控件实际行高累加——页头 44 + 版本卡 198 + 崩溃卡 96 + 链接卡 138
    /// + 卡间距 48 = 524；加 48 上下边距 = 572，取 580 留 8pt 余量。
    /// 只加高窗口、不收窄卡片：其余页面下方多出的留白不会挤压任何内容，
    /// 切页高度仍然恒定（`-diagnoseSettingsWindow` 有断言守着）。
    ///
    /// **刻意不按当前页自适应**：切页时窗口高度跳动比多点留白更分心，
    /// 而且侧边栏会跟着上下伸缩，观感不稳定。所以宁可让内容少的页下方
    /// 留白，也要让窗口尺寸恒定。
    ///
    /// 新增设置项时必须重新核对这个值：内容一旦超过窗口内容区高度，
    /// 卡片会被挤扁（`-diagnoseSettingsWindow` 有断言守着）。
    static let windowHeight: CGFloat = 580
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
    ///
    /// 输入框撑满整个卡片宽度并不好用：路径与密钥本来就不长，
    /// 过宽的输入框会让眼睛在标签与文本之间跑很远，也不像系统设置。
    /// 窄于这个值时跟随可用宽度收缩，不固定。
    ///
    /// 300 是「窗口正方形」约束下的上限：内容区 504 减去外边距与卡片内边距，
    /// 留给「标签 108 + 间距 10 + 控件」的宽度约 420，控件最多到 300。
    static let maxFieldWidth: CGFloat = 300

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

// MARK: - 卡片
