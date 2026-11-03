//
//  AnnotationEditorState.swift
//  AnShotUI
//
//  标注编辑器的权威状态（P6）。
//
//  设计要点（对应 docs/m1-capture/model.md §6 与 plan.md 的 P6 落地）：
//
//  - **单一权威**：当前工具、样式、选区、已提交标注、未提交草稿、
//    正在编辑的文字、撤销历史只存在这里。
//    视图（覆盖层、工具栏）只显示状态并向上抛事件，不自己保存编辑数据。
//  - **草稿不入历史**：拖拽过程中的每个鼠标位置只更新 `draft`；
//    松开鼠标（或文字编辑结束）时才提交一个值快照。
//    这样「撤销一次」对应「撤掉一个标注」，而不是撤掉一串中间位置。
//  - **选区也是编辑状态**：`EditState` 里就有 selection，
//    移动选区在手势结束时提交一次，撤销时整体回到上一步。
//    只把 annotations 恢复、把 selection 落在外面，会让历史与画面脱节。
//  - **样式按工具分组**：形状关心线宽、文字关心字号、马赛克关心块大小，
//    合成一套 color/lineWidth 会串味（P6 首次实现里字号跟着线宽走就是这个毛病）。
//  - **历史是值快照**：`EditState` 含 selection + annotations，不复制位图。
//

import AnShotCore
import Foundation

/// 标注工具。
enum AnnotationTool: String, CaseIterable, Sendable {
    /// 指针：不创建标注，鼠标行为与 P4 一致（调整选区）。
    case pointer
    case rectangle
    case line
    case arrow
    case text
    case mosaic
    /// 编号标记：圆底 + 自增序号。
    case numbering
    /// 高亮：半透明矩形。
    case highlight
    /// 测量：两点连线 + 距离读数。
    case measure
    /// 放大镜：圆形区域放大（与马赛克同类的像素处理）。
    case magnifier
    /// 手绘：自由笔迹（存储已简化的点序列）。
    case freehand
    /// 弯曲箭头：二次贝塞尔 + 箭头头部。
    case curvedArrow

    /// 主工具栏上的分组。
    ///
    /// 主栏只呈现分组，具体形状/设置放到二级面板：
    /// 平铺全部按钮会让工具条比选区还宽，也会让「改颜色」这类高频操作
    /// 与「换工具」争夺同一行注意力。
    enum Family: String, CaseIterable, Sendable {
        case pointer
        case shape
        case text
        case mosaic
    }

    var family: Family {
        switch self {
        case .pointer: return .pointer
        // 标注增强里的形状与标记都归 `.shape`：它们共用「颜色 + 线宽」这一组样式，
        // 单独开一个 family 只会让工具栏多一层没有区分度的分组。
        case .rectangle, .line, .arrow, .numbering, .highlight, .measure, .freehand, .curvedArrow:
            return .shape
        case .text: return .text
        // 放大镜与马赛克同类：都要读取底图像素做重采样，因此放在同一分组。
        case .mosaic, .magnifier: return .mosaic
        }
    }

    /// 分组内可选的具体工具（主栏按钮的二级面板内容）。
    static func tools(in family: Family) -> [AnnotationTool] {
        allCases.filter { $0.family == family }
    }

    /// 工具栏上显示的名字。
    var displayName: String {
        switch self {
        case .pointer: return "指针"
        case .rectangle: return "矩形"
        case .line: return "直线"
        case .arrow: return "箭头"
        case .text: return "文字"
        case .mosaic: return "马赛克"
        case .numbering: return "编号"
        case .highlight: return "高亮"
        case .measure: return "测量"
        case .magnifier: return "放大镜"
        case .freehand: return "手绘"
        case .curvedArrow: return "曲线箭头"
        }
    }

    /// 分组显示的名字。
    static func displayName(of family: Family) -> String {
        switch family {
        case .pointer: return "指针"
        case .shape: return "形状"
        case .text: return "文字"
        case .mosaic: return "马赛克"
        }
    }

    /// 应用内快捷键（覆盖层为 key window 时生效）。
    var keyCharacter: Character {
        switch self {
        case .pointer: return "v"
        case .rectangle: return "r"
        case .line: return "l"
        case .arrow: return "a"
        case .text: return "t"
        case .mosaic: return "m"
        case .numbering: return "n"
        case .highlight: return "h"
        // measure 的 m 已被马赛克占用，用 d（dimension）。
        case .measure: return "d"
        case .magnifier: return "g"
        case .freehand: return "f"
        case .curvedArrow: return "c"
        }
    }

    /// 是否需要靠拖拽出几何形状来创建。
    ///
    /// 文字是「点一下再输入」，指针根本不创建标注，二者不参与拖拽。
    var isDraggable: Bool {
        switch self {
        case .pointer, .text: return false
        default: return true
        }
    }

    /// 是否是绘制类工具（决定鼠标落在选区内时的行为）。
    var isDrawingTool: Bool {
        self != .pointer
    }
}

/// 马赛克的两种子模式。
enum MosaicToolMode: String, CaseIterable, Sendable {
    /// 框选：拖出一个矩形，整块像素化。
    case rectangle
    /// 涂抹：按住拖动，沿路径刷出像素化区域。
    case brush

    var displayName: String {
        switch self {
        case .rectangle: return "框选"
        case .brush: return "涂抹"
        }
    }
}

/// 新建标注使用的样式。
///
/// 按工具分组保存：改文字颜色不会动到箭头的颜色，
/// 改字号也不再被线宽牵动。
struct AnnotationStyle: Equatable, Sendable {
    // 形状组（矩形 / 直线 / 箭头）
    var shapeColor: RGBAColor
    var shapeLineWidth: Double

    // 文字组。字号单位是**点**（界面单位），写入模型时按 scaleFactor 换算为像素。
    var textColor: RGBAColor
    var textFontSize: Double

    // 马赛克组
    var mosaicMode: MosaicToolMode
    var mosaicBlockSize: Double
    /// 涂抹笔刷半径（**点**，界面单位），写入模型时同样换算为像素。
    var mosaicBrushRadius: Double

    /// 高亮颜色（**带透明度**：用途是标出来但仍看得见底下的内容）。
    var highlightColor: RGBAColor

    /// 编号圆的半径（像素）。
    var numberingRadius: Double

    /// 放大镜倍数与半径。
    var magnifierZoom: Double
    var magnifierRadius: Double

    /// 曲线箭头的弯曲程度：控制点相对弦中点的垂直偏移比例（0 = 直线）。
    var curvedArrowBend: Double

    /// 箭头头部的**额外缩放倍率**。
    ///
    /// 乘在「线宽 × 4（长）/ × 3（宽）」这个基准之上，而不是直接存绝对尺寸：
    /// 基准本身要随线宽走（细线配大箭头会很突兵），倍率则让用户在这个
    /// 保持比例的前提下单独放大或缩小头部。
    ///
    /// 默认 1 就是改动前的行为，老会话与已有习惯不受影响。
    var arrowHeadScale: Double

    /// 调色板。6 色够用，且无需自定义取色器。
    static let palette: [RGBAColor] = [
        RGBAColor(r: 1.00, g: 0.23, b: 0.19, a: 1),
        RGBAColor(r: 1.00, g: 0.80, b: 0.00, a: 1),
        RGBAColor(r: 0.20, g: 0.78, b: 0.35, a: 1),
        RGBAColor(r: 0.00, g: 0.48, b: 1.00, a: 1),
        RGBAColor(r: 0.10, g: 0.10, b: 0.10, a: 1),
        RGBAColor(r: 1.00, g: 1.00, b: 1.00, a: 1),
    ]

