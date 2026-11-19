//
//  AutoScrollDriverTests.swift
//  AnShotCaptureTests
//
//  Phase 4 自动平滑翻页引擎单元测试：合成事件标记隔离、人工滚轮 0 延迟接管、
//  控制栏悬停防抖、自适应降步长与自动触底停止。
//

import AnShotCore
import CoreGraphics
import Testing

@testable import AnShotCapture

@MainActor
@Suite("Phase 4 · AutoScrollDriver 状态机与事件隔离")
struct AutoScrollDriverTests {

    @Test("合成滚轮事件标记隔离：忽略自身合成事件，真实人工滚轮立刻暂停并接管")
    func syntheticTagFilteringAndManualTakeover() {
        let driver = AutoScrollDriver(
            selectionAppKitRect: CGRect(x: 100, y: 100, width: 600, height: 500),
            axis: .vertical,
            speed: .normal,
            disableSystemHooks: true
        )
        defer { driver.stop() }

        var takeoverCount = 0
        driver.onManualTakeover = { takeoverCount += 1 }
        driver.start()
        #expect(driver.state == .running)

        // 自身合成标记事件必须被过滤，不触发接管
        let ignored = driver.handleObservedWheelEvent(userData: AutoScrollDriver.syntheticScrollEventTag)
        #expect(!ignored)
        #expect(driver.state == .running)
        #expect(takeoverCount == 0)

        // 外部真实人工滚轮（userData = 0）立刻暂停自动翻页并回调接管
        let takenOver = driver.handleObservedWheelEvent(userData: 0)
        #expect(takenOver)
        #expect(driver.state == .pausedByUser)
        #expect(takeoverCount == 1)
    }

    @Test("鼠标移入控制栏暂停防抖，移出无缝恢复自动翻页")
    func hoverPauseAndResume() {
        let driver = AutoScrollDriver(
            selectionAppKitRect: CGRect(x: 100, y: 100, width: 500, height: 400),
            disableSystemHooks: true
        )
        defer { driver.stop() }

        driver.start()
        #expect(driver.state == .running)

        driver.setControlBarHovered(true)
        #expect(driver.state == .pausedForHover)

        driver.setControlBarHovered(false)
        #expect(driver.state == .running)
    }

    @Test("遇未对齐自适应降步长，连续静止自动判触底并停止")
    func adaptiveStepAndAutoReachBottom() {
        let driver = AutoScrollDriver(
            selectionAppKitRect: CGRect(x: 100, y: 100, width: 500, height: 400),
            speed: .fast,
            stillBottomThreshold: 4,
            disableSystemHooks: true
        )
        defer { driver.stop() }

        var bottomCalled = false
        driver.onReachedBottom = { bottomCalled = true }
        driver.start()

        let initialStep = driver.currentStepPixels
        // 遇到未对齐（页面未渲染完）：降低步长
        driver.observeFrameFeedback(didAdvance: false, isUnresolved: true)
        #expect(driver.currentStepPixels < initialStep)

        // 正常推进恢复
        driver.observeFrameFeedback(didAdvance: true, isUnresolved: false)
        #expect(driver.state == .running)

        // 连续 4 次静止自动触底停止
        for _ in 0..<4 {
            driver.observeFrameFeedback(didAdvance: false, isUnresolved: false)
        }
        #expect(driver.state == .reachedBottom)
        #expect(bottomCalled)
    }

    @Test("发出的合成滚轮步长携带唯一 ASLS 标记且方向正确")
    func emitScrollStepTagsEventCorrectly() {
        let driver = AutoScrollDriver(
            selectionAppKitRect: CGRect(x: 100, y: 100, width: 500, height: 400),
            axis: .horizontal,
            speed: .slow,
            disableSystemHooks: true
        )
        defer { driver.stop() }

        var posted: (point: CGPoint, delta: Int32, axis: ScrollAxis, tag: Int64)?
        driver.eventPoster = { point, delta, axis, tag in
            posted = (point, delta, axis, tag)
        }
        driver.start()
        driver.emitScrollStep()

        #expect(posted != nil)
        #expect(posted?.delta == -AutoScrollSpeed.slow.stepPixels)
        #expect(posted?.axis == .horizontal)
        #expect(posted?.tag == AutoScrollDriver.syntheticScrollEventTag)
    }
}
