//
//  OverlayShortcutHUD.swift
//  AnShotUI
//
//  覆盖层左下角极简静态快捷微提示 + 按 `?` 展开的完整快捷键速查浮卡。
//
//  ── 设计原则 ──────────────────────────────────────────────────
//  1. 克制且静止：左下角微胶囊仅有「框选前」与「确认后」两种静态文案，
//     标注过程中绝不随工具或选中状态反复跳字闪烁；
//  2. 避让即隐：当选区、工具栏或尺寸标签靠近左下角时直接静默隐藏，不来回跳角分散注意力；
//  3. 绘制与命中同源：`pillRect` / `cheatSheetRect` / `toggleHintButtonRect` 是唯一几何真相。
//

import AppKit
import CoreGraphics
import CoreText
import Foundation

@MainActor
enum OverlayShortcutHUD {

    /// 供绘制与命中共同读取的不可变输入快照。
    struct State {
        let viewBounds: CGRect
        let safeInsets: NSEdgeInsets
        let isSelectionConfirmed: Bool
        let isHintEnabled: Bool
        let isCheatSheetVisible: Bool
        let isSuppressedByMode: Bool
        let avoidRects: [CGRect]
        let isEnglish: Bool
    }

    /// 微胶囊 / 速查卡命中目标。
    enum HitTarget: Equatable {
        /// 点击左下角静态微胶囊（切换展开/收起完整速查卡）。
        case toggleCheatSheet
        /// 点击速查卡底部「显示/隐藏底部提示」开关。
        case toggleHintVisibility
        /// 点击速查卡其余本体区域（吞掉事件，避免穿透误触画布）。
        case cheatSheetBody
    }

    /// 微胶囊内部的一个「键帽 + 标签」条目。
    struct PillSegment: Equatable {
        let key: String
        let label: String
    }

    /// 速查卡的一组快捷键。
    struct CheatSheetSection {
        let title: String
        let items: [(key: String, label: String)]
    }

    private static let cornerMargin: CGFloat = 16
    private static let pillHeight: CGFloat = 28
    private static let pillPaddingX: CGFloat = 10
    private static let keycapHeight: CGFloat = 18
    private static let keycapPadX: CGFloat = 5
    private static let keyToLabelGap: CGFloat = 5
    private static let segmentGap: CGFloat = 10
    private static let avoidPadding: CGFloat = 10

    // 静态缓存纯 CoreText 字体与颜色，彻底绕开 AppKit `NSString.size(withAttributes:)` / `draw(at:)`
    // 在高频 `mouseMoved` 与重绘中触发 macOS 27 CoreText 字典深拷贝异常的风险。
    private static let pillKeyFont: CTFont = NSFont.monospacedSystemFont(ofSize: 10.5, weight: .semibold) as CTFont
    private static let pillLabelFont: CTFont = NSFont.systemFont(ofSize: 11.5, weight: .medium) as CTFont
    private static let sheetTitleFont: CTFont = NSFont.systemFont(ofSize: 13, weight: .semibold) as CTFont
    private static let sheetCloseFont: CTFont = NSFont.systemFont(ofSize: 11, weight: .regular) as CTFont
    private static let sheetSectionFont: CTFont = NSFont.systemFont(ofSize: 10.5, weight: .semibold) as CTFont
    private static let sheetDescFont: CTFont = NSFont.systemFont(ofSize: 11.5, weight: .regular) as CTFont

