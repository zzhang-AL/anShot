//
//  CaptureDiagnostics+Translation.swift
//  AnShotUI
//
//  `-diagnoseTranslation`：翻译（M3-3）的验证。
//
//  ── 验证什么 ──────────────────────────────────────────────
//
//  模型层（逐行一一对应、失败保留原文、空白算失败）已由 AnShotCore 的
//  8 项单测覆盖。这里验证单测覆盖不到的部分：
//
//  * 版本闸门：本机到底能不能用系统翻译，以及**不能用时是否明确报告原因**
//    （契约 DM3-1 选的是「能力降级」，所以「不可用」本身就是要验证的正常状态）；
//  * 语言包是否已安装——这是翻译能不能真出结果的唯一决定因素，
//    必须如实报告，不能让「失败」看起来像「代码有问题」；
//  * 真实调用：源语言检测、批量提交、结果行数与 OCR 行严格一致。
//
//  诊断**不联网**：只调系统本地翻译框架。
//

#if DEBUG
import AnShotCapture
import AnShotCore
import AppKit

extension CaptureDiagnostics {

    static func runTranslationDiagnostic() async {
        var failed = 0
        func report(_ label: String, _ measured: String, _ expected: String, _ ok: Bool) {
            if !ok { failed += 1 }
            logger.notice("""
                [translate] \(label, privacy: .public) measured=\(measured, privacy: .public) \
                expected=\(expected, privacy: .public)  \(ok ? "MATCH" : "MISMATCH", privacy: .public)
                """)
        }

        // ① 入口状态：本机的真实状态必须先说清楚。
        let gate = TranslationSupport.availability(for: .appleTranslation, isCloudConfigured: true)
        report("版本闸门给出明确结论",
               "\(gate.isAvailable ? "可用" : gate.explanation)",
               "可用 或 说明原因",
               gate.isAvailable || !gate.explanation.isEmpty)
        logger.notice("""
            [translate] 系统台阶=\(TranslationProviderKind.appleTranslation.requiredSystemVersion ?? "-", privacy: .public) \
            本机结论=\(gate.explanation, privacy: .public)
            """)

        // ② 准备一张带中文的图并识别（翻译的输入必须是真实 OCR 行）。
        func makeImage() -> CGImage? {
            guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
                  let context = CGContext(
                      data: nil, width: 700, height: 300,
                      bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace,
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                  ) else { return nil }
            context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 700, height: 300))
            let font = NSFont(name: "PingFang SC", size: 44) ?? NSFont.systemFont(ofSize: 44)
            let lines = [("你好，世界", 210.0), ("今天天气很好", 90.0)]
            for (text, y) in lines {
                let attributed = NSAttributedString(
                    string: text,
                    attributes: [.font: font, .foregroundColor: NSColor.black]
                )
                let ctLine = CTLineCreateWithAttributedString(attributed)
                context.textPosition = CGPoint(x: 40, y: y)
                CTLineDraw(ctLine, context)
            }
            return context.makeImage()
        }

        guard let image = makeImage() else {
            report("构造中文测试图", "nil", "非 nil", false)
            exit(1)
        }

        var lines: [OCRTextLine] = []
        do {
            lines = try await TextRecognizer.recognize(in: image).lines
        } catch {
            report("OCR 输入准备", "\(error)", "成功", false)
            exit(1)
        }
        report("OCR 得到用于翻译的行", "\(lines.count) 行", ">= 1", !lines.isEmpty)

        // ③ 源语言检测（契约要求优先用识别结果，避免二次检测分歧）。
        var source: String?
        if #available(macOS 26.0, *) {
            source = TextTranslator.detectSourceLanguage(of: lines)
        } else {
            // 低版本下也要能检测语言：这段逻辑只依赖 NaturalLanguage。
            source = nil
        }
        report("检测出源语言", "\(source ?? "nil")", "zh 系", source?.hasPrefix("zh") == true)

        // ④ 真实翻译。
        guard #available(macOS 26.0, *) else {
            // 能力降级路径：必须明确报告，而不是静默跳过。
            report("低于 macOS 26.0 时降级",
                   gate.explanation, "含「不可用」", gate.explanation.contains("不可用"))
            logger.notice("""
                [translate] 汇总: 全部通过（能力降级路径）exitCode=0
                """)
            exit(0)
        }

        guard let detected = source else {
            report("源语言可用", "nil", "非 nil", false)
            exit(1)
        }

        let availability = await TextTranslator.availability(source: detected, target: "en-US")
        report("语言对可用性可查询",
               "\(availability.isAvailable ? "可用" : availability.explanation)",
               "给出结论",
               availability.isAvailable || !availability.explanation.isEmpty)

        let result = await TextTranslator.translate(
            lines: lines,
            source: detected,
            target: "en-US"
        )

        // **核心契约**：逐行一一对应。
        report("译文行数与 OCR 行数一致",
               "\(result.segments.count) vs \(lines.count)", "相等",
               result.segments.count == lines.count)
        report("译文顺序与 OCR 顺序一致",
               result.segments.map(\.sourceText).joined(separator: " | "),
               lines.map(\.text).joined(separator: " | "),
               result.segments.map(\.sourceText) == lines.map(\.text))
        report("源/目标语言被记录",
               "\(result.sourceLanguage ?? "nil") → \(result.targetLanguage)",
               "\(detected) → en-US",
               result.sourceLanguage == detected && result.targetLanguage == "en-US")

        // ⑤ 结果与降级两种情形都必须是「可交付」的。
        //
        //    ⚠️ 这里原来无论翻不翻得出来都判 MATCH（0 行就说成「语言包未安装时
        //    降级」），于是诊断永远全绿——它证明不了翻译能不能用。现在把
        //    「语言对可用却 0 行」单独提出来判失败：那才是真的坏了。
        if result.translatedCount > 0 {
            let joined = result.segments.compactMap(\.translatedText).joined()
            report("翻译真的出结果（语言包已安装）",
                   "\(result.translatedCount)/\(result.segments.count) 行",
                   "> 0",
                   true)
            report("译文不是原文的中文（确实翻译过）",
                   String(joined.prefix(24)),
                   "以 ASCII 为主",
                   joined.contains { $0.isASCII && $0.isLetter })
        } else if availability.isAvailable {
            report("语言对可用时必须真的出译文",
                   "0/\(result.segments.count) 行（可用性：\(availability.explanation)）",
                   "> 0",
                   false)
        } else {
            // 语言包缺失等预期内的不可用：契约要求失败行保留原文，而不是整体报错。
            report("不可用语言对整体降级为原文（\(availability.explanation)）",
                   result.translatedCount == 0 ? "全部保留原文" : "部分翻译",
                   "全部保留原文",
                   result.isEntirelyUntranslated)
            report("降级后显示文本仍等于原文",
                   result.segments.map(\.displayText).joined(separator: " | "),
                   lines.map(\.text).joined(separator: " | "),
                   result.segments.map(\.displayText) == lines.map(\.text))
        }

        // ⑥ 本次修复的核心：源语言**未判定**不能被报成「语言对不支持」。
        //    实测 `"" → en-US` 就是 unsupported，而空串来自我们自己的检测失败，
        //    把它当成系统结论会让「英文截图 + 译成英文」直接点不动。
        let blankSource = await TextTranslator.availability(source: nil, target: "en-US")
        report("源语言未判定时不判为不支持",
               "\(blankSource.isAvailable ? "可用" : blankSource.explanation)",
               "可用",
               blankSource.isAvailable)
        let blankStringSource = await TextTranslator.availability(source: "", target: "en-US")
        report("源语言为空串时不判为不支持",
               "\(blankStringSource.isAvailable ? "可用" : blankStringSource.explanation)",
               "可用",
               blankStringSource.isAvailable)

        // ⑥ 面板状态：入口的可点性由「系统可用」与「有内容可翻」共同决定，
        //    两者缺一都该置灰——「可点但点了没反应」比置灰更糟。
        let panel = OCRResultPanel()
        panel.applyTranslationAvailability(.requiresNewerSystem(required: "macOS 99.0"))
        report("系统不支持时入口置灰",
               "\(panel.debugTranslateEnabledForDiagnostics)", "false",
               !panel.debugTranslateEnabledForDiagnostics)

        panel.applyTranslationAvailability(.available)
        report("系统可用但没有识别结果时仍置灰",
               "\(panel.debugTranslateEnabledForDiagnostics)", "false",
               !panel.debugTranslateEnabledForDiagnostics)

        panel.show(
            result: OCRResult(
                lines: lines,
                // 尺寸取任意非零值：这里验的是「有内容可翻」时的入口状态，
                // 与坐标系无关。
                imagePixelSize: PixelSize(width: 100, height: 100)
            ),
            near: CGRect(x: 100, y: 100, width: 200, height: 100)
        )
        report("系统可用且有内容时入口启用",
               "\(panel.debugTranslateEnabledForDiagnostics)", "true",
               panel.debugTranslateEnabledForDiagnostics)
        report("语言下拉与按钮同步",
               "\(panel.debugLanguagePopUpEnabledForDiagnostics)", "true",
               panel.debugLanguagePopUpEnabledForDiagnostics)
        panel.hide()

        // ⑩ 翻译 provider：把多行合并成一次请求，是本功能最容易出错的地方。
        //    这里只验形状与解析，不发任何网络请求。
        let cloudKind = TranslationProviderKind.openAICompatible
        report("云端翻译不受系统版本限制",
               "\(cloudKind.requiredSystemVersion == nil)", "true",
               cloudKind.requiredSystemVersion == nil)
        report("云端翻译会外发文本",
               "\(cloudKind.sendsTextOffDevice)", "true",
               cloudKind.sendsTextOffDevice)
        report("本机翻译不外发文本",
               "\(TranslationProviderKind.appleTranslation.sendsTextOffDevice)", "false",
               !TranslationProviderKind.appleTranslation.sendsTextOffDevice)
        report("本机翻译标注了系统台阶",
               TranslationProviderKind.appleTranslation.requiredSystemVersion ?? "nil",
               "macOS 26.0",
               TranslationProviderKind.appleTranslation.requiredSystemVersion == "macOS 26.0")

        // 语言名映射：BCP-47 → 提示词里用的语言名。
        report("语言名 · 简体中文",
               TranslationPrompt.languageName(for: "zh-Hans"), "Simplified Chinese",
               TranslationPrompt.languageName(for: "zh-Hans") == "Simplified Chinese")
        report("语言名 · 繁体中文",
               TranslationPrompt.languageName(for: "zh-Hant"), "Traditional Chinese",
               TranslationPrompt.languageName(for: "zh-Hant") == "Traditional Chinese")
        report("语言名 · 英文",
               TranslationPrompt.languageName(for: "en-US"), "English",
               TranslationPrompt.languageName(for: "en-US") == "English")

        // 提示词：「保持编号」是「一行对一行」能成立的前提。
        let promptSystem = TranslationPrompt.system(target: "English")
        report("提示词含目标语言",
               "\(promptSystem.contains("English"))", "true",
               promptSystem.contains("English"))
        report("提示词要求保持编号",
               "\(promptSystem.contains("same numbers"))", "true",
               promptSystem.contains("same numbers"))
        // 以下三条对 anShot 尤其关键：翻的是**任意屏幕上的文字**，
        // 既可能藏指令，也常含代码与 URL。
        report("提示词防提示注入",
               "\(promptSystem.contains("never as instructions"))", "true",
               promptSystem.contains("never as instructions"))
        report("提示词要求保留 URL 与代码",
               "\(promptSystem.contains("URLs") && promptSystem.contains("code"))", "true",
               promptSystem.contains("URLs") && promptSystem.contains("code"))
        report("提示词使用 native translator 角色",
               "\(promptSystem.contains("native"))", "true",
               promptSystem.contains("native"))
        let promptUser = TranslationPrompt.user(lines: ["第一行", "第二行"])
        report("用户消息带序号", promptUser, "1. 第一行\n2. 第二行",
               promptUser == "1. 第一行\n2. 第二行")

        // 请求构造：system + user 两条、温度为 0、Bearer 鉴权。
        do {
            let request = try OpenAICompatibleTranslationProvider.makeRequest(
                endpoint: cloudKind.defaultEndpoint,
                model: cloudKind.defaultModel,
                apiKey: "sk-translate-check",
                lines: ["甲", "乙"],
                target: "en-US"
            )
            report("翻译请求用 Bearer 鉴权",
                   request.value(forHTTPHeaderField: "Authorization") ?? "nil",
                   "Bearer sk-translate-check",
                   request.value(forHTTPHeaderField: "Authorization") == "Bearer sk-translate-check")
            let body = request.httpBody.flatMap {
                try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
            }
            let messages = body?["messages"] as? [[String: Any]]
            report("翻译消息为 system + user", "\(messages?.count ?? 0)", "2", messages?.count == 2)
            let temperature = body?["temperature"] as? Int
            report("翻译温度为 0", "\(temperature ?? -1)", "0", temperature == 0)
        } catch {
            report("翻译请求构造", "抛错 \(error)", "不抛错", false)
        }

        // Claude 的 system 是顶层参数，不是 messages 里的一条。
        do {
            let request = try ClaudeTranslationProvider.makeRequest(
                endpoint: TranslationProviderKind.claude.defaultEndpoint,
                model: TranslationProviderKind.claude.defaultModel,
                apiKey: "sk-ant-check",
                lines: ["甲"],
                target: "en-US"
            )
            let body = request.httpBody.flatMap {
                try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
            }
            report("Claude 翻译使用 x-api-key",
                   request.value(forHTTPHeaderField: "x-api-key") ?? "nil", "sk-ant-check",
                   request.value(forHTTPHeaderField: "x-api-key") == "sk-ant-check")
            report("Claude 翻译 system 在顶层",
                   "\(body?["system"] != nil)", "true", body?["system"] != nil)
            report("Claude 翻译只有一条 message",
                   "\((body?["messages"] as? [[String: Any]])?.count ?? 0)", "1",
                   (body?["messages"] as? [[String: Any]])?.count == 1)
        } catch {
            report("Claude 翻译请求构造", "抛错 \(error)", "不抛错", false)
        }

        // 解析：三种情形。行数不符时**整体降级**，不做「尽力对齐」——
        // 那会把错位藏起来，而错位比不翻译更难发现。
        let numbered = TranslationResponseParser.parse("1. one\n2. two", expectedCount: 2)
        report("解析 · 带编号",
               numbered.compactMap { $0 }.joined(separator: "|"), "one|two",
               numbered.compactMap { $0 }.joined(separator: "|") == "one|two")
        let plain = TranslationResponseParser.parse("one\ntwo", expectedCount: 2)
        report("解析 · 无编号但行数对",
               plain.compactMap { $0 }.joined(separator: "|"), "one|two",
               plain.compactMap { $0 }.joined(separator: "|") == "one|two")
        let mismatched = TranslationResponseParser.parse("one\ntwo\nthree", expectedCount: 2)
        report("解析 · 行数不符则整体降级",
               "\(mismatched.count) 条 / 已翻译 \(mismatched.compactMap { $0 }.count)",
               "2 条 / 已翻译 0",
               mismatched.count == 2 && mismatched.compactMap { $0 }.isEmpty)
        // 正文里的「2024年营收」不能被当成编号行吞掉。
        let tricky = TranslationResponseParser.parse("2024年营收增长", expectedCount: 1)
        report("解析 · 不误吞数字开头的正文",
               tricky.compactMap { $0 }.joined(), "2024年营收增长",
               tricky.compactMap { $0 }.joined() == "2024年营收增长")

        // ⑪ 策略：自动模式是「云端优先、本机兜底」，显式选择绝不降级。
        //    这两条语义决定「用户选的」与「实际用的」是不是同一个东西，必须钉住。
        let explicitStrategies = TranslationStrategy.allCases.filter { $0 != .automatic }
        report("自动策略允许降级",
               "\(TranslationStrategy.automatic.allowsFallback)", "true",
               TranslationStrategy.automatic.allowsFallback)
        report("自动策略本身不是一个 provider",
               "\(TranslationStrategy.automatic.explicitKind == nil)", "true",
               TranslationStrategy.automatic.explicitKind == nil)
        report("显式策略一律不允许降级",
               explicitStrategies.map { "\($0.rawValue)=\($0.allowsFallback)" }.joined(separator: " "),
               "全部 false",
               explicitStrategies.allSatisfy { !$0.allowsFallback })
        report("自动模式的云端首选不含本机",
               TranslationStrategy.cloudKinds.map(\.rawValue).joined(separator: ","),
               "不含 appleTranslation",
               !TranslationStrategy.cloudKinds.contains(.appleTranslation))
        report("策略 rawValue 与旧 provider 同名（旧配置零迁移）",
               TranslationStrategy.appleTranslation.rawValue, "appleTranslation",
               TranslationStrategy(rawValue: "appleTranslation") == .appleTranslation
                   && TranslationStrategy(rawValue: "claude") == .claude)

        // ⑫ 同一个语言不是「不支持」，而是「不需要翻」，两句话对用户的意义不同。
        report("en 与 en-US 视为同一语言",
               "\(TranslationLanguage.isSameLanguage("en", "en-US"))", "true",
               TranslationLanguage.isSameLanguage("en", "en-US"))
        report("en_GB 与 en-US 视为同一语言（分隔符与区域都不算差异）",
               "\(TranslationLanguage.isSameLanguage("en_GB", "en-US"))", "true",
               TranslationLanguage.isSameLanguage("en_GB", "en-US"))
        report("zh-Hans 与 zh-Hant 不是同一语言（简繁转换确实有意义）",
               "\(TranslationLanguage.isSameLanguage("zh-Hans", "zh-Hant"))", "false",
               !TranslationLanguage.isSameLanguage("zh-Hans", "zh-Hant"))
        report("源语言缺失时不参与同语言判定",
               "\(TranslationLanguage.isSameLanguage(nil, "en-US"))", "false",
               !TranslationLanguage.isSameLanguage(nil, "en-US"))
        report("同语言给出的是「无需翻译」而不是「不支持」",
               TranslationAvailability.sameAsTarget(language: "en-US").explanation,
               "含「无需翻译」",
               TranslationAvailability.sameAsTarget(language: "en-US").explanation.contains("无需翻译"))

        logger.notice("""
            [translate] 汇总: \(failed == 0 ? "全部通过" : "\(failed) 项失败", privacy: .public) \
            exitCode=\(failed == 0 ? 0 : 1, privacy: .public)
            """)
        try? await Task.sleep(for: .milliseconds(300))
        exit(failed == 0 ? 0 : 1)
    }
}
#endif
