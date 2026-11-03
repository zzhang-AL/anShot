//
//  CaptureParameters.swift
//  AnShotAutomation
//
//  截图请求的参数模型与校验。
//
//  这是 CLI 与 MCP 两条入口**共用**的中间表示：两侧的语法不同
//  （命令行是 `--region 0,0,800,600`，MCP 是 JSON 数组），
//  但语义必须完全一致。任何「CLI 能做而 MCP 不能」或反之的差异，
//  都会变成难以解释的行为不一致——所以两侧都先落到本类型再执行。
//
//  ── 坐标系（唯一权威定义）───────────────────────────────────
//
//  `region` 使用**显示器内逻辑点，原点在该显示器左上角**。
//  这与 `CaptureScope.region` 的约定同源，不引入任何转换层。
//
//  易错点：区域**不是**全局坐标，也**不是**像素。
//  想要主屏右上角 100 点见方，就写 `[1370, 0, 100, 100]`（以 1470 点宽的主屏为例），
//  而不是写全局坐标或像素值。
//
//  ── 校验为什么放在这里而不是各入口 ───────────────────────────
//
//  曾有一版把「长度上限必须非负」交给 CLI 与 MCP 各自检查，结果是
//  整屏分支（`region == nil`）提前返回、绕过了所有数值检查。
//  因此所有校验收敛到 `validate()`，入口只负责把字符串/JSON 变成数字。
//

import AnShotCapture
import CoreGraphics
import Foundation

/// 一次截图请求。
public struct CaptureParameters: Sendable, Equatable {

    /// 长边像素上限的允许最大值。
    ///
    /// 设它是为了拒绝无意义的巨值（如 `1e18`）。真实显示器最长边不过 6K 量级，
    /// 允许到 16384 已远超实际需要；再大只是「不缩放」的同义词，
    /// 却会让下游的整数换算接近溢出边界。
    public static let maximumLongEdge = 16_384

    /// 坐标分量的允许最大绝对值。
    ///
    /// 与上面同理：超出这个量级的坐标一定是输入错误，
    /// 与其让它在 `CGRect` 运算里变成奇怪的结果，不如在入口拒绝。
    public static let maximumCoordinateMagnitude: Double = 1_000_000

    /// 目标显示器。`nil` 表示主显示器。
    ///
    /// 与 `windowID` / `applicationName` 互斥：窗口自带归属显示器。
    public var displayID: CGDirectDisplayID?

    /// 目标桌面 ID；为 nil 时截取显示器当前桌面。
    public var spaceID: UInt64?

    /// 是否允许为了截取其他桌面的整屏或区域而切换桌面；默认不允许。
    public var allowDesktopSwitch: Bool

    /// 显示器内区域（逻辑点，原点左上）。`nil` 表示整块显示器。
    ///
    /// 与 `windowID` / `applicationName` 互斥：窗口截图的取景就是整个窗口。
    public var region: CGRect?

    /// 目标窗口（`CGWindowID`）。`nil` 表示不按窗口寻址。
    ///
    /// 这是「截一个可能被遮挡、不在最顶层的应用」的唯一可靠方式：
    /// 显示器 + 区域要求调用方先知道窗口在哪，而它恰恰看不到才要截图。
    public var windowID: CGWindowID?

    /// 按应用名寻址目标窗口。`nil` 表示不按应用寻址。
    ///
    /// 与 `windowID` 二选一：ID 精确但要求调用方先枚举；
    /// 应用名对模型更友好（「截 Safari」是它真正想表达的东西）。
    public var applicationName: String?

    /// 长边像素上限。`nil` 表示使用默认值，`0` 表示不缩放。
    public var maxLongEdge: Int?

    /// 落盘路径。`nil` 表示只返回数据不落盘。
    ///
    /// 已存在时会被**唯一化**（追加序号），绝不覆盖已有文件——
    /// 见 `AnShotCore.OutputPath` 与 `CaptureService` 的排他创建约定。
    public var savePath: String?

