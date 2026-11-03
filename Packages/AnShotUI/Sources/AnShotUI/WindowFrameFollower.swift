//
//  WindowFrameFollower.swift
//  AnShotUI
//
//  周期性把「窗口的实时矩形」喂给录制范围框。
//
//  ── 为什么是轮询 ──────────────────────────────────────────
//
//  窗口移动没有可订阅的通知（别人的窗口拿不到 `NSWindow` 回调），
//  所以只能按固定间隔查询（见 `WindowFrameProbe`）。2 Hz 是权衡结果：
//  再快没有意义（范围框是人眼看的），再慢则拖动窗口时框会明显落后。
//
//  ── 只上报「变了」的帧 ────────────────────────────────────
//
//  范围框每次 `update(rect:)` 都会重设窗口位置并重绘。
//  窗口静止时按 2 Hz 反复重建是纯浪费（并且会与鼠标交互抢主线程），
//  因此矩形未变时不上报。
//

import AnShotCapture
import AppKit

/// 跟随某个窗口的矩形变化。
@MainActor
final class WindowFrameFollower {

    private let windowID: CGWindowID
    private let interval: TimeInterval
    /// 收到新矩形时回调（**AppKit 屏幕坐标**，可直接用于窗口摆放）。
    private let onUpdate: (CGRect) -> Void

    private var timer: Timer?
    private var lastReported: CGRect?

    /// 最近一次上报或探测到的矩形（诊断用）。
    private(set) var lastKnownRect: CGRect?

    init(
        windowID: CGWindowID,
        interval: TimeInterval = 0.5,
        onUpdate: @escaping (CGRect) -> Void
    ) {
        self.windowID = windowID
        self.interval = interval
        self.onUpdate = onUpdate
    }

    /// 开始跟随。重复调用无效。
    func start() {
        guard timer == nil else { return }
        poll()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
    }

    /// 停止跟随并释放定时器。
    func stop() {
        timer?.invalidate()
        timer = nil
        lastReported = nil
        lastKnownRect = nil
    }

    /// 查询一次并把变化交给调用方。
    private func poll() {
        guard let global = WindowFrameProbe.frame(of: windowID) else {
            // 窗口暂时不可见（最小化、切 Space）：**保持现状**。
            // 录制还在继续，把范围框藏起来或挪到别处都会误导用户。
            return
        }
        // 全局左上原点 → AppKit 屏幕坐标：范围框按 AppKit 坐标摆窗口。
        let rect = OverlayWindow.appKitScreenRect(forGlobalRect: global)
        lastKnownRect = rect
        guard rect != lastReported else { return }
        lastReported = rect
        onUpdate(rect)
    }
}