    /// 线宽区间（底图像素）。这是**模型单位**，不随屏幕缩放变化。
    ///
    /// 从「三档按钮」改成连续区间：2 / 4 / 8 这样的档位在两头都不够用——
    /// 圈注表格里的细线要 1~2px，在大图上画重点要 15px 以上，
    /// 而 5、6 这类中间值恰恰是绝大多数时候想要的，档位永远给不出。
    ///
    /// 上下限按实际用途定：1px 是仍能看清的最细描边，
    /// 24px 在 4K 截图上已是一笔明显的记号；再粗就开始盖住被标注的内容本身。
    static let lineWidthRange: ClosedRange<Double> = 1 ... 24

    /// 文字字号档位（点，界面单位）。
    static let fontSizes: [Double] = [16, 20, 28, 40, 56]

    /// 马赛克块大小档位（底图像素）。
    static let mosaicBlockSizes: [Double] = [6, 12, 20]

    /// 涂抹笔刷直径档位（点，界面单位）。
    /// 涂抹笔刷直径区间（**点**，界面单位）。
    ///
    /// 与线宽同样从「档位」改成连续滑块：16 / 32 / 56 三档在两头都不够用——
    /// 修掉一小块文字要 8pt 以下，整片遮掉要 80pt 以上。
    ///
    /// 下限 6pt：再细就与马赛克块本身差不多大，看不出「涂过」的痕迹；
    /// 上限 120pt：已能一笔盖住大半个画面，再大只是让手更难对准。
    static let mosaicBrushDiameterRange: ClosedRange<Double> = 6 ... 120

    /// 涂抹笔刷的默认直径（点）。对应旧的中间那一档（32）。
    static let defaultMosaicBrushDiameter: Double = 32
    static let highlightColors: [RGBAColor] = [
        RGBAColor(r: 1, g: 0.95, b: 0.2, a: 0.35),
        RGBAColor(r: 0.35, g: 0.9, b: 0.45, a: 0.35),
        RGBAColor(r: 0.4, g: 0.7, b: 1, a: 0.35),
    ]
    static let numberingRadii: [Double] = [14, 20, 28]
    static let magnifierZooms: [Double] = [1.5, 2, 3]
    static let magnifierRadii: [Double] = [40, 60, 90]
    static let curvedArrowBends: [Double] = [0, 0.25, 0.5]
    /// 箭头大小倍率区间。下限 0.5 时头部约为线宽的两倍，仍能认成箭头；
    /// 上限 3 时头部长度达线宽的 12 倍，已经是很重的标记。
    static let arrowHeadScaleRange: ClosedRange<Double> = 0.5 ... 3

    static let `default` = AnnotationStyle(
        shapeColor: palette[0],
        shapeLineWidth: 4,
        textColor: palette[0],
        textFontSize: fontSizes[2],
        mosaicMode: .rectangle,
        mosaicBlockSize: mosaicBlockSizes[1],
        mosaicBrushRadius: defaultMosaicBrushDiameter / 2,
        highlightColor: highlightColors[0],
        numberingRadius: numberingRadii[1],
        magnifierZoom: magnifierZooms[1],
        magnifierRadius: magnifierRadii[1],
        curvedArrowBend: curvedArrowBends[1],
        arrowHeadScale: 1
    )

    /// 箭头头部长度（底图像素）：线宽基准 × 用户倍率。
    ///
    /// 把「4 / 3 倍基准 × 倍率」集中成一个计算属性，而不是在
    /// 箭头与曲线箭头两处各乘一遍：两个工具共用同一种头部几何，
    /// 分头写迟早会出现「改了箭头的头部大小，曲线箭头却没跟着变」。
    var arrowHeadLength: Double { shapeLineWidth * 4 * arrowHeadScale }

    /// 箭头头部宽度（底图像素）。
    var arrowHeadWidth: Double { shapeLineWidth * 3 * arrowHeadScale }

    /// 当前工具使用的颜色；该工具不取色时为 `nil`。
    ///
    /// 返回 `nil` 的两种情形：
    /// - **指针**：它不创建标注，没有颜色可言；
    /// - **马赛克**：它是像素化处理而不是绘制颜色，
    ///   显示「当前颜色」会误导用户（改完色，画出来的马赛克毫无变化）。
    func color(for tool: AnnotationTool) -> RGBAColor? {
        switch tool {
        case .text: return textColor
        case .rectangle, .line, .arrow: return shapeColor
        // 放大镜与马赛克同理：改「颜色」不会让放大出来的像素变色，显示它只会误导。
        case .numbering, .measure, .freehand, .curvedArrow: return shapeColor
        case .highlight: return highlightColor
        case .pointer, .mosaic, .magnifier: return nil
        }
    }
}

/// 正在编辑的一段文字。
///
/// 放在编辑器状态里而不是留在视图上：
/// 输入过程中用户可能改字号或改颜色，改完必须同步到输入控件；
/// 提交时也要保证「看到的」与「写进模型的」是同一份内容。
struct TextEditDraft: Equatable {
    /// 正在重新编辑的已有标注 ID；新建文字为 nil。
    var annotationID: UUID?
    /// 文字左上角（底图像素）。
    var topLeft: PixelPoint
    var text: String
    /// 字号（点，界面单位）。
    var fontSize: Double
    var color: RGBAColor

    /// 该文字使用的字体描述（模型单位：像素）。
    func font(scaleFactor: CGFloat) -> FontDescriptor {
        FontDescriptor.system(size: fontSize * Double(scaleFactor))
    }
}

/// 标注编辑的权威状态。
@MainActor
final class AnnotationEditorState {
    // MARK: - 状态

    private(set) var tool: AnnotationTool = .pointer

    var style: AnnotationStyle = .default {
        didSet {
            guard style != oldValue else { return }
            // 正在编辑的文字要跟随样式变化：用户改颜色/字号后
            // 输入控件里的字必须立刻跟着变，否则「看到的」与「提交的」不一致。
            if textDraft != nil {
                textDraft?.color = style.textColor
                textDraft?.fontSize = style.textFontSize
            }
            notifyChange()
        }
    }

    /// 当前选区（底图像素）。与 `EditState.selection` 保持同步。
    private(set) var selection: PixelRect

    /// 当前选区是否已被用户确认（而非自动识别给出的候选）。
    ///
    /// **存在的理由**：自动识别的结果随鼠标移动不断变化，它不体现用户的
    /// 任何决定。而选区一旦存在，视图就会把「内部按下拖拽」解释为移动——
    /// 于是用户看到识别框后想自己框选，一拖却把整个框平移走了。
    /// 两种阶段的交互含义不同，必须分开表达：
    /// - 候选：按下拖拽 = 重新框选；不绘制缩放手柄；光标为十字。
    /// - 已确认：手柄缩放、内部拖拽移动、外部拖拽重新框选。
    ///
    /// 权威放在编辑器而不是各窗口的视图里：确认是**会话级**的决定，
    /// 多显示器时每屏一个视图，各存一份会让用户在 A 屏确认后
    /// B 屏仍冒出识别候选。
    private(set) var isSelectionConfirmed: Bool

