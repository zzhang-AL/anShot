//
//  GIFFrameTimelineTests.swift
//  AnShotCaptureTests
//
//  GIF 帧时间轴与百度 token 缓存的凭据绑定。
//
//  时间轴这一组断言的是同一个不变量：**无论合并多少相同帧、丢多少失败格，
//  所有帧占用的格数之和都等于采样总格数**——否则 GIF 的播放时长会与影片不一致。
//

import Foundation
import Testing

@testable import AnShotCapture

@Suite("GIF 帧时间轴")
struct GIFFrameTimelineTests {

    /// 用整数代替图像：相等即「像素相同」。
    private func run(_ slots: [Int?], total: Int) -> [(frame: Int, slots: Int)] {
        var timeline = GIFFrameTimeline<Int>(isSame: ==)
        var output: [(frame: Int, slots: Int)] = []
        for (index, frame) in slots.enumerated() {
            guard let frame else { continue }
            if let emitted = timeline.accept(frame, at: index) {
                output.append(emitted)
            }
        }
        if let last = timeline.finish(totalSlots: total) {
            output.append(last)
        }
        return output
    }

    @Test("全部不同：每格一帧，每帧占 1 格")
    func distinctFrames() {
        let result = run([1, 2, 3, 4], total: 4)
        #expect(result.map(\.frame) == [1, 2, 3, 4])
        #expect(result.map(\.slots) == [1, 1, 1, 1])
    }

    @Test("相邻相同的帧合并，时长并入保留的那一帧")
    func identicalFramesCoalesce() {
        let result = run([1, 1, 1, 2, 2, 3], total: 6)
        #expect(result.map(\.frame) == [1, 2, 3])
        #expect(result.map(\.slots) == [3, 2, 1])
    }

    @Test("中间取帧失败：该格并入前一帧，总时长不变")
    func failedSlotsExtendPrevious() {
        let result = run([1, nil, nil, 2], total: 4)
        #expect(result.map(\.frame) == [1, 2])
        #expect(result.map(\.slots) == [3, 1])
    }

    @Test("开头取帧失败：并入第一个成功的帧")
    func leadingFailuresBelongToFirstFrame() {
        let result = run([nil, nil, 5, 6], total: 4)
        #expect(result.map(\.frame) == [5, 6])
        #expect(result.map(\.slots).reduce(0, +) == 4)
    }

    @Test("末尾取帧失败：最后一帧一直占到总格数")
    func trailingFailuresBelongToLastFrame() {
        let result = run([1, 2, nil, nil], total: 4)
        #expect(result.map(\.slots) == [1, 3])
    }

    @Test("全部静止：只写一帧，占满全部时长")
    func staticRecordingIsOneFrame() {
        let result = run(Array(repeating: 7, count: 30), total: 30)
        #expect(result.count == 1)
        #expect(result.first?.slots == 30)
    }

    @Test("一帧都没有：不产出")
    func noFrames() {
        #expect(run([nil, nil], total: 2).isEmpty)
    }
}

@Suite("百度 token 缓存与凭据绑定")
struct BaiduTokenOwnershipTests {

    @Test("指纹随任一凭据变化")
    func fingerprintDependsOnBothCredentials() {
        let base = BaiduAccessTokenStore.fingerprint(apiKey: "a", secretKey: "b")
        #expect(base == BaiduAccessTokenStore.fingerprint(apiKey: "a", secretKey: "b"))
        #expect(base != BaiduAccessTokenStore.fingerprint(apiKey: "a2", secretKey: "b"))
        #expect(base != BaiduAccessTokenStore.fingerprint(apiKey: "a", secretKey: "b2"))
        // 分隔符防拼接歧义："ab"+"c" 与 "a"+"bc" 不能撞成同一个指纹。
        #expect(
            BaiduAccessTokenStore.fingerprint(apiKey: "ab", secretKey: "c")
                != BaiduAccessTokenStore.fingerprint(apiKey: "a", secretKey: "bc")
        )
    }

    @Test("缓存属于同一组凭据且未过期时直接复用，不发网络请求")
    func cachedTokenReusedForSameOwner() async throws {
        let secrets = InMemorySecretStore()
        let settings = OCRProviderSettings(
            defaults: UserDefaults(suiteName: "anshot-test-\(UUID().uuidString)")!,
            secrets: secrets
        )
        let expiry = ISO8601DateFormatter().string(from: Date().addingTimeInterval(3600))
        try secrets.setSecret("cached-token", for: "ocr.baiduPPOCR.accessToken")
        try secrets.setSecret(expiry, for: "ocr.baiduPPOCR.accessTokenExpiry")
        try secrets.setSecret(
            BaiduAccessTokenStore.fingerprint(apiKey: "key", secretKey: "secret"),
            for: "ocr.baiduPPOCR.accessTokenOwner"
        )

        let token = try await BaiduAccessTokenStore(settings: settings)
            .token(apiKey: "key", secretKey: "secret")
        #expect(token == "cached-token")
    }

    @Test("作废缓存时一并清掉凭据指纹")
    func invalidateClearsOwner() throws {
        let secrets = InMemorySecretStore()
        let settings = OCRProviderSettings(
            defaults: UserDefaults(suiteName: "anshot-test-\(UUID().uuidString)")!,
            secrets: secrets
        )
        try secrets.setSecret("owner", for: "ocr.baiduPPOCR.accessTokenOwner")
        BaiduAccessTokenStore(settings: settings).invalidate()
        #expect(secrets.secret(for: "ocr.baiduPPOCR.accessTokenOwner") == nil)
    }
}
