//
//  RecordingPreferencesStore.swift
//  AnShotUI
//
//  录制准备面板里「输出格式」与「两路音频」的记忆。
//
//  ── 为什么这三项值得记住 ──────────────────────────────────
//
//  它们在两次录制之间几乎不变：习惯录 GIF 的人次次都要把音频关掉，
//  习惯带旁白的人次次都要确认麦克风。而面板是常驻实例，若每次弹出都复位成
//  「MP4 + 双开」，用户每天都要重新表达同一个决定。
//
//  ── 为什么不担心「隐状态」─────────────────────────────────
//
//  三项全都摆在准备面板上：分段控件写着 MP4/GIF，两个复选框写着声音开关，
//  开始录制前一眼可见。面板不再替用户复位，所以不存在「看不见却生效」的配置。
//
//  与它们相反的是**范围与目标**：那次要录哪块区域、哪个窗口，每次都可能不同，
//  且目标身份只在命中那一刻有效（见 `RecordingSetupPanel` 的类型注释），
//  因此仍由面板每次重置，不进入这份记忆。
//
//  ── 为什么用独立 key ─────────────────────────────────────
//
//  与 `AppSettings` 的 `settings.*` 分开：两套偏好的字段增长互不影响，
//  也不会因为一次写坏把保存目录、快捷键一起带走。
//

import AnShotCore
import Foundation

/// 录制准备面板的偏好记忆。
///
/// 单例：偏好跨会话保留，而面板本身只是界面。
@MainActor
final class RecordingPreferencesStore {

    static let shared = RecordingPreferencesStore()

    private enum Key {
        /// 输出格式。取值为 `movie` / `gif`。
        static let outputFormat = "recording.output.format"
        /// GIF 时长上限（秒），只在格式为 GIF 时有意义。
        static let gifDuration = "recording.output.gif.maximumDuration"
        /// GIF 最大边长（像素），只在格式为 GIF 时有意义。
        static let gifPixelDimension = "recording.output.gif.maximumPixelDimension"
        static let systemAudio = "recording.audio.system"
        static let microphone = "recording.audio.microphone"
    }

    private enum OutputFormat {
        static let movie = "movie"
        static let gif = "gif"
    }

    private let defaults: UserDefaults

    /// - Parameter defaults: 注入以便测试使用独立 suite，避免污染真实偏好。
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    // MARK: - 输出格式

    /// 上次选定的输出格式及 GIF 档位。
    ///
    /// 没有记录时返回 `.movie`：与「界面默认 MP4」一致。GIF 档位随格式一起读，
    /// 因为 `RecordingOutputChoice` 本身就是「格式 + 参数」的一个整体。
    var output: RecordingOutputChoice {
        get {
            guard defaults.string(forKey: Key.outputFormat) == OutputFormat.gif else {
                return .movie
            }
            return .gif(Self.readGIFSettings(from: defaults))
        }
        set {
            switch newValue {
            case .movie:
                defaults.set(OutputFormat.movie, forKey: Key.outputFormat)
            case .gif(let settings):
                defaults.set(OutputFormat.gif, forKey: Key.outputFormat)
                defaults.set(settings.maximumDuration, forKey: Key.gifDuration)
                defaults.set(settings.maximumPixelDimension, forKey: Key.gifPixelDimension)
            }
        }
    }

    /// 读 GIF 档位。
    ///
    /// **只恢复界面能表达的档位**：两个下拉各自只能落在 `durationOptions` /
    /// `pixelDimensionOptions` 里的某一项，若存进档位外的值，面板会显示第 0 档
    /// 而实际传出的是那个值——显示与生效分叉。档位集合在版本间可能收缩，
    /// 因此不认识的值一律回落默认值，而不是勉强使用。
    private static func readGIFSettings(from defaults: UserDefaults) -> GIFSettings {
        let storedDuration = (defaults.object(forKey: Key.gifDuration) as? NSNumber)?.doubleValue
        let storedDimension = (defaults.object(forKey: Key.gifPixelDimension) as? NSNumber)?.intValue
        let duration = storedDuration.flatMap {
            GIFSettings.durationOptions.contains($0) ? $0 : nil
        } ?? GIFSettings.defaultDuration
        let dimension = storedDimension.flatMap {
            GIFSettings.pixelDimensionOptions.contains($0) ? $0 : nil
        } ?? GIFSettings.defaultPixelDimension
        return GIFSettings(maximumDuration: duration, maximumPixelDimension: dimension)
    }

    // MARK: - 音频

    // 这两项对应 `AudioSettings.systemAudio` / `.microphone`；`AudioSettings`
    // 的其余字段（采样率、声道数、是否排除自身声音）**有意不持久化**：
    // 它们没有界面入口，存下来就是看不见的设置，而两路捕获共用同一个采样率
    // 是既有约束，随偏好漂移只会让导出链路的配置变复杂。

    /// 系统内录是否勾选。缺省 `true`：录屏一般都希望带声音（面板上的契约默认）。
    var systemAudio: Bool {
        get { Self.readBool(from: defaults, key: Key.systemAudio, fallback: true) }
        set { defaults.set(newValue, forKey: Key.systemAudio) }
    }

    /// 麦克风旁白是否勾选。缺省 `true`，理由同上。
    var microphone: Bool {
        get { Self.readBool(from: defaults, key: Key.microphone, fallback: true) }
        set { defaults.set(newValue, forKey: Key.microphone) }
    }

    /// 读布尔值。
    ///
    /// 必须用 `object(forKey:)` 区分「没存过」与「存的是 false」：
    /// `bool(forKey:)` 两者都返回 false，那样「默认双开」就会变成默认静音。
    private static func readBool(from defaults: UserDefaults, key: String, fallback: Bool) -> Bool {
        guard let number = defaults.object(forKey: key) as? NSNumber else {
            return fallback
        }
        return number.boolValue
    }
}
