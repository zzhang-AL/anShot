//
//  RecordingControlBar.swift
//  AnShotUI
//
//  录制中的浮动控制条：状态指示、计时、暂停/继续、停止。
//
//  ── 为何是 NSPanel + .nonactivatingPanel ────────────────────
//
//  录制期间用户仍在操作别的应用，控制条绝不能抢走键盘焦点——
//  一旦抢焦点，用户的下一次按键就会落进控制条而不是他原本的应用。
//  `.nonactivatingPanel` + `becomesKeyOnlyIfNeeded` 保证点击按钮不会激活本应用。
//
//  ── 为何自绘而不复用系统控件外观 ────────────────────────────
//
//  控制条浮在任意应用之上，系统的浅色/深色控件在浅底与深底上都会出现
//  对比度不足的问题（这与 M1 覆盖层遇到的是同一类问题），
//  故统一使用明确的深色半透明底 + 白字，在任何背景上都能看清。
//

import AnShotCore
import AppKit
import Foundation

@MainActor
public final class RecordingControlBar {

    /// 点击暂停/继续。
    public var onTogglePause: (() -> Void)?
    /// 点击停止。
    public var onStop: (() -> Void)?

    private let panel: NSPanel
    private let statusDot = NSView()
    private let timeLabel = NSTextField(labelWithString: "00:00")
    private let hintLabel = NSTextField(labelWithString: "")
    private let pauseButton = NSButton()
    private let stopButton = NSButton()

    /// 当前状态与已录时长。`refreshHint` 依赖它们现算文案。
    private var state: RecordingState = .idle
    private var elapsed: TimeInterval = 0

    /// 本次会话的 GIF 时长上限。nil 表示非 GIF 输出（无上限、无导出进度）。
    private var gifLimit: TimeInterval?

    /// GIF 导出进度（0…1）。nil 表示尚未进入导出。
    private var exportProgress: Double?

    private static let barSize = CGSize(width: 232, height: 46)

