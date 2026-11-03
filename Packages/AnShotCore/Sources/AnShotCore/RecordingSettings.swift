//
//  RecordingSettings.swift
//  AnShotCore
//
//  录制配置的纯数据类型：视频、音频、输出。契约见 docs/m2-recording/model.md §4。
//
//  ── 为何这里不含录制范围（scope）────────────────────────────────
//
//  `CaptureScope` 定义在 `AnShotCapture`（M1 的捕获协议所在模块），
//  而依赖方向是 `AnShotCapture → AnShotCore`。若把含 scope 的完整配置放在本模块，
//  本模块就必须反向依赖捕获模块，形成循环。
//
//  故：与框架无关的设置值放本文件，含范围的完整配置见
//  `AnShotCapture.RecordingConfiguration`。
//

import Foundation

// MARK: - 视频

/// 视频编码器。
///
/// 默认 H.264：兼容性优先。HEVC 文件更小，但旧设备与部分分享场景播放受限。
public enum VideoCodec: String, Sendable, Equatable, CaseIterable {
    case h264
    case hevc

    /// 人类可读名称。
    public var displayName: String {
        switch self {
        case .h264: return "H.264"
        case .hevc: return "HEVC"
        }
    }
}

/// 视频设置。
public struct VideoSettings: Sendable, Equatable {

    /// 目标帧率。契约允许 15 / 24 / 30 / 60；GIF 场景通常 10–15。
    public var frameRate: Int

    public var codec: VideoCodec

    /// 平均码率（bps）。nil 表示交给 VideoToolbox 按分辨率自动决定。
    public var averageBitRate: Int?

    /// 是否录制光标。录制通常要录到光标，与截图相反。
    public var showsCursor: Bool

    public init(
        frameRate: Int = 30,
        codec: VideoCodec = .h264,
        averageBitRate: Int? = nil,
        showsCursor: Bool = true
    ) {
        self.frameRate = frameRate
        self.codec = codec
        self.averageBitRate = averageBitRate
        self.showsCursor = showsCursor
    }

    /// 帧间隔（秒）。供 `SCStreamConfiguration.minimumFrameInterval` 使用。
    public var frameInterval: TimeInterval {
        guard frameRate > 0 else { return 1.0 / 30.0 }
        return 1.0 / Double(frameRate)
    }
}

// MARK: - 音频

/// 音频设置。
///
/// 两路音频的权限归属不同：系统声音属于**屏幕录制**权限（已授权），
/// 麦克风属于**麦克风** TCC 服务（独立的真实授权状态 API）。
public struct AudioSettings: Sendable, Equatable {

    /// 系统内录。最低 macOS 13.0（`SCStreamConfiguration.capturesAudio`）。
    public var systemAudio: Bool

    /// 麦克风旁白。
    ///
    /// ScreenCaptureKit 的麦克风捕获是 macOS 15.0+，部署基线 13.0 上不可用，
    /// 故一律走 AVFoundation 的 `AVCaptureDevice`（见 plan.md §3.1 决策 A）。
    public var microphone: Bool

    /// 采样率。同时传给系统声音捕获与麦克风采集，以减少后续重采样。
    public var sampleRate: Int

    /// 声道数。
    public var channelCount: Int

    /// 是否排除本进程自身产生的声音（避免录到 anShot 自己的提示音）。
    public var excludesOwnAudio: Bool

    public init(
        systemAudio: Bool = false,
        microphone: Bool = false,
        sampleRate: Int = 48_000,
        channelCount: Int = 2,
        excludesOwnAudio: Bool = true
    ) {
        self.systemAudio = systemAudio
        self.microphone = microphone
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.excludesOwnAudio = excludesOwnAudio
    }

    /// 是否需要任何音频输入。
    public var isAnyEnabled: Bool {
        systemAudio || microphone
    }
}

// MARK: - 输出

/// 影片容器格式。
public enum MovieContainer: String, Sendable, Equatable, CaseIterable {
    /// MP4：默认，兼容性最好。
    case mp4
    /// QuickTime：需要特殊轨道时使用。
    case mov

    /// 文件扩展名。
    public var fileExtension: String {
        rawValue
    }

    /// AVFoundation 的类型标识。
    public var uniformTypeIdentifier: String {
        switch self {
        case .mp4: return "public.mpeg-4"
        case .mov: return "com.apple.quicktime-movie"
        }
    }
}

/// GIF 设置。
///
/// ── 哪些参数对用户可见 ────────────────────────────────────────
///
/// **只有 `maximumDuration` 与 `maximumPixelDimension` 出现在界面上**，
/// 且取值限定在 `durationOptions` / `pixelDimensionOptions` 两个集合内。
/// 帧率与循环次数不下沉到界面：帧率对用户的意义远小于它对文件体积的影响，
/// 而「无限循环」是 GIF 的通行预期——把这两项摆上界面只增加决策成本。
///
/// 界面上**不提供「原尺寸」档**：真机全屏 2940×1912 下，15 秒 12fps 的原尺寸 GIF
/// 是百 MB 级、导出需数分钟的文件。它不是「更清晰的选择」，而是必然产废的陷阱
/// ——需要原始画质时应当录 MP4。也因此不需要「0 表示不缩放」这类哨兵值，
/// `validate()` 里 `maximumPixelDimension > 0` 的既有校验得以保留原样。
///
/// ── 为何默认值是产品默认值而非硬上限 ──────────────────────────
///
/// `CGImageDestination` 支持逐帧追加，不需要全部帧驻留内存，
/// 真正的风险在于源帧的存放方式——录制阶段必须流式落盘，
/// 导出阶段逐帧解码转换（见 `model.md` §4.4）。
///
/// 但 `maximumDuration` 有一个**行为性**后果：录制到达该时长会**自动停止**
/// （`SCStreamRecorder.scheduleAutoStop`）。因此它必须对用户显性化，
/// 否则用户会遇到「录着录着它自己停了」而无从理解。
public struct GIFSettings: Sendable, Equatable {

