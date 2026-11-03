//
//  CloudOCRProvider.swift
//  AnShotCapture
//
//  云端文字识别 provider（契约见 docs/model-providers/model.md §2.3 / §5）。
//
//  ── 为什么这些 provider 只产出 `unavailable` 坐标 ────────────
//
//  多模态模型返回的是一段自然语言文本，不是文本框。让它顺带返回坐标
//  （「请给出 bbox」）在一些模型上确实能给，但：
//
//  * 不同模型给的坐标系不一致（归一化 / 像素 / 左上 / 左下都出现过）；
//  * 同一次对话里同一行的坐标也可能前后矛盾；
//  * 而下游的 `TranslationSegment` 与 `OCRTextLine` 是**按数量一一对应**的，
//    坐标错一位就会让译文配错图上的位置。
//
//  与其产出一份看起来有、实际上不可信的位置数据，不如明确说「没有」。
//  需要坐标的场景继续用 Apple Vision。这也是契约把 `coordinateCapability`
//  做成显式字段的原因（见 AnShotCore/OCRProvider.swift 的文件头）。
//
//  ── 不做回退 ──────────────────────────────────────────────
//
//  这里任何失败都原样抛出，**不**偷偷改用 Vision。
//  用户选择了云端，就应该知道云端失败是什么原因（密钥错 / 超时 / 限流），
//  而不是拿到一份来源不明的结果。
//

import AnShotCore
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// MARK: - 错误

/// provider 的失败原因。
public enum OCRProviderFailure: Error, LocalizedError, Equatable {

    /// 未配置 API Key。
    case missingAPIKey

    /// endpoint 不是合法 URL。
    case badEndpoint

    /// HTTP 状态码非 2xx。
    case http(code: Int, body: String)

    /// 响应体无法解析出文本。
    case badResponse

    /// 响应体是模型退化产物（重复 token 循环），详见 `OCRTextSanity`。
    case degenerateOutput

    /// 服务端在 200 响应里返回的业务错误。
    ///
    /// 百度把「token 失效 / 额度用尽 / 图片超限」都放在 200 的 `error_code` 里，
    /// 只看 HTTP 状态码会把这些全部当成识别成功。
    case serviceError(code: Int, message: String)

    /// 图像无法编码为 PNG。
    case unsupportedImage

    /// Keychain 操作失败（`OSStatus`）。
    case keychain(Int32)

    public var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "未配置 API Key"
        case .badEndpoint:
            return "Endpoint 无效"
        case let .http(code, body):
            let detail = body.isEmpty ? "" : " — \(body)"
            return "HTTP \(code)\(detail)"
        case .badResponse:
            return "响应格式无法解析"
        case .degenerateOutput:
            return "云端返回的内容异常（疑似模型重复输出），请更换识别模型后重试"
        case let .serviceError(code, message):
            return "服务返回错误 \(code)：\(message)"
        case .unsupportedImage:
            return "图像无法编码"
        case let .keychain(status):
            return "Keychain 操作失败（\(status)）"
        }
    }
}

// MARK: - 提示词

/// OCR 提示词。
///
/// **改动这里等于改契约**（model.md §5.3）：换一行提示词，模型返回的切行
/// 方式、标点保留程度、甚至是否夹带解释都可能变。要改就同步改文档。
enum OCRPrompt {

    /// 通用多模态模型的系统提示词。
    static let generalSystem = """
    You are a precise OCR engine. Extract every piece of visible text from the image.

    Rules:
    1. Output only the recognized text, one line per text line, in natural reading order.
    2. Do not add explanations, labels, translations, or Markdown fences.
    3. Preserve the original characters exactly, including punctuation and numbers.
    4. If the image contains no text, output nothing.
    """

    static let generalUser = "Extract all text from this image."

    /// DeepSeek-OCR 的官方指令。
    ///
    /// **`<image>` 占位符不能省**，指令也必须用官方原话——
    /// 这条不是从文档抄来的猜测，是实测结论（硅基流动 `deepseek-ai/DeepSeek-OCR`，
    /// 同一张 4 行中英文测试图）：
    ///
    /// | 提示词 | 结果 |
    /// | --- | --- |
    /// | 通用英文提示词 | `}` |
    /// | `Free OCR.` | 8191 个 `}` |
    /// | `<image>\nFree OCR.` | **4 行全部正确** |
    /// | `<\|grounding\|>Convert the document to markdown.` | `}` |
    /// | `<\|grounding\|>OCR this image.` | 乱码 + 未解析的 `<\|box_start\|>` |
    /// | 中文指令「识别图片中的所有文字」 | `}` |
    ///
    /// 两个反直觉之处：图片明明已经通过 `image_url` 传了，**文本里仍要有
    /// `<image>` 标记**（模型靠它对齐视觉输入的位置）；而看起来更「正规」的
    /// grounding 指令反而不如这一句朴素的有效。
    static let deepSeekOCRUser = "<image>\nFree OCR."

