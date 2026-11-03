import CoreGraphics
import Foundation

/// 自动识别出的选区目标。
///
/// 识别只决定**选区的来源**，不改变捕获方式：拿到矩形之后仍然是从冻结底图上裁剪。
/// 因此这里输出的是「显示器内逻辑点矩形」，与 `CaptureScope` 的语义一致。
public struct DetectionTarget: Equatable, Sendable {
    /// 识别层级。取值顺序即由内到外的优先级。
    public enum Layer: String, Sendable, CaseIterable {
        /// 界面控件（按钮、输入框等），需要辅助功能权限。
        case control
        /// 单个窗口。
        case window
        /// 一个应用在本显示器内的全部窗口。
        case application
        /// 整个显示器。
        case display

        /// 界面提示用的中文名。
        public var displayName: String {
            switch self {
            case .control: return "控件"
            case .window: return "窗口"
            case .application: return "应用"
            case .display: return "显示器"
            }
        }
    }

    /// 该结果由哪一层识别产生。
    public let layer: Layer
    /// 矩形，**显示器内逻辑点**坐标（原点在显示器左上）。
    ///
    /// 这是「截图选区」语义：窗门层与应用层都已被裁进当前显示器
    /// （见 `DetectionGeometry.clampedLocalBounds`）。
    public let rect: CGRect
    /// 所属显示器。
    public let displayID: CGDirectDisplayID
    /// 标题：窗口标题、应用名或控件角色；显示器层为 `nil`。
    public let title: String?

    /// 该目标的**捕获范围**，全局左上原点坐标（与 `SCWindow.frame` 同一坐标系）。
    ///
    /// 存在理由：录制与截图的几何不是一回事。
    /// - `.window`：录制按整个窗口录（`desktopIndependentWindow`），窗口可以跨屏；
    ///   而 `rect` 已裁进当前显示器，拿它当录制框会在跨屏/超大窗口上少一圈。
    /// - `.application`：录制以**显示器**为范围（`SCContentFilter(display:includingApplications:)`
    ///   的契约），输出尺寸就是整块显示器，而不是该应用窗口的外接矩形。
    ///
    /// 注意它**不改变截图选区的裁剪语义**：截图仍然用 `rect`。
    /// 为 `nil` 时调用方应退回 `rect`（旧调用方的兼容路径）。
    public let globalRect: CGRect?

    /// 命中的窗口标识。仅 `.window` 层有效。
    ///
    /// 录制需要它来构造 `CaptureScope.window`：**不能**由 `rect` 反查窗口——
    /// 窗口可移动、可被遮挡，矩形相同的窗口不止一个，反查得到的身份是猜测。
    /// 该值在命中测试的那一刻产生，必须原样传递。
    public let windowID: CGWindowID?

    /// 命中的进程标识。`.window` 层为其所属进程，`.application` 层为所选应用。
    ///
    /// 同样必须原样传递：应用录制需要 pid 才能构造
    /// `SCContentFilter(display:including:)`。
    public let processID: pid_t?

    public init(
        layer: Layer,
        rect: CGRect,
        displayID: CGDirectDisplayID,
        title: String?,
        windowID: CGWindowID? = nil,
        processID: pid_t? = nil,
        globalRect: CGRect? = nil
    ) {
        self.layer = layer
        self.rect = rect
        self.displayID = displayID
        self.title = title
        self.windowID = windowID
        self.processID = processID
        self.globalRect = globalRect
    }
}

/// 识别相关的纯几何运算。
///
/// **坐标转换必须集中在这里。** 三层识别的数据源坐标系各不相同
/// （`SCWindow.frame` 与辅助功能元素都是全局左上原点点坐标），
/// 而选区模型用的是显示器内逻辑点。转换散落在各处时，
/// 偏差只会在多显示器或非零原点的情况下暴露——那是最难复现的一类缺陷。
public enum DetectionGeometry {
    /// 全局点矩形 → 显示器内逻辑点矩形。
    ///
    /// 副显示器的 `bounds.origin` 可能是负数，因此这里只做平移，
    /// 不做任何「绝对值」或「假设原点为 0」的处理。
    public static func localRect(
        fromGlobal rect: CGRect,
        displayBounds: CGRect
    ) -> CGRect {
        CGRect(
            x: rect.origin.x - displayBounds.origin.x,
            y: rect.origin.y - displayBounds.origin.y,
            width: rect.width,
            height: rect.height
        )
    }

    /// 显示器内逻辑点矩形 → 全局点矩形（`localRect` 的逆运算）。
    public static func globalRect(
        fromLocal rect: CGRect,
        displayBounds: CGRect
    ) -> CGRect {
        CGRect(
            x: rect.origin.x + displayBounds.origin.x,
            y: rect.origin.y + displayBounds.origin.y,
            width: rect.width,
            height: rect.height
        )
    }

    /// 一组矩形的外接矩形。
    ///
    /// 应用级识别用它将「该应用的所有窗口」压成一个矩形。
    /// 空数组返回 `nil`——调用方应当据此退回窗口层或显示器层，
    /// 而不是拿到一个面积为 0 的矩形去当选区。
    public static func boundingBox(of rects: [CGRect]) -> CGRect? {
        guard let first = rects.first else {
            return nil
        }

        var minX = first.minX
        var minY = first.minY
        var maxX = first.maxX
        var maxY = first.maxY

        for rect in rects.dropFirst() {
            minX = Swift.min(minX, rect.minX)
            minY = Swift.min(minY, rect.minY)
            maxX = Swift.max(maxX, rect.maxX)
            maxY = Swift.max(maxY, rect.maxY)
        }

        let width = maxX - minX
        let height = maxY - minY
        guard width > 0, height > 0 else {
            return nil
        }

        return CGRect(x: minX, y: minY, width: width, height: height)
    }

    /// 与显示器取交集；交集为空或退化时返回 `nil`。
    ///
    /// 跨屏窗口的识别结果会越出当前显示器，必须裁掉——
    /// 否则选区会落在显示器之外，捕获与导出都拿不到对应像素。
    public static func intersection(
        _ rect: CGRect,
        with bounds: CGRect
    ) -> CGRect? {
        let result = rect.intersection(bounds)
        guard !result.isNull, result.width >= 1, result.height >= 1 else {
            return nil
        }
        return result
    }

    /// 把一组全局矩形裁进显示器并转成显示器内逻辑点矩形。
    ///
    /// 这是应用级与窗口级识别的公共收尾：先逐个裁剪（跨屏窗口只保留本屏部分），
    /// 再求外接矩形。顺序不能颠倒——先求外接矩形再裁剪，
    /// 会让「一个窗口跨到另一屏」把本屏结果撑到屏幕边缘。
    public static func clampedLocalBounds(
        ofGlobalRects rects: [CGRect],
        displayBounds: CGRect
    ) -> CGRect? {
        let localRects = rects.compactMap { rect -> CGRect? in
            intersection(rect, with: displayBounds).map {
                localRect(fromGlobal: $0, displayBounds: displayBounds)
            }
        }
        return boundingBox(of: localRects)
    }
}
