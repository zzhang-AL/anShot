//
//  AppleTranslationBridge.swift
//  AnShotUI
//
//  macOS 15.0+ SwiftUI `.translationTask` 极薄桥接层。
//
//  ── 架构动机 ──────────────────────────────────────────────────
//
//  Apple 在 macOS 15.0 引入了离线 Translation 框架，但无视图构造器
//  `TranslationSession(installedSource:target:)` 要到 macOS 26.0 才公开；
//  在 macOS 15.0–25.x 上，唯一官方支持的会话入口是 SwiftUI 的 `.translationTask`
//  修饰符，且该修饰符具备系统级语言包下载弹窗能力。
//
//  本文件将极薄的 SwiftUI 宿主严格隔离在 `AnShotUI` 内，通过 `AnShotCapture` 的
//  `AppleTranslationBridgeRegistry` 反向注册执行器，既保持 `AnShotCore`/`AnShotCapture`
//  零 SwiftUI 依赖，又在 macOS 13/14 部署基线下 100% 兼容编译。
//

import AnShotCapture
import AnShotCore
import AppKit
import Foundation

#if canImport(SwiftUI) && canImport(Translation)
import SwiftUI
import Translation
#endif

private let logger = AnShotLog.translation

/// 本机系统翻译桥接引导器。
public enum AppleTranslationBridgeBootstrap {

    /// 在支持 macOS 15.0+ `Translation` 框架的运行环境中注册桥接执行器。
    @MainActor
    public static func installIfSupported() {
        #if canImport(SwiftUI) && canImport(Translation)
        if #available(macOS 15.0, *) {
            AppleTranslationBridgeRegistry.register(AppleTranslationBridge.shared)
            logger.notice("AppleTranslationBridge 已注册（macOS 15.0+ 本机翻译桥接就绪）")
        }
        #endif
    }
}

#if canImport(SwiftUI) && canImport(Translation)
@available(macOS 15.0, *)
private struct TranslationRequestPayload: Sendable {
    let id: UUID
    let lines: [OCRTextLine]
    let sourceIdentifier: String?
    let targetIdentifier: String
}

@available(macOS 15.0, *)
private final class AppleTranslationBridge: AppleTranslationBridgeExecutor, @unchecked Sendable {

    static let shared = AppleTranslationBridge()

    private init() {}

    func translate(
        _ lines: [OCRTextLine],
        from source: String?,
        to target: String
    ) async -> TranslationExecutionResult {
        guard !lines.isEmpty else {
            return TranslationExecutionResult(
                result: TranslationAligner.align(
                    lines: lines,
                    translations: [],
                    sourceLanguage: source ?? "",
                    targetLanguage: target
                )
            )
        }
        return await AppleTranslationHost.shared.translate(lines: lines, source: source, target: target)
    }
}

@available(macOS 15.0, *)
@MainActor
private final class AppleTranslationHost {

    static let shared = AppleTranslationHost()

    private struct PendingRequest {
        let payload: TranslationRequestPayload
        let continuation: CheckedContinuation<TranslationExecutionResult, Never>
    }

    private let viewModel = BridgeViewModel()
    private var hostPanel: NSPanel?
    private var activeRequest: PendingRequest?
    private var queue: [PendingRequest] = []
    private var timeoutTask: Task<Void, Never>?

    private init() {
        viewModel.onExecutionFinished = { [weak self] requestID, execution in
            self?.finishActiveRequest(id: requestID, execution: execution)
        }
    }

    func translate(
        lines: [OCRTextLine],
        source: String?,
        target: String
    ) async -> TranslationExecutionResult {
        await withCheckedContinuation { continuation in
            let payload = TranslationRequestPayload(
                id: UUID(),
                lines: lines,
                sourceIdentifier: source,
                targetIdentifier: target
            )
            queue.append(PendingRequest(payload: payload, continuation: continuation))
            pumpNextIfIdle()
        }
    }

