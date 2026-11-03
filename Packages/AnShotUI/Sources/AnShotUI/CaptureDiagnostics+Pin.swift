//
//  CaptureDiagnostics+Pin.swift
//  AnShotUI
//
//  `-diagnosePin`：固定截图（Pin）的验证。
//
//  ── 验证什么 ──────────────────────────────────────────────
//
//  Pin 是内存纪律的**唯一显式例外**（契约 §6），所以最该验证的不是「窗口能显示」，
//  而是例外的边界与三条状态的分界：
//
//  * **上限**：默认值、可配置、越界被夹回、达上限时拒绝而不是关掉最旧的；
//  * **隐藏 ≠ 关闭**：隐藏后窗口不可见但位图仍在，恢复后还能看见；
//  * **关闭 = 释放**：位图被置空、占用归零；
//  * **卡片上的两个出口**：取消固定（收起，保留位图）与关闭（释放）摆在右上角，
//    接的是**不同**的动作，右键菜单里不再有这两项；
//  * **拖动**：`NSImageView` 本身不可拖（那是根因），`PinImageView` 可拖。
//
//  这些都用「窗口是否可见」证明不了：隐藏与关闭在屏幕上是同一个样子，
//  必须直接查管理器持有的位图与视图属性。
//

#if DEBUG
import AnShotCapture
import AnShotCore
import AppKit

extension CaptureDiagnostics {

    static func runPinDiagnostic() async {
        var failed = 0
        func report(_ label: String, _ measured: String, _ expected: String, _ ok: Bool) {
            if !ok { failed += 1 }
            logger.notice("""
                [pin] \(label, privacy: .public) measured=\(measured, privacy: .public) \
                expected=\(expected, privacy: .public)  \(ok ? "MATCH" : "MISMATCH", privacy: .public)
                """)
        }

        func makeImage(width: Int, height: Int) -> CGImage? {
            let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
            guard let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return nil }
            context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.9, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            return context.makeImage()
        }

        /// 四个按钮是否都完整落在卡片内。
        ///
        /// 不是洁癖：`imageView.layer.masksToBounds` 会把超出卡片的按钮**直接剪掉**，
        /// 被剪掉的按钮等于不存在。卡片能被缩小而按钮不跟着缩，所以这条必须每次布局后都成立。
        func buttonsInsideCard(_ window: PinWindow) -> Bool {
            guard let bounds = window.contentView?.bounds else { return false }
            return window.cardButtons.allSatisfy { bounds.contains($0.frame) }
        }

        /// 四个按钮的位置描述（断言失败时用来定位是哪一个跑出去了）。
        func cardButtonBounds(_ window: PinWindow) -> String {
            window.cardButtons
                .map { "\(Int($0.frame.minX)),\(Int($0.frame.minY))" }
                .joined(separator: " / ")
        }

        // ─── 设置：用独立 suite，绝不污染用户的真实偏好 ───
        let suiteName = "com.anshot.diagnose.pin"
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
        guard let store = UserDefaults(suiteName: suiteName) else {
            report("独立 UserDefaults suite", "nil", "非 nil", false)
            exit(1)
        }
        let settings = AppSettings(store: store)

        report("默认上限", "\(settings.pinMaximumCount)", "\(AppSettings.defaultPinMaximumCount)",
               settings.pinMaximumCount == AppSettings.defaultPinMaximumCount)

        // 越界值必须被夹回：上限为 0 会让「钉住」永久失效且界面上无从解释。
        settings.setPinMaximumCount(0)
        report("上限 0 被夹到下限", "\(settings.pinMaximumCount)", "\(AppSettings.pinLimitRange.lowerBound)",
               settings.pinMaximumCount == AppSettings.pinLimitRange.lowerBound)
        settings.setPinMaximumCount(9999)
        report("超上限被夹到上限", "\(settings.pinMaximumCount)", "\(AppSettings.pinLimitRange.upperBound)",
               settings.pinMaximumCount == AppSettings.pinLimitRange.upperBound)

        // 自定义一个小的上限，让后面的「达上限」验证不必创建 20 个窗口。
        settings.setPinMaximumCount(3)
        let reloaded = AppSettings(store: store)
        report("上限持久化并可重现读回", "\(reloaded.pinMaximumCount)", "3", reloaded.pinMaximumCount == 3)
        report("默认 Pin 切换热键已定义", AppSettings.defaultPinToggleShortcut.displayName, "⌃2",
               AppSettings.defaultPinToggleShortcut.displayName == "⌃2")

        let manager = PinManager(settings: settings)
        report("管理器读到的是设置里的上限", "\(manager.maximumPins)", "3", manager.maximumPins == 3)

        guard let image = makeImage(width: 400, height: 300) else {
            report("构造测试图", "nil", "非 nil", false)
            exit(1)
        }

