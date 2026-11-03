//
//  CaptureSetup.swift
//  AnShotCapture
//
//  单帧捕获的共享准备逻辑：权限预检、可共享内容查询、过滤器与流配置构造。
//
//  两个实现（`ScreenshotCapturer` 与 `StreamCapturer`）共用这一套构造，
//  避免参数在两个实现之间漂移——这类漂移会造成「同一个区域内，两个实现
//  抓出的图尺寸或坐标不一致」的隐蔽缺陷。
//

import AnShotCore
import CoreGraphics
import CoreMedia
import Foundation
import ScreenCaptureKit

private let setupLogger = AnShotLog.capture
@available(macOS 12.3, *)
enum CaptureSetup {

    // MARK: - 前置检查

    /// 权限预检。
    ///
    /// 放在最前面是为了避免在无权限时调用 `SCShareableContent`——
    /// 后者会触发系统授权流程，不是一次普通的查询所应产生的副作用。
    static func requirePermission() throws {
        guard CGPreflightScreenCaptureAccess() else {
            throw CaptureError.permissionDenied
        }
    }

    /// 校验显示器可用并返回其几何信息。
    static func displayContext(for displayID: CGDirectDisplayID) throws -> (
        bounds: CGRect,
        scaleFactor: CGFloat,
        pixelSize: CGSize
    ) {
        let bounds = CGDisplayBounds(displayID)
        guard bounds.width >= 1, bounds.height >= 1 else {
            throw CaptureError.displayUnavailable
        }
        return (
            bounds: bounds,
            scaleFactor: DisplayGeometry.scaleFactor(for: displayID),
            pixelSize: DisplayGeometry.pixelSize(for: displayID)
        )
    }

    /// 把请求范围裁剪到显示器边界内。
    ///
    /// - Returns: 裁剪后的区域（逻辑点）；非区域范围时为 `nil`。
    /// - Throws: 裁剪后为空时抛 `.emptyResult`。
    static func normalizedRegion(for scope: CaptureScope) throws -> CGRect? {
        switch scope {
        case .region(let displayID, let rect):
            guard let clamped = DisplayGeometry.clamp(rect: rect, to: displayID) else {
                throw CaptureError.emptyResult
            }
            return clamped
        case .display, .window, .application:
            return nil
        }
    }

    /// 单帧截图的目标形态。
    ///
    /// 比 `CaptureScope` 窄：单帧产物必须携带一个缩放系数（逻辑点 → 像素的
    /// 换算依据），因此「某进程的全部窗口」这种可跨显示器的范围天然不适用。
    /// 这是一个**明确的边界**，不是暂缺的实现——边界外的请求会被拒绝并给出
    /// 替代方案，而不是静默降级成一张别处的图。
    enum SingleFrameTarget {
        /// 显示器（`region` 为 nil 表示整屏，否则为已裁剪到显示器内的区域）。
        case display(CGDirectDisplayID, region: CGRect?)

        /// 单个窗口。
        case window(CGWindowID)
    }

    /// 校验单帧截图支持的范围，并取出可执行目标。
    ///
    /// 区域在这里一并裁剪：调用方原先要分别调用「取显示器」与「裁剪区域」，
    /// 两次调用之间存在「校验用的显示器」与「实际用的显示器」不一致的窗口期。
    static func resolveSingleFrameTarget(_ scope: CaptureScope) throws -> SingleFrameTarget {
        switch scope {
        case .display(let displayID):
            return .display(displayID, region: nil)

        case .region(let displayID, _):
            // `normalizedRegion` 已经保证「非空区域或抛错」，因此这里的 `??`
            // 只在非区域范围时才可能生效。
            return .display(displayID, region: try normalizedRegion(for: scope))

        case .window(let windowID):
            return .window(windowID)

        case .application:
            throw CaptureError.unsupportedScope(
                "单帧截图不支持\(scope.displayName)：一个应用可有多个窗口、且能横跨"
                + "多块显示器，无法确定唯一的缩放系数。请改用窗口范围"
                + "（一次截一个窗口）或「显示器 + 区域」。"
            )
        }
    }

