//
//  RecordingStateMachineTests.swift
//  AnShotCoreTests
//
//  录制会话状态机的单元测试。
//
//  ── 为何这些测试比普通的枚举测试更重要 ────────────────────────
//
//  录制会话的绝大多数缺陷是生命周期竞态：重复停止、停止与首帧同时到达、
//  流启动失败后仍在等待首帧。这些竞态在真机上都难以稳定复现，
//  但它们在状态机上只是「某个 (状态, 事件) 组合」。
//
//  故本文件除了覆盖各条正常路径，还包含一条**穷尽性测试**：
//  遍历全部 (状态 × 事件) 组合，断言「被接受的转换集合」与预期**完全一致**。
//  新增状态或事件时该测试必然失败，从而强制显式更新转换表——
//  这是防止「悄悄多出一条合法转换」的唯一自动化手段。
//

import Foundation
import Testing
@testable import AnShotCore

private typealias State = RecordingState
private typealias Event = RecordingEvent

/// (状态, 事件) 组合的哈希键，用于穷尽性比对。
private struct TransitionKey: Hashable {
    let state: State
    let event: Event
}

@Suite("录制状态机")
struct RecordingStateMachineTests {

    // MARK: - 正常路径

    @Test("正常路径：开始 → 首帧 → 停止 → 完成")
    func happyPath() {
        var machine = RecordingStateMachine()

        #expect(machine.state == .idle)
        #expect(machine.canStart)

        #expect(machine.apply(.start).newState == .preparing)
        #expect(!machine.canStart, "已受理开始请求后不应再接受新的开始请求")

        #expect(machine.apply(.sessionReady).newState == .recording)
        #expect(machine.state.isActive)

        #expect(machine.apply(.stop).newState == .finishing)
        #expect(!machine.state.isActive)

        #expect(machine.apply(.finishSucceeded).newState == .finished)
        #expect(machine.state.isTerminal)
    }

    @Test("暂停与恢复：数据不入输出但会话仍在进行")
    func pauseAndResume() {
        var machine = RecordingStateMachine(state: .recording)

        #expect(machine.apply(.pause).newState == .paused)
        #expect(machine.state.isActive, "暂停只是停止写入，会话并未结束")

        #expect(machine.apply(.resume).newState == .recording)

        // 暂停态同样可以直接停止
        _ = machine.apply(.pause)
        #expect(machine.apply(.stop).newState == .finishing)
    }

    @Test("准备阶段停止：首帧未到也能收尾")
    func stopDuringPreparing() {
        var machine = RecordingStateMachine(state: .preparing)

        // 这是真实场景：用户按下热键后又立刻取消，此时流可能还在启动中
        #expect(machine.apply(.stop).newState == .finishing)
        #expect(machine.apply(.finishSucceeded).newState == .finished)
    }

    // MARK: - 幂等与非法事件

    @Test("重复停止被忽略而非报错")
    func repeatedStopIsIgnored() {
        var machine = RecordingStateMachine(state: .recording)
        #expect(machine.apply(.stop).didApply)

        // 第二次停止：收尾已在进行中，必须被忽略
        let second = machine.apply(.stop)
        #expect(!second.didApply)
        #expect(second == .ignored(state: .finishing, event: .stop))

        _ = machine.apply(.finishSucceeded)

        // 会话结束后的停止同样被忽略（契约：stop 在 finished 上为空操作）
        let third = machine.apply(.stop)
        #expect(!third.didApply)
        #expect(machine.state == .finished, "被忽略的事件不得改变状态")
    }

    @Test("重复开始被忽略")
    func repeatedStartIsIgnored() {
        var machine = RecordingStateMachine(state: .recording)
        #expect(!machine.apply(.start).didApply)
        #expect(machine.state == .recording)

        var preparing = RecordingStateMachine(state: .preparing)
        #expect(!preparing.apply(.start).didApply)
    }