    /// 按模型挑提示词。
    ///
    /// 专用 OCR 模型不是通用多模态模型：它们按训练时那套固定指令理解输入，
    /// 喂通用提示词只会得到垃圾。新增这类模型时，在这里加一条分支即可。
    static func resolve(model: String) -> (system: String?, user: String) {
        let normalized = model.lowercased()
        if normalized.contains("deepseek-ocr") {
            // 不带 system：专用模型的训练输入里没有 system 段，
            // 多给一段反而可能干扰它识别的格式。
            return (nil, deepSeekOCRUser)
        }
        return (generalSystem, generalUser)
    }
}

// MARK: - 图像编码

/// 把 `CGImage` 编码成可以放进请求体的 PNG。
enum OCRImageEncoder {

    /// 最长边上限。
    ///
    /// 截图可能是 4K 以上，base64 后体积再翻 1.33 倍，既慢又容易被服务端拒绝。
    /// 2048 对文字识别足够——模型看的是字形，不是像素级纹理。
    static let maxSide: CGFloat = 2048

    /// 编码为 PNG，超过上限时先等比降采样。
    static func pngData(from image: CGImage, maxSide: CGFloat = maxSide) -> Data? {
        guard let prepared = downsampled(image, maxSide: maxSide) else { return nil }

        let buffer = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            buffer,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            return nil
        }
        CGImageDestinationAddImage(destination, prepared, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return buffer as Data
    }

    /// 等比降采样；未超限时原样返回。
    private static func downsampled(_ image: CGImage, maxSide: CGFloat) -> CGImage? {
        let width = CGFloat(image.width)
        let height = CGFloat(image.height)
        let longest = max(width, height)
        guard longest > maxSide, longest > 0 else { return image }

        let ratio = maxSide / longest
        let targetWidth = max(1, Int((width * ratio).rounded()))
        let targetHeight = max(1, Int((height * ratio).rounded()))

        guard let context = CGContext(
            data: nil,
            width: targetWidth,
            height: targetHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: image.colorSpace ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight))
        return context.makeImage()
    }
}

// MARK: - 执行流程

/// 云端 provider 的公共执行流程。
///
/// 抽成 enum 而不是协议 extension：若做成内部协议，它的 extension 成员也是
/// internal，而 `OCRProvider` 是 public 协议——public 类型无法用 internal 成员
/// 满足 public 协议要求。与其为了复用几行代码把实现细节提成 public 协议，
/// 不如让两个 provider 各自显式委托到这里。
enum CloudOCRRunner {

    /// 校验配置 → 编码图片 → 组装请求。
    ///
    /// - Parameters:
    ///   - kind: 用于取默认 endpoint / model。
    ///   - config: 已解析的配置（含密钥）。
    ///   - image: 待识别图像。
    ///   - build: 只负责请求体与鉴权头；URL 与超时由这里统一设置。
    static func makeRequest(
        kind: OCRProviderKind,
        config: OCRProviderConfig,
        image: CGImage,
        build: (OCRProviderConfig, String) throws -> URLRequest
    ) throws -> URLRequest {
        let apiKey = config.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !apiKey.isEmpty else { throw OCRProviderFailure.missingAPIKey }

        guard let url = URL(string: config.resolvedEndpoint(for: kind)), url.scheme != nil else {
            throw OCRProviderFailure.badEndpoint
        }

        guard let png = OCRImageEncoder.pngData(from: image) else {
            throw OCRProviderFailure.unsupportedImage
        }

        var request = try build(config, png.base64EncodedString())
        request.url = url
        request.timeoutInterval = 60
        return request
    }

    /// 发请求并装配结果。
    static func run(
        kind: OCRProviderKind,
        request: URLRequest,
        image: CGImage,
        extractText: (Data) throws -> String
    ) async throws -> OCRResult {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw OCRProviderFailure.badResponse
        }
        guard (200 ..< 300).contains(http.statusCode) else {
            let body = String(decoding: data.prefix(600), as: UTF8.self)
            throw OCRProviderFailure.http(code: http.statusCode, body: body)
        }

        let text = try extractText(data)
        // 模型可能「成功」地返回重复垃圾（见 `OCRTextSanity`）：接口层面 HTTP 200、
        // finish_reason=stop，只有内容形态能识破。转成显式失败而非展示给用户。
        guard !OCRTextSanity.looksDegenerate(text) else {
            throw OCRProviderFailure.degenerateOutput
        }
        return OCRTextAssembler.makeResult(
            rawText: text,
            // 坐标系是**原图**的，不是降采样后的：云端不产出坐标，
            // 这里的尺寸只用于让结果自描述（面板显示、诊断输出）。
            imagePixelSize: PixelSize(width: Double(image.width), height: Double(image.height)),
            capability: kind.coordinateCapability
        )
    }
}

