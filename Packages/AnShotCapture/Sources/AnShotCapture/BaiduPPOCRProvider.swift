//
//  BaiduPPOCRProvider.swift
//  AnShotCapture
//
//  百度智能云 PP-OCRv6（`pp_ocrv5` 接口）。契约见 docs/model-providers/model.md §5.6。
//
//  ── 它与其他云端 provider 的三个不同点 ─────────────────────
//
//  1. **两个凭据换一个 token**：百度用 API Key + Secret Key 换 `access_token`
//     （30 天有效），识别请求本身只带 token。所以这里多一层 token 缓存，
//     并且必须处理「缓存里的 token 已失效」——那是这类服务最常见的失败。
//  2. **不是 JSON 请求体**：`application/x-www-form-urlencoded`，
//     图片是 base64 再 urlencode 之后的 `image` 字段。
//  3. **返回真实坐标与置信度**：`rec_boxes` 是 `[x_min, y_min, x_max, y_max]`
//     的像素坐标、左上角原点——与核心 `PixelRect` 契约同构。因此这个 provider
//     的坐标能力是 `.precise`，是现有云端 provider 里唯一能补齐坐标短板的。
//

import AnShotCore
import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

// MARK: - access_token

/// access_token 的缓存与换取。
///
/// 缓存它是必要的：token 30 天有效，每次识别都换一次会让请求数与配额开销翻倍。
/// 缓存放**密钥存储**而不是 UserDefaults——它不是用户填的密钥，但性质相同，
/// 散落在明文偏好里就等于把凭据降级了。
struct BaiduAccessTokenStore: Sendable {

    private static let tokenAccount = "ocr.baiduPPOCR.accessToken"
    private static let expiryAccount = "ocr.baiduPPOCR.accessTokenExpiry"

    /// 换取该 token 所用凭据的指纹。
    ///
    /// 缓存必须与凭据绑定：用户在设置里换了 Key/Secret 之后，旧 token 仍在有效期内
    /// （最长 30 天），只看有效期就会继续拿旧账号的 token 发请求——计费落在旧账号上，
    /// 新填的凭据形同没生效，而且没有任何报错能让用户察觉。
    private static let ownerAccount = "ocr.baiduPPOCR.accessTokenOwner"

    /// token 失效时百度返回的错误码：110 = 无效，111 = 已过期。
    static let invalidTokenCodes: Set<Int> = [110, 111]

    let settings: OCRProviderSettings

    /// 取一个可用 token；缓存仍有效时直接用。
    ///
    /// - Parameter forceRefresh: 忽略缓存强制换取，用于「服务端说 token 失效」之后的重试。
    func token(apiKey: String, secretKey: String, forceRefresh: Bool = false) async throws -> String {
        let owner = Self.fingerprint(apiKey: apiKey, secretKey: secretKey)
        if !forceRefresh {
            let cached = settings.storedSecret(for: Self.tokenAccount) ?? ""
            let expiryText = settings.storedSecret(for: Self.expiryAccount) ?? ""
            let cachedOwner = settings.storedSecret(for: Self.ownerAccount) ?? ""
            if !cached.isEmpty,
               cachedOwner == owner,
               let expiry = ISO8601DateFormatter().date(from: expiryText),
               expiry > Date() {
                return cached
            }
        }

        let fetched = try await fetch(apiKey: apiKey, secretKey: secretKey)
        // 提前 1 小时当作过期：否则容易卡在边界上换回一个莫名其妙的 110。
        let expiry = Date().addingTimeInterval(max(fetched.expiresIn - 3600, 60))
        try? settings.storeSecret(fetched.value, for: Self.tokenAccount)
        try? settings.storeSecret(ISO8601DateFormatter().string(from: expiry), for: Self.expiryAccount)
        try? settings.storeSecret(owner, for: Self.ownerAccount)
        return fetched.value
    }

    /// 丢掉缓存。token 被服务端拒绝时调用。
    func invalidate() {
        try? settings.storeSecret(nil, for: Self.tokenAccount)
        try? settings.storeSecret(nil, for: Self.expiryAccount)
        try? settings.storeSecret(nil, for: Self.ownerAccount)
    }