    private static let white96 = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.96)
    private static let white95 = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.95)
    private static let white85 = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.85)
    private static let white84 = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.84)
    private static let white76 = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.76)
    private static let white54 = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.54)
    private static let white50 = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.50)

    private struct MeasuredLine {
        let line: CTLine
        let width: CGFloat
        let height: CGFloat
        let ascent: CGFloat
    }

    private static func makeLine(_ text: String, font: CTFont, color: CGColor) -> MeasuredLine {
        let attrStr = CFAttributedStringCreateMutable(kCFAllocatorDefault, 0)!
        CFAttributedStringReplaceString(attrStr, CFRange(location: 0, length: 0), text as CFString)
        let range = CFRange(location: 0, length: CFAttributedStringGetLength(attrStr))
        CFAttributedStringSetAttribute(attrStr, range, kCTFontAttributeName, font)
        CFAttributedStringSetAttribute(attrStr, range, kCTForegroundColorAttributeName, color)
        let line = CTLineCreateWithAttributedString(attrStr)
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        var leading: CGFloat = 0
        let width = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
        return MeasuredLine(line: line, width: width, height: ascent + descent, ascent: ascent)
    }

    private static func drawLine(_ measured: MeasuredLine, atTopLeft origin: CGPoint, in context: CGContext) {
        context.saveGState()
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        context.textPosition = CGPoint(x: origin.x, y: origin.y + measured.ascent)
        CTLineDraw(measured.line, context)
        context.restoreGState()
    }

    // MARK: - 文案

    static func pillSegments(isSelectionConfirmed: Bool, isEnglish: Bool) -> [PillSegment] {
        if isSelectionConfirmed {
            if isEnglish {
                return [
                    PillSegment(key: "Space", label: "Pan"),
                    PillSegment(key: "Scroll", label: "Adjust"),
                    PillSegment(key: "?", label: "Shortcuts"),
                ]
            }
            return [
                PillSegment(key: "Space", label: "移选区"),
                PillSegment(key: "滚轮", label: "调参"),
                PillSegment(key: "?", label: "快捷键"),
            ]
        } else {
            if isEnglish {
                return [
                    PillSegment(key: "⌘A", label: "Full"),
                    PillSegment(key: "Space", label: "Window"),
                    PillSegment(key: "C", label: "Color"),
                    PillSegment(key: "?", label: "Keys"),
                ]
            }
            return [
                PillSegment(key: "⌘A", label: "全屏"),
                PillSegment(key: "Space", label: "独立窗体"),
                PillSegment(key: "C", label: "取色"),
                PillSegment(key: "?", label: "快捷键"),
            ]
        }
    }

    static func cheatSheetSections(isEnglish: Bool) -> [CheatSheetSection] {
        if isEnglish {
            return [
                CheatSheetSection(
                    title: "Selection & Capture",
                    items: [
                        ("⌘A", "Select current screen"),
                        ("Scroll Hover", "Cycle control / window / screen"),
                        ("Space", "Window mode / Hold to pan selection"),
                        ("Drag Size Pill", "Pan selection from any tool"),
                        ("Arrows / ⌥+Arrows", "Nudge 1px / Resize selection"),
                        ("C / ⇧C", "Copy HEX / RGB under cursor"),
                    ]
                ),
                CheatSheetSection(
                    title: "Annotate & Edit",
                    items: [
                        ("Drag Shape", "Move just-drawn or selected item"),
                        ("Scroll Wheel", "Adjust stroke, font size or blur"),
                        ("⌘D / ⌫", "Duplicate / Delete selected item"),
                        ("⌘Z / ⇧⌘Z", "Undo / Redo"),
                        ("Enter / ⇧Enter", "Finish text / Insert newline"),
                    ]
                ),
                CheatSheetSection(
                    title: "Tools & Output",
                    items: [
                        ("R O A T M H S N F V", "Switch annotation tools"),
                        ("Enter / Double-Click", "Copy to clipboard"),
                        ("⌘S / ⌘P", "Save to file / Pin on screen"),
                        ("? / Esc", "Toggle help / Cancel"),
                    ]
                ),
            ]
        }
        return [
            CheatSheetSection(
                title: "选区与取景",
                items: [
                    ("⌘A", "一键全选当前屏幕"),
                    ("悬停滚轮", "逐层切换控件 / 窗口 / 全屏"),
                    ("Space", "切换窗体模式 / 按住平移选区"),
                    ("拖尺寸胶囊", "任意标注工具下直接平移选区"),
                    ("方向键 / ⌥+方向键", "1px 移动 / 调整选区宽高"),
                    ("C / ⇧C", "复制光标处 HEX / RGB 色值"),
                ]
            ),
            CheatSheetSection(
                title: "标注与编辑",
                items: [
                    ("直接拖动", "移动刚画好或选中的标注"),
                    ("滚轮", "调节线宽 / 字号 / 模糊度 / 半径"),
                    ("⌘D / ⌫", "复刻 / 删除选中标注"),
                    ("⌘Z / ⇧⌘Z", "撤销 / 重做"),
                    ("Enter / ⇧Enter", "提交文字 / 文字换行"),
                ]
            ),
            CheatSheetSection(
                title: "工具与输出",
                items: [
                    ("R O A T M H S N F V", "快速切换标注工具"),
                    ("Enter / 双击空白", "复制截图并完成"),
                    ("⌘S / ⌘P", "保存文件 / 钉在屏幕上"),
                    ("? / Esc", "展开收起速查 / 退出"),
                ]
            ),
        ]
    }

    // MARK: - 几何计算

    /// 左下角微胶囊矩形；若被关闭、被模式抑制或与选区/工具栏重叠则返回 `nil`（避让即隐）。
    static func pillRect(for state: State) -> CGRect? {
        guard !state.isSuppressedByMode,
              state.isHintEnabled || state.isCheatSheetVisible,
              state.viewBounds.width >= 260,
              state.viewBounds.height >= 120 else {
            return nil
        }

        let segments = pillSegments(isSelectionConfirmed: state.isSelectionConfirmed, isEnglish: state.isEnglish)

        var contentWidth: CGFloat = 0
        for (index, segment) in segments.enumerated() {
            if index > 0 {
                contentWidth += segmentGap
            }
            let keyWidth = ceil(makeLine(segment.key, font: pillKeyFont, color: white95).width) + keycapPadX * 2
            let labelWidth = ceil(makeLine(segment.label, font: pillLabelFont, color: white76).width)
            contentWidth += keyWidth + keyToLabelGap + labelWidth
        }

        let width = min(state.viewBounds.width - cornerMargin * 2, contentWidth + pillPaddingX * 2)
        let x = state.viewBounds.minX + max(cornerMargin, state.safeInsets.left + cornerMargin)
        let y = state.viewBounds.maxY - max(cornerMargin, state.safeInsets.bottom + cornerMargin) - pillHeight
        let rect = CGRect(x: x.rounded(), y: y.rounded(), width: ceil(width), height: pillHeight)

        // 速查卡展开期间始终保留触发胶囊；收起态下与选区/工具栏/尺寸胶囊重叠时直接静默隐藏。
        if !state.isCheatSheetVisible {
            let guardRect = rect.insetBy(dx: -avoidPadding, dy: -avoidPadding)
            for avoid in state.avoidRects where !avoid.isEmpty {
                if guardRect.intersects(avoid) {
                    return nil
                }
            }
        }
        return rect
    }

    /// 完整快捷键速查卡矩形与底部开关按钮矩形（`isCheatSheetVisible == false` 时为 nil）。
    static func cheatSheetGeometry(for state: State) -> (cardRect: CGRect, toggleRect: CGRect)? {
        guard state.isCheatSheetVisible, !state.isSuppressedByMode else { return nil }
        let cardWidth: CGFloat = min(352, max(260, state.viewBounds.width - cornerMargin * 2))
        let sections = cheatSheetSections(isEnglish: state.isEnglish)

        let padTop: CGFloat = 14
        let padBottom: CGFloat = 12
        let titleHeight: CGFloat = 20
        let sectionHeaderHeight: CGFloat = 18
        let rowHeight: CGFloat = 22
        let sectionSpacing: CGFloat = 10
        let footerHeight: CGFloat = 30

        var height = padTop + titleHeight + 8
        for (index, section) in sections.enumerated() {
            if index > 0 {
                height += sectionSpacing
            }
            height += sectionHeaderHeight + CGFloat(section.items.count) * rowHeight
        }
        height += 10 + footerHeight + padBottom

        let x = state.viewBounds.minX + max(cornerMargin, state.safeInsets.left + cornerMargin)
        let bottomAnchor: CGFloat
        if let pill = pillRect(for: state) {
            bottomAnchor = pill.minY - 8
        } else {
            bottomAnchor = state.viewBounds.maxY - max(cornerMargin, state.safeInsets.bottom + cornerMargin)
        }
        let minY = state.viewBounds.minY + max(cornerMargin, state.safeInsets.top + cornerMargin)
        let clampedHeight = min(height, max(160, bottomAnchor - minY))
        let y = max(minY, bottomAnchor - clampedHeight)
        let cardRect = CGRect(x: x.rounded(), y: y.rounded(), width: cardWidth.rounded(), height: clampedHeight.rounded())
        let toggleRect = CGRect(
            x: cardRect.minX + 12,
            y: cardRect.maxY - padBottom - footerHeight + 2,
            width: cardRect.width - 24,
            height: footerHeight - 4
        )
        return (cardRect, toggleRect)
    }

    /// 命中检测：速查卡优先于底部微胶囊。
    static func hitTest(_ point: CGPoint, state: State) -> HitTarget? {
        if let sheet = cheatSheetGeometry(for: state), sheet.cardRect.contains(point) {
            if sheet.toggleRect.contains(point) {
                return .toggleHintVisibility
            }
            return .cheatSheetBody
        }
        if let pill = pillRect(for: state), pill.contains(point) {
            return .toggleCheatSheet
        }
        return nil
    }

    // MARK: - 绘制

    static func draw(_ state: State, in context: CGContext) {
        if let pill = pillRect(for: state) {
            drawPill(pill, state: state, in: context)
        }
        if let sheet = cheatSheetGeometry(for: state) {
            drawCheatSheet(sheet.cardRect, toggleRect: sheet.toggleRect, state: state, in: context)
        }
    }

    private static func drawPill(_ rect: CGRect, state: State, in context: CGContext) {
        context.saveGState()
        let path = CGPath(roundedRect: rect, cornerWidth: rect.height / 2, cornerHeight: rect.height / 2, transform: nil)
        context.setFillColor(NSColor.black.withAlphaComponent(0.68).cgColor)
        context.addPath(path)
        context.fillPath()
        context.setStrokeColor(NSColor.white.withAlphaComponent(0.16).cgColor)
        context.setLineWidth(1)
        context.addPath(path)
        context.strokePath()

        let segments = pillSegments(isSelectionConfirmed: state.isSelectionConfirmed, isEnglish: state.isEnglish)

        var x = rect.minX + pillPaddingX
        for (index, segment) in segments.enumerated() {
            if index > 0 {
                // 柔和中点分隔符
                let dotX = x + segmentGap / 2
                context.setFillColor(NSColor.white.withAlphaComponent(0.28).cgColor)
                context.fillEllipse(in: CGRect(x: dotX - 1, y: rect.midY - 1, width: 2, height: 2))
                x += segmentGap
            }

            let keyMeasured = makeLine(segment.key, font: pillKeyFont, color: white95)
            let capWidth = ceil(keyMeasured.width) + keycapPadX * 2
            let capRect = CGRect(
                x: x,
                y: rect.midY - keycapHeight / 2,
                width: capWidth,
                height: keycapHeight
            )
            let capPath = CGPath(roundedRect: capRect, cornerWidth: 4.5, cornerHeight: 4.5, transform: nil)
            context.setFillColor(NSColor.white.withAlphaComponent(0.14).cgColor)
            context.addPath(capPath)
            context.fillPath()
            context.setStrokeColor(NSColor.white.withAlphaComponent(0.22).cgColor)
            context.setLineWidth(0.75)
            context.addPath(capPath)
            context.strokePath()

            drawLine(
                keyMeasured,
                atTopLeft: CGPoint(x: capRect.midX - keyMeasured.width / 2, y: capRect.midY - keyMeasured.height / 2),
                in: context
            )
            x += capWidth + keyToLabelGap

            let labelMeasured = makeLine(segment.label, font: pillLabelFont, color: white76)
            drawLine(
                labelMeasured,
                atTopLeft: CGPoint(x: x, y: rect.midY - labelMeasured.height / 2),
                in: context
            )
            x += ceil(labelMeasured.width)
        }
        context.restoreGState()
    }

    private static func drawCheatSheet(
        _ cardRect: CGRect,
        toggleRect: CGRect,
        state: State,
        in context: CGContext
    ) {
        context.saveGState()
        let path = CGPath(roundedRect: cardRect, cornerWidth: 12, cornerHeight: 12, transform: nil)
        context.setShadow(
            offset: CGSize(width: 0, height: -4),
            blur: 14,
            color: NSColor.black.withAlphaComponent(0.42).cgColor
        )
        context.setFillColor(NSColor(calibratedWhite: 0.08, alpha: 0.9).cgColor)
        context.addPath(path)
        context.fillPath()
        context.setShadow(offset: .zero, blur: 0, color: nil)

        context.setStrokeColor(NSColor.white.withAlphaComponent(0.18).cgColor)
        context.setLineWidth(1)
        context.addPath(path)
        context.strokePath()

        let title = state.isEnglish ? "Overlay Shortcuts" : "截图与标注快捷操作"
        let closeHint = state.isEnglish ? "? / Esc to close" : "按 ? 或 Esc 关闭"
        let padX: CGFloat = 14
        var y = cardRect.minY + 13

        let titleMeasured = makeLine(title, font: sheetTitleFont, color: white96)
        drawLine(titleMeasured, atTopLeft: CGPoint(x: cardRect.minX + padX, y: y), in: context)

        let closeMeasured = makeLine(closeHint, font: sheetCloseFont, color: white50)
        drawLine(closeMeasured, atTopLeft: CGPoint(x: cardRect.maxX - padX - closeMeasured.width, y: y + 2), in: context)
        y += 26

        let sections = cheatSheetSections(isEnglish: state.isEnglish)
        for (secIdx, section) in sections.enumerated() {
            if secIdx > 0 { y += 10 }
            let sectionMeasured = makeLine(section.title, font: sheetSectionFont, color: white54)
            drawLine(sectionMeasured, atTopLeft: CGPoint(x: cardRect.minX + padX, y: y), in: context)
            y += 18

            for item in section.items {
                let keyMeasured = makeLine(item.key, font: pillKeyFont, color: white95)
                let capW = ceil(keyMeasured.width) + 10
                let capRect = CGRect(x: cardRect.minX + padX, y: y + 1, width: capW, height: 18)
                let capPath = CGPath(roundedRect: capRect, cornerWidth: 4.5, cornerHeight: 4.5, transform: nil)
                context.setFillColor(NSColor.white.withAlphaComponent(0.13).cgColor)
                context.addPath(capPath)
                context.fillPath()
                drawLine(
                    keyMeasured,
                    atTopLeft: CGPoint(x: capRect.midX - keyMeasured.width / 2, y: capRect.midY - keyMeasured.height / 2),
                    in: context
                )

                let descX = capRect.maxX + 8
                let descMeasured = makeLine(item.label, font: sheetDescFont, color: white84)
                let maxDescWidth = max(40, cardRect.maxX - padX - descX)
                context.saveGState()
                context.clip(to: CGRect(x: descX, y: capRect.minY - 2, width: maxDescWidth, height: 22))
                drawLine(
                    descMeasured,
                    atTopLeft: CGPoint(x: descX, y: capRect.midY - descMeasured.height / 2),
                    in: context
                )
                context.restoreGState()
                y += 22
            }
        }

        // 底部区域分隔线与「显示/隐藏左下角提示」点击行
        context.setStrokeColor(NSColor.white.withAlphaComponent(0.12).cgColor)
        context.setLineWidth(1)
        context.move(to: CGPoint(x: cardRect.minX + padX, y: toggleRect.minY - 5))
        context.addLine(to: CGPoint(x: cardRect.maxX - padX, y: toggleRect.minY - 5))
        context.strokePath()

        let toggleBgPath = CGPath(roundedRect: toggleRect, cornerWidth: 6, cornerHeight: 6, transform: nil)
        context.setFillColor(NSColor.white.withAlphaComponent(0.08).cgColor)
        context.addPath(toggleBgPath)
        context.fillPath()

        let toggleLabel: String
        if state.isEnglish {
            toggleLabel = state.isHintEnabled ? "Hide bottom hint pill" : "Show bottom hint pill"
        } else {
            toggleLabel = state.isHintEnabled ? "不再显示左下角快捷提示" : "重新显示左下角快捷提示"
        }
        let toggleMeasured = makeLine(toggleLabel, font: pillLabelFont, color: white85)
        drawLine(
            toggleMeasured,
            atTopLeft: CGPoint(x: toggleRect.midX - toggleMeasured.width / 2, y: toggleRect.midY - toggleMeasured.height / 2),
            in: context
        )

        context.restoreGState()
    }
}