    private func pumpNextIfIdle() {
        guard activeRequest == nil, !queue.isEmpty else { return }
        let request = queue.removeFirst()
        activeRequest = request

        ensureHostPanelVisible()

        let normalizedSource = request.payload.sourceIdentifier?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let sourceLanguage: Locale.Language? = (normalizedSource?.isEmpty == false)
            ? Locale.Language(identifier: normalizedSource!)
            : nil
        let targetLanguage = Locale.Language(identifier: request.payload.targetIdentifier)

        // 先置空再重新配置新任务，确保同语言对连续多次翻译也能稳定触发 `.translationTask`。
        viewModel.activePayload = request.payload
        viewModel.configuration = nil
        let nextConfig = TranslationSession.Configuration(source: sourceLanguage, target: targetLanguage)
        let requestID = request.payload.id
        Task { @MainActor [weak self] in
            guard let self, self.activeRequest?.payload.id == requestID else { return }
            self.viewModel.configuration = nextConfig
        }

        // 兜底超时：防止系统弹窗异常或非窗口化测试环境导致 continuation 永久挂起。
        timeoutTask?.cancel()
        timeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(45))
            guard let self, self.activeRequest?.payload.id == requestID else { return }
            logger.error("AppleTranslationBridge 超时，已降级返回原文")
            self.finishActiveRequest(
                id: requestID,
                execution: Self.fallbackExecution(
                    payload: request.payload,
                    message: "本机系统翻译超时，请确认语言包已下载或稍后重试。"
                )
            )
        }
    }

    private func finishActiveRequest(id: UUID, execution: TranslationExecutionResult) {
        guard let request = activeRequest, request.payload.id == id else { return }
        timeoutTask?.cancel()
        timeoutTask = nil
        activeRequest = nil
        viewModel.activePayload = nil
        viewModel.configuration = nil
        request.continuation.resume(returning: execution)

        if queue.isEmpty {
            hostPanel?.orderOut(nil)
        } else {
            pumpNextIfIdle()
        }
    }

    /// 构造并展示 2×2 透明无边框宿主面板。
    ///
    /// 放在主屏居中位置：若系统需要为本机翻译弹出「下载语言包」弹窗，
    /// 弹窗会锚定在此宿主窗口处，从而自然居中展示给用户。
    private func ensureHostPanelVisible() {
        let panel: NSPanel
        if let existing = hostPanel {
            panel = existing
        } else {
            let created = NSPanel(
                contentRect: CGRect(x: 0, y: 0, width: 2, height: 2),
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            created.isReleasedWhenClosed = false
            created.isOpaque = false
            created.backgroundColor = .clear
            created.alphaValue = 0.01
            created.hasShadow = false
            created.ignoresMouseEvents = true
            created.level = .floating
            created.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
            created.contentView = NSHostingView(rootView: TranslationBridgeView(viewModel: viewModel))
            hostPanel = created
            panel = created
        }

        let visible = NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        panel.setFrameOrigin(CGPoint(x: visible.midX, y: visible.midY))
        panel.orderFrontRegardless()
    }

    nonisolated static func fallbackExecution(
        payload: TranslationRequestPayload,
        message: String
    ) -> TranslationExecutionResult {
        let aligned = TranslationAligner.align(
            lines: payload.lines,
            translations: Array(repeating: nil, count: payload.lines.count),
            sourceLanguage: payload.sourceIdentifier ?? "",
            targetLanguage: payload.targetIdentifier
        )
        return TranslationExecutionResult(result: aligned, errorMessage: message)
    }

    nonisolated static func userFriendlyErrorMessage(for error: Error) -> String {
        let description = error.localizedDescription
        if description.isEmpty {
            return "本机系统翻译失败，请确认对应语言包已下载，或在设置中改用云端翻译。"
        }
        return "本机系统翻译不可用：\(description)"
    }
}

@available(macOS 15.0, *)
@MainActor
private final class BridgeViewModel: ObservableObject {
    @Published var configuration: TranslationSession.Configuration?
    var activePayload: TranslationRequestPayload?
    var onExecutionFinished: ((UUID, TranslationExecutionResult) -> Void)?
}

@available(macOS 15.0, *)
private struct UncheckedTranslationSessionBox: @unchecked Sendable {
    let session: TranslationSession
}

@available(macOS 15.0, *)
private struct TranslationBridgeView: View {
    @ObservedObject var viewModel: BridgeViewModel

    var body: some View {
        Color.clear
            .frame(width: 2, height: 2)
            .translationTask(viewModel.configuration) { session in
                guard let payload = viewModel.activePayload else { return }
                // `AppleTranslationHost` 串行队列保证每个 session 仅由单次任务独占使用，无并发访问竞争。
                let box = UncheckedTranslationSessionBox(session: session)
                let execution = await Self.runTranslation(sessionBox: box, payload: payload)
                viewModel.onExecutionFinished?(payload.id, execution)
            }
    }

    /// 在非主线程隔离上下文内独占消费 `TranslationSession`。
    private nonisolated static func runTranslation(
        sessionBox: UncheckedTranslationSessionBox,
        payload: TranslationRequestPayload
    ) async -> TranslationExecutionResult {
        let session = sessionBox.session
        let requests = payload.lines.enumerated().map { index, line in
            TranslationSession.Request(sourceText: line.text, clientIdentifier: String(index))
        }

        do {
            // 若对应语言包尚未下载，macOS 15 会自动弹出系统级语言包下载确认框。
            try await session.prepareTranslation()
            let responses = try await session.translations(from: requests)

            var translations: [String?] = Array(repeating: nil, count: payload.lines.count)
            var resolvedSource = payload.sourceIdentifier ?? ""
            for response in responses {
                if resolvedSource.isEmpty {
                    resolvedSource = response.sourceLanguage.minimalIdentifier
                }
                if let identifier = response.clientIdentifier,
                   let index = Int(identifier),
                   index >= 0,
                   index < translations.count {
                    translations[index] = response.targetText
                }
            }

            let aligned = TranslationAligner.align(
                lines: payload.lines,
                translations: translations,
                sourceLanguage: resolvedSource,
                targetLanguage: payload.targetIdentifier
            )
            let message: String? = aligned.isEntirelyUntranslated
                ? "本机系统翻译未返回译文，请确认已下载对应语言包。"
                : nil
            return TranslationExecutionResult(result: aligned, errorMessage: message)
        } catch {
            logger.error("AppleTranslationBridge 翻译失败：\(error.localizedDescription, privacy: .public)")
            let reason = AppleTranslationHost.userFriendlyErrorMessage(for: error)
            return AppleTranslationHost.fallbackExecution(payload: payload, message: reason)
        }
    }
}
#endif