    public init() {
        panel = NSPanel(
            contentRect: CGRect(origin: .zero, size: Self.barSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        // 不激活本应用：见文件头说明
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        // 出现在所有空间，包括全屏应用之上
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.ignoresMouseEvents = false

        configureContent()
    }

    // MARK: - 内容

    private func configureContent() {
        let container = NSView(frame: CGRect(origin: .zero, size: Self.barSize))
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor(calibratedWhite: 0.12, alpha: 0.92).cgColor
        container.layer?.cornerRadius = 10
        container.layer?.borderWidth = 1
        container.layer?.borderColor = NSColor(calibratedWhite: 1, alpha: 0.12).cgColor

        // 状态圆点
        statusDot.frame = CGRect(x: 14, y: Self.barSize.height / 2 - 5, width: 10, height: 10)
        statusDot.wantsLayer = true
        statusDot.layer?.cornerRadius = 5
        statusDot.layer?.backgroundColor = CaptureFrameStyle.recording.cgColor
        container.addSubview(statusDot)

        // 计时
        timeLabel.frame = CGRect(x: 32, y: Self.barSize.height / 2 - 11, width: 72, height: 22)
        timeLabel.font = .monospacedDigitSystemFont(ofSize: 15, weight: .medium)
        timeLabel.textColor = .white
        timeLabel.alignment = .left
        container.addSubview(timeLabel)

        // 状态提示（准备中 / 已暂停 / 剩余时间 / GIF 进度）
        //
        // 宽度 60 是**用字长反推的上限**：它恰好在计时标签与暂停按钮之间。
        // 因此这里只放短文案（「剩 15s」「GIF 42%」）——把「生成 GIF 42%」
        // 这样的长句塞进来会挤压按钮位置，而按钮的可点性比文字完整更重要。
        hintLabel.frame = CGRect(x: 104, y: Self.barSize.height / 2 - 9, width: 60, height: 18)
        hintLabel.font = .systemFont(ofSize: 11)
        hintLabel.textColor = NSColor(calibratedWhite: 1, alpha: 0.65)
        container.addSubview(hintLabel)

        // 暂停 / 继续
        styleButton(pauseButton, symbol: "pause.fill", action: #selector(handlePause))
        pauseButton.frame = CGRect(x: 164, y: Self.barSize.height / 2 - 13, width: 26, height: 26)
        container.addSubview(pauseButton)

        // 停止
        styleButton(stopButton, symbol: "stop.fill", action: #selector(handleStop))
        stopButton.frame = CGRect(x: 196, y: Self.barSize.height / 2 - 13, width: 26, height: 26)
        container.addSubview(stopButton)

        panel.contentView = container
    }

    private func styleButton(_ button: NSButton, symbol: String, action: Selector) {
        button.bezelStyle = .regularSquare
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.contentTintColor = .white
        button.target = self
        button.action = action
        button.wantsLayer = true
        button.layer?.backgroundColor = NSColor(calibratedWhite: 1, alpha: 0.14).cgColor
        button.layer?.cornerRadius = 6
        if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) {
            button.image = image
        } else {
            // 系统符号不可用时的文字回退（macOS 13 起 SF Symbols 应可用）
            button.title = symbol == "stop.fill" ? "■" : "II"
            button.imagePosition = .noImage
        }
    }

    // MARK: - 显示

    /// 显示控制条。
    ///
    /// - Parameters:
    ///   - recordingRect: 录制区域（**AppKit 屏幕坐标**）。
    ///   传入时控制条紧贴该区域上方外侧摆放——从截图工具栏进入录制时，
    ///   用户的视线停在选区上，控制条出现在同一位置附近才像是「就地替换」；
    ///   跳到屏幕顶部会让人以为会话已经结束。
    ///   传 nil（全屏录制）时退回到屏幕顶部中央。
    ///   - gifLimit: GIF 时长上限（秒）。非 GIF 输出传 nil。
    ///   传值后，录制期间会显示倒计时——上限到达会**自动停止**，
    ///   不显示就等于用户的内容被凭空截断且无人告知。
    ///   - screen: 录制所在的屏幕。nil 时取与 `recordingRect` 重叠最多的屏幕，
    ///   再退回主屏（菜单栏所在屏）。
    ///   **不能用 `NSScreen.main`**：它是「键盘焦点所在的屏幕」，多屏时与录制目标
    ///   无关——录副屏的选区时，控制条会被钳制到另一块屏幕上去。
    public func show(
        near recordingRect: CGRect? = nil,
        on screen: NSScreen? = nil,
        gifLimit: TimeInterval? = nil
    ) {
        self.gifLimit = gifLimit
        exportProgress = nil
        let screen = screen
            ?? recordingRect.flatMap(Self.screen(overlapping:))
            ?? NSScreen.screens.first
        guard let visible = screen?.visibleFrame else {
            panel.orderFrontRegardless()
            return
        }

        var origin: CGPoint
        if let rect = recordingRect, rect.width > 1 {
            let gap: CGFloat = 10
            let above = CGPoint(
                x: rect.midX - Self.barSize.width / 2,
                y: rect.maxY + gap
            )
            let below = CGPoint(
                x: rect.midX - Self.barSize.width / 2,
                y: rect.minY - Self.barSize.height - gap
            )
            // 优先上方；上方放不下（顶到屏幕外）则放到下方
            origin = (above.y + Self.barSize.height <= visible.maxY) ? above : below
            // 水平方向钳制在可见区域内，避免贴边时被裁掉一半
            origin.x = min(
                max(visible.minX + 8, origin.x),
                visible.maxX - Self.barSize.width - 8
            )
            origin.y = min(max(visible.minY + 8, origin.y), visible.maxY - Self.barSize.height - 8)
        } else {
            origin = CGPoint(
                x: visible.midX - Self.barSize.width / 2,
                y: visible.maxY - Self.barSize.height - 16
            )
        }
        panel.setFrameOrigin(origin)
        // orderFrontRegardless：不激活应用也要显示在最前
        panel.orderFrontRegardless()
    }

    public func hide() {
        panel.orderOut(nil)
    }

    /// 与 `rect` 重叠面积最大的屏幕；完全不重叠时为 nil。
    static func screen(overlapping rect: CGRect) -> NSScreen? {
        NSScreen.screens
            .map { screen -> (NSScreen, CGFloat) in
                let overlap = screen.frame.intersection(rect)
                return (screen, overlap.isNull ? 0 : overlap.width * overlap.height)
            }
            .filter { $0.1 > 0 }
            .max { $0.1 < $1.1 }?
            .0
    }

    /// 控制条当前是否在屏（诊断用）。
    public var isVisible: Bool {
        panel.isVisible
    }

    /// 控制条的窗口号，用于让捕获过滤器把它排除在成片之外。
    ///
    /// **只有 `orderFront` 之后才有值**——窗口尚未创建时 `windowNumber` 为 0。
    /// 因此录制启动必须晚于控制条显示，否则拿不到可排除的窗口号。
    public var windowID: CGWindowID? {
        let number = panel.windowNumber
        return number > 0 ? CGWindowID(number) : nil
    }

    // MARK: - 更新

    /// 按状态刷新显示。
    public func update(state: RecordingState, elapsed: TimeInterval) {
        self.state = state
        self.elapsed = elapsed
        timeLabel.stringValue = Self.format(elapsed)

        switch state {
        case .preparing:
            statusDot.layer?.backgroundColor = NSColor.systemOrange.cgColor
            pauseButton.image = symbolImage("pause.fill")
        case .recording:
            // 与录制范围框同源：控制条的圆点与屏幕上的边框必须看起来是同一种红，
            // 否则用户会怀疑这是两个不同状态。
            statusDot.layer?.backgroundColor = CaptureFrameStyle.recording.cgColor
            pauseButton.image = symbolImage("pause.fill")
        case .paused:
            statusDot.layer?.backgroundColor = CaptureFrameStyle.paused.cgColor
            pauseButton.image = symbolImage("play.fill")
        case .finishing:
            statusDot.layer?.backgroundColor = NSColor.systemGray.cgColor
        case .idle, .finished, .failed:
            break
        }

        // 收尾期间两个按钮一律置灰：流已停、转码不可暂停，
        // 它们此刻点下去没有任何效果。可点却无反应比置灰更难理解。
        pauseButton.isEnabled = (state == .recording || state == .paused)
        stopButton.isEnabled = (state != .finishing)

        refreshHint()
    }

    /// 更新 GIF 导出进度（0…1）。
    ///
    /// 与 `update(state:elapsed:)` 分开：进度是**同一状态内的连续值**，
    /// 不是会话生命周期的一部分（见 `SCStreamRecorder.onExportProgress`）。
    /// 传入值已在 `GIFExporter` 里量化成整百分比，这里再做一次文案去重。
    public func updateExportProgress(_ value: Double) {
        exportProgress = min(max(0, value), 1)
        refreshHint()
    }

    /// 重算提示文案。只在**文案真的变了**时写 label。
    ///
    /// 200 ms 的 tick 意味着它每秒被调用 5 次；无脑赋值会让「剩 8s」
    /// 这类文案在 label 上反复重绘（GIF 导出 720 帧时尤其明显）。
    private func refreshHint() {
        let text: String
        switch state {
        case .preparing:
            text = "准备中"
        case .paused:
            text = "已暂停"
        case .recording:
            text = remainingText()
        case .finishing:
            text = exportProgress.map { "GIF \(Int(($0 * 100).rounded()))%" } ?? "收尾中"
        case .idle, .finished, .failed:
            // 这三个状态不改提示：保持既有行为（原先也不在此处赋值）
            text = hintLabel.stringValue
        }
        if hintLabel.stringValue != text {
            hintLabel.stringValue = text
        }
    }

    /// GIF 的剩余时间文案。非 GIF 输出时为空。
    ///
    /// 向上取整：剩余 0.2 秒时显示「剩 1s」而不是「剩 0s」——
    /// 显示 0 而仍在录，看起来像是坏了。
    private func remainingText() -> String {
        guard let gifLimit else { return "" }
        let remaining = max(0, Int((gifLimit - elapsed).rounded(.up)))
        return "剩 \(remaining)s"
    }

    private func symbolImage(_ name: String) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)
    }

    /// 把秒数格式化为 `MM:SS`（超过一小时显示 `H:MM:SS`）。
    static func format(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%02d:%02d", minutes, secs)
    }

    // MARK: - 动作

    @objc private func handlePause() {
        onTogglePause?()
    }

    @objc private func handleStop() {
        onStop?()
    }

    #if DEBUG
    // MARK: - 诊断

    /// 诊断用：当前提示文案（「准备中」/「剩 15s」/「GIF 42%」…）。
    ///
    /// 提示文案是**上限可见性**的唯一载体（导出进度同理），
    /// 而它们是用户可见的行为，因此不能只靠日志证明。
    public var hintTextForDiagnostics: String { hintLabel.stringValue }

    /// 诊断用：暂停按钮此刻是否可点。
    public var pauseEnabledForDiagnostics: Bool { pauseButton.isEnabled }

    /// 诊断用：停止按钮此刻是否可点。
    public var stopEnabledForDiagnostics: Bool { stopButton.isEnabled }
    #endif
}
