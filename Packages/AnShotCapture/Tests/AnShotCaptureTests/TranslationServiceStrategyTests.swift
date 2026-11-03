//
//  TranslationServiceStrategyTests.swift
//  AnShotCaptureTests
//
//  翻译策略与降级链（M3-3 修复）。
//
//  这里测的是本次修复真正引入的行为差异，而不是把实现再念一遍：
//
//  * `.automatic` 允许「云端优先、本机兜底」，且兜底**只在云端一行都没翻出来时**
//    发生（部分成功不重翻：那会把已经翻好的行换成另一套译文）。
//  * 显式选择**绝不降级**——本机不外发、云端不偷懒回本机。
//
//  「有没有回落」只有调用记录能证明：结果里看不出本机到底被碰过没有，
//  所以这批用例全部用假 provider 记下调用顺序，既快又不碰网络与系统语言包。
//

import Foundation
import Testing

import AnShotCore

@testable import AnShotCapture

/// 内存密钥存储：测试不落盘，也不碰用户真实的 secrets.json。
private final class InMemorySecretStore: SecretStoring, @unchecked Sendable {

    private var values: [String: String] = [:]
    private let lock = NSLock()

    func secret(for account: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return values[account]
    }

    func setSecret(_ value: String?, for account: String) throws {
        lock.lock()
        defer { lock.unlock() }
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmed, !trimmed.isEmpty {
            values[account] = trimmed
        } else {
            values[account] = nil
        }
    }

    func removeSecret(for account: String) throws {
        lock.lock()
        defer { lock.unlock() }
        values[account] = nil
    }
}

/// 固定的假 provider：`translated` 为 nil 表示整段失败（全部保留原文）。
private struct StubProvider: TranslationProvider {

    let kind: TranslationProviderKind
    let translated: String?

    func translate(
        _ lines: [OCRTextLine],
        from source: String?,
        to target: String
    ) async -> TranslationResult {
        TranslationAligner.align(
            lines: lines,
            translations: lines.map { _ in translated },
            sourceLanguage: source ?? "",
            targetLanguage: target
        )
    }
}

/// 记录 provider 的调用顺序。
private final class CallRecorder: @unchecked Sendable {

    private var storage: [TranslationProviderKind] = []
    private let lock = NSLock()

    var calls: [TranslationProviderKind] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func record(_ kind: TranslationProviderKind) {
        lock.lock()
        storage.append(kind)
        lock.unlock()
    }
}

@Suite("TranslationService 策略")
struct TranslationServiceStrategyTests {

    private func line(_ text: String) -> OCRTextLine {
        OCRTextLine(text: text, candidates: [], confidence: 1, boundingBox: .zero)
    }

    private func sampleLines() -> [OCRTextLine] {
        [line("你好，世界"), line("今天天气很好")]
    }

    /// 一套隔离的设置：独立 UserDefaults suite + 内存密钥存储。
    private func makeSettings(
        strategy: TranslationStrategy,
        cloud: TranslationProviderKind = .openAICompatible,
        cloudKey: String? = "sk-test"
    ) -> TranslationProviderSettings {
        let defaults = UserDefaults(suiteName: "anshot.tests.translation.\(UUID().uuidString)") ?? .standard
        let settings = TranslationProviderSettings(defaults: defaults, secrets: InMemorySecretStore())
        settings.selectedStrategy = strategy
        settings.preferredCloudKind = cloud
        if let cloudKey {
            try? settings.save(TranslationProviderConfig(apiKey: cloudKey), for: cloud)
        }
        return settings
    }

    private func makeService(
        settings: TranslationProviderSettings,
        recorder: CallRecorder,
        cloudSucceeds: Bool,
        localSucceeds: Bool = true
    ) -> TranslationService {
        TranslationService(settings: settings) { kind, _ in
            recorder.record(kind)
            let succeeds = kind == .appleTranslation ? localSucceeds : cloudSucceeds
            return StubProvider(kind: kind, translated: succeeds ? "译文-\(kind.rawValue)" : nil)
        }
    }

    // MARK: - 自动模式

    @Test("取消云端请求后，不得再启动本机兜底")
    func cancelledCloudDoesNotStartFallback() async {
        let settings = makeSettings(strategy: .automatic)
        let recorder = CallRecorder()
        let gate = TranslationRequestGate()
        let service = TranslationService(settings: settings) { kind, _ in
            recorder.record(kind)
            return GatedTranslationProvider(kind: kind, gate: gate)
        }
        let task = Task {
            await service.translate(lines: sampleLines(), source: "zh-Hans", target: "en-US")
        }
        await gate.waitUntilStarted()
        task.cancel()
        await gate.release()
        _ = await task.value
        #expect(recorder.calls == [.openAICompatible])
    }

