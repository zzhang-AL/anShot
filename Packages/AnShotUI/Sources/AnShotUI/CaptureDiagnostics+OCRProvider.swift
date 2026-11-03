//
//  CaptureDiagnostics+OCRProvider.swift
//  AnShotUI
//
//  `-diagnoseOCRProvider`：识别 provider 配置层的端到端验证。
//
//  ── 为什么单独一套诊断 ────────────────────────────────────
//
//  `-diagnoseOCR` 验的是 Vision 的**识别与坐标契约**（会不会上下翻转之类），
//  它跑的是本地路径。本诊断验的是另一层：**配置能不能可靠地存与取**、
//  密钥有没有落到不该落的地方、云端路径会不会假装自己有坐标。
//
//  这两类问题都不会在识别结果里表现出来——密钥明文躺着、坐标悄悄变成零矩形，
//  识别本身都「成功了」。
//
//  ── 用独立的 UserDefaults suite ──────────────────────────
//
//  诊断会写配置。直接写 `.standard` 会污染用户真实的识别设置，
//  下一次截图就按诊断留下的残留发请求。所以另开一个 suite，跑完删掉。
//

#if DEBUG
import AnShotCapture
import AnShotCore
import AppKit

extension CaptureDiagnostics {

    static func runOCRProviderDiagnostic() async {
        var failed = 0
        func report(_ label: String, _ measured: String, _ expected: String, _ ok: Bool) {
            if !ok { failed += 1 }
            logger.notice("""
                [ocr-provider] \(label, privacy: .public) measured=\(measured, privacy: .public) \
                expected=\(expected, privacy: .public)  \(ok ? "MATCH" : "MISMATCH", privacy: .public)
                """)
        }

        let suiteName = "com.anshot.app.diagnostics.ocrprovider"
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            logger.error("[ocr-provider] 无法创建诊断用 UserDefaults suite")
            exit(1)
        }
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }

        // 内存密钥存储：诊断进程可能没有可用的 Keychain 上下文，
        // 用真实 Keychain 会把「环境不通」误报成「代码有问题」。
        let secrets = InMemorySecretStore()
        let settings = OCRProviderSettings(defaults: defaults, secrets: secrets)

        // ── ① 默认行为不能被「可配置」改变 ──
        report(
            "未配置时默认 provider",
            settings.selectedKind.rawValue,
            OCRProviderKind.appleVision.rawValue,
            settings.selectedKind == .appleVision
        )
        report(
            "Vision 无需密钥即视为已配置",
            "\(settings.isConfigured(.appleVision))",
            "true",
            settings.isConfigured(.appleVision)
        )

        // ── ② 配置往返 ──
        let apiKey = "sk-diagnostic-key-1234567890"
        let saved = OCRProviderConfig(
            endpoint: "https://example.com/v1/chat/completions",
            model: "diagnostic-model",
            apiKey: apiKey
        )
        do {
            try settings.save(saved, for: .openAICompatible)
        } catch {
            report("保存配置", "抛错 \(error)", "成功", false)
        }
        let loaded = settings.config(for: .openAICompatible)
        report(
            "配置往返（endpoint/model/apiKey）",
            "\(loaded.endpoint) | \(loaded.model) | key=\(loaded.apiKey == apiKey)",
            "三字段与写入一致",
            loaded == saved
        )
        report(
            "已填密钥时 isConfigured",
            "\(settings.isConfigured(.openAICompatible))",
            "true",
            settings.isConfigured(.openAICompatible)
        )

        // ── ③ 密钥不得出现在 UserDefaults ──
        //   这是本诊断最要紧的一条：它挡的是「明文落盘」这种不会报错、
        //   也不会被功能测试发现的缺陷。
        let leaked = defaults.dictionaryRepresentation().contains { _, value in
            if let data = value as? Data {
                return String(decoding: data, as: UTF8.self).contains(apiKey)
            }
            if let text = value as? String {
                return text.contains(apiKey)
            }
            return false
        }
        report("API Key 未写入 UserDefaults", leaked ? "发现明文" : "未发现", "未发现", !leaked)

        // ── ④ 清除时要连密钥一起清 ──
        do {
            try settings.clear(.openAICompatible)
        } catch {
            report("清除配置", "抛错 \(error)", "成功", false)
        }
        let account = OCRProviderSettings.secretAccount(for: .openAICompatible)
        report(
            "清除后 isConfigured",
            "\(settings.isConfigured(.openAICompatible))",
            "false",
            !settings.isConfigured(.openAICompatible)
        )
        report(
            "清除后密钥也已删除",
            secrets.secret(for: account) ?? "nil",
            "nil",
            secrets.secret(for: account) == nil
        )

        // ── ④.5 本地文件存储：往返 + 文件权限 ──
        //   权限是这套方案唯一的安全边界，必须断言：
        //   写文件时若丢掉了 0600（比如被 umask 放宽），
        //   功能上完全正常，只有权限变了——不测就发现不了。
        let secretFileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("anshot-secret-diag-\(UUID().uuidString).json")
        let fileStore = LocalFileSecretStore(fileURL: secretFileURL)
        do {
            try fileStore.setSecret("sk-file-check", for: "diag.account")
            let readBack = fileStore.secret(for: "diag.account")
            report("本地文件存储往返", readBack ?? "nil", "sk-file-check", readBack == "sk-file-check")

            let attributes = try? FileManager.default.attributesOfItem(atPath: secretFileURL.path)
            let permissions = (attributes?[.posixPermissions] as? NSNumber)?.intValue ?? 0
            report(
                "密钥文件权限为 0600",
                String(format: "%03o", permissions),
                "600",
                permissions == 0o600
            )

            try fileStore.removeSecret(for: "diag.account")
            let afterRemove = fileStore.secret(for: "diag.account")
            report("删除后读取为空", afterRemove ?? "nil", "nil", afterRemove == nil)
        } catch {
            report("本地文件存储", "抛错 \(error)", "成功", false)
        }
        try? FileManager.default.removeItem(at: secretFileURL)

        // ── ⑤ Vision 路径：坐标能力必须是 precise ──
        guard let image = TextRecognizer.sampleImage() else {
            report("生成测试图", "nil", "非 nil", false)
            exit(1)
        }
        do {
            let result = try await AppleVisionOCRProvider().recognize(in: image)
            report(
                "Vision 坐标能力",
                result.coordinateCapability.rawValue,
                OCRCoordinateCapability.precise.rawValue,
                result.coordinateCapability == .precise
            )
            report(
                "Vision 图像尺寸为原图",
                "\(Int(result.imagePixelSize.width))x\(Int(result.imagePixelSize.height))",
                "\(image.width)x\(image.height)",
                Int(result.imagePixelSize.width) == image.width
                    && Int(result.imagePixelSize.height) == image.height
            )
        } catch {
            report("Vision 识别", "抛错 \(error)", "成功", false)
        }

        // ── ⑥ 云端装配：明确没有坐标，且用零矩形而不是整图 ──
        let assembled = OCRTextAssembler.makeResult(
            rawText: "第一行\n\n   第二行   \n",
            imagePixelSize: PixelSize(width: 100, height: 50),
            capability: .unavailable
        )
        report("云端切行并丢弃空行", "\(assembled.lines.count)", "2", assembled.lines.count == 2)
        report(
            "云端行文本已去首尾空白",
            assembled.lines.last?.text ?? "nil",
            "第二行",
            assembled.lines.last?.text == "第二行"
        )
        report(
            "云端坐标能力",
            assembled.coordinateCapability.rawValue,
            OCRCoordinateCapability.unavailable.rawValue,
            assembled.coordinateCapability == .unavailable
        )
        let allZero = assembled.lines.allSatisfy { $0.boundingBox == .zero }
        report("云端包围盒全为零矩形", "\(allZero)", "true", allZero)

        // ── ⑦ 请求构造：不发网络请求，只验格式 ──
        let requestConfig = OCRProviderConfig(apiKey: "sk-shape-check")
        do {
            let request = try OpenAICompatibleOCRProvider(config: requestConfig).makeRequest(in: image)
            report(
                "OpenAI 鉴权头",
                request.value(forHTTPHeaderField: "Authorization") ?? "nil",
                "Bearer sk-shape-check",
                request.value(forHTTPHeaderField: "Authorization") == "Bearer sk-shape-check"
            )
            report(
                "OpenAI endpoint 取自默认值",
                request.url?.absoluteString ?? "nil",
                OCRProviderKind.openAICompatible.defaultEndpoint,
                request.url?.absoluteString == OCRProviderKind.openAICompatible.defaultEndpoint
            )
            let body = request.httpBody.flatMap {
                try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
            }
            let messages = body?["messages"] as? [[String: Any]]
            report("OpenAI 消息条数（system + user）", "\(messages?.count ?? 0)", "2", messages?.count == 2)
            let model = body?["model"] as? String
            report(
                "OpenAI 未填模型时回填默认",
                model ?? "nil",
                OCRProviderKind.openAICompatible.defaultModel,
                model == OCRProviderKind.openAICompatible.defaultModel
            )
            // 图片必须以 data URL 承载：少了前缀服务端会当成普通字符串。
            let userContent = (messages?.last?["content"] as? [[String: Any]]) ?? []
            let imageURL = userContent.compactMap { $0["image_url"] as? [String: Any] }
                .compactMap { $0["url"] as? String }
                .first ?? ""
            report(
                "OpenAI 图片为 data URL",
                imageURL.hasPrefix("data:image/png;base64,") ? "前缀正确" : String(imageURL.prefix(24)),
                "前缀 data:image/png;base64,",
                imageURL.hasPrefix("data:image/png;base64,")
            )
        } catch {
            report("OpenAI 请求构造", "抛错 \(error)", "成功", false)
        }

        // 专用 OCR 模型必须走专用提示词：模型名匹配时不能带 system 段，
        // 且 user 文本里必须含 `<image>` 标记——实测缺了它，
        // 同一个模型对同一张图只会返回 `}`。这条回归一旦发生，
        // 功能上「能跑通、有返回」，只有肉眼看结果才会发现是垃圾。
        do {
            let deepSeek = OCRProviderConfig(model: "deepseek-ai/DeepSeek-OCR", apiKey: "sk-shape-check")
            let request = try OpenAICompatibleOCRProvider(config: deepSeek).makeRequest(in: image)
            let body = request.httpBody.flatMap {
                try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
            }
            let messages = body?["messages"] as? [[String: Any]] ?? []
            let roles = messages.compactMap { $0["role"] as? String }
            report("DeepSeek-OCR 不带 system 段", roles.joined(separator: ","), "user", roles == ["user"])

            let userText = (messages.first?["content"] as? [[String: Any]])?
                .first { ($0["type"] as? String) == "text" }
                .flatMap { $0["text"] as? String } ?? ""
            report(
                "DeepSeek-OCR 的 user 文本含 <image> 标记",
                userText.contains("<image>") ? "含" : "缺（会返回垃圾）",
                "含",
                userText.contains("<image>")
            )
            report(
                "DeepSeek-OCR 使用官方指令",
                userText.replacingOccurrences(of: "\n", with: "⏎"),
                "<image>⏎Free OCR.",
                userText == "<image>\nFree OCR."
            )
        } catch {
            report("DeepSeek-OCR 请求构造", "抛错 \(error)", "成功", false)
        }

        do {
            let request = try ClaudeOCRProvider(config: requestConfig).makeRequest(in: image)
            report(
                "Claude 鉴权头",
                request.value(forHTTPHeaderField: "x-api-key") ?? "nil",
                "sk-shape-check",
                request.value(forHTTPHeaderField: "x-api-key") == "sk-shape-check"
            )
            report(
                "Claude 版本头",
                request.value(forHTTPHeaderField: "anthropic-version") ?? "nil",
                "2023-06-01",
                request.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01"
            )
            let body = request.httpBody.flatMap {
                try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
            }
            let content = ((body?["messages"] as? [[String: Any]])?.first?["content"] as? [[String: Any]]) ?? []
            let imageBlock = content.first { ($0["type"] as? String) == "image" }
            let source = imageBlock?["source"] as? [String: Any]
            report(
                "Claude 图片块 media_type",
                source?["media_type"] as? String ?? "nil",
                "image/png",
                (source?["media_type"] as? String) == "image/png"
            )
            // Claude 用裸 base64：带上 data URL 前缀会被拒绝。
            let data = source?["data"] as? String ?? ""
            report(
                "Claude 使用裸 base64（无 data URL 前缀）",
                data.hasPrefix("data:") ? "带了前缀" : "裸 base64",
                "裸 base64",
                !data.isEmpty && !data.hasPrefix("data:")
            )
        } catch {
            report("Claude 请求构造", "抛错 \(error)", "成功", false)
        }

        // ── ⑧ 缺密钥时必须直接失败，不得回退 ──
        do {
            _ = try OpenAICompatibleOCRProvider(config: OCRProviderConfig()).makeRequest(in: image)
            report("缺密钥时报错", "未抛错", "missingAPIKey", false)
        } catch let error as OCRProviderFailure {
            report("缺密钥时报错", "\(error)", "\(OCRProviderFailure.missingAPIKey)", error == .missingAPIKey)
        } catch {
            report("缺密钥时报错", "抛了别的错 \(error)", "missingAPIKey", false)
        }

        // ── ⑨ 未配置的云端 provider 经 OCRService 也要直接失败 ──
        defaults.set(OCRProviderKind.claude.rawValue, forKey: OCRProviderSettings.selectedKindKey)
        do {
            _ = try await OCRService(settings: settings).recognize(in: image)
            report("未配置云端 provider 直接失败", "未抛错", "missingAPIKey", false)
        } catch let error as OCRProviderFailure {
            report(
                "未配置云端 provider 直接失败",
                "\(error)",
                "\(OCRProviderFailure.missingAPIKey)",
                error == .missingAPIKey
            )
        } catch {
            report("未配置云端 provider 直接失败", "抛了别的错 \(error)", "missingAPIKey", false)
        }

        // ── ⑧ 退化输出检测：模型失败的形态是「HTTP 200 + finish_reason=stop + 重复垃圾」，
        //      接口层面看不出异常，只能靠内容形态识破（实测 DeepSeek-OCR 就会这样）。
        let degenerateCases: [(String, String)] = [
            ("单字符重复", String(repeating: "}", count: 400)),
            ("空格分隔重复", String(repeating: "0 ", count: 200)),
            ("片段重复", String(repeating: "theta=0.5, ", count: 60)),
        ]
        for (name, sample) in degenerateCases {
            let hit = OCRTextSanity.looksDegenerate(sample)
            report("退化检测 · \(name)", "\(hit)", "true", hit)
        }
        let healthyTexts = [
            "订单编号：SO-2026-0914-0073\nTotal amount: 1,280.50 CNY\n状态：待发货 / Pending shipment",
            "}",
            "0 0 1 0 2 0",
        ]
        for (index, text) in healthyTexts.enumerated() {
            let hit = OCRTextSanity.looksDegenerate(text)
            report("退化检测 · 不误判正常文本 #\(index + 1)", "\(hit)", "false", !hit)
        }

        // ── ⑨ 百度 PP-OCRv6：格式与另两个云端 provider 完全不同（表单编码、
        //      两个凭据换 token、返回坐标），逐项验证形状。
        let baiduKind = OCRProviderKind.baiduPPOCR
        report(
            "百度 OCR 需要 Secret Key",
            "\(baiduKind.requiresSecretKey)",
            "true",
            baiduKind.requiresSecretKey
        )
        report(
            "百度 OCR 不需要模型名",
            "\(baiduKind.requiresModel)",
            "false",
            !baiduKind.requiresModel
        )
        report(
            "百度 OCR 坐标能力为 precise",
            baiduKind.coordinateCapability.rawValue,
            "precise",
            baiduKind.coordinateCapability == .precise
        )
        report(
            "百度 OCR 默认地址",
            baiduKind.defaultEndpoint,
            "https://aip.baidubce.com/rest/2.0/ocr/v1/pp_ocrv5",
            baiduKind.defaultEndpoint == "https://aip.baidubce.com/rest/2.0/ocr/v1/pp_ocrv5"
        )

        // 请求构造：token 在查询串、图片在表单体。
        do {
            let request = try BaiduPPOCRProvider.makeRequest(
                endpoint: baiduKind.defaultEndpoint,
                token: "tok-1",
                payload: "ab+/cd=="
            )
            let contentType = request.value(forHTTPHeaderField: "Content-Type") ?? "nil"
            report(
                "百度 Content-Type 为表单",
                contentType,
                "application/x-www-form-urlencoded",
                contentType == "application/x-www-form-urlencoded"
            )
            report(
                "百度 token 放在查询串",
                request.url?.query ?? "nil",
                "access_token=tok-1",
                request.url?.query == "access_token=tok-1"
            )
            // base64 里的 `+` `/` `=` 不转义会被表单解码成别的字节，
            // 服务端只会说「图片格式不对」，与真因隔了好几层。
            let body = request.httpBody.flatMap { String(data: $0, encoding: .utf8) } ?? "nil"
            report(
                "百度 base64 特殊字符已转义",
                body,
                "image=ab%2B%2Fcd%3D%3D",
                body == "image=ab%2B%2Fcd%3D%3D"
            )
        } catch {
            report("百度请求构造", "抛错 \(error)", "不抛错", false)
        }

        // 响应解析：lines / probability / rec_boxes 是**按下标对齐**的三个数组。
        let baiduJSON: [String: Any] = [
            "page_result": [[
                "lines": ["无言独上西楼", "月如钩"],
                "probability": [0.986, 0.975],
                "rec_boxes": [[405, 104, 915, 242], [408, 267, 684, 393]],
                "lines_result_num": 2,
            ]],
        ]
        do {
            let parsed = try BaiduPPOCRProvider.makeResult(
                json: baiduJSON,
                imageSize: PixelSize(width: 1920, height: 1080)
            )
            report("百度解析出两行", "\(parsed.lines.count)", "2", parsed.lines.count == 2)
            report(
                "百度保留真实置信度",
                String(format: "%.3f", parsed.lines.first?.confidence ?? -1),
                "0.986",
                abs((parsed.lines.first?.confidence ?? -1) - 0.986) < 0.0005
            )
            // [x_min, y_min, x_max, y_max] → origin/size，不做任何翻转。
            let box = parsed.lines.first?.boundingBox ?? .zero
            let described = "\(box.origin.x),\(box.origin.y),\(box.size.width),\(box.size.height)"
            report(
                "百度矩形转成原点与尺寸",
                described,
                "405.0,104.0,510.0,138.0",
                described == "405.0,104.0,510.0,138.0"
            )
            report(
                "百度结果坐标能力为 precise",
                parsed.coordinateCapability.rawValue,
                "precise",
                parsed.coordinateCapability == .precise
            )
        } catch {
            report("百度响应解析", "抛错 \(error)", "不抛错", false)
        }

        // 三个数组长度不齐时取短的：宁可少一行，也不要下标越界。
        do {
            let ragged: [String: Any] = [
                "page_result": [[
                    "lines": ["甲", "乙", "丙"],
                    "rec_boxes": [[0, 0, 10, 10]],
                ]],
            ]
            let parsed = try BaiduPPOCRProvider.makeResult(
                json: ragged,
                imageSize: PixelSize(width: 100, height: 100)
            )
            report("百度数组不齐时取短", "\(parsed.lines.count)", "1", parsed.lines.count == 1)
        } catch {
            report("百度数组不齐时取短", "抛错 \(error)", "1", false)
        }

        // 业务错误藏在 200 响应里（token 失效 / 额度用尽），必须被识别成失败。
        let baiduError = BaiduPPOCRProvider.businessError(in: [
            "error_code": 110,
            "error_msg": "Access token invalid or no longer valid",
        ])
        let expectedBaiduError = OCRProviderFailure.serviceError(
            code: 110,
            message: "Access token invalid or no longer valid"
        )
        report(
            "百度业务错误被识别",
            baiduError.map { "\($0)" } ?? "nil",
            "\(expectedBaiduError)",
            baiduError == expectedBaiduError
        )
        report(
            "百度正常响应无业务错误",
            "\(BaiduPPOCRProvider.businessError(in: baiduJSON) == nil)",
            "true",
            BaiduPPOCRProvider.businessError(in: baiduJSON) == nil
        )

        // 分辨率：正常尺寸必须原样送（缩了就是白降小字精度），超限才缩。
        let unchanged = BaiduPPOCRProvider.resizeIfNeeded(image, maxSide: 8192)
        report(
            "百度不缩小正常尺寸",
            "\(unchanged.width)x\(unchanged.height)",
            "\(image.width)x\(image.height)",
            unchanged.width == image.width && unchanged.height == image.height
        )
        let shrunk = BaiduPPOCRProvider.resizeIfNeeded(image, maxSide: 100)
        report(
            "百度超限时按比例缩",
            "\(shrunk.width)x\(shrunk.height)",
            "最长边 ≤ 100",
            max(shrunk.width, shrunk.height) <= 100
        )

        logger.notice("""
            [ocr-provider] 汇总: \(failed == 0 ? "全部通过" : "\(failed) 项失败", privacy: .public) \
            exitCode=\(failed == 0 ? 0 : 1, privacy: .public)
            """)
        try? await Task.sleep(for: .milliseconds(300))
        exit(failed == 0 ? 0 : 1)
    }
}
#endif