    /// 已提交的标注（底图像素坐标，数组索引即 z 序）。
    private(set) var annotations: [Annotation] = []

    /// 当前选中的标注 ID（`nil` 表示没有选中任何标注）。
    ///
    /// 只存 ID 而不是整条标注：标注会在移动/改样式/撤销时被整体替换，
    /// 存副本会导致「选中的是旧值、画面上是新值」。ID 是稳定标识，
    /// 每条操作都按 ID 回查当前数组，天然不会读到过期数据。
    ///
    /// 不放进 `EditState`：历史快照表达的是「被编辑的内容」，
    /// 选中是视图层的焦点。撤销后若该 ID 已不存在，由 `apply` 自动清空。
    private(set) var selectedAnnotationID: UUID?

    /// 选中的标注（按当前数组回查）。
    var selectedAnnotation: Annotation? {
        selectedAnnotationIndex.map { annotations[$0] }
    }

    /// 是否有选中标注。
    var hasSelectedAnnotation: Bool { selectedAnnotation != nil }

    /// 选中标注在当前数组中的下标。
    private var selectedAnnotationIndex: Int? {
        guard let id = selectedAnnotationID else { return nil }
        return annotations.firstIndex { $0.id == id }
    }

    /// 未提交的草稿。拖拽过程中持续更新，不进入历史。
    private(set) var draft: Annotation?

    /// 正在编辑的文字（新建或重新编辑）。
    private(set) var textDraft: TextEditDraft?

    var canUndo: Bool { history.canUndo }
    var canRedo: Bool { history.canRedo }
    var hasDraft: Bool { draft != nil }
    var isEditingText: Bool { textDraft != nil }

    /// 状态变化回调（工具、样式、标注、草稿、历史可用性）。
    var onChange: (() -> Void)?

    /// 文字草稿**内容**变化的回调（每次按键）。
    ///
    /// 与 `onChange` 分开：内容变化只需要同步输入控件本身，
    /// 不必触发整幅画面的重绘与重合成。
    var onTextContentChange: (() -> Void)?

    // MARK: - 私有

    private var history: EditHistory
    private var draftAnchor: PixelPoint?
    /// 涂抹草稿累积的路径点（底图像素）。
    private var draftStrokePoints: [PixelPoint] = []

    /// 当前草稿占用的编号序号（仅编号工具有值）。
    ///
    /// 序号必须在**手势开始**时取一次并随草稿保存：`updateDraft` 在每次
    /// `mouseDragged` 都会重建草稿，若在那里取号，拖一次就会消耗掉几十个序号，
    /// 用户看到的就是「拖一下号码跳到 5、再拖一下跳到 9」。
    private var draftNumberingIndex: Int?

    init(selection: PixelRect? = nil) {
        let initial = selection ?? PixelRect(
            origin: .zero,
            size: PixelSize(width: 0, height: 0)
        )
        self.selection = initial
        // 会话起点一律是**候选**——即使带着默认选区（默认策略给的整屏）进来。
        //
        // 那个选区不是用户的决定：它是「还没动鼠标时给个可用起点」，
        // 第一次鼠标移动就该被识别改写。曾经把「有初始选区」当成已确认，
        // 后果是识别被守卫永久挡死——用户看到的现象是
        // 「按 Control+1 后完全没有自动识别，只能拖拽框选」。
        //
        // 「程序化设置 = 已确认」另由 `OverlayController.setSelection`
        // → `commitSelection` 表达，不走这里。
        self.isSelectionConfirmed = false
        history = EditHistory(initial: EditState(selection: initial))
    }

    /// 更新选区但**不写入历史**。
    ///
    /// 供自动识别使用：识别结果随鼠标移动不断变化，每次都提交会让
    /// 撤销栈被几十个中间态塞满，`⌘Z` 变得毫无用处。
    /// 只有用户确认下来的选区（拖拽结束、点击确认）才走 `commitSelection`。
    ///
    /// 识别结果**永远是候选**：它不体现用户的任何决定，故这里把确认状态
    /// 一并退回。
    func setPreviewSelection(_ rect: PixelRect) {
        guard rect != selection || isSelectionConfirmed else { return }
        selection = rect
        isSelectionConfirmed = false
        notifyChange()
    }

    /// 确认当前选区：把自动识别的候选转为用户的既定选区。
    ///
    /// 确认后识别不再覆盖它，选区内部拖拽的含义也从「重新框选」
    /// 变成「移动」。
    ///
    /// 不写历史：确认既不改变选区几何也不改变标注，往撤销栈里压一条
    /// 内容相同的快照，只会让用户按 ⌘Z 时看不到任何变化。
    func confirmSelection() {
        guard !isSelectionConfirmed else { return }
        isSelectionConfirmed = true
        notifyChange()
    }

    // MARK: - 工具与样式

    func select(_ newTool: AnnotationTool) {
        // 选工具等于声明「我要开始编辑了」，先把候选确认下来：
        // 否则用户在候选框上选了矩形工具，一拖拽却变成重新框选选区。
        confirmSelection()

        guard newTool != tool else { return }
        // 切换工具时丢弃未完成的草稿：它属于上一个工具。
        discardDraft()
        // 切到绘制工具时清空选中，切回指针时保留：
        // 绘制工具下拖拽的语义是「画新的」，若还留着上一轮的高亮框，
        // 用户会以为下一次拖拽是移动旧标注；而指针正是用来继续调整的，
        // 清空反而要求用户重新点一次。
        if newTool != .pointer {
            selectedAnnotationID = nil
        }
        tool = newTool
        notifyChange()
    }

    func selectShape(_ shape: AnnotationTool) {
        guard shape.family == .shape else { return }
        select(shape)
    }

    func selectColor(_ color: RGBAColor) {
        // 按当前工具写入对应的颜色槽，避免「改文字颜色顺手改了箭头」。
        switch tool {
        case .text: style.textColor = color
        case .highlight: style.highlightColor = color
        // 放大镜与马赛克是像素处理，没有颜色槽（面板也不会显示颜色）。
        case .pointer, .rectangle, .line, .arrow, .mosaic, .magnifier,
             .numbering, .measure, .freehand, .curvedArrow:
            style.shapeColor = color
        }
        // 有选中标注时，颜色按钮的作用对象是**当前选中的那一条**：
        // 用户是在指针工具下点开编辑控件的，此时改的是既有内容而不是下一笔。
        // 样式槽也一并更新，撤销/取消选中之后接着画，用的就是刚选的颜色。
        updateSelectedColor(color)
    }

    func selectNumberingRadius(_ radius: Double) {
        style.numberingRadius = radius
    }

    func selectMagnifierZoom(_ zoom: Double) {
        style.magnifierZoom = zoom
    }

    func selectCurvedArrowBend(_ bend: Double) {
        style.curvedArrowBend = bend
    }

