//
//  OCRProviderContract.swift
//  AnShotCore
//
//  文字识别的提供者身份与坐标能力（契约见 docs/model-providers/model.md §1）。
//
//  ⚠️ 文件名带 `Contract` 后缀是刻意的：本文件只定义**契约**
//  （提供者身份、坐标能力、文本组装、合理性校验），不含任何实现。
//  实现（协议与 Apple Vision 适配器）在 `AnShotCapture/OCRProvider.swift`。
//  两者曾**同名**，从路径上无法区分，检索 `OCRProvider.swift`
//  必然拿到两处结果、IDE 跳转也存在歧义。
//
//  ── 为什么「坐标能力」要成为契约的一部分 ────────────────────
//
//  `OCRResult` 的每一行都带 `boundingBox`，而下游（翻译按行对齐、
//  结果面板逐行渲染、将来的译文原位替换）都依赖它。
//
//  但**不是每个识别来源都能给出坐标**：Apple Vision 返回真实文本框，
//  云端多模态模型通常只回一段纯文本。如果两者产出同一种 `OCRResult`
//  而不加区分，就会出现「云端结果里那些零矩形被下游当成真实位置」——
//  那是最难查的一类缺陷：不报错，只是位置全错。
//
//  因此把「这份坐标有多可信」显式写进结果，让消费方**必须**先判断能力，
//  才可能误用。
//

import Foundation

/// 文字识别的提供者。
public enum OCRProviderKind: String, Codable, CaseIterable, Sendable {

    /// Apple Vision：本机识别，无网络请求，返回精确文本框。
    case appleVision

    /// 任何 OpenAI chat-completions 兼容的多模态服务。
    case openAICompatible

    /// Anthropic Claude Messages API。
    case claude

    /// 百度智能云 PP-OCRv6（`pp_ocrv5` 接口）。
    ///
    /// 与前两个云端 provider 的关键差别：
    /// - 不用模型名，是固定能力的传统 OCR 服务；
    /// - 用「API Key + Secret Key」两个凭据换取 `access_token`；
    /// - **返回真实文本行坐标与逐行置信度**，因此坐标能力是 `.precise`。
    case baiduPPOCR

    /// 界面展示名。
    public var displayName: String {
        switch self {
        case .appleVision: return "Apple Vision（本机）"
        case .openAICompatible: return "OpenAI 兼容"
        case .claude: return "Claude"
        case .baiduPPOCR: return "百度 PP-OCRv6"
        }
    }

    /// 默认请求地址；空串表示该 provider 不需要地址。
    public var defaultEndpoint: String {
        switch self {
        case .appleVision: return ""
        case .openAICompatible: return "https://api.openai.com/v1/chat/completions"
        case .claude: return "https://api.anthropic.com/v1/messages"
        case .baiduPPOCR: return "https://aip.baidubce.com/rest/2.0/ocr/v1/pp_ocrv5"
        }
    }

    /// 默认模型名；空串表示该 provider 不需要模型。
    public var defaultModel: String {
        switch self {
        case .appleVision: return ""
        case .openAICompatible: return "gpt-4o-mini"
        case .claude: return "claude-3-5-haiku-latest"
        case .baiduPPOCR: return ""
        }
    }

    /// 该 provider 产出的坐标能力。
    public var coordinateCapability: OCRCoordinateCapability {
        switch self {
        case .appleVision: return .precise
        case .openAICompatible, .claude: return .unavailable
        // 百度 OCR 按行返回 `rec_boxes`（像素坐标、左上原点），与核心的
        // `PixelRect` 契约同构，不需要任何换算假设。
        case .baiduPPOCR: return .precise
        }
    }

    /// 是否需要 API Key。Apple Vision 不需要。
    public var requiresAPIKey: Bool { self != .appleVision }

    /// 是否需要额外的 Secret Key。
    ///
    /// 百度 OCR 用「API Key + Secret Key」两个凭据换取 `access_token`。
    /// 刻意用独立属性而不是把两个凭据拼成一个字符串：拼接会把「这里有两个凭据」
    /// 藏进数据格式里，设置界面就无从知道该多显示一个输入框。
    public var requiresSecretKey: Bool { self == .baiduPPOCR }

    /// 是否需要模型名。百度 OCR 是固定能力的传统服务，没有模型可选。
    public var requiresModel: Bool {
        switch self {
        case .appleVision, .baiduPPOCR: return false
        case .openAICompatible, .claude: return true
        }
    }

    /// 是否会把图像发送到本机之外。
    ///
    /// 界面用它决定是否展示隐私提示、以及是否需要首次确认。
    /// 用「不是 appleVision」而不是「有 endpoint」来判断：新增 provider 时
    /// 忘记维护列表只会让它少一次提示，而反过来写会**默认**把数据外发。
    public var sendsImageOffDevice: Bool { self != .appleVision }
}

