//
//  RecordingTargetPick.swift
//  AnShotUI
//
//  录制目标选取的状态与判定。
//
//  ── 为什么它单独存在 ──────────────────────────────────────
//
//  选取期间本视图的鼠标与键盘只服务于「选一个目标」：不能改截图选区
//  （用户正拿它当录制区域）、不能落进标注、也不能让回车把整个会话导出掉。
//  这些判断散在四个事件分支里时，改一处就容易漏另一处，而它们失效的表现
//  都是「点了没反应」或「取消后反而改了选区」——最难查的那一类。
//
//  ── 它不做什么 ────────────────────────────────────────────
//
//  不认识视图、识别会话与坐标：调用方负责「按位置取一次原始命中」，
//  这里只回答三件事——这次命中算不算数、是否还在选取中、这次松手要不要吞。
//

import AnShotCapture
import AnShotCore

/// 一次录制目标选取的过程状态。
struct RecordingTargetPick {

    /// 正在选取的范围类型；nil 表示不在选取中。
    private(set) var kind: RecordingScopeKind?

    /// 最近一次命中（悬停候选）。点击锁定时**不读它**，会重新命中。
    private(set) var candidate: DetectionTarget?

    /// 手势是否已按下（尚未收到 mouseUp）。
    ///
    /// 存在的唯一目的：吞掉「按下之后按 ESC 取消」残留的那次松手。
    /// 那时 `kind` 已为 nil，不拦就会落入截图侧的「提交草稿 / 提交选区」路径，
    /// 把一次取消变成一次意外的编辑。
    private(set) var isGestureDown = false

    /// 是否正在选取。
    var isActive: Bool { kind != nil }

    /// 该范围强制使用的识别层级。
    ///
    /// 层级由所选范围决定，**不看修饰键**：用户已经用「窗口 / 应用」表达了意图，
    /// 再要求他记住「⇧ 是窗口、⌘ 是应用」是多余的。
    var preference: DetectionLayerPreference? {
        switch kind {
        case .window: return .window
        case .application: return .application
        default: return nil
        }
    }

    /// 该范围要求命中属于哪一层。
    var requiredLayer: DetectionTarget.Layer? {
        switch kind {
        case .window: return .window
        case .application: return .application
        default: return nil
        }
    }

    /// 进入选取。
    ///
    /// 只接受需要目标的范围（窗口 / 应用）：区域与全屏不需要选对象。
    /// - Returns: 是否真的进入了选取。
    @discardableResult
    mutating func begin(_ kind: RecordingScopeKind) -> Bool {
        guard kind.requiresTarget else { return false }
        self.kind = kind
        candidate = nil
        isGestureDown = false
        return true
    }

    /// 退出选取。
    ///
    /// **不清 `isGestureDown`**：它要留给松手去吞——在这里清掉，
    /// 取消后残留的那次松手就会落入截图提交路径。
    mutating func end() {
        guard kind != nil || candidate != nil else { return }
        kind = nil
        candidate = nil
    }

    /// 记录这次命中。
    ///
    /// **不去重**：去重会按视图各存一份「上次的候选」，跨屏 A → B → A 时
    /// A 屏那份没变，于是回到 A 后不再通知——预览框就停在 B 上。
    /// 重复上报无代价：面板按标题去重，预览框按几何去重。
    mutating func update(candidate: DetectionTarget?) {
        self.candidate = candidate
    }

    /// 只接受与本范围层级一致的命中。
    ///
    /// 两种偏好在无命中时都会退回「显示器」层，而显示器没有窗口/应用身份，
    /// 锁定了也构造不出过滤器，因此必须在这里挡掉。
    func accept(_ target: DetectionTarget?) -> DetectionTarget? {
        guard let requiredLayer else { return nil }
        return target.flatMap { $0.layer == requiredLayer ? $0 : nil }
    }

    /// 按下：标记手势已开始。
    mutating func markGestureDown() {
        isGestureDown = true
    }

    /// 松手：返回这次松手是否需要被吞掉（若需要，标记同时清零）。
    mutating func consumeGestureDown() -> Bool {
        let wasDown = isGestureDown
        isGestureDown = false
        return wasDown
    }
}