        // ─── ① 钉住：窗口尺寸按屏幕缩放换算（这里用 2x，期望逻辑尺寸 200x150） ───
        guard case .created(let pin) = manager.pin(image: image, screenScale: 2) else {
            report("钉住第一张", "limitReached", "created", false)
            exit(1)
        }
        try? await Task.sleep(for: .milliseconds(300))
        report("Pin 数量", "\(manager.pins.count)", "1", manager.pins.count == 1)
        report("窗口按屏幕缩放换算尺寸",
               "\(Int(pin.frame.width))x\(Int(pin.frame.height))", "200x150",
               abs(pin.frame.width - 200) < 1 && abs(pin.frame.height - 150) < 1)
        report("窗口可见", "\(pin.isVisible)", "true", pin.isVisible)
        report("持有位图", "\(pin.contentImage != nil)", "true", pin.contentImage != nil)
        report("层级在普通窗口之上",
               "\(pin.level.rawValue) >= floating(\(NSWindow.Level.floating.rawValue))",
               "true", pin.level.rawValue >= NSWindow.Level.floating.rawValue)
        report("不进全屏空间（不遮挡别人的全屏应用）",
               "\(pin.collectionBehavior.contains(.fullScreenAuxiliary))", "false",
               !pin.collectionBehavior.contains(.fullScreenAuxiliary))
        report("序号从 1 开始且写入描述", pin.descriptor, "含 #1", pin.descriptor.hasPrefix("#1"))

        // ─── ② 拖动：这是「Pin 拖不动」的根因所在 ───
        // 对照断言是关键：普通 NSImageView 返回 false（正因如此原实现整块区域不可拖），
        // 而 PinWindow 用的 PinImageView 必须返回 true。
        report("内容视图是 PinImageView", "\(type(of: pin.contentView as Any))", "PinImageView",
               pin.contentView is PinImageView)
        report("PinImageView 允许背景拖动", "\(pin.contentView?.mouseDownCanMoveWindow ?? false)", "true",
               pin.contentView?.mouseDownCanMoveWindow == true)
        let plain = NSImageView()
        report("普通 NSImageView 不允许（对照，证明修正有意义）",
               "\(plain.mouseDownCanMoveWindow)", "false", !plain.mouseDownCanMoveWindow)

        // ─── ③ 位置：指定左上角时落在该处，不被级联偏移带跑 ───
        let visible = NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        // 取屏幕左下的一个点：与①那张（贴在可见区上方偏左）在垂直方向相距很远，
        // 否则测到的会是「级联偏移」而不是「按指定位置放」——两者都是对的行为，
        // 混在一起就分不清是哪一条在起作用。
        let target = CGPoint(x: visible.minX + 60, y: visible.minY + 200)
        guard case .created(let located) = manager.pin(image: image, screenScale: 2, topLeft: target) else {
            report("按指定位置钉第二张", "limitReached", "created", false)
            exit(1)
        }
        try? await Task.sleep(for: .milliseconds(200))
        report("窗口左上角落在指定位置",
               "(\(Int(located.frame.minX)), \(Int(located.frame.maxY)))",
               "(\(Int(target.x)), \(Int(target.y)))",
               abs(located.frame.minX - target.x) < 1 && abs(located.frame.maxY - target.y) < 1)
        report("第二张与第一张不重叠", "\(located.frame.intersects(pin.frame))", "false",
               !located.frame.intersects(pin.frame))

        // ─── ④ 缩放：滚轮与按钮两条入口都要真能用 ───
        //
        // 为什么这里非要用**合成滚轮事件**而不是直接调方法：上一版诊断只调了
        // `nudgeScale(by:)`（「方法存在」），而真实滚轮一格只变 2%——用户反馈正是
        // 「不能缩放」。幅度与路径（视图 → 窗口响应链）都必须落在断言里。
        //
        // 历史实现与结论：旧系数是「2% × scrollingDeltaY」，对普通滚轮（每格 ±1）
        // 就是 2%，肉眼几乎看不出；触控板与鼠标滚轮给的单位完全不同
        //（精确像素 vs 行数），一律线性相加必然有一端手感是错的。
        let basePixelSize = CGSize(width: 400, height: 300)

        /// 造一个滚轮事件。`precise` 对应触控板/妙控鼠标（像素单位），
        /// 否则是普通滚轮（行单位）。
        func scrollEvent(_ delta: Int32, precise: Bool, option: Bool = false) -> NSEvent? {
            guard let cgEvent = CGEvent(
                scrollWheelEvent2Source: nil,
                units: precise ? .pixel : .line,
                wheelCount: 1,
                wheel1: delta,
                wheel2: 0,
                wheel3: 0
            ) else { return nil }
            if option {
                cgEvent.flags = .maskAlternate
            }
            return NSEvent(cgEvent: cgEvent)
        }

        /// 把滚轮事件交给**内容视图**：响应链是「视图 → 窗口」，窗口的重写方法在链尾。
        /// 直接调 `window.scrollWheel` 只能证明方法存在，证明不了滚轮会走到那里。
        func scroll(_ delta: Int32, precise: Bool, option: Bool = false) {
            guard let event = scrollEvent(delta, precise: precise, option: option) else { return }
            pin.contentView?.scrollWheel(with: event)
        }

        pin.applyScale(1, pixelSize: basePixelSize, screenScale: 2)
        let beforeScale = pin.frame.width
        scroll(1, precise: false)
        try? await Task.sleep(for: .milliseconds(200))
        report("普通滚轮滚一格就能明显放大（幅度可感知）",
               "\(Int(beforeScale)) → \(Int(pin.frame.width))", "≥ 5%（旧实现只有 2%）",
               pin.frame.width >= beforeScale * 1.05)