    func selectLineWidth(_ width: Double) {
        // 量化到 0.1 像素，而不是更粗的 0.5：
        //
        // 0.1px 是底图上的亚像素级差异，任何显示器都表现不出来，
        // 在 68pt 长的轨道上折合不到 0.3pt 的拖动距离——
        // 用户感受到的就是「拖到哪里就得到哪里」，而 0.5px 的步长
        //（每档 1.5pt）快速拖动时是能感觉出跳的。
        //
        // 为什么仍要量化而不是原样存：滑块给出的是 Double 的原始比值
        //（如 4.3478260869565215），原样写进模型会让界面读数与实际值对不上。
        // 0.1 的步长恰好就是界面显示的一位小数，两者严格一致。
        style.shapeLineWidth = Self.quantize(
            width,
            step: 0.1,
            in: AnnotationStyle.lineWidthRange
        )
        // 用**量化后**的值去改选中标注：界面读数显示的就是它，
        // 若把滑块的原始比值写进模型，读数与画面就会差一个亚像素。
        updateSelectedLineWidth(style.shapeLineWidth)
    }

    func selectArrowHeadScale(_ scale: Double) {
        style.arrowHeadScale = Self.quantize(
            scale,
            step: 0.1,
            in: AnnotationStyle.arrowHeadScaleRange
        )
    }

    /// 把滑块的连续输入量化到固定步长，并夹到区间内。
    ///
    /// 量化的理由不是「省空间」，而是**让显示与实际值一致**：
    /// 界面只有两三个字符的宽度显示读数，若模型存 4.3478 而界面写 4，
    /// 用户就再也无法从界面上知道自己到底画了多粗的线。
    /// 步长取得足够细（0.1）后，量化对「无级调节」的体感没有影响。
    private static func quantize(
        _ value: Double,
        step: Double,
        in range: ClosedRange<Double>
    ) -> Double {
        guard step > 0 else { return value }
        let clamped = min(max(value, range.lowerBound), range.upperBound)
        // 先除以步长再取整，最后乘回去；四舍五入而非截断，
        // 否则手柄从左往右拖与从右往左拖会在同一个位置给出差一档的值。
        let ticks = (clamped / step).rounded()
        // 乘回去之后必须按 step 的十进制位数规整一次。
        //
        // 理由：二进制浮点下 `23 * 0.1 = 2.3000000000000003`，而字面量
        // `2.3` 是 `2.2999999999999998`——**两者不相等**。也就是线宽拖到
        // 2.3 时，模型里存的值与任何写 `2.3` 的比较都不相等。
        //
        // 显示层（`String(format: "%.1f", …)`）看不出问题，但精确比较与
        // 序列化往返都会露出来。而量化的本意正是「让显示与实际值一致」
        //（见上方注释），留下这个误差等于没做。
        let scale = Self.decimalScale(of: step)
        return ((ticks * step) * scale).rounded() / scale
    }

    /// `step` 的十进制缩放因子：0.1 → 10，0.25 → 100，1 → 1。
    ///
    /// 用于把量化结果规整到与 step 相同的小数位，消除 `ticks * step`
    /// 引入的二进制浮点误差。实测：以 0.1 为步长遍历 [1, 24] 全区间，
    /// 规整后每一个结果都与对应的一位小数字面量**严格相等**。
    private static func decimalScale(of step: Double) -> Double {
        var scale = 1.0
        var probe = step
        // 最多探 6 位小数：界面用到的步长最细是 0.1，6 位有充足余量。
        for _ in 0 ..< 6 {
            if abs(probe - probe.rounded()) < 1e-9 { break }
            probe *= 10
            scale *= 10
        }
        return scale
    }

    func selectFontSize(_ size: Double) {
        style.textFontSize = size
        // 同颜色/线宽：有选中文字时改的是那一段文字，而不只是「下一段」。
        updateSelectedFontSize(size)
    }

    func selectMosaicMode(_ mode: MosaicToolMode) {
        guard mode != style.mosaicMode else { return }
        discardDraft()
        style.mosaicMode = mode
    }

    func selectMosaicBlockSize(_ size: Double) {
        style.mosaicBlockSize = size
    }

    /// 设置涂抹笔刷的大小。
    ///
    /// 接口收的是**直径**而不是半径：滑块上给用户看的是直径
    ///（「笔刷 32」比「半径 16」直观），而模型里存的是半径。
    /// 换算只在这一处，避免两套单位的乘除散落在布局与渲染里。
    func selectMosaicBrushDiameter(_ diameter: Double) {
        // 量化到整数点：滑块给出的是任意 Double，而界面显示整数直径，
        // 不量化会让读数与实际笔刷大小对不上（与线宽同一套理由）。
        let clamped = min(
            max(diameter, AnnotationStyle.mosaicBrushDiameterRange.lowerBound),
            AnnotationStyle.mosaicBrushDiameterRange.upperBound
        )
        style.mosaicBrushRadius = clamped.rounded() / 2
    }

    // MARK: - 选区

    /// 提交一次选区变化（手势结束时调用）。
    ///
    /// 选区参与历史：撤销一次应当回到「移动选区之前」，
    /// 而不是把标注撤掉却把选区留在原地。
    func commitSelection(_ newSelection: PixelRect) {
        // 先翻确认状态，且**不受几何是否变化影响**：
        // 用户手势结束本身就宣告了「这就是我要的选区」。若因为新几何恰好
        // 等于当前候选就提前返回，视图会一直按候选处理，
        // 用户的下一次拖拽又会变成重新框选。
        let wasConfirmed = isSelectionConfirmed
        isSelectionConfirmed = true

        guard newSelection != selection else {
            if !wasConfirmed { notifyChange() }
            return
        }
        selection = newSelection
        history.commit(EditState(selection: newSelection, annotations: annotations))
        notifyChange()
    }

    // MARK: - 标注选中与再编辑

    /// 按点选中标注（命中测试见 `Annotation.hitTest`）。
    ///
    /// 反向遍历：数组尾部是最上层，视觉上「点到的」应当是压在最上面的那条。
    /// 命中顺序只在这里决定一次，命中/绘制/工具栏都读同一份结果。
    ///
    /// 选中本身**不写历史**：它不改变任何可撤销的内容，而 `EditState`
    /// 也不含选中态——把一条内容相同的快照压进栈里，只会让用户按 ⌘Z
    /// 时看到画面毫无变化。移动/删除/改样式才写历史。
    ///
    /// - Returns: 是否命中某条标注（点到空白返回 `false`，并清除选中）。
    @discardableResult
    func selectAnnotation(at point: PixelPoint, tolerance: Double) -> Bool {
        for annotation in annotations.reversed() where annotation.hitTest(point, tolerance: tolerance) {
            guard selectedAnnotationID != annotation.id else { return true }
            selectedAnnotationID = annotation.id
            notifyChange()
            return true
        }
        // 点到空白 = 取消选中。没有任何选中时不必通知，避免每一下空点击都重绘。
        clearAnnotationSelection()
        return false
    }

    /// 清除选中（点到空白、切换绘制工具、删除之后调用）。
    func clearAnnotationSelection() {
        guard selectedAnnotationID != nil else { return }
        selectedAnnotationID = nil
        notifyChange()
    }

    /// 按增量移动选中标注。
    ///
    /// 增量会被夹住，保证标注不会整块移出选区（画布）：
    /// 用户拖动的是「画布里的内容」，把它拖到画布外就等于丢弃，
    /// 而这里的交互没有删除语义。
    func moveSelected(by delta: PixelPoint) {
        guard let index = selectedAnnotationIndex else { return }
        let annotation = annotations[index]
        let clamped = clampedDelta(for: annotation, delta: delta)
        guard clamped != PixelPoint.zero else { return }

        annotations[index] = annotation.translated(by: clamped)
        history.commit(EditState(selection: selection, annotations: annotations))
        notifyChange()
    }