    @Test("已经取消的翻译请求不创建 provider")
    func alreadyCancelledRequestDoesNoWork() async {
        let recorder = CallRecorder()
        let service = makeService(settings: makeSettings(strategy: .automatic),
                                  recorder: recorder, cloudSucceeds: true)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await service.translate(lines: sampleLines(), source: "zh-Hans", target: "en-US")
        }
        let result = await task.value
        #expect(recorder.calls.isEmpty)
        #expect(result.isEntirelyUntranslated)
    }

    @Test("自动模式：云端给出译文时不再碰本机")
    func automaticPrefersCloud() async {
        let settings = makeSettings(strategy: .automatic)
        let recorder = CallRecorder()
        let service = makeService(settings: settings, recorder: recorder, cloudSucceeds: true)

        let result = await service.translate(lines: sampleLines(), source: "zh-Hans", target: "en-US")

        #expect(recorder.calls == [.openAICompatible])
        #expect(result.translatedCount == sampleLines().count)
    }

    @Test("自动模式：云端一行都没翻出来时回落到本机")
    func automaticFallsBackToLocal() async {
        let settings = makeSettings(strategy: .automatic)
        let recorder = CallRecorder()
        let service = makeService(settings: settings, recorder: recorder, cloudSucceeds: false)

        let result = await service.translate(lines: sampleLines(), source: "zh-Hans", target: "en-US")

        #expect(recorder.calls == [.openAICompatible, .appleTranslation])
        #expect(result.segments.first?.translatedText == "译文-appleTranslation")
    }

    @Test("自动模式：首选云端没有密钥时直接用本机，不白跑一次请求")
    func automaticSkipsUnconfiguredCloud() async {
        let settings = makeSettings(strategy: .automatic, cloudKey: nil)
        let recorder = CallRecorder()
        let service = makeService(settings: settings, recorder: recorder, cloudSucceeds: true)

        _ = await service.translate(lines: sampleLines(), source: "zh-Hans", target: "en-US")

        #expect(recorder.calls == [.appleTranslation])
    }

    @Test("自动模式用的是设置里选定的那个云端，而不是固定某一个")
    func automaticUsesPreferredCloud() async {
        let settings = makeSettings(strategy: .automatic, cloud: .claude)
        let recorder = CallRecorder()
        let service = makeService(settings: settings, recorder: recorder, cloudSucceeds: true)

        _ = await service.translate(lines: sampleLines(), source: "zh-Hans", target: "en-US")

        #expect(recorder.calls == [.claude])
    }

    // MARK: - 显式策略：绝不降级

    @Test("显式选择云端时不降级到本机")
    func explicitCloudNeverFallsBack() async {
        let settings = makeSettings(strategy: .openAICompatible)
        let recorder = CallRecorder()
        let service = makeService(settings: settings, recorder: recorder, cloudSucceeds: false)

        let result = await service.translate(lines: sampleLines(), source: "zh-Hans", target: "en-US")

        #expect(recorder.calls == [.openAICompatible], "显式选云端就该只用云端")
        #expect(result.isEntirelyUntranslated)
    }

    @Test("显式选择本机时绝不外发：本机翻不出来也不碰云端")
    func explicitLocalNeverEscalates() async {
        let settings = makeSettings(strategy: .appleTranslation, cloudKey: "sk-test")
        let recorder = CallRecorder()
        let service = makeService(
            settings: settings,
            recorder: recorder,
            cloudSucceeds: true,
            localSucceeds: false
        )

        let result = await service.translate(lines: sampleLines(), source: "zh-Hans", target: "en-US")

        #expect(recorder.calls == [.appleTranslation], "用户选本机就是不想外发，配了密钥也不许偷用")
        #expect(result.isEntirelyUntranslated)
    }

    // MARK: - 可用性

    @Test("同语言被判为「无需翻译」，而不是去问系统要一个「不支持」")
    func sameLanguageIsNotUnsupported() async {
        let settings = makeSettings(strategy: .automatic)
        let service = makeService(settings: settings, recorder: CallRecorder(), cloudSucceeds: true)

        let availability = await service.availability(source: "en", target: "en-US")

        #expect(availability == .sameAsTarget(language: "en-US"))
        #expect(availability.explanation.contains("无需翻译"))
    }

    @Test("源语言未判定时不会被报成「语言对不支持」")
    func unknownSourceIsNotUnsupported() async {
        let settings = makeSettings(strategy: .automatic)
        let service = makeService(settings: settings, recorder: CallRecorder(), cloudSucceeds: true)

        let availability = await service.availability(source: nil, target: "en-US")

        #expect(availability.isAvailable, "检测失败是我们自己的限制，不该说成系统不支持")
    }

    @Test("显式云端缺密钥时报告的是「没配置」而不是「不可用」")
    func explicitCloudWithoutKeyIsNotConfigured() async {
        let settings = makeSettings(strategy: .claude, cloud: .claude, cloudKey: nil)
        let service = makeService(settings: settings, recorder: CallRecorder(), cloudSucceeds: true)

        let availability = await service.availability(source: "zh-Hans", target: "en-US")

        #expect(availability == .notConfigured(provider: TranslationProviderKind.claude.displayName))
    }

    @Test("自动模式在云端已配置时不再去查系统（本机不构成瓶颈）")
    func automaticAvailabilitySkipsLocalGate() async {
        let settings = makeSettings(strategy: .automatic)
        let service = makeService(settings: settings, recorder: CallRecorder(), cloudSucceeds: true)

        let availability = await service.availability(source: "ja-JP", target: "en-US")

        #expect(availability.isAvailable)
    }

    @Test("空输入不算「全部未翻译」，也不该发起任何调用")
    func emptyInputDoesNotCallAnything() async {
        let settings = makeSettings(strategy: .automatic)
        let recorder = CallRecorder()
        let service = makeService(settings: settings, recorder: recorder, cloudSucceeds: true)

        let result = await service.translate(lines: [], source: "zh-Hans", target: "en-US")

        #expect(result.segments.isEmpty)
        #expect(result.isEntirelyUntranslated == false)
        #expect(recorder.calls.isEmpty)
    }
}