        let beforeScrollDown = pin.frame.width
        scroll(-2, precise: false)
        try? await Task.sleep(for: .milliseconds(200))
        report("滚轮反向能缩小", "\(Int(beforeScrollDown)) → \(Int(pin.frame.width))", "变小",
               pin.frame.width < beforeScrollDown)

        pin.applyScale(1, pixelSize: basePixelSize, screenScale: 2)
        let beforePrecise = pin.frame.width
        scroll(20, precise: true)
        try? await Task.sleep(for: .milliseconds(200))
        report("触控板滑动也能缩放（精确像素单位，步长更细）",
               "\(Int(beforePrecise)) → \(Int(pin.frame.width))", "≥ 1%",
               pin.frame.width >= beforePrecise * 1.01)

        pin.applyScale(1, pixelSize: basePixelSize, screenScale: 2)
        // 透明度从 0.5 起调：从 1.0 往上调会被上限夹住，「没变」就成了必然，
        // 那样的断言过不过都不说明任何事（第一版就是这么写错的）。
        pin.setAlpha(0.5)
        let sizeBeforeOption = pin.frame.width
        scroll(3, precise: false, option: true)
        report("⌥+滚轮只调透明度、不动尺寸",
               "尺寸 \(Int(sizeBeforeOption))→\(Int(pin.frame.width)) 透明度 \(String(format: "%.2f", pin.alphaValue))",
               "尺寸不变且透明度变大",
               abs(pin.frame.width - sizeBeforeOption) < 0.5 && pin.alphaValue > 0.51)
        pin.setAlpha(1)

        // 触控板双指捏合：手势事件合成不出来（`NSEvent` 没有公开的 magnify 构造），
        // 所以这里喂的是「事件 → 语义」之后的输入层；那一层只有一行翻译（见 scrollWheel/magnify），
        // 真实捏合手感列入人工验收。
        pin.applyScale(1, pixelSize: basePixelSize, screenScale: 2)
        let beforePinch = pin.frame.width
        pin.applyCardInput(.pinch(amount: 0.2), transparency: false)
        try? await Task.sleep(for: .milliseconds(200))
        let pinchExpected = beforePinch * Foundation.exp(0.2)
        report("触控板捏合能放大（手势 0.2 → 尺寸 ×e^0.2）",
               "\(Int(beforePinch)) → \(Int(pin.frame.width))", "\(Int(pinchExpected))",
               abs(pin.frame.width - pinchExpected) < 1.5)
        pin.applyCardInput(.pinch(amount: -0.2), transparency: false)
        report("捏合反向能**回到**原尺寸（指数映射可逆）",
               "\(Int(pin.frame.width))", "\(Int(beforePinch))",
               abs(pin.frame.width - beforePinch) < 1)
        pin.setAlpha(0.5)
        let sizeBeforePinchAlpha = pin.frame.width
        pin.applyCardInput(.pinch(amount: 0.2), transparency: true)
        report("⌃+捏合调透明度、不动尺寸",
               "尺寸 \(Int(sizeBeforePinchAlpha))→\(Int(pin.frame.width)) 透明度 \(String(format: "%.2f", pin.alphaValue))",
               "尺寸不变且透明度变大",
               abs(pin.frame.width - sizeBeforePinchAlpha) < 0.5 && pin.alphaValue > 0.55)
        pin.setAlpha(1)
        pin.applyScale(1, pixelSize: basePixelSize, screenScale: 2)

        // ⌃+滚轮（用户指定的透明度手势）与 ⌥+滚轮走同一条入口。
        pin.setAlpha(0.5)
        let sizeBeforeControl = pin.frame.width
        pin.applyCardInput(.scroll(delta: -3, precise: false), transparency: true)
        report("⌃+滚轮调透明度、不动尺寸",
               "尺寸 \(Int(sizeBeforeControl))→\(Int(pin.frame.width)) 透明度 \(String(format: "%.2f", pin.alphaValue))",
               "尺寸不变且透明度变小",
               abs(pin.frame.width - sizeBeforeControl) < 0.5 && pin.alphaValue < 0.49)
        pin.setAlpha(1)

        report("按钮缩放是等比（乘性）而不是加减固定值",
               "1.0 → \(String(format: "%.3f", 1.0 * PinWindow.buttonZoomStep))",
               String(format: "%.3f", PinWindow.buttonZoomStep),
               abs(PinWindow.buttonZoomStep - 1.1) < 0.001)

        // 下限：卡片不能小到把按钮裁掉——「＋」被裁掉会把用户锁在一张再也放不大的图里。
        pin.applyScale(0.01, pixelSize: basePixelSize, screenScale: 2)
        try? await Task.sleep(for: .milliseconds(200))
        report("缩到极限时卡片仍放得下按钮（不会被裁成死角）",
               "卡片 \(Int(pin.frame.width))x\(Int(pin.frame.height)) 短边 \(Int(min(pin.frame.width, pin.frame.height)))",
               "短边 ≥ \(Int(PinWindow.minimumCardSide))",
               min(pin.frame.width, pin.frame.height) >= PinWindow.minimumCardSide - 1)
        report("下限由卡片尺寸推出，而不是写死的绝对下限",
               String(format: "%.3f > %.3f", pin.scale, PinWindow.absoluteMinimumScale),
               "大于绝对下限", pin.scale > PinWindow.absoluteMinimumScale)
        report("极限缩放下四个按钮仍完整落在卡片内",
               cardButtonBounds(pin), "全部在卡片内", buttonsInsideCard(pin))

