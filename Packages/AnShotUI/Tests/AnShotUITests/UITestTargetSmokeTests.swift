//
//  UITestTargetSmokeTests.swift
//  AnShotUITests
//
//  测试目标可用性的探针。
//
//  存在的理由：`AnShotUI` 自建立以来没有测试 target，`@testable import` 能否
//  穿透到 AppKit 密集的模块内部，以及 Swift Testing 在链接了 AppKit 的模块上
//  能否正常跑，此前都没有被验证过。这条测试是「测试基建可用」的最小证明，
//  其余测试才有意义。
//

import AnShotCore
import Testing

@testable import AnShotUI

@Suite("UI 测试目标可用性")
struct UITestTargetSmokeTests {

    @Test("能访问 AnShotUI 的内部类型")
    func canAccessInternalTypes() {
        // AnnotationTool 是 internal（非 public）：能取到它就证明
        // @testable import 生效，这是本 target 存在的全部前提。
        #expect(AnnotationTool.allCases.count == 12)
    }

    @Test("标注工具的家族划分与二级面板内容一致")
    func familyGroupingCoversEveryTool() {
        let grouped = AnnotationTool.Family.allCases.flatMap { AnnotationTool.tools(in: $0) }
        #expect(Set(grouped) == Set(AnnotationTool.allCases), "每个工具都必须恰好属于一个家族")
    }

    @Test("应用内快捷键无冲突")
    func keyCharactersAreUnique() {
        // 快捷键冲突只有在用户按键时才暴露，且表现为「按了没反应」，
        // 是典型的静默缺陷——用测试穷尽它能避免人工逐键试探。
        let characters = AnnotationTool.allCases.map(\.keyCharacter)
        #expect(Set(characters).count == characters.count, "快捷键必须唯一，实际 \(characters)")
    }
}
