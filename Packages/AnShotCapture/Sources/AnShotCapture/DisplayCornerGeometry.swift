//
//  DisplayCornerGeometry.swift
//  AnShotCapture
//
//  显示器**物理圆角**几何：屏幕自己的四角是圆的（MacBook 的内置屏尤其明显），
//  贴到屏幕边缘的框想与屏幕贴合，就必须知道这个半径——它是硬件属性，
//  每个型号、每块屏都可能不同，不能用一个常量代替。
//
//  ── 取值途径（第一手实测确立） ──────────────────────────────
//
//  公开 API 里没有这个值（实测：`NSScreen.deviceDescription` 只有 6 个键、
//  `CGDisplayGetCornerRadius` 不存在、`NSScreen` 上若干候选 selector 均不响应、
//  整屏截图**不含**屏幕圆角遮罩——四角仍是完整内容，所以也无法从像素测量）。
//
//  可用的是 SkyLight 的导出符号 `SLSDisplayGetCornerRadii`。它的签名**来自反汇编**，
//  不是猜的：
//
//      x0 经 CGSDisplaySystemState::displayByDisplayID 使用  → displayID
//      x1..x4 逐个 cbz 保护后 str d?, [x?]                   → 四个 double 出参
//      w0 失败路径 mov #0x3e8（1000）                        → int 返回码，0 为成功
//
//  出参到内部字段的映射同样是反汇编读出来的（内存降序对应参数升序）：
//      x1 ← [obj+0xe8]   x2 ← [obj+0xe0]   x3 ← [obj+0xd8]   x4 ← [obj+0xd0]
//
//  本机实测：`(x1, x2, x3, x4) = (0, 0, 20.3528, 20.3499)`，即两个角为 0、两个角约 20.35。
//
//  ── 角顺序的依据（这里是唯一的推断，写清楚以免以后误用） ────────
//
//  参数顺序与内存顺序相反（x1↔0xe8 … x4↔0xd0），单看反汇编无法确定语义顺序。
//  采用 x3/x4 = **顶部**、x1/x2 = 底部，依据有两条：
//
//  1. 用户反馈：框选到屏幕上方时，上方圆角与屏幕**不贴合**，且明确反对「收成直角」
//     —— 这两条共同指向「屏幕上方两角本身是圆角」。若顶部是 0（直角），
//     收成直角恰恰就是贴合，不会出现这个反馈。
//  2. 本机（MacBook Air 内置屏）两个非零值相同、两个零值相同，符合「顶/底各一对」的
//     对称布局；顶部两角有遮罩、底部两角为直角也与上述现象一致。
//
//  **左右映射（哪个是 left）无法区分**：两值相差 0.003pt（约 0.006 像素），
//  视觉不可分辨，故按惯例取 x3 = 左上、x4 = 右上。若日后在别的机型上发现
//  左右差异明显，需要重新确认这一项。
//
//  ── 单位 ────────────────────────────────────────────────────
//
//  返回值按**逻辑点**使用。依据：本机得到 20.35，与该类内屏圆角的可见量级相符；
//  若按物理像素解释则是 10.2pt，明显小于肉眼可见的屏幕圆角。本机为 2x 屏，
//  代码**不做**任何 scale 换算，也不假设其它屏幕是 1x/2x——换算是错的比不换算更糟。
//  诊断会同时打印两种解释，便于在别的机器上核对。
//

import AnShotCore
import CoreGraphics
import Foundation

private let cornerLogger = AnShotLog.capture
/// 一块显示器的物理圆角半径（**逻辑点**）。
///
/// 四角分别保存，不压成一个值：系统按角给出，不同角可以不同（本机就是顶/底不同）。
public struct DisplayCornerRadii: Equatable, Sendable {
    public let topLeft: CGFloat
    public let topRight: CGFloat
    public let bottomLeft: CGFloat
    public let bottomRight: CGFloat

