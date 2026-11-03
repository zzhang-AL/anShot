//
//  ScreenCapturing.swift
//  AnShotCapture
//
//  捕获层抽象。见 docs/m1-capture/plan.md §3.1。
//
//  ── 实现选择（用户批准的双实现方案）─────────────────────────
//
//  部署基线 macOS 13.0，而 SCScreenshotManager 是 14.0+，故需要两条路径：
//
//      StreamCapturer      macOS 12.3+   基线实现，SCStream 抓首帧
//      ScreenshotCapturer  macOS 14.0+   优化路径，单帧专用 API
//
//  两个实现共用 `CaptureSetup` 的过滤器与配置构造，避免参数漂移导致
//  「同一个区域内两个实现抓出的图尺寸或坐标不一致」。
//
//  ── 验证边界（不得含糊）───────────────────────────────────
//
//  开发机是 macOS 27，`CapturerFactory.makeDefault()` 永远返回
//  `ScreenshotCapturer`，因此 `StreamCapturer` 的**选择逻辑**在本机不会发生。
//  但其**实现本身**可通过 `CapturerFactory.make(.stream)` 强制执行并验证。
//  真实 macOS 13 上的运行兼容性**仍未验证**，不可当作已证实。
//
//  ── 坐标系约定（M1 最高技术风险，plan.md §6）─────────────────────
//
//  CaptureScope 的 rect 使用 **显示器逻辑点坐标**，原点在该显示器左上角：
//      - 与 ScreenCaptureKit 的 sourceRect 一致（同为逻辑点），无需换算
//      - 与 UI 层从 NSView 拿到的坐标同源，减少一次换算就少一次出错机会
//  捕获结果的 CGImage 天然是 **像素**。逻辑点 → 像素 的唯一换算点
//  在「UI 选区 → 标注模型」的边界，由 CoreGraphics 的缩放系数统一承担。
//
//  ── 协议设计约束 ─────────────────────────────────────────────
//
//  协议必须暴露「配置与过滤器的构造」，而非仅暴露「结果」，
//  否则 M2 的录制无法复用本管线，只能推翻重写。为此本模块不把
//  ScreenCaptureKit 的类型泄漏到协议签名中（CaptureScope 是自有类型），
//  实现层负责转换成 SCContentFilter / SCStreamConfiguration。
//

import AppKit
import CoreGraphics
import Foundation

// MARK: - 捕获范围

/// 捕获范围。
///
/// 坐标约定：`rect` 为**显示器逻辑点**，原点在该显示器左上角
/// （即 CoreGraphics 显示坐标系，非 AppKit 的左下原点坐标系）。
///
/// M2 起扩展为四种范围。扩展方式为**新增 case 而非新建类型**（DRY）：
/// 单帧截图与持续录制面对的是同一套「录什么」语义，若各建一套类型，
/// 二者之间的转换层必然成为漂移源。
public enum CaptureScope: Sendable, Equatable {
    /// 整个显示器。
    case display(CGDirectDisplayID)

    /// 显示器内的区域。超出显示器边界的部分会被裁剪。
    case region(CGDirectDisplayID, rect: CGRect)

    /// 单个窗口。范围由窗口的实时 frame 决定，可跨显示器跟随。
    ///
    /// 未携带显示器：窗口可在录制期间移动到任意显示器，
    /// 以显示器为参数反而会限制跟随行为。
    case window(CGWindowID)

    /// 某进程的全部窗口，**以指定显示器为范围**。
    ///
    /// ⚠️ 契约（`model.md` §2.3）：`SCContentFilter(display:includingApplications:)
    /// 是**以显示器为范围**的过滤器，**不会**覆盖该应用在其它显示器上的窗口。
    /// 故此处必须显式携带显示器，不能只给 pid——只给 pid 根本无法构造过滤器，
    /// 且会让调用方误以为能录到全部显示器。
    case application(pid_t, on: CGDirectDisplayID)

    /// 目标显示器；窗口范围没有显示器归属时为 nil。
    ///
    /// 窗口可能同时横跨多块显示器，不存在唯一的归属显示器，故返回 nil。
    /// 调用方必须显式处理 nil，而不是拿到一个「碰巧正确」的显示器。
    public var displayID: CGDirectDisplayID? {
        switch self {
        case .display(let id):              return id
        case .region(let id, _):            return id
        case .window:                       return nil
        case .application(_, let displayID): return displayID
        }
    }