    public init(
        displayID: CGDirectDisplayID? = nil,
        spaceID: UInt64? = nil,
        allowDesktopSwitch: Bool = false,
        region: CGRect? = nil,
        windowID: CGWindowID? = nil,
        applicationName: String? = nil,
        maxLongEdge: Int? = nil,
        savePath: String? = nil
    ) {
        self.displayID = displayID
        self.spaceID = spaceID
        self.allowDesktopSwitch = allowDesktopSwitch
        self.region = region
        self.windowID = windowID
        self.applicationName = applicationName
        self.maxLongEdge = maxLongEdge
        self.savePath = savePath
    }

    /// 解析后的长边上限。`nil` 落到默认值。
    ///
    /// 调用前应已通过 `validate()`；未校验时按给定值使用。
    public var resolvedMaxLongEdge: Int {
        maxLongEdge ?? ImageScaling.defaultMaxLongEdge
    }

    /// 校验并把参数归一化为可执行的捕获目标。
    ///
    /// 这是**唯一**的校验入口：CLI 与 MCP 只负责把字符串/JSON 变成数字，
    /// 一切值域与互斥关系都在这里裁决，避免两条入口出现行为分歧。
    ///
    /// - Throws: `AutomationError.invalidArgument` / `.displayUnavailable` / `.windowUnavailable`
    public func resolveTarget() throws -> ResolvedCaptureTarget {
        // ① 数值合法性——与寻址方式无关，故必须先做。
        //    放在区域分支之后会让整屏请求绕过这些检查。
        try validateNumericBounds()

        // ② 寻址互斥。不做「谁优先」的静默取舍：同时传 region 与 window_id 的
        //    调用说明调用方自己没想清楚要什么，猜错的代价是它拿到一张看起来
        //    正常、却完全不是要的那块的图。
        try validateAddressingExclusivity()

        // ③ 窗口寻址优先于显示器：它是更具体的表达。
        if let windowID {
            return try windowTarget(windowID: windowID)
        }
        if let applicationName {
            return try applicationTarget(named: applicationName)
        }

        let targetDisplay = try resolvedDisplay()

        // ④ 区域：裁剪到显示器边界。
        guard let region else {
            return .display(targetDisplay)
        }

        guard region.width >= 1, region.height >= 1 else {
            throw AutomationError.invalidArgument(
                "region 的宽高必须 ≥ 1（收到 \(region.width)×\(region.height)）。"
                + "region 格式为 [x, y, width, height]，单位是该显示器内的逻辑点。"
            )
        }

        guard let clamped = DisplayGeometry.clamp(rect: region, to: targetDisplay) else {
            let bounds = DisplayGeometry.bounds(for: targetDisplay)
            throw AutomationError.invalidArgument(
                "region 与该显示器没有有效交集。"
                + "该显示器逻辑尺寸为 \(Int(bounds.width))×\(Int(bounds.height)) 点，"
                + "region 的原点必须落在显示器内。"
            )
        }

        return .region(targetDisplay, rect: clamped)
    }

    /// 把目标压平成「显示器 + 区域」。
    ///
    /// 保留这个签名，是为了让不关心「截的到底是什么」的调用方（诊断、
    /// 会话层取默认选区）不必处理三种目标形态。窗口目标在这里表现为
    /// 「窗口所在显示器 + 整屏区域」，因为窗口截图没有「显示器内区域」这一说。
    public func validate() throws -> (displayID: CGDirectDisplayID, region: CGRect?) {
        switch try resolveTarget() {
        case .display(let displayID):
            return (displayID, nil)
        case .region(let displayID, let rect):
            return (displayID, rect)
        case .window(_, let displayID, _, _, _):
            return (displayID, nil)
        }
    }

    // MARK: - 寻址校验

    /// 寻址方式的互斥检查。
    private func validateAddressingExclusivity() throws {
        if allowDesktopSwitch && spaceID == nil {
            throw AutomationError.invalidArgument("allow_switch 需要与 space_id 同时使用。")
        }
        if windowID != nil, applicationName != nil {
            throw AutomationError.invalidArgument(
                "window_id 与 app 不能同时使用：前者是精确窗口 ID，后者按应用名解析，"
                + "请只给其中一个。"
            )
        }

        if let applicationName,
           applicationName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw AutomationError.invalidArgument("app 不能是空字符串。")
        }

        guard windowID != nil || applicationName != nil else { return }

        if spaceID != nil {
            throw AutomationError.invalidArgument(
                "space_id 与 window_id / app 不能同时使用：桌面截图以显示器或区域为范围。"
            )
        }