        // 本来就是小图（30×30 像素）：不强制放大，只是不能再缩小。
        report("小图不被强制放大（下限夹到 1.0）",
               String(format: "%.2f", PinWindow.minimumScale(pixelSize: CGSize(width: 30, height: 30), screenScale: 1)),
               "1.00",
               abs(PinWindow.minimumScale(pixelSize: CGSize(width: 30, height: 30), screenScale: 1) - 1) < 0.001)
        pin.applyScale(1, pixelSize: basePixelSize, screenScale: 2)
        report("重置缩放回到原始大小", "\(Int(pin.frame.width))", "200", abs(pin.frame.width - 200) < 1)

        pin.setAlpha(0.5)
        report("透明度可调", String(format: "%.2f", pin.alphaValue), "0.50", abs(pin.alphaValue - 0.5) < 0.01)
        pin.setAlpha(0.01)
        report("透明度有下限（不会调到看不见）", String(format: "%.2f", pin.alphaValue), ">= 0.20",
               pin.alphaValue >= 0.19)
        pin.setAlpha(1)

        // ─── ⑤ 隐藏 ≠ 关闭 ───
        pin.hidePin()
        report("隐藏后窗口不可见", "\(pin.isVisible)", "false", !pin.isVisible)
        report("隐藏后**位图仍在**", "\(pin.contentImage != nil)", "true", pin.contentImage != nil)
        report("隐藏后仍计入数量", "\(manager.pins.count)", "2", manager.pins.count == 2)
        report("隐藏计数", "隐藏 \(manager.hiddenCount) / 可见 \(manager.visibleCount)", "1 / 1",
               manager.hiddenCount == 1 && manager.visibleCount == 1)

        pin.showPin()
        report("恢复显示后窗口可见", "\(pin.isVisible)", "true", pin.isVisible)
        report("恢复显示后位图未变", "\(pin.contentImage != nil)", "true", pin.contentImage != nil)
        report("恢复显示后隐藏计数归零", "\(manager.hiddenCount)", "0", manager.hiddenCount == 0)

        // ─── ⑥ 全部隐藏 / 全部显示 ───
        manager.hideAll()
        report("全部隐藏后无可见窗", "\(manager.visibleCount)", "0", manager.visibleCount == 0)
        report("全部隐藏后位图仍全部保留", "\(manager.estimatedBytes > 0)", "true", manager.estimatedBytes > 0)
        report("全部隐藏后数量不变", "\(manager.pins.count)", "2", manager.pins.count == 2)

        // 一键切换：有可见 → 全隐；全隐 → 全显。
        manager.toggleAllVisibility()
        report("全隐时切换 = 全部显示", "\(manager.visibleCount)", "\(manager.pins.count)",
               manager.visibleCount == manager.pins.count)
        manager.toggleAllVisibility()
        report("有可见时切换 = 全部隐藏", "\(manager.visibleCount)", "0", manager.visibleCount == 0)
        manager.showAll()
        report("显示全部", "\(manager.visibleCount)", "\(manager.pins.count)",
               manager.visibleCount == manager.pins.count)

        // ─── ⑦ 达上限：拒绝新请求，且**不**关掉任何已有的 ───
        // 上限是 3，当前已有 2 个，先补到 3 个。
        guard case .created = manager.pin(image: image, screenScale: 2) else {
            report("补到上限", "limitReached", "created", false)
            exit(1)
        }
        report("已达上限", "\(manager.isAtLimit)", "true", manager.isAtLimit)

        let idsBefore = manager.pins.map(\.pinID)
        let rejected = manager.pin(image: image, screenScale: 2)
        var rejectedLimit: Int?
        if case .limitReached(let limit) = rejected { rejectedLimit = limit }
        report("达上限时拒绝新请求", "\(rejectedLimit != nil)", "true", rejectedLimit != nil)
        report("拒绝时带上的上限数字", "\(rejectedLimit ?? -1)", "3", rejectedLimit == 3)
        report("拒绝时数量不变", "\(manager.pins.count)", "3", manager.pins.count == 3)
        report("拒绝时不关闭任何已有 Pin（不像早期版本那样丢最旧的）",
               "\(manager.pins.map(\.pinID) == idsBefore)", "true", manager.pins.map(\.pinID) == idsBefore)
        report("被拒绝的 Pin 没有留下窗口", "\(manager.pins.count) 个", "3 个", manager.pins.count == 3)

        // ─── ⑧ 关闭 = 释放 ───
        manager.closeAll()
        report("关闭后清空", "\(manager.pins.count)", "0", manager.pins.isEmpty)
        report("关闭后释放位图", "\(pin.contentImage == nil)", "true", pin.contentImage == nil)
        report("关闭后窗口不可见", "\(pin.isVisible)", "false", !pin.isVisible)
        report("释放后占用归零", "\(manager.estimatedBytes)", "0", manager.estimatedBytes == 0)