    /// 删除选中标注。
    ///
    /// - Returns: 是否真的删掉了一条（没有选中或选中已失效时返回 `false`）。
    @discardableResult
    func deleteSelected() -> Bool {
        guard let index = selectedAnnotationIndex else {
            // 选中 ID 可能因为撤销/重做而指向已不存在的标注，顺手清掉悬空引用。
            clearAnnotationSelection()
            return false
        }
        annotations.remove(at: index)
        selectedAnnotationID = nil
        history.commit(EditState(selection: selection, annotations: annotations))
        notifyChange()
        return true
    }

    /// 修改选中标注的颜色（无选中时什么也不做）。
    ///
    /// 只动标注、不动样式：这个接口是「作用于选中项」的窄入口，
    /// 样式槽的联动由 `selectColor` 负责，避免两处各改一遍样式。
    func updateSelectedColor(_ color: RGBAColor) {
        guard let index = selectedAnnotationIndex else { return }
        let updated = Self.restyled(annotations[index], color: color)
        commitSelectedChange(updated, at: index)
    }

    /// 修改选中标注的线宽（底图像素，无选中时什么也不做）。
    func updateSelectedLineWidth(_ width: Double) {
        guard let index = selectedAnnotationIndex else { return }
        let updated = Self.restyled(annotations[index], lineWidth: width)
        commitSelectedChange(updated, at: index)
    }

    /// 修改选中文字的字号（点，界面单位；无选中或选中的不是文字时什么也不做）。
    func updateSelectedFontSize(_ size: Double) {
        guard let index = selectedAnnotationIndex else { return }
        let updated = Self.restyled(annotations[index], fontSize: size)
        commitSelectedChange(updated, at: index)
    }

    /// 把一条已重新构造的标注写回数组并记一步历史。
    ///
    /// 内容没变就不提交：`selectColor` 这类入口会在「点了一个已是当前颜色的色块」
    /// 时被触发，若照样压栈，⌘Z 会退到一个视觉上完全相同的状态。
    private func commitSelectedChange(_ updated: Annotation, at index: Int) {
        guard updated != annotations[index] else { return }
        annotations[index] = updated
        history.commit(EditState(selection: selection, annotations: annotations))
        notifyChange()
    }

    /// 把增量夹到「整条标注仍在选区内」的范围。
    private func clampedDelta(for annotation: Annotation, delta: PixelPoint) -> PixelPoint {
        // 用 `hitBoundingRect` 而不是 `boundingRect`：文字的包围盒在后者里是零尺寸，
        // 那样文字会被判成「随便移都不会出界」。
        let bounds = annotation.hitBoundingRect
        return PixelPoint(
            x: Self.clampAxis(
                delta.x,
                lower: selection.origin.x - bounds.origin.x,
                upper: selection.origin.x + selection.size.width - (bounds.origin.x + bounds.size.width)
            ),
            y: Self.clampAxis(
                delta.y,
                lower: selection.origin.y - bounds.origin.y,
                upper: selection.origin.y + selection.size.height - (bounds.origin.y + bounds.size.height)
            )
        )
    }

    /// 单轴夹取。
    ///
    /// `lower > upper` 表示标注本身比选区还大（例如先选中一个整屏的标注、
    /// 再把选区改小），此时「完全装进去」不可能；退而要求它仍然盖住整个选区，
    /// 至少不会出现拖一下就把画布露出来的观感。
    private static func clampAxis(_ value: Double, lower: Double, upper: Double) -> Double {
        if lower <= upper {
            return min(max(value, lower), upper)
        }
        return min(max(value, upper), lower)
    }

    /// 修改标注样式的纯函数部分。
    ///
    /// 集中在一处而不是每种操作各写一遍 switch：12 种 kind 的字段名相近，
    /// 分散实现时最容易漏掉 `numbering.textColor` 或 `magnifier.border` 这类
    /// 「长得像 stroke 但不是 stroke」的字段。
    private static func restyled(
        _ annotation: Annotation,
        color: RGBAColor? = nil,
        lineWidth: Double? = nil,
        fontSize: Double? = nil
    ) -> Annotation {
        func restroke(_ stroke: StrokeStyle) -> StrokeStyle {
            StrokeStyle(
                color: color ?? stroke.color,
                width: lineWidth ?? stroke.width,
                dash: stroke.dash,
                isSketchy: stroke.isSketchy
            )
        }

        let kind: Annotation.Kind
        switch annotation.kind {
        case let .rectangle(rect, stroke, fill, cornerRadius):
            kind = .rectangle(rect: rect, stroke: restroke(stroke), fill: fill, cornerRadius: cornerRadius)

        case let .line(start, end, stroke):
            kind = .line(start: start, end: end, stroke: restroke(stroke))

        case let .arrow(start, end, stroke, headLength, headWidth):
            kind = .arrow(
                start: start,
                end: end,
                stroke: restroke(stroke),
                headLength: headLength,
                headWidth: headWidth
            )

        case let .text(origin, text, font, textColor, background, maxWidth):
            var updatedFont = font
            var updatedOrigin = origin
            if let fontSize, fontSize > 0, fontSize != font.size {
                updatedFont.size = fontSize
                // 模型存的是**基线起点**。字号变大时 ascent 也变大，
                // 基线原地不动会让文字顶端向上长出去；补上 ascent 差，
                // 用户看到的左上角就停在原处（与输入框里的观感一致）。
                let dy = TextMetrics.ascent(for: updatedFont) - TextMetrics.ascent(for: font)
                updatedOrigin = PixelPoint(x: origin.x, y: origin.y + dy)
            }
            kind = .text(
                origin: updatedOrigin,
                text: text,
                font: updatedFont,
                color: color ?? textColor,
                background: background,
                maxWidth: maxWidth
            )

        case let .mosaic(rect, mode, intensity):
            // 马赛克是像素处理：没有颜色、线宽可言，改了也不会影响成图。
            kind = .mosaic(rect: rect, mode: mode, intensity: intensity)

        case let .mosaicStroke(points, radius, mode, intensity):
            kind = .mosaicStroke(points: points, radius: radius, mode: mode, intensity: intensity)

        case let .numbering(center, radius, index, stroke, fill, textColor):
            // 编号的描边与序号文字创建时同色，改色时两者一起改，
            // 否则会出现「红圈配蓝字」这种谁也调不回来的状态。
            kind = .numbering(
                center: center,
                radius: radius,
                index: index,
                stroke: restroke(stroke),
                fill: fill,
                textColor: color ?? textColor
            )

        case let .highlight(rect, highlightColor):
            kind = .highlight(rect: rect, color: color ?? highlightColor)

        case let .measure(start, end, stroke):
            kind = .measure(start: start, end: end, stroke: restroke(stroke))

        case let .magnifier(center, radius, zoom, border):
            kind = .magnifier(center: center, radius: radius, zoom: zoom, border: restroke(border))

        case let .freehand(points, stroke):
            kind = .freehand(points: points, stroke: restroke(stroke))

        case let .curvedArrow(start, control, end, stroke, headLength, headWidth):
            kind = .curvedArrow(
                start: start,
                control: control,
                end: end,
                stroke: restroke(stroke),
                headLength: headLength,
                headWidth: headWidth
            )
        }
        return Annotation(id: annotation.id, kind: kind)
    }

    // MARK: - 拖拽草稿