        if region != nil {
            throw AutomationError.invalidArgument(
                "窗口寻址（window_id / app）与 region 不能同时使用："
                + "窗口截图的范围就是整个窗口，不接受额外的采样子区域。"
            )
        }
        if displayID != nil {
            throw AutomationError.invalidArgument(
                "窗口寻址（window_id / app）与 display_id 不能同时使用："
                + "窗口自带归属显示器。若确实要截某块屏，请改用 display_id + region。"
            )
        }
    }

    /// 解析「显式指定或默认」的目标显示器。
    ///
    /// 为何默认分支也要查：曾经它直接取 `CGMainDisplayID()` 就返回，
    /// 于是一条「主屏存在性」的不变量只在显式指定时成立。
    /// 两台机器上看起来都对，直到某台没有可用主屏的机器上
    /// 得到一个指向不存在显示器的 scope，错误推迟到捕获层才出现。
    /// 现在两条路径走同一个活跃列表判据。
    private func resolvedDisplay() throws -> CGDirectDisplayID {
        let activeDisplays = DisplayGeometry.activeDisplays()
        let matchingDesktops: [DesktopInfo]
        if let spaceID {
            guard spaceID > 0 else {
                throw AutomationError.invalidArgument("space_id 必须大于 0。")
            }
            matchingDesktops = try DesktopCatalog.all().filter { $0.id == spaceID }
            guard !matchingDesktops.isEmpty else {
                throw AutomationError.invalidArgument("目标桌面不存在，请先调用 list_desktops 获取桌面 ID。")
            }
        } else {
            matchingDesktops = []
        }

        if let requested = displayID {
            guard activeDisplays.contains(requested) else {
                throw AutomationError.displayUnavailable(requested)
            }
            if spaceID != nil && !matchingDesktops.contains(where: { $0.displayID == requested }) {
                throw AutomationError.invalidArgument("目标桌面不属于该显示器，请重新调用 list_desktops。")
            }
            return requested
        }

        let main = DisplayGeometry.mainDisplay()
        if spaceID != nil {
            return matchingDesktops.first(where: { $0.displayID == main })?.displayID
                ?? matchingDesktops[0].displayID
        }
        guard activeDisplays.contains(main) else {
            throw AutomationError.displayUnavailable(main)
        }
        return main
    }

    // MARK: - 窗口寻址

    /// 按窗口 ID 解析目标。
    private func windowTarget(windowID: CGWindowID) throws -> ResolvedCaptureTarget {
        // 不直接信任调用方给的 ID：窗口可能已关闭，或它本身就是本进程自己的
        // 窗口（枚举会排除这类）。这类情况必须在提交给捕获层之前给出可操作
        // 报错，否则它会以「截到一张空图」的形式出现在链路最后一步。
        guard let info = WindowCatalog.info(for: windowID) else {
            throw AutomationError.windowUnavailable(
                "窗口 #\(windowID) 不存在或已关闭。可用 list_windows 查看当前可截图的窗口。"
            )
        }
        return try resolvedWindowTarget(info)
    }

    /// 按应用名解析目标。
    private func applicationTarget(named name: String) throws -> ResolvedCaptureTarget {
        guard let info = WindowCatalog.resolve(applicationName: name) else {
            // 把可选应用名列出来：只报「没找到」会让模型反复试同一个错名字，
            // 而它并没有任何依据去猜正确的名字。
            let names = WindowCatalog.applicationNames()
            let preview = names.prefix(20).joined(separator: "、")
            let suffix = names.count > 20 ? "…（共 \(names.count) 个）" : ""
            throw AutomationError.windowUnavailable(
                "没有找到应用「\(name)」的可截图窗口。"
                + (names.isEmpty
                   ? "当前没有任何可截图的窗口。"
                   : "当前可用的应用：\(preview)\(suffix)。")
            )
        }
        return try resolvedWindowTarget(info)
    }

    /// 把窗口描述转成可执行的捕获目标（并确定它所在的显示器）。
    private func resolvedWindowTarget(_ info: WindowInfo) throws -> ResolvedCaptureTarget {
        let frame = CGRect(
            x: info.frame.x,
            y: info.frame.y,
            width: info.frame.width,
            height: info.frame.height
        )

        guard frame.width >= 1, frame.height >= 1 else {
            throw AutomationError.invalidArgument(
                "窗口 #\(info.id)「\(info.title ?? info.appName)」的尺寸为 0，无法截取。"
            )
        }

        guard let displayID = info.displayID ?? DisplayGeometry.displayContaining(frame) else {
            throw AutomationError.windowUnavailable(
                "窗口 #\(info.id)「\(info.title ?? info.appName)」不在任何可用显示器上"
                + "（可能已最小化或完全移出屏幕）。"
            )
        }

        return .window(
            info.id,
            displayID: displayID,
            frame: frame,
            title: info.title,
            applicationName: info.appName
        )
    }

    /// 数值合法性检查。
    ///
    /// 拒绝 NaN / 无穷大 / 超量级坐标：这些输入在 `CGRect` 与
    /// `Int()` 换算里不会报错，而是产生难以归因的怪异结果
    /// （空图、尺寸为 0、或整数转换溢出陷阱）。
    private func validateNumericBounds() throws {
        if let region {
            let components: [(String, CGFloat)] = [
                ("x", region.origin.x),
                ("y", region.origin.y),
                ("width", region.width),
                ("height", region.height)
            ]

            for (name, value) in components {
                guard value.isFinite else {
                    throw AutomationError.invalidArgument(
                        "region 的 \(name) 不是有限数值（收到 \(value)）。"
                    )
                }
                guard abs(Double(value)) <= Self.maximumCoordinateMagnitude else {
                    throw AutomationError.invalidArgument(
                        "region 的 \(name) 超出允许范围（|值| ≤ \(Int(Self.maximumCoordinateMagnitude))），"
                        + "收到 \(value)。坐标单位是该显示器内的逻辑点。"
                    )
                }
            }
        }

        if let maxLongEdge {
            guard maxLongEdge >= 0 else {
                throw AutomationError.invalidArgument("max_size 不能为负：\(maxLongEdge)。")
            }
            guard maxLongEdge <= Self.maximumLongEdge else {
                throw AutomationError.invalidArgument(
                    "max_size 过大：\(maxLongEdge)（上限 \(Self.maximumLongEdge)）。"
                    + "传 0 表示保持原始分辨率。"
                )
            }
        }
    }
}