        // 关闭后再钉：上限不再拦（说明数的是当前持有量，不是历史累计）。
        guard case .created = manager.pin(image: image, screenScale: 2) else {
            report("关闭后可以继续钉", "limitReached", "created", false)
            exit(1)
        }
        report("关闭后可以继续钉（上限数的是持有量而非累计）", "\(manager.pins.count)", "1",
               manager.pins.count == 1)
        manager.closeAll()
        report("全部关闭后无残留", "\(manager.pins.count) 个 / \(manager.estimatedBytes) B", "0 / 0",
               manager.pins.isEmpty && manager.estimatedBytes == 0)

        // ─── ⑨ 级联：同一位置连钉两张不会完全叠在一起 ───
        // 不做这一步的话，连钉几张会看起来像只钉了一次，而每一张都真实占着内存。
        let anchor = CGPoint(x: visible.minX + 300, y: visible.minY + 400)
        guard case .created(let base) = manager.pin(image: image, screenScale: 2, topLeft: anchor),
              case .created(let cascaded) = manager.pin(image: image, screenScale: 2, topLeft: anchor)
        else {
            report("级联场景构造", "limitReached", "created", false)
            exit(1)
        }
        try? await Task.sleep(for: .milliseconds(200))
        report("同位置再钉一张会错开",
               "\(Int(base.frame.minX)),\(Int(base.frame.maxY)) → \(Int(cascaded.frame.minX)),\(Int(cascaded.frame.maxY))",
               "不相等", cascaded.frame.origin != base.frame.origin)
        report("级联后两张不重叠", "\(cascaded.frame.intersects(base.frame))", "false",
               !cascaded.frame.intersects(base.frame))
        report("级联方向是右下",
               "dx=\(Int(cascaded.frame.minX - base.frame.minX)) dy=\(Int(cascaded.frame.maxY - base.frame.maxY))",
               "dx>0 且 dy<0",
               cascaded.frame.minX > base.frame.minX && cascaded.frame.maxY < base.frame.maxY)
        manager.closeAll()
        report("级联场景收尾", "\(manager.pins.count)", "0", manager.pins.isEmpty)

        // ─── ⑩ 防丢：整个窗口被推到屏幕外时必须拉回 ───
        // 「随意拖动」的代价是有真丢窗口的风险：拖到屏幕外就再也点不到。
        // 判据是**完全离开**所有屏幕，部分越界（图一半贴在屏幕外）是正常摆法。
        guard case .created(let stray) = manager.pin(image: image, screenScale: 2) else {
            report("防丢场景构造", "limitReached", "created", false)
            exit(1)
        }
        stray.setFrameOrigin(CGPoint(x: visible.maxX + 2000, y: visible.maxY + 2000))
        try? await Task.sleep(for: .milliseconds(700))
        report("拖出屏幕后会被拉回可见区",
               "(\(Int(stray.frame.minX)), \(Int(stray.frame.minY)))",
               "与可见区相交",
               NSScreen.screens.contains { $0.visibleFrame.intersects(stray.frame) })

        // 只部分越界时不该动它：那是一种正常摆法。
        let halfOut = CGRect(origin: stray.frame.origin, size: stray.frame.size)
        stray.setFrameOrigin(CGPoint(x: visible.maxX - 40, y: halfOut.minY))
        try? await Task.sleep(for: .milliseconds(700))
        report("部分越界不被纠正（正常的摆放方式）",
               "\(Int(stray.frame.minX))", "\(Int(visible.maxX - 40))",
               abs(stray.frame.minX - (visible.maxX - 40)) < 1)
        manager.closeAll()

        // ─── ⑪ 卡片右上角的两个出口 ───
        // 用户给的规则：**「关闭」本身从不销毁**。固定中它只隐藏（位图保留，
        // 菜单栏可恢复）；只有先按图钉「取消固定」，关闭才隐藏并释放。
        // 两个维度正交：图钉管「这张图留不留」，✕ 管「现在收不收」。
        //
        // 这套语义在屏幕上几乎看不出来（两种状态的外观一样），所以断言全部落在
        // 「点完之后位图、管理列表、可见性各自怎样」，而不是外观。
        guard case .created(let card) = manager.pin(image: image, screenScale: 2) else {
            report("卡片按钮场景构造", "limitReached", "created", false)
            exit(1)
        }
        try? await Task.sleep(for: .milliseconds(200))

