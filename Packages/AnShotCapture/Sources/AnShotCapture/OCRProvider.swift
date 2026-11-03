//
//  OCRProvider.swift
//  AnShotCapture
//
//  文字识别提供者协议，以及 Apple Vision 的实现
//  （契约见 docs/model-providers/model.md §3）。
//
//  ── 为什么这里是「适配器」而不是把 TextRecognizer 改名 ──────────
//
//  `TextRecognizer` 是 Vision 的具体调用：怎么配请求、怎么转坐标，
//  都在它那里，而且诊断 `-diagnoseOCR` 直接测它——测的就是坐标翻转这类
//  框架细节。把协议与「用 Vision 实现协议」分成两层，
//  改协议不会动到那 11 条断言所锚定的代码。
//

import AnShotCore
import CoreGraphics
import Foundation

/// 文字识别提供者。
///
/// 实现必须是 `Sendable`：识别会被放到线程池里执行，不能携带 UI 状态。
/// 实现**不得**自行做 provider 回退——失败就抛错，由上层决定怎么办。
public protocol OCRProvider: Sendable {

    /// 提供者身份。
    var kind: OCRProviderKind { get }

    /// 该实现产出的坐标能力。返回结果的 `coordinateCapability` 必须与它一致。
    var coordinateCapability: OCRCoordinateCapability { get }

    /// 识别图像中的文字。
    func recognize(in image: CGImage) async throws -> OCRResult
}

/// 需要发 HTTP 请求的 provider。
///
/// 存在的理由：请求格式（鉴权头、body 结构、图片编码）是**外部契约**的一部分
///（model.md §5），而它的正确性只能靠真实往返才能完全确认。
/// 把「组装请求」单独暴露出来，诊断就能在**不发网络请求**的前提下断言格式，
/// 从而把「格式错」与「密钥错 / 网络不通」两类问题分开。
public protocol HTTPOCRProvider: OCRProvider {

    /// 组装本次识别将要发送的请求（**不会真的发送**）。
    func makeRequest(in image: CGImage) throws -> URLRequest
}

/// Apple Vision：本机识别，返回精确文本框。
public struct AppleVisionOCRProvider: OCRProvider {

    public init() {}

    public var kind: OCRProviderKind { .appleVision }

    public var coordinateCapability: OCRCoordinateCapability { .precise }

    public func recognize(in image: CGImage) async throws -> OCRResult {
        // 直接委托：识别级别、语言矫正、自动语言检测、坐标转换全在 TextRecognizer，
        // 这里不做任何二次加工，保证改造前后逐字段一致。
        try await TextRecognizer.recognize(in: image)
    }
}