    /// 凭据指纹：只存哈希，不在缓存条目里再放一份明文凭据。
    static func fingerprint(apiKey: String, secretKey: String) -> String {
        let digest = SHA256.hash(data: Data("\(apiKey)\n\(secretKey)".utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func fetch(
        apiKey: String,
        secretKey: String
    ) async throws -> (value: String, expiresIn: Double) {
        var components = URLComponents(string: "https://aip.baidubce.com/oauth/2.0/token")
        components?.queryItems = [
            URLQueryItem(name: "grant_type", value: "client_credentials"),
            URLQueryItem(name: "client_id", value: apiKey),
            URLQueryItem(name: "client_secret", value: secretKey),
        ]
        guard let url = components?.url else {
            throw OCRProviderFailure.badEndpoint
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw OCRProviderFailure.badResponse
        }
        guard (200 ..< 300).contains(http.statusCode) else {
            throw OCRProviderFailure.http(
                code: http.statusCode,
                body: String(decoding: data.prefix(600), as: UTF8.self)
            )
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw OCRProviderFailure.badResponse
        }
        // 换取失败时百度返回 200 + error / error_description，而不是非 2xx。
        if let error = json["error"] as? String {
            let detail = json["error_description"] as? String ?? error
            throw OCRProviderFailure.serviceError(code: -1, message: "获取 access_token 失败：\(detail)")
        }
        guard let token = json["access_token"] as? String, !token.isEmpty else {
            throw OCRProviderFailure.badResponse
        }
        return (token, (json["expires_in"] as? Double) ?? 2_592_000)
    }
}

// MARK: - Provider

/// 百度智能云 PP-OCRv6。
public struct BaiduPPOCRProvider: OCRProvider {

    /// 百度允许的最长边。超过就按比例缩，避免服务端直接拒绝整张图。
    static let maxSide = 8192.0

    private let config: OCRProviderConfig
    private let settings: OCRProviderSettings

    /// - Parameters:
    ///   - config: 本次识别使用的配置快照（含 API Key 与 Secret Key）。
    ///   - settings: 用于读写 access_token 缓存。
    public init(config: OCRProviderConfig, settings: OCRProviderSettings) {
        self.config = config
        self.settings = settings
    }

    public var kind: OCRProviderKind { .baiduPPOCR }

    /// 百度按行返回像素坐标，因此是精确能力。
    public var coordinateCapability: OCRCoordinateCapability { .precise }

    public func recognize(in image: CGImage) async throws -> OCRResult {
        let apiKey = config.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let secretKey = config.secretKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !apiKey.isEmpty, !secretKey.isEmpty else {
            throw OCRProviderFailure.missingAPIKey
        }

        let store = BaiduAccessTokenStore(settings: settings)
        let endpoint = config.resolvedEndpoint(for: .baiduPPOCR)
        let payload = try Self.encode(image: image)
        let imageSize = PixelSize(width: Double(image.width), height: Double(image.height))

        var token = try await store.token(apiKey: apiKey, secretKey: secretKey)
        do {
            let json = try await Self.send(endpoint: endpoint, token: token, payload: payload)
            return try Self.makeResult(json: json, imageSize: imageSize)
        } catch let failure as OCRProviderFailure {
            // token 失效是这类服务的常态（30 天有效期，或服务端提前作废）。
            // 换一个新 token 重试一次，而不是把 110 直接抛给用户去猜。
            guard case let .serviceError(code, _) = failure,
                  BaiduAccessTokenStore.invalidTokenCodes.contains(code) else {
                throw failure
            }
            store.invalidate()
            token = try await store.token(apiKey: apiKey, secretKey: secretKey, forceRefresh: true)
            let json = try await Self.send(endpoint: endpoint, token: token, payload: payload)
            return try Self.makeResult(json: json, imageSize: imageSize)
        }
    }

    // MARK: 请求构造

    /// 图片 → base64。
    ///
    /// 刻意**不做** 2048 降采样：那个阈值是给多模态模型定的（它们的视觉编码器
    /// 分辨率有限，图再大也白搭）。百度是真正的 OCR 引擎，分辨率越高小字越准，
    /// 它的上限是 8192px，所以只在超过上限时才缩。
    ///
    /// 标 `public` 是为诊断验证格式（与 `HTTPOCRProvider.makeRequest` 同一理由）：
    /// 请求/响应的形状是对外契约，不能只靠真实网络请求才能验。
    public static func encode(image: CGImage) throws -> String {
        let prepared = resizeIfNeeded(image, maxSide: maxSide)
        let buffer = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            buffer as CFMutableData,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            throw OCRProviderFailure.unsupportedImage
        }
        CGImageDestinationAddImage(destination, prepared, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw OCRProviderFailure.unsupportedImage
        }
        return (buffer as Data).base64EncodedString()
    }

    /// 抽出来单独放，是因为诊断要验证「超限才缩、不超限原样传」。
    public static func resizeIfNeeded(_ image: CGImage, maxSide: Double) -> CGImage {
        let longest = Double(max(image.width, image.height))
        guard longest > maxSide else { return image }

        let ratio = maxSide / longest
        let width = max(Int((Double(image.width) * ratio).rounded()), 1)
        let height = max(Int((Double(image.height) * ratio).rounded()), 1)
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return image
        }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage() ?? image
    }

    /// 组装识别请求（不含 token 换取）。公开理由同 `encode`。
    public static func makeRequest(endpoint: String, token: String, payload: String) throws -> URLRequest {
        var components = URLComponents(string: endpoint)
        guard components?.scheme != nil else {
            throw OCRProviderFailure.badEndpoint
        }
        components?.queryItems = [URLQueryItem(name: "access_token", value: token)]
        guard let url = components?.url else {
            throw OCRProviderFailure.badEndpoint
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("image=\(formEncode(payload))".utf8)
        return request
    }

    static func send(endpoint: String, token: String, payload: String) async throws -> [String: Any] {
        let request = try makeRequest(endpoint: endpoint, token: token, payload: payload)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw OCRProviderFailure.badResponse
        }
        guard (200 ..< 300).contains(http.statusCode) else {
            throw OCRProviderFailure.http(
                code: http.statusCode,
                body: String(decoding: data.prefix(600), as: UTF8.self)
            )
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw OCRProviderFailure.badResponse
        }
        // 业务错误藏在 200 里：只看状态码会把它当成一次成功的识别。
        if let error = Self.businessError(in: json) {
            throw error
        }
        return json
    }

    /// 取出 200 响应里的业务错误，没有则返回 nil。
    ///
    /// 抽成独立函数是为了能被诊断直接覆盖：网络请求不能进诊断，
    /// 但「这段 JSON 算不算错误」必须能验。
    ///
    /// 不叫 `serviceError`：那是 `OCRProviderFailure` 的 case 名，
    /// 同名类型方法会让调用点读起来像在构造失败而不是在解析响应。
    public static func businessError(in json: [String: Any]) -> OCRProviderFailure? {
        guard let code = json["error_code"] as? Int else { return nil }
        let message = json["error_msg"] as? String ?? "未知错误"
        return .serviceError(code: code, message: message)
    }

    /// 表单百分号编码。base64 里的 `+` `/` `=` 必须转义，
    /// 否则服务端解出的是另一串字节，报错还会指向「图片格式不对」。
    public static func formEncode(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    // MARK: 响应解析

    /// 解析 `page_result[0]` 的三个平行数组。
    ///
    /// `lines` / `probability` / `rec_boxes` **按下标对齐**，这里取最短长度：
    /// 长度不齐时按短的算，总比下标越界崩掉好。置信度缺失时填 1.0——
    /// 但要注意那意味着「没有信息」，不是「百分之百确定」。
    public static func makeResult(json: [String: Any], imageSize: PixelSize) throws -> OCRResult {
        guard let pages = json["page_result"] as? [[String: Any]],
              let first = pages.first else {
            throw OCRProviderFailure.badResponse
        }

        let texts = (first["lines"] as? [String]) ?? []
        let probabilities = (first["probability"] as? [Double]) ?? []
        let boxes = (first["rec_boxes"] as? [[Int]]) ?? []

        let count = min(texts.count, boxes.count)
        guard count > 0 else {
            throw OCRProviderFailure.badResponse
        }

        var lines: [OCRTextLine] = []
        for index in 0 ..< count {
            let text = texts[index].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            lines.append(
                OCRTextLine(
                    text: text,
                    // 百度不返回备选文本。
                    candidates: [],
                    confidence: index < probabilities.count ? probabilities[index] : 1.0,
                    boundingBox: makeBox(boxes[index])
                )
            )
        }

        // 保留服务端顺序，不重排：百度按阅读顺序返回，而重排需要一套
        // 「什么算同一行」的判定，那属于翻译对齐的活（见 OCRResult.readingOrder）。
        return OCRResult(
            lines: lines,
            imagePixelSize: imageSize,
            coordinateCapability: .precise
        )
    }

    /// `[x_min, y_min, x_max, y_max]` → `PixelRect`。
    ///
    /// 百度的坐标系是像素、左上角原点，与核心契约一致，不需要任何翻转。
    public static func makeBox(_ box: [Int]) -> PixelRect {
        guard box.count == 4 else { return .zero }
        let xMin = Double(box[0])
        let yMin = Double(box[1])
        let xMax = Double(box[2])
        let yMax = Double(box[3])
        return PixelRect(
            origin: PixelPoint(x: xMin, y: yMin),
            size: PixelSize(width: max(xMax - xMin, 0), height: max(yMax - yMin, 0))
        )
    }
}