    public init(topLeft: CGFloat, topRight: CGFloat, bottomLeft: CGFloat, bottomRight: CGFloat) {
        self.topLeft = topLeft
        self.topRight = topRight
        self.bottomLeft = bottomLeft
        self.bottomRight = bottomRight
    }

    /// 四角是否全为 0（系统报告该显示器四角都是直角）。
    public var isRectangular: Bool {
        topLeft == 0 && topRight == 0 && bottomLeft == 0 && bottomRight == 0
    }

    public var description: String {
        "tl=\(topLeft) tr=\(topRight) bl=\(bottomLeft) br=\(bottomRight)"
    }
}

/// 读取显示器的物理圆角。
///
/// 失败一律返回 `nil`（而不是 0）：调用方据此保留普通圆角，
/// 不会把「读不到」误当成「屏幕是直角」。绝不伪造机型对照表。
public enum DisplayCornerGeometry {

    /// `SLSDisplayGetCornerRadii` 的函数指针类型（签名见文件头注释）。
    private typealias GetCornerRadiiFn = @convention(c) (
        CGDirectDisplayID,
        UnsafeMutablePointer<Double>?,
        UnsafeMutablePointer<Double>?,
        UnsafeMutablePointer<Double>?,
        UnsafeMutablePointer<Double>?
    ) -> Int32

    /// 成功返回码；失败路径返回 1000（反汇编实测）。
    private static let successCode: Int32 = 0

    /// 可信半径上限（逻辑点）。超过这个量级只能说明取到的不是半径——
    /// 宁可判定失败，也不要把一个荒谬的值画到框上。
    private static let maximumPlausibleRadius: CGFloat = 200

    /// 动态加载的私有函数。只加载一次；失败后不再重试（避免每次会话都 dlopen 失败一次）。
    private static let function: GetCornerRadiiFn? = {
        let path = "/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/SkyLight"
        guard let handle = dlopen(path, RTLD_NOW) else {
            cornerLogger.notice("display corner radii: SkyLight 无法加载，保留普通圆角")
            return nil
        }
        guard let symbol = dlsym(handle, "SLSDisplayGetCornerRadii") else {
            cornerLogger.notice("display corner radii: 符号不存在（系统版本变化？），保留普通圆角")
            return nil
        }
        return unsafeBitCast(symbol, to: GetCornerRadiiFn.self)
    }()

    private static let lock = NSLock()

    // 下面三项是**确实存在**的可变静态状态（缓存 + 失败标记），由 `lock` 保护。
    // 标 `nonisolated(unsafe)` 是向编译器声明「并发安全由本类型自己负责」——
    // Swift 6 不允许可变的 static 存储，而把缓存改成实例对象只会把同一个问题
    // 换一个地方摆。项目内 `GlobalHotKey` 用的是同一种处理。
    private nonisolated(unsafe) static var cache: [CGDirectDisplayID: DisplayCornerRadii] = [:]
    /// 已确认取不到的显示器（避免反复调用失败路径）。
    private nonisolated(unsafe) static var unavailable: Set<CGDirectDisplayID> = []
    private nonisolated(unsafe) static var observerInstalled = false