    /// 区域范围（逻辑点）。非区域范围时为 nil。
    public var regionRect: CGRect? {
        switch self {
        case .region(_, let rect):          return rect
        case .display, .window, .application: return nil
        }
    }

    /// 是否需要显示器上下文才能构造捕获目标。
    ///
    /// 单帧截图实现用它判断是否可以直接拒绝：
    /// 窗口范围没有确定的显示器，而单帧捕获的产物需要一个缩放系数来换算坐标。
    public var requiresDisplayContext: Bool {
        switch self {
        case .window:                       return false
        case .display, .region, .application: return true
        }
    }

    /// 人类可读的范围描述，用于日志与错误信息。
    public var displayName: String {
        switch self {
        case .display(let id):              return "显示器 #\(id)"
        case .region(let id, let rect):
            return "显示器 #\(id) 的区域 \(Int(rect.width))×\(Int(rect.height))"
        case .window(let id):               return "窗口 #\(id)"
        case .application(let pid, let displayID):
            return "进程 #\(pid) 的窗口（显示器 #\(displayID)）"
        }
    }
}

// MARK: - 捕获结果

/// 窗口截图的来源描述。
///
/// 只在按窗口捕获时存在。带着它走完整条链路（捕获层 → 自动化层 → JSON / MCP）
/// 的理由：调用方需要知道「这张图到底是哪个窗口」，而窗口可能在截图期间被
/// 关闭或改名——事后再查会得到与这张图无关的结果。
public struct WindowCaptureInfo: Sendable, Equatable {

    /// `CGWindowID`。
    public let windowID: CGWindowID

    /// 窗口标题。无屏幕录制权限或窗口本身无标题时为 nil。
    public let title: String?

    /// 所属应用名。
    public let applicationName: String?

    /// 窗口在**全局**显示坐标系中的矩形（逻辑点，原点主屏左上）。
    public let frame: CGRect

    /// 窗口所在显示器。
    public let displayID: CGDirectDisplayID

    /// 捕获时是否在可见桌面上；未知时为 nil。
    public let isOnScreen: Bool?

    public init(
        windowID: CGWindowID,
        title: String?,
        applicationName: String?,
        frame: CGRect,
        displayID: CGDirectDisplayID,
        isOnScreen: Bool? = nil
    ) {
        self.windowID = windowID
        self.title = title
        self.applicationName = applicationName
        self.frame = frame
        self.displayID = displayID
        self.isOnScreen = isOnScreen
    }

    /// 人类可读的简短描述，用于错误信息与元数据文本。
    public var displayName: String {
        let name = title ?? applicationName ?? "未命名窗口"
        return "窗口 #\(windowID)「\(name)」"
    }
}

/// 一帧捕获结果。
public struct CapturedFrame: Sendable {
    /// 图像数据。像素尺寸与请求范围的逻辑尺寸乘以 `scaleFactor` 对应。
    public let image: CGImage

    /// 来源显示器。
    public let displayID: CGDirectDisplayID

    /// 捕获时该显示器的像素缩放系数（Retina 为 2.0）。
    ///
    /// 用途：建模时的「逻辑点 → 像素」换算。必须是**捕获时刻**的值，
    /// 因为用户可能在捕获后改变分辨率或把窗口拖到另一块屏幕上。
    public let scaleFactor: CGFloat

    /// 捕获完成时刻。用于诊断端到端延迟。
    public let capturedAt: Date

    /// 窗口来源。整屏 / 区域捕获时为 `nil`。
    public let window: WindowCaptureInfo?

    /// 图像像素尺寸。等价于 `image.width` / `image.height`，此处显式暴露以免上层到处取。
    public var pixelSize: CGSize {
        CGSize(width: image.width, height: image.height)
    }

    public init(
        image: CGImage,
        displayID: CGDirectDisplayID,
        scaleFactor: CGFloat,
        capturedAt: Date = Date(),
        window: WindowCaptureInfo? = nil
    ) {
        self.image = image
        self.displayID = displayID
        self.scaleFactor = scaleFactor
        self.capturedAt = capturedAt
        self.window = window
    }
}

// MARK: - 错误

/// 捕获失败原因。
public enum CaptureError: Error, Sendable {
    /// 缺少屏幕录制权限。
    case permissionDenied
    /// 目标显示器不存在或已断开。
    case displayUnavailable
    /// 目标窗口或应用已不存在。
    case scopeUnavailable
    /// 该范围在当前实现中不受支持（如单帧截图不支持窗口范围）。
    case unsupportedScope(String)
    /// 捕获超时（未在预期时间内收到帧）。
    case timedOut
    /// 捕获返回了空图像。
    case emptyResult

