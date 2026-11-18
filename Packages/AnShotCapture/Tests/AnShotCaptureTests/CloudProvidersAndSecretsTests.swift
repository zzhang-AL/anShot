//
//  CloudProvidersAndSecretsTests.swift
//  AnShotCaptureTests
//
//  云端 OCR/翻译解析、HTTPS 校验、百度坐标反缩放与清除缓存、LocalFileSecretStore 加固单测。
//

import AnShotCore
import CoreGraphics
import Foundation
import Testing
@testable import AnShotCapture

@Suite("云端 OCR 与翻译解析")
struct CloudProvidersTests {

    @Test("Endpoint 安全校验强制 HTTPS，仅对本地回环放行 HTTP")
    func endpointSecurityAllowsOnlyHTTPSOrLoopback() throws {
        #expect(try EndpointSecurity.validatedURL(from: "https://api.openai.com/v1/chat/completions").scheme == "https")
        #expect(try EndpointSecurity.validatedURL(from: "http://localhost:8080/v1").host == "localhost")
        #expect(try EndpointSecurity.validatedURL(from: "http://127.0.0.1:11434/api").host == "127.0.0.1")
        #expect(try EndpointSecurity.validatedURL(from: "http://[::1]:8000/v1").scheme == "http")

        for unsafe in [
            "http://api.openai.com/v1",
            "http://example.com:8080/ocr",
            "file:///etc/passwd",
            "ftp://example.com/a",
            "not-a-url"
        ] {
            #expect(throws: OCRProviderFailure.badEndpoint) {
                _ = try EndpointSecurity.validatedURL(from: unsafe)
            }
        }
    }

    @Test("Claude 响应解析过滤 thinking 块，并检测 max_tokens 截断")
    func claudeExtractionHandlesThinkingAndTruncation() throws {
        let thinkingPayload: [String: Any] = [
            "stop_reason": "end_turn",
            "content": [
                ["type": "thinking", "thinking": "Let me think..."],
                ["type": "text", "text": "1. Hello\n2. World"]
            ]
        ]
        let thinkingData = try JSONSerialization.data(withJSONObject: thinkingPayload)
        let extracted = try ClaudeTranslationProvider.extractText(thinkingData)
        #expect(extracted == "1. Hello\n2. World")
        #expect(try ClaudeOCRProvider.extractText(thinkingData) == "1. Hello\n2. World")

        let truncatedPayload: [String: Any] = [
            "stop_reason": "max_tokens",
            "content": [
                ["type": "text", "text": "1. Partial"]
            ]
        ]
        let truncatedData = try JSONSerialization.data(withJSONObject: truncatedPayload)
        #expect(throws: OCRProviderFailure.truncatedResponse) {
            _ = try ClaudeTranslationProvider.extractText(truncatedData)
        }
    }

    @Test("OpenAI 响应解析兼容数组 content，并检测 length 截断")
    func openAIExtractionHandlesArrayContentAndLengthTruncation() throws {
        let arrayPayload: [String: Any] = [
            "choices": [[
                "finish_reason": "stop",
                "message": [
                    "content": [
                        ["type": "reasoning", "text": "skip"],
                        ["type": "text", "text": "Line A"],
                        ["type": "text", "text": "\nLine B"]
                    ]
                ]
            ]]
        ]
        let data = try JSONSerialization.data(withJSONObject: arrayPayload)
        #expect(try OpenAICompatibleOCRProvider.extractText(data) == "Line A\nLine B")
        #expect(try OpenAICompatibleTranslationProvider.extractText(data) == "Line A\nLine B")

        let truncatedPayload: [String: Any] = [
            "choices": [[
                "finish_reason": "length",
                "message": ["content": "partial"]
            ]]
        ]
        let truncatedData = try JSONSerialization.data(withJSONObject: truncatedPayload)
        #expect(throws: OCRProviderFailure.truncatedResponse) {
            _ = try OpenAICompatibleOCRProvider.extractText(truncatedData)
        }
    }

    @Test("TranslationResponseParser 支持显式行标容错对齐，无编号行数不符仍整体降级")
    func parserSupportsIndexedToleranceAndPreservesPlainContract() {
        // 缺第 2 行时第 1、3 行依然对号入座，仅第 2 行保留 nil。
        let partial = TranslationResponseParser.parse("[[1]] Alpha\n[[3]] Gamma", expectedCount: 3)
        #expect(partial == ["Alpha", nil, "Gamma"])

        // 末尾附带额外解释行或超出行号时不破坏有效槽位。
        let extra = TranslationResponseParser.parse("1. First\n2. Second\n3. Extra", expectedCount: 2)
        #expect(extra == ["First", "Second"])

        // 无编号且行数不匹配必须整体降级为全 nil（不猜对齐）。
        let mismatched = TranslationResponseParser.parse("one\ntwo\nthree", expectedCount: 2)
        #expect(mismatched == [nil, nil])

        // 数字开头的正文不误吞。
        let tricky = TranslationResponseParser.parse("2024年营收增长", expectedCount: 1)
        #expect(tricky == ["2024年营收增长"])
    }

    @Test("TranslationService 在云端配置缺失或端点异常时透传 errorMessage")
    func translationServiceExposesCloudFailureMessage() async {
        let defaults = UserDefaults(suiteName: "anshot.tests.trans.err.\(UUID().uuidString)")!
        let secrets = InMemorySecretStore()
        let settings = TranslationProviderSettings(defaults: defaults, secrets: secrets)
        settings.selectedStrategy = .claude
        try? settings.save(
            TranslationProviderConfig(endpoint: "http://insecure.example.com/v1", apiKey: "sk-test"),
            for: .claude
        )

        let service = TranslationService(settings: settings)
        let lines = [OCRTextLine(text: "你好", candidates: [], confidence: 1, boundingBox: .zero)]
        let execution = await service.translateWithDiagnostics(lines: lines, source: "zh-Hans", target: "en-US")

        #expect(execution.result.isEntirelyUntranslated)
        #expect(execution.errorMessage != nil)
        #expect(service.lastErrorMessage == execution.errorMessage)
    }

    @Test("百度 OCR 降采样坐标反缩放、灰度图兼容、表单编码与清除缓存")
    func baiduRescalingAndCacheClearing() throws {
        // 1. 超过 maxSide 的图像按比例缩放并把 rec_boxes 还原回原图坐标。
        let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
        let wideContext = CGContext(
            data: nil, width: 200, height: 100, bitsPerComponent: 8, bytesPerRow: 0,
            space: srgb, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        let wideImage = wideContext.makeImage()!
        let resized = BaiduPPOCRProvider.resizeWithScaleIfNeeded(wideImage, maxSide: 100)
        #expect(resized.image.width == 100)
        #expect(resized.image.height == 50)
        #expect(abs(resized.scaleX - 0.5) < 1e-6)
        #expect(abs(resized.scaleY - 0.5) < 1e-6)

        let json: [String: Any] = [
            "page_result": [[
                "lines": ["Hello"],
                "probability": [0.99],
                "rec_boxes": [[10, 20, 50, 40]]
            ]]
        ]
        let result = try BaiduPPOCRProvider.makeResult(
            json: json,
            imageSize: PixelSize(width: 200, height: 100),
            coordinateScaleX: resized.scaleX,
            coordinateScaleY: resized.scaleY
        )
        let box = try #require(result.lines.first?.boundingBox)
        #expect(abs(box.origin.x - 20) < 1e-6)
        #expect(abs(box.origin.y - 40) < 1e-6)
        #expect(abs(box.size.width - 80) < 1e-6)
        #expect(abs(box.size.height - 40) < 1e-6)

        // 2. 灰度图在降采样画布上不失败。
        let graySpace = CGColorSpaceCreateDeviceGray()
        let grayContext = CGContext(
            data: nil, width: 300, height: 100, bitsPerComponent: 8, bytesPerRow: 0,
            space: graySpace, bitmapInfo: CGImageAlphaInfo.none.rawValue
        )!
        let grayImage = grayContext.makeImage()!
        let grayDownsampled = BaiduPPOCRProvider.resizeWithScaleIfNeeded(grayImage, maxSide: 150)
        #expect(grayDownsampled.image.width == 150)
        #expect(OCRImageEncoder.pngData(from: grayImage, maxSide: 150) != nil)

        // 3. 字节级表单拼装与 formEncode 完全一致。
        let samplePayload = "ab+/cd=="
        let fastBody = BaiduPPOCRProvider.formEncodedBody(forBase64: samplePayload)
        #expect(String(decoding: fastBody, as: UTF8.self) == "image=\(BaiduPPOCRProvider.formEncode(samplePayload))")

        // 4. clear(.baiduPPOCR) 同步清除 3 个派生 token 缓存键。
        let secrets = InMemorySecretStore()
        let defaults = UserDefaults(suiteName: "anshot.tests.baidu.clear.\(UUID().uuidString)")!
        let settings = OCRProviderSettings(defaults: defaults, secrets: secrets)
        try settings.save(OCRProviderConfig(apiKey: "ak", secretKey: "sk"), for: .baiduPPOCR)
        try settings.storeSecret("tok", for: BaiduAccessTokenStore.tokenAccount)
        try settings.storeSecret("2099-01-01T00:00:00Z", for: BaiduAccessTokenStore.expiryAccount)
        try settings.storeSecret("owner-hash", for: BaiduAccessTokenStore.ownerAccount)

        try settings.clear(.baiduPPOCR)
        #expect(settings.storedSecret(for: BaiduAccessTokenStore.tokenAccount) == nil)
        #expect(settings.storedSecret(for: BaiduAccessTokenStore.expiryAccount) == nil)
        #expect(settings.storedSecret(for: BaiduAccessTokenStore.ownerAccount) == nil)
    }
}