    /// 读取指定显示器的四角半径；系统不提供或数值不可信时返回 `nil`。
    public static func radii(for displayID: CGDirectDisplayID) -> DisplayCornerRadii? {
        installObserverIfNeeded()

        lock.lock()
        if let hit = cache[displayID] {
            lock.unlock()
            return hit
        }
        if unavailable.contains(displayID) {
            lock.unlock()
            return nil
        }
        lock.unlock()

        guard let function else {
            markUnavailable(displayID, reason: "符号不可用")
            return nil
        }

        var x1 = 0.0
        var x2 = 0.0
        var x3 = 0.0
        var x4 = 0.0
        let code = function(displayID, &x1, &x2, &x3, &x4)
        guard code == successCode else {
            markUnavailable(displayID, reason: "返回码 \(code)")
            return nil
        }

        // 校验：必须是有限值、非负、量级可信。任何一项不满足都判为「读不到」。
        let raw = [x1, x2, x3, x4]
        guard raw.allSatisfy({ $0.isFinite && $0 >= 0 && CGFloat($0) <= maximumPlausibleRadius }) else {
            markUnavailable(displayID, reason: "数值不可信 \(raw)")
            return nil
        }

        let radii = DisplayCornerRadii(
            topLeft: CGFloat(x3),
            topRight: CGFloat(x4),
            bottomLeft: CGFloat(x1),
            bottomRight: CGFloat(x2)
        )

        // 屏幕参数一变（分辨率、缩放、换屏），半径与几何都可能变，缓存必须作废。
        lock.lock()
        cache[displayID] = radii
        lock.unlock()

        let scale = DisplayGeometry.scaleFactor(for: displayID)
        cornerLogger.notice("""
            display corner radii: display=\(displayID, privacy: .public) \
            \(radii.description, privacy: .public) \
            原始出参=(\(x1, privacy: .public), \(x2, privacy: .public), \(x3, privacy: .public), \(x4, privacy: .public)) \
            scale=\(scale, privacy: .public) 按像素解释=\(radii.topLeft * scale, privacy: .public)
            """)
        return radii
    }

    /// 清空缓存（显示配置变化、或诊断要重新探测时调用）。
    public static func invalidateCache() {
        lock.lock()
        cache.removeAll()
        unavailable.removeAll()
        lock.unlock()
    }

    private static func markUnavailable(_ displayID: CGDirectDisplayID, reason: String) {
        lock.lock()
        unavailable.insert(displayID)
        lock.unlock()
        cornerLogger.notice("""
            display corner radii: display=\(displayID, privacy: .public) 取不到（\(reason, privacy: .public)）；\
            该显示器的框保留普通圆角
            """)
    }

    /// 监听屏幕配置变化，自动作废缓存。
    ///
    /// 用 CoreGraphics 的重配置回调，而不是
    /// `NSApplication.didChangeScreenParametersNotification`：本模块是捕获层，
    /// `ScreenCapturing.swift` 明确约定「不把平台 UI 框架的类型泄漏进协议与实现」，
    /// 而 `NSApplication` 是 AppKit 类型——为了一条通知把整个 AppKit 拉进捕获层
    /// 并不划算。AppKit 的这条通知本身就是由这个 CG 回调转发出来的，
    /// 直接用底层反而少一层。
    private static func installObserverIfNeeded() {
        lock.lock()
        let installed = observerInstalled
        observerInstalled = true
        lock.unlock()
        guard !installed else { return }
        // 注册是幂等的（同一函数指针重复注册只生效一次），
        // 但仍用 `observerInstalled` 挡一道，不依赖系统行为。
        CGDisplayRegisterReconfigurationCallback(displayReconfigurationCallback, nil)
    }
}

/// 屏幕配置变化的 CoreGraphics 回调。
///
/// - **为什么过滤 `beginConfiguration`**：头文件（`CGDisplayConfiguration.h`）说明
///   回调在配置变化**开始时**会带上 `kCGDisplayBeginConfigurationFlag` 广播一次，
///   此时各屏几何可能还是中间态。只有不带该标志的那一批（头文件：
///   「每块新增 / 移除 / 当前在线的屏各一次」）才表示「所有显示状态都已是最新」。
///   原来的通知只在变化后发一次，语义与之对应。
///
/// - **为什么不传 `userInfo`**：C 函数指针不能捕获上下文，而回调体只需调用
///   类型方法（`DisplayCornerGeometry` 是无实例的 enum），无需实例。
///
/// - **线程**：回调可能在非主线程被调用。`invalidateCache()` 内部有锁，
///   故任意线程调用都安全。
private let displayReconfigurationCallback: CGDisplayReconfigurationCallBack = { _, flags, _ in
    guard !flags.contains(.beginConfigurationFlag) else { return }
    DisplayCornerGeometry.invalidateCache()
}
