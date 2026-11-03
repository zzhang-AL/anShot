//
//  TranslationStrategyTests.swift
//  AnShotCoreTests
//
//  翻译选用策略（M3-3 修复）与语言标识比较。
//
//  这批测试盯的是本次修复引入的两条**语义**，而不是实现细节：
//  「自动允许降级、显式绝不降级」与「同一个语言不等于不支持」。
//  前者决定用户的选择会不会被悄悄改掉，后者决定用户看到的失败原因对不对。
//

import Foundation
import Testing

@testable import AnShotCore

@Suite("TranslationStrategy")
struct TranslationStrategyTests {

    @Test("自动策略本身不是一个 provider")
    func automaticHasNoExplicitKind() {
        #expect(TranslationStrategy.automatic.isAutomatic)
        #expect(TranslationStrategy.automatic.explicitKind == nil)
    }

    @Test("只有自动策略允许降级，显式策略一律不许")
    func onlyAutomaticAllowsFallback() {
        #expect(TranslationStrategy.automatic.allowsFallback)

        for strategy in TranslationStrategy.allCases where strategy != .automatic {
            #expect(strategy.allowsFallback == false, "显式策略 \(strategy.rawValue) 不允许降级")
            #expect(strategy.explicitKind != nil, "显式策略必须能指到一个 provider")
        }
    }

    @Test("旧配置的 rawValue 能直接解析成对应策略（零迁移）")
    func legacyRawValuesStillDecode() {
        #expect(TranslationStrategy(rawValue: "appleTranslation") == .appleTranslation)
        #expect(TranslationStrategy(rawValue: "openAICompatible") == .openAICompatible)
        #expect(TranslationStrategy(rawValue: "claude") == .claude)
        #expect(TranslationStrategy(rawValue: "automatic") == .automatic)
        #expect(TranslationStrategy(rawValue: "不存在的值") == nil)
    }

    @Test("云端首选候选里不能出现本机")
    func cloudKindsExcludeLocal() {
        #expect(TranslationStrategy.cloudKinds.contains(.appleTranslation) == false)
        #expect(TranslationStrategy.cloudKinds.contains(TranslationStrategy.defaultCloudKind))
        #expect(
            TranslationStrategy.cloudKinds.allSatisfy { $0.sendsTextOffDevice },
            "「云端首选」列出来的必须是真会外发的 provider"
        )
    }

    @Test("每个策略都有非空展示名")
    func displayNamesAreUsable() {
        for strategy in TranslationStrategy.allCases {
            #expect(strategy.displayName.isEmpty == false)
        }
    }
}

@Suite("TranslationLanguage")
struct TranslationLanguageTests {

    @Test("区域与分隔符差异不算不同语言")
    func regionDoesNotMatter() {
        // 这一条是本次修复的核心依据：`en` → `en-US` 被系统判为 unsupported，
        // 但那是「不需要翻」，不是「不支持」。
        #expect(TranslationLanguage.isSameLanguage("en", "en-US"))
        #expect(TranslationLanguage.isSameLanguage("en_GB", "en-US"))
        #expect(TranslationLanguage.isSameLanguage("zh-Hans", "zh-Hans-CN"))
        #expect(TranslationLanguage.isSameLanguage("EN-us", "en"))
    }

    @Test("脚本差异算不同语言（简繁转换是用户可能真想要的）")
    func scriptMatters() {
        #expect(TranslationLanguage.isSameLanguage("zh-Hans", "zh-Hant") == false)
    }

    @Test("缺失或空标识不参与判定")
    func missingIdentifierIsNotAMatch() {
        #expect(TranslationLanguage.isSameLanguage(nil, "en-US") == false)
        #expect(TranslationLanguage.isSameLanguage(nil, nil) == false)
        #expect(TranslationLanguage.isSameLanguage("", "en-US") == false)
        #expect(TranslationLanguage.isSameLanguage("   ", "en-US") == false)
        #expect(TranslationLanguage.isSameLanguage("en-US", nil) == false)
    }

    @Test("规范化丢掉区域与变体、保留脚本")
    func normalization() {
        #expect(TranslationLanguage.normalized("EN_us") == "en")
        #expect(TranslationLanguage.normalized("zh-Hant-TW") == "zh-hant")
        #expect(TranslationLanguage.normalized("zh-Hans-CN") == "zh-hans")
        #expect(TranslationLanguage.normalized("") == "")
        #expect(TranslationLanguage.normalized("  ") == "")
    }

    @Test("语言名认不出来时原样回传，不编造")
    func displayNameFallsBackToIdentifier() {
        #expect(TranslationLanguage.displayName(of: "en-US") == "英文")
        #expect(TranslationLanguage.displayName(of: "zh-Hans") == "简体中文")
        #expect(TranslationLanguage.displayName(of: "zh-Hant") == "繁体中文")
        #expect(TranslationLanguage.displayName(of: "xx-YY") == "xx-YY")
    }
}

@Suite("TranslationAvailability")
struct TranslationAvailabilityTests {

    @Test("同一语言给出的是「无需翻译」而不是「不支持」")
    func sameTargetIsNotUnsupported() {
        let availability = TranslationAvailability.sameAsTarget(language: "en-US")

        #expect(availability.isAvailable == false)
        #expect(availability.explanation.contains("无需翻译"))
        #expect(availability.explanation.contains("英文"))
        #expect(availability.explanation.contains("不支持") == false, "这一条绝不能说得像功能坏了")
    }

    @Test("缺语言包是可行动的提示，与「语言对不支持」分开")
    func languagePackIsActionable() {
        let pack = TranslationAvailability.languagePackNotInstalled(source: "zh-Hant", target: "en-US")
        let pair = TranslationAvailability.unsupportedLanguagePair(source: "xx-YY", target: "en-US")

        #expect(pack.isAvailable == false)
        #expect(pack.explanation.contains("语言包"))
        #expect(pair.explanation.contains("不支持"))
        #expect(pack != pair, "两条信息必须能被区分，否则界面只能给出一句笼统的失败")
    }

    @Test("只有 available 才算可用")
    func onlyAvailableIsAvailable() {
        #expect(TranslationAvailability.available.isAvailable)
        #expect(TranslationAvailability.unknown.isAvailable == false)
        #expect(TranslationAvailability.requiresNewerSystem(required: "macOS 26.0").isAvailable == false)
        #expect(TranslationAvailability.notConfigured(provider: "Claude").isAvailable == false)
    }

    @Test("源语言为空的「不支持」文案退化成自动检测，不显示空字符串")
    func nilSourceReadsAsAutoDetect() {
        let availability = TranslationAvailability.unsupportedLanguagePair(source: nil, target: "en-US")
        #expect(availability.explanation.contains("自动检测"))
    }
}