    /// 底层框架报错，附带描述。
    case underlying(String)
}

extension CaptureError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .permissionDenied:  return "缺少屏幕录制权限"
        case .displayUnavailable: return "目标显示器不可用"
        case .scopeUnavailable:  return "目标窗口或应用已不存在"
        case .unsupportedScope(let detail): return detail
        case .timedOut:          return "捕获超时"
        case .emptyResult:       return "捕获返回空图像"
        case .underlying(let message): return message
        }
    }
}

// MARK: - 协议

/// 捕获器抽象。
///
/// 实现须为 `Sendable`，且**不得**在会话之间保持图像引用——
/// 见 plan.md §3.3 内存纪律第 3 条「会话结束立即释放」。
public protocol ScreenCapturing: Sendable {
    /// 抓取单帧。
    ///
    /// - Parameter scope: 捕获范围。
    /// - Returns: 捕获结果，其 `image` 像素尺寸与 `scope` 的逻辑尺寸
    ///   乘以该显示器的缩放系数对应。
    /// - Throws: `CaptureError`
    func captureFrame(scope: CaptureScope) async throws -> CapturedFrame
}

// MARK: - 显示器几何工具

/// 显示器几何查询。捕获层与 UI 层都依赖它，且必须对坐标系的理解保持一致。
public enum DisplayGeometry {

    /// 显示器当前的像素缩放系数（Retina 为 2.0）。
    ///
    /// **必须用 `CGDisplayMode.pixelWidth`，不能用 `CGDisplayPixelsWide`。**
    /// 实测（macOS 27 / 内建 Retina 屏）：
    ///
    ///     CGDisplayBounds          = 1470 x 956      （逻辑点）
    ///     CGDisplayPixelsWide/High = 1470 x 956      ⚠️ 返回的是模式的点宽
    ///     CGDisplayMode.pixelWidth/Height = 2940 x 1912  ✅ 真正的物理像素
    ///     NSScreen.backingScaleFactor     = 2.0
    ///
    /// 若误用 `CGDisplayPixelsWide`，缩放系数会算成 1.0，
    /// 导致捕获请求 1x 而非全分辨率——曾因此在实际抓图中得到 1470x956 的降采样结果。
    public static func scaleFactor(for displayID: CGDirectDisplayID) -> CGFloat {
        let pointWidth = CGDisplayBounds(displayID).width
        guard pointWidth > 0 else { return fallbackScaleFactor(for: displayID) }

        // `CGDisplayCopyDisplayMode` 会在显示器切换分辨率、睡眠唤醒、或系统繁忙时
        // **瞬时返回 nil**（而同一毫秒内 `CGDisplayBounds` 仍然有效）。
        //
        // 这里曾经直接回退到 1.0，而调用方把返回值当作真实比例去换算选区，
        // 于是在 Retina 屏上得到一个只有一半宽高的矩形、原点也减半——
        // 用户看到的现象正是「框选一大片，导出的图只有左上角一小块」。
        // 因此回退必须继续往下找**可靠的**来源，而不是给一个看似合理的常数。
        if let mode = CGDisplayCopyDisplayMode(displayID), mode.pixelWidth > 0 {
            let scale = CGFloat(mode.pixelWidth) / pointWidth
            if scale > 0 { return scale }
        }

        return fallbackScaleFactor(for: displayID)
    }

    /// 拿不到 display mode 时的回退链。
    ///
    /// 顺序体现可靠性排序：`NSScreen.backingScaleFactor` 来自窗口系统本身，
    /// 与前台应用看到的缩放一致；`CGDisplayPixelsWide` 虽然在本机实测中
    /// 返回的是**逻辑点宽**（见 `scaleFactor` 的说明），但当它与
    /// `CGDisplayBounds` 不一致时，那个比值仍是有意义的像素/点比。
    private static func fallbackScaleFactor(for displayID: CGDirectDisplayID) -> CGFloat {
        if let screen = screen(for: displayID), screen.backingScaleFactor > 0 {
            return screen.backingScaleFactor
        }

        let pointWidth = CGDisplayBounds(displayID).width
        let pixelWidth = CGFloat(CGDisplayPixelsWide(displayID))
        if pointWidth > 0, pixelWidth > pointWidth {
            return pixelWidth / pointWidth
        }

        return 1.0
    }

