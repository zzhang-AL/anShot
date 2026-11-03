//
//  EditorStyleStore.swift
//  AnShotUI
//
//  新建标注的样式记忆：把工具栏上最后一次选定的样式带到下一次会话。
//
//  ── 为什么只记样式，不记当前工具 ────────────────────────────
//
//  工具表达的是「这一次要做什么」，不是长期偏好：上次用箭头画完、关掉编辑器，
//  下次打开若沿用箭头，用户想框选时第一笔就会画出箭头——而且这个错很容易
//  被当成「工具坏了」。样式（颜色、线宽、字号、各个工具的参数）则相反，
//  是同一个人反复复用的东西，每次重设纯属白做。
//
//  ── 为什么不担心「隐状态」──────────────────────────────────
//
//  样式本来就显示在标注工具栏上：颜色选中点、线宽/字号读数、各类档位按钮
//  都是按当前 `style` 画的。恢复后一眼可见，改一笔就覆盖，
//  不存在「看不见却在生效」的配置——这正是它和「记住上次选区」的区别。
//
//  ── 为什么用独立 key + 一份 JSON ─────────────────────────────
//
//  与 `AppSettings` 的 `settings.*` 分开：两套偏好的字段增长互不影响，
//  也不会因为一次写坏把对方的数据一起带走。整份样式一次写入，
//  避免逐字段写留下「颜色更新了、线宽还是旧的」这种半份状态。
//

import AnShotCore
import Foundation

/// 新建标注的默认样式存储。
///
/// 单例：样式跨会话保留，而编辑器状态本身随每次截图重建。
@MainActor
final class EditorStyleStore {

    static let shared = EditorStyleStore()

    /// 独立 key。前缀用 `editor.` 而不是 `settings.`：后者是 `AppSettings` 的地盘。
    private static let key = "editor.defaultStyle"

    private let defaults: UserDefaults

    /// - Parameter defaults: 注入以便测试使用独立 suite，避免污染真实偏好。
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    // MARK: - 读写

    /// 读取上次的样式。
    ///
    /// 没有记录、或记录被外部改坏（不是 JSON / 字段类型不对）时退回
    /// `AnnotationStyle.default`：一个读不出来的偏好不能变成「编辑器起不来」。
    func load() -> AnnotationStyle {
        guard let data = defaults.data(forKey: Self.key),
              let record = try? JSONDecoder().decode(EditorStyleRecord.self, from: data) else {
            return .default
        }
        return record.resolved()
    }

    /// 记住当前样式。
    ///
    /// 编码失败时**保留旧记录**而不是清空：值来自界面控件，不含 JSON 无法表示的
    /// 数值（NaN/无穷），失败只可能是极端情况；此时留下上一份能用的样式，
    /// 比把记忆抹成默认值更容易解释。
    func save(_ style: AnnotationStyle) {
        guard let data = try? JSONEncoder().encode(EditorStyleRecord(style)) else { return }
        defaults.set(data, forKey: Self.key)
    }
}

// MARK: - 落盘格式

/// 落盘用的扁平记录。
///
/// 所有字段都是可选的：解码时缺哪个字段就只让哪个字段回落默认值，
/// 而不是整份丢弃——否则每加一个字段，用户已有的记忆就会失效一次。
///
/// 不直接把 `AnnotationStyle` 声明成 `Codable`：它旁边的 `Annotation` 一族
/// 的 JSON 是**工程文件契约**（见 `Annotation.swift` 文件头），工具栏偏好
/// 没必要挤进同一套格式，也不该为了让一个 UserDefaults 记录可编码而改变模型。
private struct EditorStyleRecord: Codable {
    var shapeColor: RGBAColor?
    var shapeLineWidth: Double?
    var textColor: RGBAColor?
    var textFontSize: Double?
    var mosaicMode: String?
    var mosaicBlockSize: Double?
    var mosaicBrushRadius: Double?
    var highlightColor: RGBAColor?
    var numberingRadius: Double?
    var magnifierZoom: Double?
    var magnifierRadius: Double?
    var curvedArrowBend: Double?
    var arrowHeadScale: Double?

    init(_ style: AnnotationStyle) {
        shapeColor = style.shapeColor
        shapeLineWidth = style.shapeLineWidth
        textColor = style.textColor
        textFontSize = style.textFontSize
        // 枚举存 rawValue：落盘的是字符串，读回时按当前枚举定义解释，
        // 未来增删子模式也不会让整份记录解不出来。
        mosaicMode = style.mosaicMode.rawValue
        mosaicBlockSize = style.mosaicBlockSize
        mosaicBrushRadius = style.mosaicBrushRadius
        highlightColor = style.highlightColor
        numberingRadius = style.numberingRadius
        magnifierZoom = style.magnifierZoom
        magnifierRadius = style.magnifierRadius
        curvedArrowBend = style.curvedArrowBend
        arrowHeadScale = style.arrowHeadScale
    }

