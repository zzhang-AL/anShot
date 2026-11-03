//
//  ScrollshotLogStore.swift
//  AnShotUI
//
//  长截图会话的**最近决策日志**：环形缓冲，专为「事后排查断层」服务。
//
//  ── 为什么需要它（而不是看控制台）────────────────────────
//
//  长截图的缺陷几乎都是**事后才被发现**的：用户拼完一张图，看到接缝处
//  内容跳了一下/缺了一截，这时会话早就结束了。而 `os_log` 的输出在
//  Console.app 里、启动参数 `-recordFrames` 的帧在临时目录里——两者都要求
//  用户「事先打开某些东西」，恰好是断层发生时不会做的事。
//
//  所以这里把**每一帧的结论**留在内存里，跨会话保留，用户发现异常后
//  从菜单栏打开即可看到：是哪一帧、因为什么被丢/被贴错、当时的位移与置信度。
//
//  ── 为什么只留最近的 ────────────────────────────────────
//
//  一帧一条记录，8 Hz 下 10 分钟就是 4800 条。全留会让内存无谓增长，
//  也会把「刚才那一次」淹没在历史里。500 条 ≈ 一分钟的高频采集，
//  足够覆盖一次出问题的会话；超出后按 FIFO 丢弃最旧的。
//
//  ── 为什么不落盘 ────────────────────────────────────────
//
//  抓帧循环在 8 Hz 的主线程里跑，逐帧写文件会把 IO 抖到采集路径上。
//  需要留档时由用户在日志窗口里显式「导出」，那是他主动选择的一次性动作。
//

import AnShotCore
import Foundation

/// 长截图逐帧决策的环形日志。
///
/// 单例：日志要**跨会话**保留（用户是拼完才发现问题），而会话本身是短命的。
@MainActor
final class ScrollshotLogStore {

    static let shared = ScrollshotLogStore()

    /// 一条帧记录。
    struct Entry: Identifiable {
        let id = UUID()
        /// 记录时刻。
        let date: Date
        /// 会话序号（自增，用来把多次长截图分开）。
        let session: Int
        /// 该会话内的帧序号。
        let frame: Int
        /// 结论（`accepted` / `duplicate` / `transient` / `unresolved` / …）。
        let verdict: String
        /// 相对上一帧的位移（有符号）。
        let deltaY: Int
        /// 配准置信度。
        let confidence: Double
        /// 该帧视口顶部在世界坐标中的位置。
        let worldOffset: Int
        /// 会话当时已覆盖的世界高度。
        let coveredHeight: Int
        /// 告警（用户最该看的一栏）。
        let warnings: [String]
        /// 求解路径（`kernel` / `flippedKernel` / `visionArbitration` / `-`）。
        let matchSource: String
        /// 是否值得高亮：未采纳、被 Vision 翻案、走了翻转求解、或带告警。
        let suspicious: Bool

        /// 是否属于「会让长图出错」的结论（给界面做标记用）。
        var isProblem: Bool {
            switch verdict {
            case "accepted": return !warnings.isEmpty
            default: return true
            }
        }
    }

    /// 保留上限。500 条 ≈ 一分钟高频采集，够覆盖一次出问题的会话。
    ///
    /// `static` 而非实例常量：测试要能按同一个数字断言「超出后丢的是最旧的」，
    /// 把 500 写死在测试里会让两者静默漂移。
    static let capacity = 500

    private(set) var entries: [Entry] = []
    /// 当前会话序号（从 1 开始；`beginSession` 递增）。
    private(set) var sessionCounter = 0

    /// 当前会话的标识，供 `ScrollshotController` 持有。
    private(set) var currentSession = 0

    private init() {}

    // MARK: - 写入

    /// 开始一次新会话，返回会话序号。
    @discardableResult
    func beginSession() -> Int {
        sessionCounter += 1
        currentSession = sessionCounter
        append(
            frame: -1,
            verdict: "session-start",
            deltaY: 0,
            confidence: 0,
            worldOffset: 0,
            coveredHeight: 0,
            warnings: [],
            matchSource: "-",
            suspicious: false,
            rawDate: Date()
        )
        return currentSession
    }

    /// 记录一帧。
    func appendFrame(
        index: Int,
        decision: ScrollshotSession.Decision,
        coveredHeight: Int,
        suspicious: Bool
    ) {
        append(
            frame: index,
            verdict: decision.verdict.rawValue,
            deltaY: decision.deltaY,
            confidence: decision.confidence,
            worldOffset: decision.worldOffset,
            coveredHeight: coveredHeight,
            warnings: decision.warnings + (decision.stalled ? ["跟丢（连续配准失败）"] : []),
            matchSource: decision.matchSource?.rawValue ?? "-",
            suspicious: suspicious,
            rawDate: Date()
        )
    }

    /// 记录一条非帧事件（会话结束、上限、取消等）。
    func appendEvent(_ text: String) {
        append(
            frame: -1,
            verdict: text,
            deltaY: 0,
            confidence: 0,
            worldOffset: 0,
            coveredHeight: 0,
            warnings: [],
            matchSource: "-",
            suspicious: true,
            rawDate: Date()
        )
    }

    private func append(
        frame: Int,
        verdict: String,
        deltaY: Int,
        confidence: Double,
        worldOffset: Int,
        coveredHeight: Int,
        warnings: [String],
        matchSource: String,
        suspicious: Bool,
        rawDate: Date
    ) {
        entries.append(Entry(
            date: rawDate,
            session: currentSession,
            frame: frame,
            verdict: verdict,
            deltaY: deltaY,
            confidence: confidence,
            worldOffset: worldOffset,
            coveredHeight: coveredHeight,
            warnings: warnings,
            matchSource: matchSource,
            suspicious: suspicious
        ))
        if entries.count > Self.capacity {
            entries.removeFirst(entries.count - Self.capacity)
        }
    }

    /// 清空（界面上的「清空」按钮）。
    func clear() {
        entries.removeAll()
    }

    // MARK: - 输出

    /// 纯文本快照：等宽对齐，用户可直接复制粘贴。
    ///
    /// 字段顺序刻意与 `ScrollshotFrameRecorder` 的 `note` 保持一致——
    /// 两条排查路径（内存日志 / 帧录制）看到的是同一组键名，不必来回对照。
    func formattedText() -> String {
        guard !entries.isEmpty else { return "（暂无记录）" }

        var lines: [String] = []
        lines.append("序号  帧    结论           位移   置信度  世界坐标  已覆盖  来源            告警")
        lines.append(String(repeating: "-", count: 108))

        for entry in entries {
            let frameText = entry.frame >= 0 ? String(entry.frame) : "—"
            let confidence = String(format: "%.3f", entry.confidence)
            let mark = entry.isProblem ? "!" : " "
            var line = String(
                format: "%@%-4d %-4@ %-13@ %6d  %-7@ %8d  %6d  %-14@ ",
                mark,
                entry.session,
                frameText as NSString,
                entry.verdict as NSString,
                entry.deltaY,
                confidence as NSString,
                entry.worldOffset,
                entry.coveredHeight,
                entry.matchSource as NSString
            )
            if !entry.warnings.isEmpty {
                line += entry.warnings.joined(separator: " | ")
            }
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }
}