    @Test("空转事件被忽略：idle 上的暂停/恢复/停止/完成")
    func idleIgnoresNonStartEvents() {
        for event in [Event.pause, .resume, .stop, .finishSucceeded, .sessionReady] {
            var machine = RecordingStateMachine()
            #expect(!machine.apply(event).didApply, "idle 上不应接受 \(event.rawValue)")
            #expect(machine.state == .idle)
        }
    }

    @Test("乱序事件被忽略：未暂停时恢复、已就绪时重复首帧")
    func outOfOrderEventsAreIgnored() {
        var recording = RecordingStateMachine(state: .recording)
        #expect(!recording.apply(.resume).didApply)
        #expect(!recording.apply(.sessionReady).didApply)

        var paused = RecordingStateMachine(state: .paused)
        #expect(!paused.apply(.pause).didApply)
        #expect(!paused.apply(.sessionReady).didApply)
    }

    // MARK: - 失败

    @Test("任何进行中的状态都可失败")
    func failureFromAnyActiveState() {
        for state in [State.preparing, .recording, .paused, .finishing] {
            var machine = RecordingStateMachine(state: state)
            #expect(machine.apply(.fail).newState == .failed, "\(state.rawValue) 应可进入 failed")
            #expect(machine.state.isTerminal)
        }
    }

    @Test("终态不接受任何事件")
    func terminalStatesRejectEverything() {
        for state in [State.finished, .failed] {
            for event in Event.allCases {
                var machine = RecordingStateMachine(state: state)
                #expect(
                    !machine.apply(event).didApply,
                    "终态 \(state.rawValue) 不应接受 \(event.rawValue)"
                )
                #expect(machine.state == state)
            }
            let machine = RecordingStateMachine(state: state)
            #expect(!machine.canStart, "终态实例不可复用，必须新建实例")
        }
    }

    // MARK: - 穷尽性

    @Test("转换表穷尽：被接受的全部 (状态, 事件) 组合与预期一致")
    func exhaustiveTransitionTable() {
        let expectedApplied: [TransitionKey: State] = [
            TransitionKey(state: .idle, event: .start): .preparing,
            TransitionKey(state: .preparing, event: .sessionReady): .recording,
            TransitionKey(state: .preparing, event: .stop): .finishing,
            TransitionKey(state: .preparing, event: .fail): .failed,
            TransitionKey(state: .recording, event: .pause): .paused,
            TransitionKey(state: .recording, event: .stop): .finishing,
            TransitionKey(state: .recording, event: .fail): .failed,
            TransitionKey(state: .paused, event: .resume): .recording,
            TransitionKey(state: .paused, event: .stop): .finishing,
            TransitionKey(state: .paused, event: .fail): .failed,
            TransitionKey(state: .finishing, event: .finishSucceeded): .finished,
            TransitionKey(state: .finishing, event: .fail): .failed
        ]

        var actualApplied: [TransitionKey: State] = [:]
        var checked = 0

        for state in State.allCases {
            for event in Event.allCases {
                var machine = RecordingStateMachine(state: state)
                let key = TransitionKey(state: state, event: event)
                let transition = machine.apply(event)
                if transition.didApply {
                    actualApplied[key] = machine.state
                } else {
                    #expect(machine.state == state, "被忽略的事件不得改变状态")
                    #expect(transition == .ignored(state: state, event: event))
                }
                checked += 1
            }
        }

        #expect(checked == State.allCases.count * Event.allCases.count,
                "穷尽性检查必须覆盖全部组合")

        // 逐组合比对，直接报出「多出」与「缺失或目标错误」两类偏差
        for (key, expectedTarget) in expectedApplied {
            let actual = actualApplied[key]?.rawValue ?? "被忽略"
            #expect(
                actualApplied[key] == expectedTarget,
                "\(key.state.rawValue) + \(key.event.rawValue) 期望 → \(expectedTarget.rawValue)，实际 → \(actual)"
            )
        }
        for key in actualApplied.keys where expectedApplied[key] == nil {
            #expect(Bool(false), "出现了未预期的合法转换：\(key.state.rawValue) + \(key.event.rawValue)")
        }
    }

}