    /// 开始一个拖拽草稿。`point` 为底图像素坐标。
    func beginDraft(at point: PixelPoint) {
        // 上一次手势若没走完收尾（正常路径不会发生），这里先把它占用的序号还回去，
        // 否则那个号码会永远消失，编号出现肉眼可见的断档。
        releaseDraftNumberingIndex()

        draftAnchor = point
        draftStrokePoints = [point]
        // 序号在**手势开始**时分配一次，拖动全程复用（见 `draftNumberingIndex`）。
        if tool == .numbering {
            draftNumberingIndex = takeNextNumberingIndex()
        }
        draft = makeDraggedAnnotation(
            from: point,
            to: point,
            strokePoints: [point],
            numberingIndex: draftNumberingIndex
        )
        notifyChange()
    }

    /// 更新拖拽草稿的终点。
    ///
    /// 手绘与马赛克涂抹都需要**累积轨迹点**，其余工具只靠起止两点定形。
    /// 上一版把累积写死在「马赛克 + 涂抹」这一个条件下，手绘因而永远拿到空点序列，
    /// 落到 `makeDraggedAnnotation` 的 `.freehand` 分支里只能退化成
    /// `[start, end]`——**拖出来的永远是直线**，鼠标轨迹整段被丢掉。
    func updateDraft(to point: PixelPoint) {
        guard let anchor = draftAnchor else { return }

        // 正常路径下 beginDraft 已经分配过序号；这里兜底一次，
        // 避免草稿被外部重置（如 `resetNumberingCounter`）后落下没有序号的标注。
        if tool == .numbering, draftNumberingIndex == nil {
            draftNumberingIndex = takeNextNumberingIndex()
        }

        if accumulatesStrokePoints {
            appendStrokePoint(point, threshold: strokeSamplingThreshold)
            draft = makeDraggedAnnotation(
                from: anchor,
                to: point,
                strokePoints: draftStrokePoints,
                numberingIndex: draftNumberingIndex
            )
        } else {
            draft = makeDraggedAnnotation(
                from: anchor,
                to: point,
                strokePoints: [],
                numberingIndex: draftNumberingIndex
            )
        }
        notifyChange()
    }

    /// 当前工具是否需要逐点累积轨迹。
    ///
    /// 手绘是「沿着鼠标轨迹画」，马赛克涂抹是「沿路径刷」，二者都要点序列；
    /// 其余工具（矩形/直线/箭头/编号/高亮/测量/放大镜/曲线箭头）的形状
    /// 完全由起止两点决定，逐点累积只会白白增加重绘量。
    private var accumulatesStrokePoints: Bool {
        tool == .freehand || (tool == .mosaic && style.mosaicMode == .brush)
    }

    /// 轨迹采样阈值（底图像素）：相邻两点小于它就丢弃新点。
    ///
    /// 阈值按**各自工具的实际视觉尺寸**取，不能共用一个数：
    /// 马赛克涂抹的阈值取决于笔刷半径（笔刷半径 8px 时点距 2px 已足够平滑），
    /// 手绘则取决于线宽（细笔需要更密的点，粗笔的折角本来就被宽度盖住）。
    /// 共用笔刷半径做阈值的话，手绘在细线宽（旧版 2px）下会采出过疏的点，
    /// 笔画出现肉眼可见的折角。
    private var strokeSamplingThreshold: Double {
        if tool == .freehand {
            return max(1.5, style.shapeLineWidth * 0.5)
        }
        return max(2, style.mosaicBrushRadius * 0.5)
    }

    /// 提交草稿。
    ///
    /// 尺寸过小（单击产生的零尺寸）的草稿会被丢弃而不是提交，
    /// 否则每次误点都会多出一个看不见的标注和一次撤销步。
    @discardableResult
    func commitDraft() -> Bool {
        guard let draft, Self.isMeaningful(draft) else {
            discardDraft()
            return false
        }

        annotations.append(Self.simplifiedForCommit(draft))
        self.draft = nil
        draftAnchor = nil
        draftStrokePoints = []
        // 已提交的编号真正占用了这个序号，不能再归还；
        // 只是清空「草稿持有」这一状态（与 `releaseDraftNumberingIndex` 的区别）。
        draftNumberingIndex = nil
        history.commit(EditState(selection: selection, annotations: annotations))
        notifyChange()
        return true
    }

    /// 提交前的收尾处理：自由笔迹在这里简化一次。
    ///
    /// **为什么只能在提交时做。** Douglas–Peucker 是全局算法，它按「到基线的
    /// 最大偏离」递归取舍顶点；拖动过程中每加入一个新点，基线的位置就变了，
    /// 之前保留下来的拐点可能被丢掉、原本丢掉的点可能被选回来。
    /// 于是笔迹在拖动中反复改变形状，用户看到的就是「已经画好的轨迹在抖」。
    ///
    /// 草稿用原始采样点（只追加、不改已有形状，拖动全程稳定），
    /// 落笔时形状已经定型，再简化一次——这一次性的收尾反而看不出变化，
    /// 因为简化保证丢弃的点都在容差内。
    ///
    /// 容差取该标注**自己**的线宽四成（而不是当前样式）：
    /// 用户可能在画完之后改了线宽，简化应当按笔画原本的粗细来算。
    private static func simplifiedForCommit(_ annotation: Annotation) -> Annotation {
        guard case let .freehand(points, stroke) = annotation.kind else { return annotation }
        return Annotation(
            id: annotation.id,
            kind: .freehand(
                points: StrokeSimplifier.simplify(
                    points,
                    tolerance: max(1, stroke.width * 0.4)
                ),
                stroke: stroke
            )
        )
    }

    /// 立即提交一次选区（供选区工具用完草稿后收口）。
    func discardDraft() {
        guard draft != nil || draftAnchor != nil || draftNumberingIndex != nil else { return }
        draft = nil
        draftAnchor = nil
        draftStrokePoints = []
        // 丢弃的草稿从未出现在画面上，它占用的序号应当可以被下一笔复用。
        releaseDraftNumberingIndex()
        notifyChange()
    }

    // MARK: - 文字编辑

    /// 开始新建文字。`topLeft` 为文字左上角（底图像素）。
    func beginTextEditing(at topLeft: PixelPoint) {
        textDraft = TextEditDraft(
            annotationID: nil,
            topLeft: topLeft,
            text: "",
            fontSize: style.textFontSize,
            color: style.textColor
        )
        notifyChange()
    }

    /// 开始重新编辑一段已有文字（保留其 ID 与 z 序）。
    func beginTextEditing(annotation: Annotation, topLeft: PixelPoint) {
        guard case let .text(_, text, font, color, _, _) = annotation.kind else { return }
        textDraft = TextEditDraft(
            annotationID: annotation.id,
            topLeft: topLeft,
            text: text,
            // 模型字号是像素，转回界面用的点。
            fontSize: font.size,
            color: color
        )
        notifyChange()
    }

    /// 记录输入框里的当前内容（每次按键都会调用）。
    func updateTextDraft(_ text: String) {
        guard textDraft != nil, textDraft?.text != text else { return }
        textDraft?.text = text
        // 只通知输入控件同步，不做全量重绘：
        // 输入控件自己就是这次变化的来源，其余画面没有变化。
        onTextContentChange?()
    }