// MARK: - OpenAI 兼容

/// 任何 chat-completions 兼容的多模态服务（OpenAI / DeepSeek / 自建网关）。
public struct OpenAICompatibleOCRProvider: HTTPOCRProvider {

    private let config: OCRProviderConfig

    /// - Parameter config: 本次识别使用的配置快照。由 `OCRService` 在每次识别前读一次，
    ///   因此设置改完下次识别就生效；而单次识别中途不会被改动影响。
    public init(config: OCRProviderConfig) {
        self.config = config
    }

    public var kind: OCRProviderKind { .openAICompatible }

    public var coordinateCapability: OCRCoordinateCapability { kind.coordinateCapability }

    public func makeRequest(in image: CGImage) throws -> URLRequest {
        try CloudOCRRunner.makeRequest(
            kind: kind,
            config: config,
            image: image,
            build: Self.build
        )
    }

    public func recognize(in image: CGImage) async throws -> OCRResult {
        let request = try makeRequest(in: image)
        return try await CloudOCRRunner.run(
            kind: kind,
            request: request,
            image: image,
            extractText: Self.extractText
        )
    }

    static func build(config: OCRProviderConfig, pngBase64: String) throws -> URLRequest {
        var request = URLRequest(url: URL(string: "https://invalid.local")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(
            "Bearer \(config.apiKey.trimmingCharacters(in: .whitespacesAndNewlines))",
            forHTTPHeaderField: "Authorization"
        )

        let model = config.resolvedModel(for: .openAICompatible)
        let prompt = OCRPrompt.resolve(model: model)

        var messages: [[String: Any]] = []
        if let system = prompt.system {
            messages.append(["role": "system", "content": system])
        }
        messages.append([
            "role": "user",
            "content": [
                ["type": "text", "text": prompt.user],
                ["type": "image_url", "image_url": ["url": "data:image/png;base64,\(pngBase64)"]],
            ],
        ])

        let body: [String: Any] = [
            "model": model,
            // 识别是确定性任务，不需要发散。
            "temperature": 0,
            "messages": messages,
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    static func extractText(_ data: Data) throws -> String {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw OCRProviderFailure.badResponse
        }
        return content
    }
}

// MARK: - Claude

/// Anthropic Claude Messages API。
public struct ClaudeOCRProvider: HTTPOCRProvider {

    private let config: OCRProviderConfig

    public init(config: OCRProviderConfig) {
        self.config = config
    }

    public var kind: OCRProviderKind { .claude }

    public var coordinateCapability: OCRCoordinateCapability { kind.coordinateCapability }

    public func makeRequest(in image: CGImage) throws -> URLRequest {
        try CloudOCRRunner.makeRequest(
            kind: kind,
            config: config,
            image: image,
            build: Self.build
        )
    }

    public func recognize(in image: CGImage) async throws -> OCRResult {
        let request = try makeRequest(in: image)
        return try await CloudOCRRunner.run(
            kind: kind,
            request: request,
            image: image,
            extractText: Self.extractText
        )
    }

    static func build(config: OCRProviderConfig, pngBase64: String) throws -> URLRequest {
        var request = URLRequest(url: URL(string: "https://invalid.local")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(
            config.apiKey.trimmingCharacters(in: .whitespacesAndNewlines),
            forHTTPHeaderField: "x-api-key"
        )
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")

        let prompt = OCRPrompt.resolve(model: config.resolvedModel(for: .claude))
        var body: [String: Any] = [
            "model": config.resolvedModel(for: .claude),
            "max_tokens": 4096,
            "temperature": 0,
            "messages": [
                [
                    "role": "user",
                    "content": [
                        [
                            "type": "image",
                            "source": [
                                "type": "base64",
                                "media_type": "image/png",
                                // Claude 用裸 base64，没有 data URL 前缀。
                                "data": pngBase64,
                            ],
                        ],
                        ["type": "text", "text": prompt.user],
                    ],
                ],
            ],
        ]
        // 专用模型不带 system 段（理由见 OCRPrompt.resolve）。
        if let system = prompt.system {
            body["system"] = system
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    static func extractText(_ data: Data) throws -> String {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = json["content"] as? [[String: Any]] else {
            throw OCRProviderFailure.badResponse
        }
        // content 是块数组，取所有 text 块拼接：只有第一个块时行为与取首个一致。
        let text = content
            .filter { ($0["type"] as? String) == "text" }
            .compactMap { $0["text"] as? String }
            .joined()
        guard !text.isEmpty else { throw OCRProviderFailure.badResponse }
        return text
    }
}