/// 校验之后的可执行捕获目标。
///
/// 三种形态互斥，由 `CaptureParameters.resolveTarget()` 裁决。
///
/// ── 为什么需要这个类型，而不是继续用 `(displayID, region)` 二元组 ──
///
/// 窗口截图既不属于「整屏」也不属于「显示器内区域」。用二元组表达它，
/// 只能靠「region 为 nil 就是整屏」这类约定去猜，而调用方无从分辨
/// 「整屏」与「某个窗口」——这正是行为分叉的温床（例如捕获层把窗口
/// 请求当成整屏，静默截了一整块屏幕回去）。
public enum ResolvedCaptureTarget: Sendable, Equatable {

    /// 整块显示器。
    case display(CGDirectDisplayID)

    /// 显示器内的区域（逻辑点，已裁剪到显示器范围）。
    case region(CGDirectDisplayID, rect: CGRect)

    /// 单个窗口。
    ///
    /// `frame` 是窗口当前的**全局**矩形（逻辑点，原点在主屏左上），
    /// 与 `CGWindowBounds` 同语义。之所以随目标一起携带而不是只带 ID：
    /// 捕获层要用它算输出像素尺寸，重新查询会引入
    /// 「尺寸与过滤器来自两次快照」的错配（窗口恰好在这一瞬移动/缩放）。
    case window(
        CGWindowID,
        displayID: CGDirectDisplayID,
        frame: CGRect,
        title: String?,
        applicationName: String?
    )

    /// 目标显示器。
    public var displayID: CGDirectDisplayID {
        switch self {
        case .display(let displayID):            return displayID
        case .region(let displayID, _):          return displayID
        case .window(_, let displayID, _, _, _): return displayID
        }
    }

    /// 对应的捕获范围。
    public var scope: CaptureScope {
        switch self {
        case .display(let displayID):
            return .display(displayID)
        case .region(let displayID, let rect):
            return .region(displayID, rect: rect)
        case .window(let windowID, _, _, _, _):
            return .window(windowID)
        }
    }
}