    /// 提交文字。
    ///
    /// - 重新编辑：原地替换（保持 ID 与 z 序），**只产生一个历史快照**。
    /// - 新建：追加到末尾。
    /// 文本为空时：重新编辑 → **删除该标注**并记入历史（文档承诺「清空即删除」）；
    /// 新建 → 安静丢弃，不产生标注也不留撤销步。
    @discardableResult
    func commitTextDraft(scaleFactor: CGFloat) -> Bool {
        guard let editing = textDraft else { return false }
        textDraft = nil
        defer { notifyChange() }

        let trimmed = editing.text.trimmingCharacters(in: .whitespacesAndNewlines)

        if let id = editing.annotationID {
            guard let index = annotations.firstIndex(where: { $0.id == id }) else {
                return false
            }
            // 内容被清空：删除这个标注，而不是保留原文。
            // 与下面「新建空文字」分开：用户对已有标注做了明确的清空动作，
            // 保留原文会让编辑看起来完全没生效；而新建时的空内容只是误触发。
            guard !trimmed.isEmpty else {
                deleteTextAnnotation(at: index)
                return true
            }

            annotations[index] = Self.makeTextAnnotation(
                id: id,
                draft: editing,
                text: trimmed,
                scaleFactor: scaleFactor
            )
            history.commit(EditState(selection: selection, annotations: annotations))
            return true
        }

        guard !trimmed.isEmpty else { return false }

        let annotation = Self.makeTextAnnotation(
            id: UUID(),
            draft: editing,
            text: trimmed,
            scaleFactor: scaleFactor
        )
        annotations.append(annotation)
        history.commit(EditState(selection: selection, annotations: annotations))
        return true
    }

    /// 放弃文字编辑（ESC），已有标注保持原内容。
    func cancelTextEditing() {
        guard textDraft != nil else { return }
        textDraft = nil
        notifyChange()
    }

    /// 删除正在编辑的文字标注（重新编辑时清空内容并确认）。
    func deleteEditingText() {
        guard let editing = textDraft, let id = editing.annotationID else { return }
        textDraft = nil
        if let index = annotations.firstIndex(where: { $0.id == id }) {
            deleteTextAnnotation(at: index)
        }
        notifyChange()
    }

    /// 删除指定下标的标注并记一步历史。
    ///
    /// 「重新编辑后清空内容」与「显式删除」是同一个结果，删除与记历史的
    /// 收口放在一处，避免两条路径各写一遍、日后只改了一条。
    private func deleteTextAnnotation(at index: Int) {
        annotations.remove(at: index)
        // 被删掉的正好是选中的那条时，选中必须一起清掉（与 `deleteSelected` 同一收口）。
        pruneAnnotationSelectionIfMissing()
        history.commit(EditState(selection: selection, annotations: annotations))
    }

    private static func makeTextAnnotation(
        id: UUID,
        draft: TextEditDraft,
        text: String,
        scaleFactor: CGFloat
    ) -> Annotation {
        let font = draft.font(scaleFactor: scaleFactor)
        // 交互上用户点的/看到的是「文字左上角」，模型要的是**基线起点**，
        // 这个换算只有 TextMetrics 一处，视图不再自己加偏移。
        let origin = TextMetrics.baselineOrigin(forTopLeft: draft.topLeft, font: font)
        return Annotation(
            id: id,
            kind: .text(
                origin: origin,
                text: text,
                font: font,
                color: draft.color,
                background: nil,
                maxWidth: nil
            )
        )
    }

    // MARK: - 撤销 / 重做

    @discardableResult
    func undo() -> Bool {
        guard let state = history.undo() else { return false }
        apply(state)
        return true
    }

    @discardableResult
    func redo() -> Bool {
        guard let state = history.redo() else { return false }
        apply(state)
        return true
    }

    /// 撤销/重做必须同时恢复**选区与标注**：二者同属一个快照。
    private func apply(_ state: EditState) {
        annotations = state.annotations
        selection = state.selection
        // 正在编辑的文字若引用了被撤销掉的标注，编辑要一并结束。
        if let editing = textDraft, let id = editing.annotationID,
           !annotations.contains(where: { $0.id == id }) {
            textDraft = nil
        }
        // 选中态不在快照里，撤销/重做后可能指向一条已经不存在的标注
        //（例如撤销掉「刚画的那一条」）。悬空引用会让工具栏显示编辑控件、
        // 删除按钮却什么也删不掉，必须在这里清空。
        pruneAnnotationSelectionIfMissing()
        notifyChange()
    }

    /// 选中的标注若已不存在，清空选中。
    private func pruneAnnotationSelectionIfMissing() {
        guard let id = selectedAnnotationID,
              !annotations.contains(where: { $0.id == id }) else { return }
        selectedAnnotationID = nil
    }

    // MARK: - 草稿构造

    private func appendStrokePoint(_ point: PixelPoint, threshold: Double) {
        guard let last = draftStrokePoints.last else {
            draftStrokePoints = [point]
            return
        }
        // 阈值由调用方按工具给出（见 `strokeSamplingThreshold`）：
        // 这里只管「离上一个记录点够不够远」，不再自己判断是哪种工具。
        if abs(point.x - last.x) >= threshold || abs(point.y - last.y) >= threshold {
            draftStrokePoints.append(point)
        }
    }

    /// 折线总长（底图像素）。
    private static func polylineLength(_ points: [PixelPoint]) -> Double {
        guard points.count >= 2 else { return 0 }
        var total = 0.0
        for index in 1 ..< points.count {
            total += distance(points[index - 1], points[index])
        }
        return total
    }

    /// 编号标记的下一个序号。
    ///
    /// 契约要求「序号由会话维护计数器，而不是由模型推断」：删掉中间一个编号后，
    /// 凭数组下标推断会得到与画面上不同的数字。计数器在**取号时**递增，
    /// 因此撤销不回收号码——编号本就应当只增不减。
    private var numberingCounter = 1

    /// 被丢弃草稿归还的序号（升序）。
    ///
    /// 归还而不是把 `numberingCounter` 减一：取号与丢弃之间完全可能已经为
    /// 其它标注取过号，减一会造出重复序号。这里把「没用掉的号」单独收着，
    /// 下次取号优先复用它们，既不留断档，也不会与已提交的号码冲突。
    private var releasedNumberingIndices: [Int] = []

    /// 取下一个编号并递增。
    func takeNextNumberingIndex() -> Int {
        if !releasedNumberingIndices.isEmpty {
            return releasedNumberingIndices.removeFirst()
        }
        defer { numberingCounter += 1 }
        return numberingCounter
    }

    /// 归还当前草稿占用的序号（草稿被丢弃/切换工具时）。
    private func releaseDraftNumberingIndex() {
        guard let index = draftNumberingIndex else { return }
        draftNumberingIndex = nil
        releasedNumberingIndices.append(index)
        releasedNumberingIndices.sort()
    }

    /// 会话重置时把编号计数器归位（新会话从 1 开始）。
    func resetNumberingCounter() {
        numberingCounter = 1
        releasedNumberingIndices.removeAll()
        draftNumberingIndex = nil
    }