    // MARK: - 界面档位

    /// 界面可选的时长上限档位（秒）。默认取 `defaultDuration`。
    public static let durationOptions: [TimeInterval] = [15, 30, 60]

    /// 界面可选的最大边长档位（像素）。默认取 `defaultPixelDimension`。
    public static let pixelDimensionOptions: [Int] = [800, 1200, 1600]

    /// 默认时长上限（秒）。**必须在 `durationOptions` 内**。
    public static let defaultDuration: TimeInterval = 15

    /// 默认最大边长（像素）。**必须在 `pixelDimensionOptions` 内**。
    public static let defaultPixelDimension: Int = 800

    /// 固定帧率，不下沉到界面。
    public static let defaultFrameRate = 12

    /// 固定循环次数，0 表示无限循环，不下沉到界面。
    public static let defaultLoopCount = 0

    // MARK: - 值

    /// 帧率。GIF 无音频，帧率过高会让文件体积爆炸。
    public var frameRate: Int

    /// 最大时长（秒）。**到达即自动停止录制**，必须在界面上可见。
    public var maximumDuration: TimeInterval

    /// 最大边长（像素）。超过则等比缩小。
    public var maximumPixelDimension: Int

    /// 循环次数。0 表示无限循环。
    public var loopCount: Int

    public init(
        frameRate: Int = GIFSettings.defaultFrameRate,
        maximumDuration: TimeInterval = GIFSettings.defaultDuration,
        maximumPixelDimension: Int = GIFSettings.defaultPixelDimension,
        loopCount: Int = GIFSettings.defaultLoopCount
    ) {
        self.frameRate = frameRate
        self.maximumDuration = maximumDuration
        self.maximumPixelDimension = maximumPixelDimension
        self.loopCount = loopCount
    }
}

/// 录制输出目标。
public enum RecordingOutput: Sendable, Equatable {

    /// 影片文件。容器由 `container` 指定。
    case movie(URL, container: MovieContainer)

    /// GIF 文件。要求先在录制阶段落盘为临时影片，导出阶段再逐帧转换。
    case gif(URL, settings: GIFSettings)

    /// 输出文件位置。
    public var url: URL {
        switch self {
        case .movie(let url, _): return url
        case .gif(let url, _):   return url
        }
    }

    /// 是否为 GIF 输出。
    public var isGIF: Bool {
        if case .gif = self { return true }
        return false
    }
}

// MARK: - 输出选择

/// 用户选择的输出格式。
///
/// ── 为什么它与 `RecordingOutput` 是两个类型 ────────────────────
///
/// 本类型表达的是「**要什么**」（MP4 还是 GIF、GIF 用哪档参数），不带路径；
/// 路径由装配层按保存设置现算（`RecordingController.defaultOutputURL`），
/// 因为保存设置可能在面板弹出之后、开始录制之前被改动。
/// 两者合一就会重演 M2 已经踩过的错配：把「打开面板那一刻」算好的东西
/// 一直带到「开始录制」（这正是 `RecordingSetupPanel` 不持有几何与身份的原因）。
public enum RecordingOutputChoice: Sendable, Equatable {

    /// MP4 影片。
    case movie

    /// GIF，携带用户选定的档位。
    case gif(GIFSettings)

    /// 产物扩展名，用于生成默认文件名。
    public var fileExtension: String {
        switch self {
        case .movie:
            return MovieContainer.mp4.fileExtension
        case .gif:
            // 不引 `UniformTypeIdentifiers`：本模块是纯数据类型层，
            // 而 GIF 的扩展名是 GIF89a 规范里的固定值。
            return "gif"
        }
    }

    /// 是否为 GIF。
    public var isGIF: Bool {
        if case .gif = self { return true }
        return false
    }

    /// 按给定路径构造正式的输出目标。
    ///
    /// - Parameter url: 已经过唯一化处理的产物路径（见 `OutputPath.unique`）。
    public func output(at url: URL) -> RecordingOutput {
        switch self {
        case .movie:
            return .movie(url, container: .mp4)
        case .gif(let settings):
            return .gif(url, settings: settings)
        }
    }

    /// 该格式下**实际生效**的音频设置。
    ///
    /// GIF 无音轨，因此一律归零。归一化必须发生在「知道格式」的那一层，
    /// 而且必须是独立的一步：面板里 GIF 模式下两个开关是**置灰**的，
    /// 但置灰不会改写它们的勾选状态（面板弹出时默认都勾选，
    /// 用户切到 GIF 并不会把它们改成 off）。
    /// 若把原始值原样带到配置里，GIF 录制会去**申请一次麦克风权限**、
    /// 并让流白跑一路系统声音捕获——而产物里一轨都不会有。
    public func effectiveAudio(_ audio: AudioSettings) -> AudioSettings {
        isGIF ? AudioSettings() : audio
    }
}