    // MARK: - 窗口捕获构造

    /// 单帧捕获所需的全部构造物。
    ///
    /// 两个实现（`ScreenshotCapturer` / `StreamCapturer`）都从这里取，
    /// 保证「同一个请求在两个实现下产出同尺寸、同归属、同元数据的图」。
    /// 各写一遍会漂移——而漂移只会在旧系统上暴露，开发机看不到。
    struct SingleFrameSetup {
        let filter: SCContentFilter
        let configuration: SCStreamConfiguration
        let displayID: CGDirectDisplayID
        let scaleFactor: CGFloat
        let windowInfo: WindowCaptureInfo?
    }

    /// 按目标构造过滤器、配置与产物元数据。
    static func makeSingleFrameSetup(
        target: SingleFrameTarget,
        scope: CaptureScope,
        content: SCShareableContent,
        showsCursor: Bool
    ) throws -> SingleFrameSetup {
        switch target {
        case .display(let targetDisplayID, let region):
            let context = try displayContext(for: targetDisplayID)
            let display = try self.display(in: content, matching: targetDisplayID)

            return SingleFrameSetup(
                filter: makeFilter(display: display),
                configuration: makeConfiguration(
                    scope: scope,
                    displayID: targetDisplayID,
                    scaleFactor: context.scaleFactor,
                    pixelSize: context.pixelSize,
                    normalizedRegion: region,
                    showsCursor: showsCursor
                ),
                displayID: targetDisplayID,
                scaleFactor: context.scaleFactor,
                windowInfo: nil
            )

        case .window(let windowID):
            let window = try self.window(in: content, matching: windowID)
            let frame = window.frame
            guard frame.width >= 1, frame.height >= 1 else {
                throw CaptureError.emptyResult
            }

            // `SCWindow` 不携带显示器信息（窗口可跨屏），按 frame 中心点定位，
            // 用它取缩放系数——输出像素尺寸必须与窗口所在屏一致。
            guard let owningDisplay = DisplayGeometry.displayContaining(frame) else {
                throw CaptureError.displayUnavailable
            }
            let context = try displayContext(for: owningDisplay)

            return SingleFrameSetup(
                filter: makeWindowFilter(window: window),
                configuration: makeWindowConfiguration(
                    frame: frame,
                    scaleFactor: context.scaleFactor,
                    showsCursor: showsCursor
                ),
                displayID: owningDisplay,
                scaleFactor: context.scaleFactor,
                windowInfo: WindowCaptureInfo(
                    windowID: windowID,
                    title: window.title,
                    applicationName: window.owningApplication?.applicationName,
                    frame: frame,
                    displayID: owningDisplay,
                    isOnScreen: window.isOnScreen
                )
            )
        }
    }

    /// 从可共享内容中取出目标窗口。
    static func window(
        in content: SCShareableContent,
        matching windowID: CGWindowID
    ) throws -> SCWindow {
        guard let window = content.windows.first(where: { $0.windowID == windowID }) else {
            throw CaptureError.scopeUnavailable
        }
        return window
    }

    /// 构造窗口内容过滤器。
    ///
    /// `desktopIndependentWindow:` 是**唯一**能捕获被遮挡窗口的过滤器：
    /// 它按窗口自身取内容，与窗口在屏幕上的前后层级无关。
    /// 「截不在最顶层的应用」全靠它——用 `display:excludingWindows:` 那类
    /// 以屏幕为范围的过滤器，截到的只会是该窗口在屏幕上**可见的那一部分**。
    ///
    /// 代价（必须如实计入结果）：被遮挡部分的像素由窗口自身绘制内容提供，
    /// 若目标应用使用了 `NSWindow` 之外的自绘表面（少数游戏、部分视频渲染），
    /// 遮挡区域可能是黑或上一次的内容。这是系统能力边界，不是本实现的选择。
    static func makeWindowFilter(window: SCWindow) -> SCContentFilter {
        SCContentFilter(desktopIndependentWindow: window)
    }

