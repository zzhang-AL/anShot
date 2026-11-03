//
//  RecordingSessionState.swift
//  AnShotCore
//
//  录制会话的状态机。见 docs/m2-recording/model.md §3。
//
//  ── 为何状态机是独立的值类型 ──────────────────────────────────
//
//  录制会话的绝大部分缺陷来自「生命周期竞态」：重复停止、停止与首帧到达同时发生、
//  流启动失败后仍在等待首帧。把状态转换表从具体的 SCStream 实现中抽出来，
//  就能在 `swift test` 中穷尽验证这些竞态，不必真起一条流。
//
//  实现层（`SCStreamRecorder`）以本状态机作为**唯一的转换裁决者**：
//  转换被拒即表示该请求是重复或非法的，实现层据此直接返回，
//  而不需要自己再维护一套 `isRunning` 之类的布尔标志——两套状态必然漂移。
//

import Foundation

/// 录制会话状态。
public enum RecordingState: String, Sendable, Equatable, CaseIterable {

    /// 尚未开始，或上一次会话已彻底结束且资源已释放。
    case idle

    /// 已受理开始请求，正在建立流并等待首帧。
    case preparing

    /// 首帧已到达，正在产出数据。
    case recording

    /// 用户暂停。暂停期间的数据不进入输出，时间轴不留空隙。
    case paused

    /// 正在收尾：停流、flush 写入器、关闭文件、释放资源。
    case finishing

    /// 会话正常结束。**终态**。
    case finished

    /// 会话因错误结束。**终态**。
    case failed

    /// 终态不接受任何事件。
    public var isTerminal: Bool {
        switch self {
        case .finished, .failed:
            return true
        case .idle, .preparing, .recording, .paused, .finishing:
            return false
        }
    }

    /// 会话已受理且尚未收尾。
    public var isActive: Bool {
        switch self {
        case .preparing, .recording, .paused:
            return true
        case .idle, .finishing, .finished, .failed:
            return false
        }
    }
}

/// 驱动状态机的输入事件。
///
/// 事件的来源各不相同——`start` / `pause` / `resume` / `stop` 来自用户操作，
/// `sessionReady` 来自流输出的首帧，`finishSucceeded` / `fail` 来自收尾路径——
/// 但它们对状态的影响是同一张表。
public enum RecordingEvent: String, Sendable, Equatable, CaseIterable {
    /// 请求开始录制。
    case start
    /// 首帧到达，流已就绪。
    case sessionReady
    /// 请求暂停。
    case pause
    /// 请求恢复。
    case resume
    /// 请求停止（含取消）。
    case stop
    /// 收尾完成。
    case finishSucceeded
    /// 出错。任何进行中的状态都可失败。
    case fail
}

/// 一次事件处理的结果。
///
/// 区分「发生了转换」与「事件被忽略」而不只是比较前后状态，是为了让测试
/// 能断言「重复 stop 是被忽略的」而不是「状态恰好没变」——后者在
/// 状态机写错时同样可能成立。
public enum RecordingTransition: Sendable, Equatable {
    case applied(from: RecordingState, to: RecordingState)
    case ignored(state: RecordingState, event: RecordingEvent)

    /// 是否发生了状态转换。
    public var didApply: Bool {
        if case .applied = self { return true }
        return false
    }

    /// 转换后的状态；被忽略时为 nil。
    public var newState: RecordingState? {
        if case .applied(_, let to) = self { return to }
        return nil
    }
}

/// 录制状态机。
///
/// 契约（`model.md` §3）：
/// - 状态转换须串行化，禁止并发 start/stop——实现层用锁保证
/// - 任何进行中的状态都可进入 `failed`；终态不再接受任何事件
/// - `stop` 在 `idle` / `finished` / `failed` 上被忽略而非报错（重复停止是幂等的）
public struct RecordingStateMachine: Sendable, Equatable {

    public private(set) var state: RecordingState

    public init(state: RecordingState = .idle) {
        self.state = state
    }

    /// 是否接受新的开始请求。
    public var canStart: Bool {
        state == .idle
    }

    /// 应用事件。
    ///
    /// - Returns: 转换结果。被忽略时状态保持不变。
    @discardableResult
    public mutating func apply(_ event: RecordingEvent) -> RecordingTransition {
        let from = state
        guard let next = Self.transition(from: from, on: event) else {
            return .ignored(state: from, event: event)
        }
        state = next
        return .applied(from: from, to: next)
    }

    /// 转换表。返回 nil 表示该事件在当前状态下被忽略。
    private static func transition(
        from state: RecordingState,
        on event: RecordingEvent
    ) -> RecordingState? {
        switch (state, event) {
        // 进行中：接收四类用户事件
        case (.idle, .start):                return .preparing
        case (.preparing, .sessionReady):    return .recording
        case (.preparing, .stop):            return .finishing
        case (.recording, .pause):           return .paused
        case (.recording, .stop):            return .finishing
        case (.paused, .resume):             return .recording
        case (.paused, .stop):               return .finishing

        // 收尾
        case (.finishing, .finishSucceeded): return .finished

        // 失败：任何进行中的状态都可进入，终态不再接受
        case (.preparing, .fail),
             (.recording, .fail),
             (.paused, .fail),
             (.finishing, .fail):            return .failed

        // 其余组合一律忽略：重复 start / 重复 stop / 终态上的任何事件 /
        // idle 上的 pause / recording 上的 resume 等
        default:                             return nil
        }
    }
}