    private func makeDraggedAnnotation(
        from start: PixelPoint,
        to end: PixelPoint,
        strokePoints: [PixelPoint],
        numberingIndex: Int? = nil
    ) -> Annotation? {
        switch tool {
        case .pointer, .text:
            return nil

        case .rectangle:
            return Annotation(kind: .rectangle(
                rect: Self.rect(from: start, to: end),
                stroke: StrokeStyle(color: style.shapeColor, width: style.shapeLineWidth),
                fill: nil,
                cornerRadius: 0
            ))

        case .line:
            return Annotation(kind: .line(
                start: start,
                end: end,
                stroke: StrokeStyle(color: style.shapeColor, width: style.shapeLineWidth)
            ))

        case .arrow:
            // 箭头的头部尺寸跟随线宽，保证不同粗细下比例一致；
            // `arrowHeadScale` 是在这个基准上的额外缩放，让用户能单独调头部大小。
            return Annotation(kind: .arrow(
                start: start,
                end: end,
                stroke: StrokeStyle(color: style.shapeColor, width: style.shapeLineWidth),
                headLength: style.arrowHeadLength,
                headWidth: style.arrowHeadWidth
            ))

        case .numbering:
            // 拖拽只决定**位置**，半径取自样式：编号的大小应当一致，
            // 逐个拖出不同半径会让同一张图上的标记大小不一。
            //
            // 序号由草稿在 beginDraft 时取好并全程复用；这里再取号会随
            // 每次 mouseDragged 自增，号码就会跳（缺陷的根源）。
            guard let index = numberingIndex else { return nil }
            return Annotation(kind: .numbering(
                // 圆心跟光标走（取终点）：按下时起止重合，圆圈就出现在按下处；
                // 拖动时逐帧重建草稿，圆圈实时跟随，松手停在落点。
                // 取中点会让圆圈只以光标一半的速度移动；取起点则拖动全无反馈。
                center: end,
                radius: style.numberingRadius,
                index: index,
                stroke: StrokeStyle(color: style.shapeColor, width: style.shapeLineWidth),
                fill: nil,
                textColor: style.shapeColor
            ))

        case .highlight:
            return Annotation(kind: .highlight(
                rect: Self.rect(from: start, to: end),
                color: style.highlightColor
            ))

        case .measure:
            return Annotation(kind: .measure(
                start: start,
                end: end,
                stroke: StrokeStyle(color: style.shapeColor, width: style.shapeLineWidth)
            ))

        case .magnifier:
            // 半径取起点到终点的距离（点下圆心、拖到边缘），并设下限：
            // 太小的放大镜既看不清也没有意义。
            return Annotation(kind: .magnifier(
                center: start,
                radius: max(24, Self.distance(start, end)),
                zoom: style.magnifierZoom,
                border: StrokeStyle(color: style.shapeColor, width: style.shapeLineWidth)
            ))

        case .freehand:
            // 草稿阶段**不做简化**，直接用原始采样点连线。
            //
            // Douglas–Peucker 是全局算法：每加入一个新点都可能改变之前保留的
            // 顶点集合（原以为要留的拐点可能被新点盖过），于是已经画出来的
            // 轨迹会在拖动过程中不断改形状，用户看到的就是「笔迹在抖」。
            // 草稿只追加点、不改已有形状；简化放在提交时一次性收尾
            //（见 `simplifiedForCommit`）。
            return Annotation(kind: .freehand(
                points: strokePoints.count >= 2 ? strokePoints : [start, end],
                stroke: StrokeStyle(color: style.shapeColor, width: style.shapeLineWidth)
            ))

        case .curvedArrow:
            return Annotation(kind: .curvedArrow(
                start: start,
                control: Self.bendControl(from: start, to: end, bend: style.curvedArrowBend),
                end: end,
                stroke: StrokeStyle(color: style.shapeColor, width: style.shapeLineWidth),
                headLength: style.arrowHeadLength,
                headWidth: style.arrowHeadWidth
            ))

        case .mosaic:
            switch style.mosaicMode {
            case .rectangle:
                return Annotation(kind: .mosaic(
                    rect: Self.rect(from: start, to: end),
                    mode: .pixelate,
                    intensity: style.mosaicBlockSize
                ))
            case .brush:
                return Annotation(kind: .mosaicStroke(
                    points: strokePoints,
                    radius: style.mosaicBrushRadius,
                    mode: .pixelate,
                    intensity: style.mosaicBlockSize
                ))
            }
        }
    }

    /// 两点中点。
    static func centerOf(_ start: PixelPoint, _ end: PixelPoint) -> PixelPoint {
        PixelPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2)
    }

    /// 两点距离。
    static func distance(_ start: PixelPoint, _ end: PixelPoint) -> Double {
        let dx = end.x - start.x
        let dy = end.y - start.y
        return (dx * dx + dy * dy).squareRoot()
    }

    /// 曲线箭头的控制点：弦中点沿法线偏移 `bend` 比例。
    ///
    /// 方向取**法线**而不是固定「向上」，这样从下往上画时曲线朝同一侧弯，
    /// 不会出现「同样的手势却弯向相反方向」。
    static func bendControl(from start: PixelPoint, to end: PixelPoint, bend: Double) -> PixelPoint {
        let mid = centerOf(start, end)
        let dx = end.x - start.x
        let dy = end.y - start.y
        let length = (dx * dx + dy * dy).squareRoot()
        guard length > 0 else { return mid }
        let offset = length * bend
        return PixelPoint(x: mid.x - dy / length * offset, y: mid.y + dx / length * offset)
    }

    /// 由两点得到归一化矩形（左上原点，宽高非负）。
    static func rect(from start: PixelPoint, to end: PixelPoint) -> PixelRect {
        PixelRect(
            origin: PixelPoint(x: min(start.x, end.x), y: min(start.y, end.y)),
            size: PixelSize(
                width: abs(end.x - start.x),
                height: abs(end.y - start.y)
            )
        )
    }

    /// 草稿是否值得提交。
    private static func isMeaningful(_ annotation: Annotation) -> Bool {
        switch annotation.kind {
        case let .rectangle(rect, _, _, _), let .mosaic(rect, _, _):
            return rect.size.width >= 2 && rect.size.height >= 2

        case let .line(start, end, _), let .arrow(start, end, _, _, _):
            return abs(end.x - start.x) >= 2 || abs(end.y - start.y) >= 2

        case let .mosaicStroke(points, _, _, _):
            return !points.isEmpty

        case let .text(_, text, _, _, _, _):
            return !text.isEmpty

        case let .numbering(_, radius, _, _, _, _):
            return radius > 0

        case let .highlight(rect, _):
            return rect.size.width >= 2 && rect.size.height >= 2

        case let .measure(start, end, _):
            return abs(end.x - start.x) >= 2 || abs(end.y - start.y) >= 2

        case let .magnifier(_, radius, zoom, _):
            return radius > 0 && zoom > 1

        case let .freehand(points, _):
            // 单点笔迹（点一下没拖动）不产生标注：那更像误触，留下的是看不见的圆点。
            //
            // 判据用**折线总长**而不是点数，也不能用首尾距离：
            // - 只数点数：`[p, p]` 有 2 个点，会把单击也算成一条笔迹；
            // - 首尾距离：画一个闭合的圈时首尾重合、距离为 0，反而把真笔迹丢掉。
            // 总长同时排掉这两种情况。
            return Self.polylineLength(points) >= 2

        case let .curvedArrow(start, _, end, _, _, _):
            return abs(end.x - start.x) >= 2 || abs(end.y - start.y) >= 2
        }
    }

    private func notifyChange() {
        onChange?()
    }
}