        report("卡片有图钉按钮", String(describing: type(of: card.pinButton)), "PinCardButton",
               String(describing: type(of: card.pinButton)) == "PinCardButton")
        report("卡片有关闭按钮", String(describing: type(of: card.closeButton)), "PinCardButton",
               String(describing: type(of: card.closeButton)) == "PinCardButton")
        report("两个按钮是两个对象（各接一个动作，不是同一个按钮）",
               "\(card.pinButton === card.closeButton)", "false", card.pinButton !== card.closeButton)
        report("`pin.slash` 符号在本机可用（取消固定后要换图标）",
               "\(NSImage(systemSymbolName: "pin.slash", accessibilityDescription: nil) != nil)",
               "true", NSImage(systemSymbolName: "pin.slash", accessibilityDescription: nil) != nil)
        report("初始状态是「固定中」", "\(card.isUnpinned)", "false", !card.isUnpinned)
        report("图钉按钮说明写明它是「取消固定」", card.pinButton.toolTip ?? "nil", "含「取消固定」",
               (card.pinButton.toolTip ?? "").contains("取消固定"))
        report("固定中时关闭按钮说明写明只隐藏、不释放（只靠图标分不出这一点）",
               card.closeButton.toolTip ?? "nil", "含「隐藏」与「不释放」",
               (card.closeButton.toolTip ?? "").contains("隐藏")
                   && (card.closeButton.toolTip ?? "").contains("不释放"))
        // 卡片常浮在别的应用之上、而本应用多是不活跃那个；无边框 `NSWindow`
        // 会把「第一次点击」拿去激活窗口。按钮必须对这条免疫——本项目已有同类实测：
        // `-diagnoseSettingsWindow` 里「应用处于激活态是合成鼠标点击的前提」。
        // 实测结论：`NSControl` 的默认实现已返回 true（下方对照组），所以**不需要**
        // 在 `PinCardButton` 里重写 `acceptsFirstMouse`；这里把前提钉住——
        // 将来把按钮换成普通自绘视图，会先在这里失败。
        let probeEvent = NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: .zero,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: card.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        )
        report("两个按钮接受首次点击（非活跃应用下点一次即生效）",
               "图钉=\(card.pinButton.acceptsFirstMouse(for: probeEvent)) 关闭=\(card.closeButton.acceptsFirstMouse(for: probeEvent))",
               "true / true",
               card.pinButton.acceptsFirstMouse(for: probeEvent)
                   && card.closeButton.acceptsFirstMouse(for: probeEvent))
        report("对照组：普通 NSButton 也是 true（故不需额外代码，只需钉住前提）",
               "\(NSButton().acceptsFirstMouse(for: probeEvent))", "true",
               NSButton().acceptsFirstMouse(for: probeEvent))
        report("四个按钮都是内容视图的子视图（未新增容器，拖动修复不受影响）",
               "\(card.cardButtons.allSatisfy { $0.superview === card.contentView })",
               "true", card.cardButtons.allSatisfy { $0.superview === card.contentView })
        report("卡片有放大按钮", String(describing: type(of: card.plusButton)), "PinCardButton",
               String(describing: type(of: card.plusButton)) == "PinCardButton")
        report("卡片有缩小按钮", String(describing: type(of: card.minusButton)), "PinCardButton",
               String(describing: type(of: card.minusButton)) == "PinCardButton")
        report("放大按钮说明写明步长与「滚轮也行」", card.plusButton.toolTip ?? "nil",
               "含「放大」", (card.plusButton.toolTip ?? "").contains("放大"))
        report("缩小按钮说明写明步长与「滚轮也行」", card.minusButton.toolTip ?? "nil",
               "含「缩小」", (card.minusButton.toolTip ?? "").contains("缩小"))

        // 位置：贴右上角，且「关闭」在最右（与系统交通灯一致：破坏性动作在最右）。
        let side = PinCardButton.side
        let inset = PinCardButton.inset
        func topRightSatisfied(_ window: PinWindow) -> Bool {
            guard let bounds = window.contentView?.bounds else { return false }
            return abs(window.closeButton.frame.maxX - (bounds.maxX - inset)) < 1
                && abs(window.closeButton.frame.maxY - (bounds.maxY - inset)) < 1
                && abs(window.pinButton.frame.maxY - window.closeButton.frame.maxY) < 0.01
        }
        report("✕ 贴卡片右上角（出口在最前）",
               "卡片右上=(\(Int(card.contentView?.bounds.maxX ?? 0)), \(Int(card.contentView?.bounds.maxY ?? 0)))",
               "✕ 右上=(卡片右上 − \(Int(inset)))", topRightSatisfied(card))
        report("四个按钮都完整落在卡片内（超出会被 masksToBounds 剪掉）",
               cardButtonBounds(card), "全部在卡片内", buttonsInsideCard(card))
        report("从右到左的顺序是 ✕、图钉、＋、－（破坏性动作与缩放分开得开）",
               "\(Int(card.closeButton.frame.minX)) > \(Int(card.pinButton.frame.minX)) > \(Int(card.plusButton.frame.minX)) > \(Int(card.minusButton.frame.minX))",
               "递减",
               card.closeButton.frame.minX > card.pinButton.frame.minX
                   && card.pinButton.frame.minX > card.plusButton.frame.minX
                   && card.plusButton.frame.minX > card.minusButton.frame.minX)
        report("同一排按钮的上下边对齐", "\(Int(card.minusButton.frame.minY))",
               "\(Int(card.closeButton.frame.minY))",
               abs(card.minusButton.frame.minY - card.closeButton.frame.minY) < 0.01)

        // 缩放会 resize 窗口（即 resize 内容视图）：按钮必须跟着贴住右上角、且自身不放大。
        card.applyScale(2, pixelSize: CGSize(width: 400, height: 300), screenScale: 2)
        try? await Task.sleep(for: .milliseconds(200))
        report("缩放后按钮仍在右上角（不跟着漂走）",
               "卡片宽 \(Int(card.contentView?.bounds.width ?? 0))", "仍满足右上角判据",
               topRightSatisfied(card))
        report("缩放后按钮大小不变（图标不该跟着图放大）",
               "\(Int(card.closeButton.frame.width))x\(Int(card.closeButton.frame.height))",
               "\(Int(side))x\(Int(side))",
               abs(card.closeButton.frame.width - side) < 1
                   && abs(card.closeButton.frame.height - side) < 1)
        card.applyScale(1, pixelSize: CGSize(width: 400, height: 300), screenScale: 2)

        // 卡片上的缩放按钮：不依赖滚轮也能放大缩小（滚轮能否到达本窗口由系统决定）。
        let baseWidth = card.frame.width
        card.plusButton.performClick(nil)
        report("点「＋」放大 10%（等比）",
               "\(Int(baseWidth)) → \(Int(card.frame.width))",
               "\(Int(baseWidth * 1.1))",
               abs(card.frame.width - baseWidth * 1.1) < 1)
        card.minusButton.performClick(nil)
        report("点「－」缩小回去",
               "\(Int(card.frame.width))", "\(Int(baseWidth))",
               abs(card.frame.width - baseWidth) < 1)
        report("缩放按钮点击后按钮仍在卡片内", cardButtonBounds(card), "全部在卡片内",
               buttonsInsideCard(card))

        // 右键菜单：出口已经移到卡片上，菜单里不得再有两者的重复入口。
        let menuTitles = card.cardAdjustmentMenu().items.map(\.title)
        report("右键菜单不再提供「隐藏」/「关闭」", "\(menuTitles)", "不含这两项",
               !menuTitles.contains("隐藏") && !menuTitles.contains("关闭"))
        report("右键菜单仍保留调整项（未随出口一起被删）", "\(menuTitles)", "含「原始大小」「不透明」",
               menuTitles.contains("原始大小") && menuTitles.contains("不透明"))

        // ① 固定中 + 关闭 = 只隐藏，位图保留、仍在管理列表（菜单栏可恢复）。
        card.closeButton.performClick(nil)
        report("固定中点关闭 → 卡片收起", "\(card.isVisible)", "false", !card.isVisible)
        report("固定中点关闭 → **位图仍在**（关闭本身从不销毁）",
               "\(card.contentImage != nil)", "true", card.contentImage != nil)
        report("固定中点关闭 → 仍在管理列表里（可从菜单栏恢复）",
               "\(manager.pins.count) 张 / 隐藏 \(manager.hiddenCount)", "1 张 / 隐藏 1",
               manager.pins.count == 1 && manager.hiddenCount == 1)

        // ② 恢复显示后按图钉 = 取消固定，但**先不隐藏**。
        card.showPin()
        card.pinButton.performClick(nil)
        report("按图钉后进入「已取消固定」", "\(card.isUnpinned)", "true", card.isUnpinned)
        report("按图钉**不隐藏**（卡片仍在屏幕上）", "\(card.isVisible)", "true", card.isVisible)
        report("按图钉后位图仍在且仍计入上限",
               "位图=\(card.contentImage != nil) / 列表 \(manager.pins.count) 张", "true / 1 张",
               card.contentImage != nil && manager.pins.count == 1)
        report("图钉按钮图标与说明随状态变化（否则用户看不出关闭会释放）",
               card.pinButton.toolTip ?? "nil", "含「重新固定」",
               (card.pinButton.toolTip ?? "").contains("重新固定"))
        report("已取消固定时关闭按钮说明改为会释放（两态的文案必须不同）",
               card.closeButton.toolTip ?? "nil", "含「并释放」",
               (card.closeButton.toolTip ?? "").contains("并释放"))

        // ③ 再按一次图钉 = 回到固定中（toggle 往返）。
        card.pinButton.performClick(nil)
        report("再按图钉可恢复固定（状态可往返）", "\(card.isUnpinned)", "false", !card.isUnpinned)
        report("恢复固定后关闭按钮说明回到「不释放」",
               card.closeButton.toolTip ?? "nil", "含「隐藏」与「不释放」",
               (card.closeButton.toolTip ?? "").contains("隐藏")
                   && (card.closeButton.toolTip ?? "").contains("不释放"))

        // ④ 已取消固定 + 关闭 = 隐藏并释放（唯一销毁路径）。
        card.pinButton.performClick(nil)
        card.closeButton.performClick(nil)
        report("已取消固定后点关闭 → 释放位图", "\(card.contentImage == nil)", "true",
               card.contentImage == nil)
        report("已取消固定后点关闭 → 窗口不可见", "\(card.isVisible)", "false", !card.isVisible)
        report("已取消固定后点关闭 → 从管理列表移除（菜单栏条目消失）",
               "\(manager.pins.count)", "0", manager.pins.isEmpty)
        report("释放后占用归零", "\(manager.estimatedBytes)", "0", manager.estimatedBytes == 0)

        // ⑤ ESC 关闭 + 指针命中（捏合的全局监视器靠命中判定决定把事件给谁）。
        //
        // 断言方式：合成 keyDown（`NSEvent.keyEvent` 是公开 API，可以造），
        // 走的是窗口真实的 `keyDown` 入口——不是直接调关闭方法，
        // 后者只能证明方法存在，证明不了「按 ESC 会走到那里」。
        guard case .created(let escCard) = manager.pin(image: image, screenScale: 2) else {
            report("ESC 场景构造", "limitReached", "created", false)
            exit(1)
        }
        try? await Task.sleep(for: .milliseconds(200))
        report("窗口可以成为 key window（否则 ESC 根本到不了卡片）",
               "\(escCard.canBecomeKey)", "true", escCard.canBecomeKey)
        report("窗口不必成为 main window", "\(escCard.canBecomeMain)", "false", !escCard.canBecomeMain)

        func keyEvent(keyCode: UInt16, characters: String, for window: PinWindow) -> NSEvent? {
            NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber,
                context: nil,
                characters: characters,
                charactersIgnoringModifiers: characters,
                isARepeat: false,
                keyCode: keyCode
            )
        }

        // 固定中按 ESC = 隐藏（保留位图），与 ✕ 的规则逐字相同。
        if let escape = keyEvent(keyCode: PinWindow.escapeKeyCode, characters: "\u{1b}", for: escCard) {
            escCard.keyDown(with: escape)
        }
        report("固定中按 ESC → 卡片收起", "\(escCard.isVisible)", "false", !escCard.isVisible)
        report("固定中按 ESC → **位图保留**（不能比 ✕ 更狠）",
               "位图=\(escCard.contentImage != nil) / 列表 \(manager.pins.count) 张",
               "true / 1 张",
               escCard.contentImage != nil && manager.pins.count == 1)

        // 已取消固定按 ESC = 隐藏并释放，同样与 ✕ 一致。
        escCard.showPin()
        escCard.pinButton.performClick(nil)
        if let escape = keyEvent(keyCode: PinWindow.escapeKeyCode, characters: "\u{1b}", for: escCard) {
            escCard.keyDown(with: escape)
        }
        report("已取消固定按 ESC → 释放位图", "\(escCard.contentImage == nil)", "true",
               escCard.contentImage == nil)
        report("已取消固定按 ESC → 从管理列表移除", "\(manager.pins.count)", "0", manager.pins.isEmpty)

        // 其它按键不得被当成关闭：否则任何一次键入都会把卡片关掉。
        guard case .created(let keyCard) = manager.pin(image: image, screenScale: 2) else {
            report("按键场景构造", "limitReached", "created", false)
            exit(1)
        }
        try? await Task.sleep(for: .milliseconds(200))
        if let other = keyEvent(keyCode: 0, characters: "a", for: keyCard) {
            keyCard.keyDown(with: other)
        }
        report("其它按键不会被当成关闭",
               "可见=\(keyCard.isVisible) / 列表 \(manager.pins.count) 张", "true / 1 张",
               keyCard.isVisible && manager.pins.count == 1)

        // 指针命中：捏合的全局监视器据此认领事件。
        let cardCenter = CGPoint(x: keyCard.frame.midX, y: keyCard.frame.midY)
        report("指针在卡片内时命中该卡片", "\(manager.pin(at: cardCenter) === keyCard)", "true",
               manager.pin(at: cardCenter) === keyCard)
        let farAway = CGPoint(x: keyCard.frame.maxX + 300, y: keyCard.frame.maxY + 300)
        report("指针在卡片外时不命中", "\(manager.pin(at: farAway) == nil)", "true",
               manager.pin(at: farAway) == nil)
        keyCard.hidePin()
        report("隐藏的卡片不参与命中（已不在窗口层级）", "\(manager.pin(at: cardCenter) == nil)", "true",
               manager.pin(at: cardCenter) == nil)
        keyCard.showPin()

        // 捏合的窗口路径（本应用活跃时走它）与监视器路径共用同一个输入分发。
        let beforeCardPinch = keyCard.frame.width
        keyCard.applyCardInput(.pinch(amount: 0.1), transparency: false)
        report("捏合经卡片输入分发生效（监视器路径共用它）",
               "\(Int(beforeCardPinch)) → \(Int(keyCard.frame.width))",
               "\(Int(beforeCardPinch * Foundation.exp(0.1)))",
               abs(keyCard.frame.width - beforeCardPinch * Foundation.exp(0.1)) < 1.5)
        report("捏合监视器已安装（非活跃应用下的唯一路径）",
               "\(manager.isPinchMonitorInstalled)", "true", manager.isPinchMonitorInstalled)

        manager.closeAll()
        report("ESC / 命中场景收尾", "\(manager.pins.count)", "0", manager.pins.isEmpty)

        UserDefaults.standard.removePersistentDomain(forName: suiteName)

        logger.notice("""
            [pin] 汇总: \(failed == 0 ? "全部通过" : "\(failed) 项失败", privacy: .public) \
            exitCode=\(failed == 0 ? 0 : 1, privacy: .public)
            """)
        try? await Task.sleep(for: .milliseconds(300))
        exit(failed == 0 ? 0 : 1)
    }
}
#endif