    /// 以 `AnnotationStyle.default` 为底，逐字段覆盖并夹回界面能表达的取值。
    func resolved() -> AnnotationStyle {
        let fallback = AnnotationStyle.default
        return AnnotationStyle(
            shapeColor: shapeColor?.clamped() ?? fallback.shapeColor,
            shapeLineWidth: shapeLineWidth.map {
                Self.continuous($0, in: AnnotationStyle.lineWidthRange)
            } ?? fallback.shapeLineWidth,
            textColor: textColor?.clamped() ?? fallback.textColor,
            textFontSize: textFontSize.flatMap {
                Self.option($0, in: AnnotationStyle.fontSizes)
            } ?? fallback.textFontSize,
            mosaicMode: mosaicMode.flatMap { MosaicToolMode(rawValue: $0) } ?? fallback.mosaicMode,
            mosaicBlockSize: mosaicBlockSize.flatMap {
                Self.option($0, in: AnnotationStyle.mosaicBlockSizes)
            } ?? fallback.mosaicBlockSize,
            mosaicBrushRadius: mosaicBrushRadius.map(Self.brushRadius) ?? fallback.mosaicBrushRadius,
            highlightColor: highlightColor?.clamped() ?? fallback.highlightColor,
            numberingRadius: numberingRadius.flatMap {
                Self.option($0, in: AnnotationStyle.numberingRadii)
            } ?? fallback.numberingRadius,
            magnifierZoom: magnifierZoom.flatMap {
                Self.option($0, in: AnnotationStyle.magnifierZooms)
            } ?? fallback.magnifierZoom,
            magnifierRadius: magnifierRadius.flatMap {
                Self.option($0, in: AnnotationStyle.magnifierRadii)
            } ?? fallback.magnifierRadius,
            curvedArrowBend: curvedArrowBend.flatMap {
                Self.option($0, in: AnnotationStyle.curvedArrowBends)
            } ?? fallback.curvedArrowBend,
            arrowHeadScale: arrowHeadScale.map {
                Self.continuous($0, in: AnnotationStyle.arrowHeadScaleRange)
            } ?? fallback.arrowHeadScale
        )
    }

    // MARK: - 取值校正

    /// 连续量：夹进区间，并按界面可显示的精度量化到 0.1。
    ///
    /// 量化的理由是**显示与生效一致**：工具栏的线宽/箭头大小只显示一位小数
    /// （`AnnotationEditorState.selectLineWidth` 也按 0.1 定量化），
    /// 若从存储里读回 4.347，界面写「4.3」而实际画 4.347，用户就无法从读数
    /// 知道自己画了多粗。
    private static func continuous(_ value: Double, in range: ClosedRange<Double>) -> Double {
        let clamped = min(max(value, range.lowerBound), range.upperBound)
        return (clamped * 10).rounded() / 10
    }

    /// 离散量：回落到**最近**的档位。
    ///
    /// 这些值是工具栏按钮的档位集合，渲染器靠 `firstIndex(of:)` 找当前档，
    /// 找不到就按第 0 档高亮（`AnnotationToolbarRenderer`）。若存进一个档位外的
    /// 值，界面显示与实际生效就会分叉——那才是真正的隐状态。
    /// 正常写入只可能来自这些档位，这里兜的是被外部改坏的情况。
    private static func option(_ value: Double, in options: [Double]) -> Double? {
        options.min { abs($0 - value) < abs($1 - value) }
    }

    /// 笔刷半径：模型存半径、界面调直径（与 `selectMosaicBrushDiameter` 同一套换算）。
    /// 量化到整数直径再折回半径，滑块读数才与真实笔刷一致。
    private static func brushRadius(_ radius: Double) -> Double {
        let diameter = min(
            max(radius * 2, AnnotationStyle.mosaicBrushDiameterRange.lowerBound),
            AnnotationStyle.mosaicBrushDiameterRange.upperBound
        )
        return diameter.rounded() / 2
    }
}

private extension RGBAColor {
    /// 按 `RGBAColor` 的契约把分量夹进 0...1。
    ///
    /// 越界分量不会让绘制崩溃，但会让「色块显示的颜色」与「实际画出的颜色」
    /// 不一致（色块由 AppKit 自行钳制），这种不一致没有任何界面线索可解释。
    func clamped() -> RGBAColor {
        RGBAColor(
            r: min(max(r, 0), 1),
            g: min(max(g, 0), 1),
            b: min(max(b, 0), 1),
            a: min(max(a, 0), 1)
        )
    }
}
