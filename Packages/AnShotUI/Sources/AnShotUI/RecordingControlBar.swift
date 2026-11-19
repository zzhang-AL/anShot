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
    /// 点击取消并丢弃当前录制。
    public var onCancel: (() -> Void)?

    private let panel: NSPanel
    private let statusDot = NSView()
    private let timeLabel = NSTextField(labelWithString: "00:00")
    private let hintLabel = NSTextField(labelWithString: "")
    private let pauseButton = NSButton()
    private let stopButton = NSButton()
    private let cancelButton = NSButton()

    /// 当前状态与已录时长。`refreshHint` 依赖它们现算文案。
    private var state: RecordingState = .idle
    private var elapsed: TimeInterval = 0

    /// 本次会话的 GIF 时长上限。nil 表示非 GIF 输出（无上限、无导出进度）。
    private var gifLimit: TimeInterval?

    /// GIF 导出进度（0…1）。nil 表示尚未进入导出。
    private var exportProgress: Double?

    /// 准备倒计时剩余秒数（>0 时处于开拍前倒计时）。
    private var countdownRemaining: Int?

    /// 取消丢弃两步确认态：首次点击进入危险确认态，2.5s 内再次点击才真正丢弃（防误丢素材）。
    private var awaitingCancelConfirmation = false
    private var cancelConfirmResetTimer: Timer?
    private var containerView: RecordingControlBarContainerView?

    private static let barHeight: CGFloat = 46
    private static let barMinWidth: CGFloat = 286
    private static let barSize = CGSize(width: barMinWidth, height: barHeight)

    /// 供测试校验两步防误丢确认状态与层级。
    var isAwaitingCancelConfirmationForTesting: Bool { awaitingCancelConfirmation }
    var windowLevelForTesting: NSWindow.Level { panel.level }
    func triggerCancelForTesting() { handleCancel() }

    public init() {
        panel = NSPanel(
            contentRect: CGRect(origin: .zero, size: Self.barSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        // 层级严格高于录制范围框（screenSaver + 1）与截图覆盖层（screenSaver），确保控制条始终在最顶层可点。
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 2)
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovable = true
        panel.isMovableByWindowBackground = true
        panel.sharingType = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.ignoresMouseEvents = false

        configureContent()
    }

    // MARK: - 内容

    private func configureContent() {
        let container = RecordingControlBarContainerView(frame: CGRect(origin: .zero, size: Self.barSize))
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor(calibratedWhite: 0.12, alpha: 0.94).cgColor
        container.layer?.cornerRadius = Self.barHeight / 2
        container.layer?.borderWidth = 1
        container.layer?.borderColor = NSColor(calibratedWhite: 1, alpha: 0.14).cgColor
        containerView = container

        statusDot.wantsLayer = true
        statusDot.layer?.cornerRadius = 5
        statusDot.layer?.backgroundColor = CaptureFrameStyle.recording.cgColor
        statusDot.translatesAutoresizingMaskIntoConstraints = false

        timeLabel.font = .monospacedDigitSystemFont(ofSize: 15, weight: .medium)
        timeLabel.textColor = .white
        timeLabel.alignment = .left
        timeLabel.setContentHuggingPriority(.required, for: .horizontal)
        timeLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        timeLabel.translatesAutoresizingMaskIntoConstraints = false

        hintLabel.font = .systemFont(ofSize: 11, weight: .regular)
        hintLabel.textColor = NSColor(calibratedWhite: 1, alpha: 0.72)
        hintLabel.lineBreakMode = .byTruncatingTail
        hintLabel.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        hintLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        hintLabel.translatesAutoresizingMaskIntoConstraints = false

        styleButton(pauseButton, symbol: "pause.fill", toolTip: "暂停 / 继续录制", action: #selector(handlePause))
        styleButton(stopButton, symbol: "stop.fill", toolTip: "停止并保存录制", action: #selector(handleStop))
        styleCancelButton(confirming: false)

        let row = NSStackView(views: [statusDot, timeLabel, hintLabel, pauseButton, stopButton, cancelButton])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        row.setCustomSpacing(12, after: hintLabel)
        row.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(row)

        NSLayoutConstraint.activate([
            statusDot.widthAnchor.constraint(equalToConstant: 10),
            statusDot.heightAnchor.constraint(equalToConstant: 10),
            pauseButton.widthAnchor.constraint(equalToConstant: 26),
            pauseButton.heightAnchor.constraint(equalToConstant: 26),
            stopButton.widthAnchor.constraint(equalToConstant: 26),
            stopButton.heightAnchor.constraint(equalToConstant: 26),
            cancelButton.heightAnchor.constraint(equalToConstant: 26),
            cancelButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 26),

            row.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 14),
            row.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            row.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])

        panel.contentView = container
        resizeBarToFit()
    }

    private func styleButton(_ button: NSButton, symbol: String, toolTip: String, action: Selector) {
        button.bezelStyle = .regularSquare
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.contentTintColor = .white
        button.toolTip = toolTip
        button.target = self
        button.action = action
        button.wantsLayer = true
        button.layer?.backgroundColor = NSColor(calibratedWhite: 1, alpha: 0.14).cgColor
        button.layer?.cornerRadius = 6
        button.translatesAutoresizingMaskIntoConstraints = false
        if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: toolTip) {
            button.image = image
        } else {
            button.title = symbol == "stop.fill" ? "■" : (symbol == "xmark" ? "✕" : "II")
            button.imagePosition = .noImage
        }
    }

    /// 取消按钮独立危险红色视觉与两步确认文案切换。
    private func styleCancelButton(confirming: Bool) {
        cancelButton.bezelStyle = .regularSquare
        cancelButton.isBordered = false
        cancelButton.target = self
        cancelButton.action = #selector(handleCancel)
        cancelButton.wantsLayer = true
        cancelButton.layer?.cornerRadius = 6
        cancelButton.translatesAutoresizingMaskIntoConstraints = false

        if confirming {
            cancelButton.image = nil
            cancelButton.imagePosition = .noImage
            cancelButton.attributedTitle = NSAttributedString(
                string: " 确认丢弃 ",
                attributes: [
                    .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
                    .foregroundColor: NSColor.white,
                ]
            )
            cancelButton.toolTip = "再次点击立即取消并丢弃当前录制"
            cancelButton.layer?.backgroundColor = AnShotTheme.danger.cgColor
        } else {
            cancelButton.attributedTitle = NSAttributedString(string: "")
            cancelButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "取消并丢弃当前录制")
            cancelButton.imagePosition = .imageOnly
            cancelButton.contentTintColor = NSColor(red: 1.0, green: 0.45, blue: 0.42, alpha: 1.0)
            cancelButton.toolTip = "取消并丢弃当前录制（点击两次确认防误触）"
            cancelButton.layer?.backgroundColor = AnShotTheme.danger.withAlphaComponent(0.24).cgColor
        }
    }

    private func resizeBarToFit() {
        guard let container = containerView else { return }
        container.layoutSubtreeIfNeeded()
        let desiredWidth = max(Self.barMinWidth, ceil(container.fittingSize.width))
        var frame = panel.frame
        let centerX = frame.midX
        frame.size = CGSize(width: desiredWidth, height: Self.barHeight)
        if frame.origin != .zero {
            frame.origin.x = centerX - desiredWidth / 2
        }
        panel.setFrame(frame, display: true)
    }

    private func resetCancelConfirmation() {
        cancelConfirmResetTimer?.invalidate()
        cancelConfirmResetTimer = nil
        if awaitingCancelConfirmation {
            awaitingCancelConfirmation = false
            styleCancelButton(confirming: false)
            resizeBarToFit()
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
        resetCancelConfirmation()
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
        if state != .preparing {
            countdownRemaining = nil
        }
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

        // 收尾期间三个按钮一律置灰：流已停、转码不可暂停也不可丢弃。
        pauseButton.isEnabled = (state == .recording || state == .paused)
        stopButton.isEnabled = (state != .finishing && countdownRemaining == nil)
        cancelButton.isEnabled = (state == .preparing || state == .recording || state == .paused)

        refreshHint()
    }

    /// 刷新录制前准备倒计时（如 3 → 2 → 1 秒）。
    public func updateCountdown(_ secondsRemaining: Int?) {
        countdownRemaining = secondsRemaining
        if let secondsRemaining, secondsRemaining > 0 {
            state = .preparing
            statusDot.layer?.backgroundColor = NSColor.systemOrange.cgColor
            timeLabel.stringValue = String(format: "00:%02d", secondsRemaining)
            pauseButton.isEnabled = false
            stopButton.isEnabled = false
            cancelButton.isEnabled = true
        }
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
            if let countdownRemaining, countdownRemaining > 0 {
                text = "倒计时 \(countdownRemaining)s"
            } else {
                text = "准备中"
            }
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
            hintLabel.isHidden = text.isEmpty
            resizeBarToFit()
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
        resetCancelConfirmation()
        onTogglePause?()
    }

    @objc private func handleStop() {
        resetCancelConfirmation()
        onStop?()
    }

    @objc private func handleCancel() {
        // 准备倒计时期间尚未录出素材，一次点击即可取消；已开始录制后须二次点击防误丢素材。
        if state == .preparing || awaitingCancelConfirmation {
            resetCancelConfirmation()
            onCancel?()
            return
        }
        awaitingCancelConfirmation = true
        styleCancelButton(confirming: true)
        resizeBarToFit()
        cancelConfirmResetTimer?.invalidate()
        let timer = Timer(timeInterval: 2.5, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.resetCancelConfirmation()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        cancelConfirmResetTimer = timer
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

    /// 诊断用：取消按钮此刻是否可点。
    public var cancelEnabledForDiagnostics: Bool { cancelButton.isEnabled }
    #endif
}

/// 控制条背景容器视图：明确允许通过背景拖拽移动控制条位置。
private final class RecordingControlBarContainerView: NSView {
    override var mouseDownCanMoveWindow: Bool { true }
}
