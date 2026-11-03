//
//  OCRService.swift
//  AnShotCapture
//
//  文字识别的统一入口（契约见 docs/model-providers/model.md §6.1）。
//
//  ── 它是「选择器」，不是「降级链」 ──────────────────────────
//
//  这里只做一件事：读当前选中的 provider，把活交给它。
//  **没有任何回退逻辑**——云端失败不会改用 Vision，Vision 识别为空也不会
//  自动转云端。两处都是刻意的：
//
//  * 用户选云端，就该看到云端的真实失败原因（密钥错 / 超时 / 限流），
//    而不是一份来源不明、看起来「成功了」的结果；
//  * 用户选本机，就意味着他不想让截图离开这台机器；
//    因为「识别结果为空」而偷偷上传，是对这个选择的直接背叛。
//
//  ── 配置在识别开始时读一次 ────────────────────────────────
//
//  每次 `recognize` 读一份配置快照。这样「改完设置立刻生效」与
//  「一次识别中途配置不会被改」同时成立。
//

import AnShotCore
import CoreGraphics
import Foundation

/// 文字识别入口。
///
/// `Sendable`：只持有一份线程安全的配置读取器，没有可变状态，
/// 因此可以安全地被并发调用（诊断、设置界面的「测试连接」与截图流程
/// 都可能在各自的任务里用它）。
public final class OCRService: Sendable {

    private let settings: OCRProviderSettings

    public init(settings: OCRProviderSettings = OCRProviderSettings()) {
        self.settings = settings
    }

    /// 当前生效的 provider。
    public var selectedKind: OCRProviderKind { settings.selectedKind }

    /// 识别图像中的文字。
    ///
    /// - Throws: `OCRProviderFailure`。未配置密钥的云端 provider 会在发请求前失败。
    public func recognize(in image: CGImage) async throws -> OCRResult {
        let kind = settings.selectedKind

        // 提前挡一次：拿空密钥去发请求只会换回一个 401，
        // 报错内容还不如直接说「未配置 API Key」清楚。
        guard settings.isConfigured(kind) else {
            throw OCRProviderFailure.missingAPIKey
        }

        let config = settings.config(for: kind)
        switch kind {
        case .appleVision:
            return try await AppleVisionOCRProvider().recognize(in: image)
        case .openAICompatible:
            return try await OpenAICompatibleOCRProvider(config: config).recognize(in: image)
        case .claude:
            return try await ClaudeOCRProvider(config: config).recognize(in: image)
        case .baiduPPOCR:
            return try await BaiduPPOCRProvider(config: config, settings: settings).recognize(in: image)
        }
    }
}