private struct GatedTranslationProvider: TranslationProvider {
    let kind: TranslationProviderKind
    let gate: TranslationRequestGate

    func translate(_ lines: [OCRTextLine], from source: String?, to target: String) async -> TranslationResult {
        if kind != .appleTranslation { await gate.waitForRelease() }
        return TranslationAligner.align(lines: lines, translations: lines.map { _ in nil },
                                       sourceLanguage: source ?? "", targetLanguage: target)
    }
}

private actor TranslationRequestGate {
    private var started = false
    private var released = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func waitForRelease() async {
        started = true
        for waiter in startWaiters { waiter.resume() }
        startWaiters.removeAll()
        if released { return }
        await withCheckedContinuation { releaseWaiter = $0 }
    }

    func release() {
        released = true
        releaseWaiter?.resume()
        releaseWaiter = nil
    }
}

@Suite("TranslationProviderSettings 策略持久化")
struct TranslationProviderSettingsStrategyTests {

    private func makeSettings() -> (TranslationProviderSettings, UserDefaults) {
        let defaults = UserDefaults(suiteName: "anshot.tests.translation.settings.\(UUID().uuidString)") ?? .standard
        let settings = TranslationProviderSettings(defaults: defaults, secrets: InMemorySecretStore())
        return (settings, defaults)
    }

    @Test("默认是自动策略，首选云端是默认云端")
    func defaultsToAutomatic() {
        let (settings, _) = makeSettings()

        #expect(settings.selectedStrategy == .automatic)
        #expect(settings.preferredCloudKind == TranslationStrategy.defaultCloudKind)
    }

    @Test("旧配置（存的是 provider rawValue）零迁移直接解析")
    func legacySelectionStillReads() {
        let (settings, defaults) = makeSettings()

        defaults.set("claude", forKey: TranslationProviderSettings.selectedStrategyKey)
        #expect(settings.selectedStrategy == .claude)

        defaults.set("appleTranslation", forKey: TranslationProviderSettings.selectedStrategyKey)
        #expect(settings.selectedStrategy == .appleTranslation)
    }

    @Test("首选云端写入脏值（含本机）时回落到默认")
    func preferredCloudRejectsLocalKind() {
        let (settings, defaults) = makeSettings()

        defaults.set("appleTranslation", forKey: TranslationProviderSettings.preferredCloudKey)
        #expect(settings.preferredCloudKind == TranslationStrategy.defaultCloudKind)

        defaults.set("不存在的值", forKey: TranslationProviderSettings.preferredCloudKey)
        #expect(settings.preferredCloudKind == TranslationStrategy.defaultCloudKind)
    }

    @Test("首选云端能正常读写云端 provider")
    func preferredCloudRoundTrips() {
        let (settings, _) = makeSettings()

        settings.preferredCloudKind = .claude
        #expect(settings.preferredCloudKind == .claude)

        settings.preferredCloudKind = .openAICompatible
        #expect(settings.preferredCloudKind == .openAICompatible)
    }
}