    /// 构造窗口单帧配置。
    ///
    /// 输出尺寸 = 窗口逻辑尺寸 × 窗口所在显示器的缩放系数，与整屏路径同源：
    /// 调用方在任何路径下拿到的图都是「1 点 = scaleFactor 像素」。
    /// 不这样做的话，窗口截图会比整屏截图糊一半，而调用方无从察觉。
    static func makeWindowConfiguration(
        frame: CGRect,
        scaleFactor: CGFloat,
        showsCursor: Bool
    ) -> SCStreamConfiguration {
        let configuration = SCStreamConfiguration()

        // 截图默认不含光标：光标会遮挡内容，且窗口截图里它通常根本不在窗口内。
        configuration.showsCursor = showsCursor

        // captureResolution 为 macOS 14.0+，13.0 上不存在此属性。
        if #available(macOS 14.0, *) {
            configuration.captureResolution = .best
        }
        configuration.scalesToFit = false
        configuration.queueDepth = 1

        configuration.width = max(1, Int((frame.width * scaleFactor).rounded()))
        configuration.height = max(1, Int((frame.height * scaleFactor).rounded()))

        return configuration
    }

    // MARK: - 可共享内容

    /// 查询可共享内容。
    ///
    /// 默认只查询当前可见内容。指定窗口不在其中时，再查询包含其他桌面与
    /// 最小化窗口的完整列表；普通截图和录制仍保留快速路径。
    static func fetchShareableContent(
        matchingWindowID: CGWindowID? = nil
    ) async throws -> SCShareableContent {
        do {
            let onScreen = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: true
            )
            guard let matchingWindowID,
                  !onScreen.windows.contains(where: { $0.windowID == matchingWindowID }) else {
                return onScreen
            }
            return try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: false
            )
        } catch {
            throw mapError(error)
        }
    }

    /// 单帧窗口请求需要在当前桌面找不到目标时扩大查询范围。
    static func fetchShareableContent(for target: SingleFrameTarget) async throws -> SCShareableContent {
        if case .window(let windowID) = target {
            return try await fetchShareableContent(matchingWindowID: windowID)
        }
        return try await fetchShareableContent()
    }

    /// 从可共享内容中取出目标显示器。
    static func display(
        in content: SCShareableContent,
        matching displayID: CGDirectDisplayID
    ) throws -> SCDisplay {
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw CaptureError.displayUnavailable
        }
        return display
    }

    // MARK: - 过滤器与配置

    /// 构造内容过滤器：包含该显示器上的全部内容。
    ///
    /// 截图应还原用户所见，故不排除自己的窗口。
    static func makeFilter(display: SCDisplay) -> SCContentFilter {
        SCContentFilter(display: display, excludingWindows: [])
    }

    /// 构造流配置。
    ///
    /// 单位约定（易错点）：`sourceRect` 是**显示器逻辑点**，
    /// 而 `width`/`height` 是**输出像素**尺寸，二者必须分别按正确单位给出。
    static func makeConfiguration(
        scope: CaptureScope,
        displayID: CGDirectDisplayID,
        scaleFactor: CGFloat,
        pixelSize: CGSize,
        normalizedRegion: CGRect?,
        showsCursor: Bool
    ) -> SCStreamConfiguration {
        let configuration = SCStreamConfiguration()

        // 截图默认不含光标：光标会遮挡内容
        configuration.showsCursor = showsCursor

        // captureResolution 为 macOS 14.0+，13.0 上不存在此属性
        if #available(macOS 14.0, *) {
            configuration.captureResolution = .best
        }
        configuration.scalesToFit = false

        // 单帧场景不需要帧队列深度；plan.md 记录 queueDepth 越大内存越高
        configuration.queueDepth = 1

        if let rect = normalizedRegion {
            configuration.sourceRect = rect
            // 逻辑点 → 像素：唯一的一次换算，四舍五入避免边界丢一像素
            configuration.width = max(1, Int((rect.width * scaleFactor).rounded()))
            configuration.height = max(1, Int((rect.height * scaleFactor).rounded()))
        } else {
            // 全屏：必须用物理像素。误用 CGDisplayPixelsWide 会得到 1x 降采样结果。
            configuration.width = max(1, Int(pixelSize.width))
            configuration.height = max(1, Int(pixelSize.height))
        }

        return configuration
    }

    // MARK: - 录制专用构造

    /// 一次录制目标的完整描述。
    ///
    /// 四个字段必须来自**同一次**内容查询：窗口会随其移动改变 frame，
    /// 若尺寸与过滤器分两次查询，就会出现「按旧尺寸输出新位置画面」这类错配。
    struct RecordingTarget {
        /// 内容过滤器。
        let filter: SCContentFilter
        /// 采样矩形（显示器内逻辑点）。仅区域范围有值。
        let sourceRect: CGRect?
        /// 输出像素尺寸。
        let pixelSize: CGSize
        /// 目标所在显示器的缩放系数。
        let scaleFactor: CGFloat
        /// 目标显示器。窗口范围可能横跨多块显示器，此时取中心点所在的那块。
        let displayID: CGDirectDisplayID
        /// 人类可读描述，用于日志。
        let description: String
    }

    /// 准备录制目标：解析范围、构造过滤器、计算输出尺寸。
    ///
    /// 四种范围：
    ///
    /// | 范围 | 过滤器 | 输出尺寸 |
    /// |---|---|---|
    /// | `.display` | `display:excludingWindows:` | 显示器物理像素 |
    /// | `.region` | 同上 + `sourceRect` | 区域逻辑尺寸 × 缩放系数 |
    /// | `.window` | `desktopIndependentWindow:` | 窗口 frame × 其所在显示器缩放系数 |
    /// | `.application` | `display:includingApplications:` | 目标显示器物理像素 |
    ///
    /// `excludedWindowIDs` 由本应用录制 UI 的窗口 ID 组成，三者（显示器/区域/应用）
    /// 都要排除：范围框、控制条、准备面板都浮在被录内容之上，不排除就会进成片。
    /// - Parameter excludedWindowIDs: 本应用录制 UI 的窗口 ID，由过滤器明确排除。
    ///   只在 `.display`/`.region`/`.application` 生效；`.window` 的过滤器只接受
    ///   一个目标窗口，没有排除参数。
    static func prepareRecordingTarget(
        scope: CaptureScope,
        content: SCShareableContent,
        excludedWindowIDs: [CGWindowID] = []
    ) throws -> RecordingTarget {
        // SCContentFilter 要的是 SCWindow 对象而非 ID，故需在本次查询结果里按 ID 解析。
        let excludedWindows = content.windows.filter {
            excludedWindowIDs.contains($0.windowID)
        }

        switch scope {
        case .display(let displayID):
            let display = try display(in: content, matching: displayID)
            let context = try displayContext(for: displayID)
            return RecordingTarget(
                filter: SCContentFilter(display: display, excludingWindows: excludedWindows),
                sourceRect: nil,
                pixelSize: context.pixelSize,
                scaleFactor: context.scaleFactor,
                displayID: displayID,
                description: "显示器 #\(displayID)"
            )

        case .region(let displayID, let rect):
            let display = try display(in: content, matching: displayID)
            let context = try displayContext(for: displayID)
            guard let clamped = DisplayGeometry.clamp(rect: rect, to: displayID) else {
                throw CaptureError.emptyResult
            }
            return RecordingTarget(
                filter: SCContentFilter(display: display, excludingWindows: excludedWindows),
                sourceRect: clamped,
                pixelSize: CGSize(
                    width: max(1, (clamped.width * context.scaleFactor).rounded()),
                    height: max(1, (clamped.height * context.scaleFactor).rounded())
                ),
                scaleFactor: context.scaleFactor,
                displayID: displayID,
                description: "显示器 #\(displayID) 的区域 \(Int(clamped.width))×\(Int(clamped.height))"
            )

        case .window(let windowID):
            guard let window = content.windows.first(where: { $0.windowID == windowID }) else {
                throw CaptureError.scopeUnavailable
            }
            let frame = window.frame
            guard frame.width >= 1, frame.height >= 1 else {
                throw CaptureError.emptyResult
            }
            // `SCWindow` 不携带显示器信息：用 frame 中心点定位所在显示器以取得缩放系数。
            // 契约（model.md §2.2）：跨屏时以**首帧确定的尺寸**为准，中途不改尺寸——
            // AVAssetWriter 不支持中途改分辨率，强行改会得到损坏文件。
            guard let displayID = DisplayGeometry.displayContaining(frame) else {
                throw CaptureError.displayUnavailable
            }
            let scaleFactor = DisplayGeometry.scaleFactor(for: displayID)
            let title = window.title ?? window.owningApplication?.applicationName ?? "未命名"
            return RecordingTarget(
                filter: SCContentFilter(desktopIndependentWindow: window),
                sourceRect: nil,
                pixelSize: CGSize(
                    width: max(1, (frame.width * scaleFactor).rounded()),
                    height: max(1, (frame.height * scaleFactor).rounded())
                ),
                scaleFactor: scaleFactor,
                displayID: displayID,
                description: "窗口 #\(windowID)「\(title)」"
            )

        case .application(let pid, let displayID):
            guard let application = content.applications.first(where: { $0.processID == pid }) else {
                throw CaptureError.scopeUnavailable
            }
            let display = try display(in: content, matching: displayID)
            let context = try displayContext(for: displayID)
            // ⚠️ 契约（model.md §2.3）：该过滤器**以显示器为范围**，只保留此显示器上
            // 属于该应用的窗口，**不会**覆盖该应用在其它显示器上的窗口。
            // 开始录制前必须把这个边界告知用户，不得静默降级。
            // 注意：该构造在较新 SDK 中的标签是 `including:`（旧标签为 `includingApplications:`）
            return RecordingTarget(
                filter: SCContentFilter(
                    display: display,
                    including: [application],
                    exceptingWindows: excludedWindows
                ),
                sourceRect: nil,
                pixelSize: context.pixelSize,
                scaleFactor: context.scaleFactor,
                displayID: displayID,
                description: "应用「\(application.applicationName)」在显示器 #\(displayID) 上的窗口"
            )
        }
    }

    /// 构造录制用的流配置。
    ///
    /// 与单帧截图的配置有几处**必须不同**，不能复用同一个构造函数：
    ///
    /// | 参数 | 单帧截图 | 录制 | 理由 |
    /// |---|---|---|---|
    /// | `queueDepth` | 1 | 更大 | 截图只要一帧；录制时队列深度为 1 会让编码器稍有阻塞就直接丢帧 |
    /// | `minimumFrameInterval` | 不设 | 按帧率设 | 不设则按显示器刷新率产帧，60Hz 屏会得到 60fps 的素材 |
    /// | `showsCursor` | false | 用户选择 | 录制通常要录到光标 |
    /// | `capturesAudio` | 不涉 | 用户选择 | 系统声音（13.0+） |
    ///
    /// - Parameter sourceRect: 区域范围的采样矩形（逻辑点）；整屏时为 `nil`。
    /// - Parameter scaleFactor: 该显示器的像素缩放系数（Retina 为 2.0）。
    /// - Parameter displayPixelSize: 显示器物理像素尺寸，整屏输出时使用。
    static func makeRecordingConfiguration(
        sourceRect: CGRect?,
        outputPixelSize: CGSize,
        video: VideoSettings,
        audio: AudioSettings
    ) -> SCStreamConfiguration {
        let configuration = SCStreamConfiguration()

        // captureResolution 为 macOS 14.0+，13.0 上不存在此属性。
        // 13.0 回退路径不使用任何 14.0+ API，故这里的分支方向不会搞反：
        // 开发机（macOS 27）走的是上面的分支，下面的回退分支需强制入口才能执行。
        if #available(macOS 14.0, *) {
            configuration.captureResolution = .best
        }
        configuration.scalesToFit = false

        configuration.showsCursor = video.showsCursor
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        // 队列深度用系统的保守值：过小（如 1）会让管道在启动阶段就无法维持，
        // 实测该值下每一轮流都收不到帧。
        configuration.queueDepth = 3
        // 不设 minimumFrameInterval 会按显示器刷新率产帧，
        // 60Hz 屏将得到 60fps 素材，与用户选择的 30fps 不符。
        let frameRate = max(1, video.frameRate)
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(frameRate))

        if let rect = sourceRect {
            // 区域：只采样该矩形，输出尺寸由调用方按「逻辑尺寸 × 缩放系数」给出
            configuration.sourceRect = rect
        }
        // 输出尺寸统一由 RecordingTarget 计算，此处只做整数化与下限保护。
        // 误用 CGDisplayPixelsWide 会得到 1x 降采样结果（见 DisplayGeometry.scaleFactor）。
        configuration.width = max(1, Int(outputPixelSize.width.rounded()))
        configuration.height = max(1, Int(outputPixelSize.height.rounded()))

        // 系统声音：capturesAudio / sampleRate / channelCount /
        // excludesCurrentProcessAudio 均为 macOS 13.0+，基线上可用。
        configuration.capturesAudio = audio.systemAudio
        if audio.systemAudio {
            configuration.sampleRate = audio.sampleRate
            configuration.channelCount = audio.channelCount
            configuration.excludesCurrentProcessAudio = audio.excludesOwnAudio
        }

        return configuration
    }

    // MARK: - 帧状态

    /// 判断 sampleBuffer 是否为**完整帧**。
    ///
    /// 依据 `SCStreamFrameInfo.status` 附件：只有 `.complete` 才是可用的整帧，
    /// `.idle` / `.blank` / `.suspended` / `.started` 都不应被当作有效内容。
    ///
    /// 单帧截图与录制共用本判定：单帧时期望的是「第一张可用的图」，
    /// 录制时期里它决定该帧是否计入统计——两处若各写一份，
    /// 迟早出现「截图接受的帧录制不接受」这类无解释的不一致。
    static func isCompleteFrame(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(
            sampleBuffer,
            createIfNecessary: false
        ) as? [[SCStreamFrameInfo: Any]] else {
            return false
        }
        guard let rawStatus = attachments.first?[.status] as? Int,
              let status = SCFrameStatus(rawValue: rawStatus) else {
            return false
        }
        return status == .complete
    }

    // MARK: - 诊断

    #if DEBUG
    /// 对比三种获取可共享内容方式的耗时。
    ///
    /// 保留此工具的目的：`fetchShareableContent` 的参数选择直接决定捕获延迟的量级
    /// （实测相差 225 倍），未来若系统行为变化或需要重新评估，可直接复测。
    ///
    /// **注意**：调用此方法会预热系统状态，因此**不得**在计时「冷启动捕获」之前调用。
    public static func benchmarkShareableContentCost() async {
        var results: [String] = []

        func measure(_ label: String, _ body: () async -> Void) async {
            let start = Date()
            await body()
            results.append(label + ": " + ms(Date().timeIntervalSince(start)) + "ms")
        }

        await measure("onScreenOnly=true") {
            _ = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        }
        await measure("onScreenOnly=false") {
            _ = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        }
        if #available(macOS 14.4, *) {
            await measure("currentProcess") {
                _ = try? await SCShareableContent.currentProcess
            }
        }
        await measure("onScreenOnly=true (2nd)") {
            _ = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        }

        setupLogger.notice("shareableContent benchmark → \(results.joined(separator: " | "), privacy: .public)")
    }
    #endif

    private static func ms(_ seconds: TimeInterval) -> String {
        String(format: "%.1f", seconds * 1000)
    }

    // MARK: - 错误映射

    /// 把 ScreenCaptureKit 的错误映射到本模块的错误类型。
    static func mapError(_ error: Error) -> CaptureError {
        if let streamError = error as? SCStreamError {
            switch streamError.code {
            case .userDeclined:
                return .permissionDenied
            case .noWindowList:
                return .emptyResult
            default:
                return .underlying("ScreenCaptureKit: \(streamError.localizedDescription)")
            }
        }
        return .underlying(error.localizedDescription)
    }
}