/// 识别结果里坐标的可信程度。
public enum OCRCoordinateCapability: String, Codable, Equatable, Sendable {

    /// 真实文本框（Apple Vision）。
    case precise

    /// 模型自报的粗略位置。**当前没有 provider 产出这一档**，
    /// 保留它是为了将来接入时下游不必再改一遍判断。
    case estimated

    /// 没有坐标信息。此时每一行的 `boundingBox` 恒为零矩形。
    case unavailable

    /// 坐标是否可直接用于精确对齐。
    public var isPrecise: Bool { self == .precise }

    /// 面向用户的一句话说明（设置界面与诊断共用）。
    public var explanation: String {
        switch self {
        case .precise: return "返回精确文本位置"
        case .estimated: return "位置为模型估算，仅供参考"
        case .unavailable: return "不返回文本位置，仅提供文本与顺序"
        }
    }
}

// MARK: - 文本装配

/// 把纯文本响应装配成 `OCRResult`。
///
/// 放在 Core 而不是某个 provider 里：这是**纯数据规则**（怎么切行、空行怎么办、
/// 没有坐标时填什么），没有半点平台依赖，因此可以被单元测试直接覆盖。
/// 各家 provider 的响应格式不同，但装配规则只有这一份——两边各写一遍，
/// 迟早会出现「一边丢空行、另一边不丢」这种只差一行的分叉。
public enum OCRTextAssembler {

    /// 按行装配。
    ///
    /// 切行规则（契约 §5.5）：
    /// - 按 `\n` 切分，逐行去掉首尾空白，**丢弃空行**；
    /// - 保持响应顺序作为阅读顺序（不多做排序：云端没有坐标，排序无从依据）；
    /// - `boundingBox` 恒为 `.zero`，置信度恒为 1.0，备选恒为空。
    ///
    /// - Parameters:
    ///   - rawText: 模型返回的原始文本。
    ///   - imagePixelSize: 原图像素尺寸（结果的自描述信息）。
    ///   - capability: 这份结果的坐标能力。
    public static func makeResult(
        rawText: String,
        imagePixelSize: PixelSize,
        capability: OCRCoordinateCapability
    ) -> OCRResult {
        let lines = rawText
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .map { text in
                OCRTextLine(
                    text: text,
                    // 不编造数值：云端不返回备选与置信度。
                    candidates: [],
                    confidence: 1.0,
                    // 零矩形 = 「没有位置信息」，而不是「位置在原点」。
                    boundingBox: .zero
                )
            }
        return OCRResult(
            lines: lines,
            imagePixelSize: imagePixelSize,
            coordinateCapability: capability
        )
    }
}

// MARK: - 健全性检查

/// 云端返回文本的健全性检查。
///
/// 存在的理由：专用 OCR 模型的失效方式往往不是报错，而是**输出重复 token**。
/// 实测 `deepseek-ai/DeepSeek-OCR` 在 1380x420 的截图上会返回 HTTP 200、
/// `finish_reason=stop`、内容却是 `0 0 0 0 0 …`；换一张图只回一个 `}`；
/// 接口层面毫无异常，用户却会拿到一屏垃圾并以为识别成功。
/// 因此这里用输出形态兜底，把「看起来像成功」的垃圾转成显式失败。
public enum OCRTextSanity {

    /// 判断文本是否像是模型退化（重复循环）的产物。
    ///
    /// 判定刻意保守，宁可漏报也不误伤正常文本：
    /// - 单一字符占比 ≥ 90%（形如 `}}}}…`，实测模型跑飞时会连输出数千个 `}`）；
    /// - 按空白与逗号切分后，唯一片段占比 ≤ 20% 且片段总数 ≥ 8
    ///   （形如 `0 0 0 0…`、`theta=0.5, theta=0.5, …`）。
    ///
    /// - Parameter text: 模型返回的原始文本。
    /// - Returns: `true` 表示疑似退化输出，调用方应视为失败而非展示。
    public static func looksDegenerate(_ text: String) -> Bool {
        // 去空白后过短的内容没有判断价值（一两行标题也可能是单个字符）。
        let compact = text.filter { !$0.isWhitespace }
        guard compact.count >= 24 else {
            return false
        }

        // 规则一：单一字符压倒性占比。
        if let first = compact.first {
            let sameCount = compact.filter { $0 == first }.count
            if sameCount * 10 >= compact.count * 9 {
                return true
            }
        }

        // 规则二：极少数片段反复出现。
        let pieces = text
            .split(whereSeparator: { $0.isWhitespace || $0 == "," || $0 == "，" })
            .map(String.init)
            .filter { !$0.isEmpty }
        if pieces.count >= 8, Set(pieces).count * 5 <= pieces.count {
            return true
        }

        return false
    }
}