    /// 找到 displayID 对应的 `NSScreen`。
    ///
    /// 关联键是 `NSScreenNumber`，它是 `CGDirectDisplayID` 的装箱值。
    private static func screen(for displayID: CGDirectDisplayID) -> NSScreen? {
        NSScreen.screens.first { screen in
            let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
            return (number as? NSNumber)?.uint32Value == displayID
        }
    }

    /// 显示器的物理像素尺寸。
    ///
    /// 与 `scaleFactor` 同源，同样取自 `CGDisplayMode.pixelWidth/pixelHeight`。
    public static func pixelSize(for displayID: CGDirectDisplayID) -> CGSize {
        if let mode = CGDisplayCopyDisplayMode(displayID) {
            return CGSize(width: mode.pixelWidth, height: mode.pixelHeight)
        }
        // 极端降级：拿不到 display mode 时按点尺寸与缩放系数推算
        let pointSize = CGDisplayBounds(displayID).size
        let scale = scaleFactor(for: displayID)
        return CGSize(
            width: (pointSize.width * scale).rounded(),
            height: (pointSize.height * scale).rounded()
        )
    }

    /// 显示器在全局显示坐标系中的范围（逻辑点，原点主屏左上）。
    public static func bounds(for displayID: CGDirectDisplayID) -> CGRect {
        CGDisplayBounds(displayID)
    }

    /// 当前活跃的显示器列表。
    public static func activeDisplays() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &displays, &count) == .success else { return [] }
        return Array(displays.prefix(Int(count)))
    }

    /// 主显示器。
    public static func mainDisplay() -> CGDirectDisplayID {
        CGMainDisplayID()
    }

    /// 把「显示器内逻辑点坐标」转换为「全局显示坐标」。
    ///
    /// `CGWindowListCreateImage` 需要全局坐标，而 `CaptureScope` 用的是
    /// 显示器内坐标，故 13.0 路径必须经过此换算。
    public static func globalRect(
        for rect: CGRect,
        in displayID: CGDirectDisplayID
    ) -> CGRect {
        let origin = CGDisplayBounds(displayID).origin
        return CGRect(
            x: origin.x + rect.origin.x,
            y: origin.y + rect.origin.y,
            width: rect.width,
            height: rect.height
        )
    }

    /// 找到包含指定矩形（全局坐标，左上原点）的显示器。
    ///
    /// 判定顺序：先看矩形中心落在哪块显示器内（最常见情形），
    /// 再退回「与之相交的显示器」——后者用于窗口正好跨屏、或中心落在显示器间隙的情形。
    ///
    /// 窗口录制需要它来确定缩放系数：窗口本身不带显示器信息，
    /// 而输出像素尺寸 = 窗口逻辑尺寸 × 其所在显示器的缩放系数。
    public static func displayContaining(_ rect: CGRect) -> CGDirectDisplayID? {
        let displays = activeDisplays().map { (id: $0, bounds: CGDisplayBounds($0)) }
        return displayContaining(rect, in: displays)
    }

    /// 使用给定显示器布局计算归属，便于验证负坐标、屏幕间隙和跨屏窗口。
    static func displayContaining(
        _ rect: CGRect,
        in displays: [(id: CGDirectDisplayID, bounds: CGRect)]
    ) -> CGDirectDisplayID? {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        if let containing = displays.first(where: { $0.bounds.contains(center) }) {
            return containing.id
        }
        // 跨屏或落在间隙：取相交面积最大的那块
        let candidates = displays
            .map { (displayID: $0.id, intersection: $0.bounds.intersection(rect)) }
            .filter { !$0.intersection.isNull && $0.intersection.width > 0 && $0.intersection.height > 0 }
        return candidates
            .max { lhs, rhs in
                (lhs.intersection.width * lhs.intersection.height)
                    < (rhs.intersection.width * rhs.intersection.height)
            }?
            .displayID
    }

    /// 把 rect 裁剪到显示器边界内，并返回 nil 表示裁剪后为空。
    public static func clamp(
        rect: CGRect,
        to displayID: CGDirectDisplayID
    ) -> CGRect? {
        let displayBounds = CGRect(origin: .zero, size: CGDisplayBounds(displayID).size)
        let clipped = rect.intersection(displayBounds)
        guard !clipped.isNull, clipped.width >= 1, clipped.height >= 1 else { return nil }
        return clipped
    }
}