@Suite("LocalFileSecretStore 权限与损坏保护")
struct LocalFileSecretStoreTests {

    @Test("以 0600 原子创建并排除备份，JSON 损坏时拒绝覆写保护既有密钥")
    func permissionsExclusionAndCorruptionProtection() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("anshot-secret-suite-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let fileURL = dir.appendingPathComponent("secrets.json")
        let store = LocalFileSecretStore(fileURL: fileURL)

        try store.setSecret("sk-alpha", for: "provider.a")
        #expect(store.secret(for: "provider.a") == "sk-alpha")

        let attrs = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        let perms = (attrs[.posixPermissions] as? NSNumber)?.intValue
        #expect(perms == 0o600)

        let values = try fileURL.resourceValues(forKeys: [.isExcludedFromBackupKey])
        #expect(values.isExcludedFromBackup == true)

        // 模拟磁盘或外部损坏了 secrets.json。
        let corrupted = Data("{corrupted-json".utf8)
        try corrupted.write(to: fileURL)

        // 写入新 key 必须抛出 corruptedStore，严禁把损坏文件覆盖清空。
        #expect {
            try store.setSecret("sk-beta", for: "provider.b")
        } throws: { error in
            error is SecretStoreError
        }
        #expect(try Data(contentsOf: fileURL) == corrupted)
    }
}
