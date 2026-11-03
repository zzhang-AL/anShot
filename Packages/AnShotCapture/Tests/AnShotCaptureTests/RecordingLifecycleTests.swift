//
//  RecordingLifecycleTests.swift
//  AnShotCaptureTests
//
//  录制会话生命周期的回归测试。
//
//  ── 为何单独为「启动完成后的判定」写测试 ──────────────────────
//
//  `SCStream` 的首帧回调在输出队列上并发执行，**可能早于 `startCapture()` 返回**。
//  因此「启动完成」这一刻的会话状态有多种合法取值，而判定逻辑只要写错一项，
//  就会把正常启动的流当成废弃流主动停掉——症状是「投递首帧后彻底沉默」
//  且停止时报 -3808，并且只在特定回调时序下出现，真机上难以稳定复现。
//
//  这类竞态的判定必须是纯函数才能穷尽验证，故本文件覆盖完整的判定矩阵。
//  实测佐证：修复前 4 轮连续会话中 2 轮失败，日志显示失败轮次的顺序是
//  「首帧到达 → startCapture 返回」；修复后 4/4 通过。
//

import Foundation
import Testing
@testable import AnShotCapture
@testable import AnShotCore

@Suite("录制启动完成后的废弃判定")
struct StreamAbandonmentTests {

    @Test("首帧先于 startCapture 返回时：不得废弃，流已正常开始录制")
    func firstFrameArrivedBeforeStartReturns() {
        // 这是最容易写错的组合：状态已从 preparing 前进到 recording，
        // 若用「状态 != preparing」判断，就会把正常启动的流误判为废弃。
        #expect(!SCStreamRecorder.shouldAbandonAfterStart(
            registeredStreamIsCurrent: true,
            state: .recording
        ))
    }

    @Test("启动完成时会话仍在准备或已暂停：均不得废弃")
    func activeStatesAreNotAbandoned() {
        for state in [RecordingState.preparing, .recording, .paused] {
            #expect(
                !SCStreamRecorder.shouldAbandonAfterStart(
                    registeredStreamIsCurrent: true,
                    state: state
                ),
                "\(state.rawValue) 属于进行中状态，不应废弃"
            )
        }
    }

    @Test("启动完成前用户已请求停止：必须废弃并清理")
    func stopRequestedBeforeStartReturns() {
        #expect(SCStreamRecorder.shouldAbandonAfterStart(
            registeredStreamIsCurrent: true,
            state: .finishing
        ))
    }

    @Test("启动完成时会话已终结：必须废弃并清理")
    func terminalStatesAreAbandoned() {
        for state in [RecordingState.finished, .failed] {
            #expect(
                SCStreamRecorder.shouldAbandonAfterStart(
                    registeredStreamIsCurrent: true,
                    state: state
                ),
                "\(state.rawValue) 不应继续持有流"
            )
        }
    }

    @Test("登记的流已被更换：无论状态如何都必须废弃")
    func replacedStreamIsAlwaysAbandoned() {
        for state in RecordingState.allCases {
            #expect(
                SCStreamRecorder.shouldAbandonAfterStart(
                    registeredStreamIsCurrent: false,
                    state: state
                ),
                "状态 \(state.rawValue) 下被替换的流都应清理"
            )
        }
    }
}

/// 测试用的并发安全计数器。
private actor AsyncCounter {
    private(set) var value = 0
    func increment() { value += 1 }
}

/// 一次性信号。
///
/// `signal()` 之前调用 `wait()` 会挂起，之后调用直接返回。
/// 存在的理由：把「某个闭包已经开始执行」从**时长猜测**变成**确定事件**。
private actor Signal {
    private var isSignaled = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func signal() {
        guard !isSignaled else { return }
        isSignaled = true
        for waiter in waiters { waiter.resume() }
        waiters.removeAll()
    }

    func wait() async {
        if isSignaled { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}

/// 时序事件日志。
///
/// 用**顺序**而不是**时长**表达「谁等了谁」：时序契约（B 必须等 A 完成）
/// 本质上是顺序约束，用时间阈值去近似它必然受调度与机器负载影响。
private actor EventLog {
    enum Event: Equatable {
        case firstBodyFinished
        case secondCallReturned
    }

    private(set) var events: [Event] = []
    func record(_ event: Event) { events.append(event) }
}

@Suite("录制收尾的唯一性")
struct RecordingFinalizeGateTests {

    @Test("后来的调用必须等待同一次收尾完成，且收尾只执行一次")
    func runOrWaitMakesLateCallersWait() async {
        let gate = FinalizeGate()
        let counter = AsyncCounter()
        let log = EventLog()
        // 第一个闭包已进入；可以退出第一个闭包
        let bodyEntered = Signal()
        let releaseBody = Signal()

        // 第一个到达者：慢收尾。慢在「等测试放行」而不是睡固定时长——
        // 后者才是原来那条测试随机失败的根因。
        let first = Task {
            await gate.runOrWait {
                await bodyEntered.signal()
                await releaseBody.wait()
                await log.record(.firstBodyFinished)
                await counter.increment()
            }
        }

        // 确定性等待：闭包已在执行 ⇒ 收尾权必然已被取走，
        // 此后发起的调用只能等待。
        //
        // 旧版在这里用 `Task.sleep(30ms)` 猜时间：`async let` 不保证子任务
        // 在 30ms 内被调度起来，一旦没起来，`gate` 尚未被认领，第二次调用
        // 就会自己执行并立即返回——于是 `waited` 约等于 0，测试随机失败
        //（实测 3 次跑 1 次失败，值 0.25s 与 0.09s 都出现过）。
        await bodyEntered.wait()

        // 此时发起的调用只能等待同一次收尾
        let second = Task {
            await gate.runOrWait { await counter.increment() }
            await log.record(.secondCallReturned)
        }

        // 放行第一个收尾
        await releaseBody.signal()
        await first.value
        await second.value

        // 先取值再断言：#expect 的 autoclosure 不支持 await
        let finalCount = await counter.value
        let events = await log.events

        #expect(finalCount == 1, "收尾必须只执行一次，实际 \(finalCount) 次")
        // 顺序即契约：第二个调用必须在第一个收尾**结束之后**才返回。
        // 若它没有等待，`secondCallReturned` 会排在 `firstBodyFinished` 之前。
        #expect(
            events == [.firstBodyFinished, .secondCallReturned],
            "后来的调用必须等到收尾完成才返回，实际顺序 \(events)"
        )
    }

    @Test("只有第一个到达者获得收尾权")
    func onlyFirstClaimSucceeds() {
        let gate = FinalizeGate()
        #expect(gate.claim())
        for _ in 0..<5 {
            #expect(!gate.claim(), "重复请求收尾必须被拒绝")
        }
    }

    @Test("并发争抢下恰好一人获得收尾权")
    func concurrentClaimsYieldExactlyOneWinner() async {
        let gate = FinalizeGate()
        let winners = await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<32 {
                group.addTask { gate.claim() }
            }
            var count = 0
            for await won in group where won {
                count += 1
            }
            return count
        }
        #expect(winners == 1, "收尾必须恰好发生一次，实际 \(winners) 次")
    }
}
