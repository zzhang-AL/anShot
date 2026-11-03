//
//  AppVersionTests.swift
//  AnShotCoreTests
//
//  版本号解析与比较的契约测试。
//
//  重点是三条**容易写错却没有报错**的规则：
//
//  1. `1.2.10 > 1.2.9`——字符串比较会得出相反结论，导致补丁版永远装不上；
//  2. `1.2 == 1.2.0`——相等性必须与 `<` 同源，否则破坏 `Comparable` 的全序；
//  3. 同号时正式版高于预发布版，而两个预发布版按字符串比较（契约规定）。
//
//  另外把非法输入逐条钉死：解析器一旦「宽容」到猜数字，
//  更新器会在用户不知情的情况下跳过新版本。
//

import Foundation
import Testing

@testable import AnShotCore

@Suite("AppVersion 版本号")
struct AppVersionTests {

    // MARK: - 解析

    @Test("允许 v/V 前缀，description 去掉前缀")
    func stripsVersionPrefix() throws {
        let lower = try #require(AppVersion("v1.2.3"))
        let upper = try #require(AppVersion("V1.2.3"))
        #expect(lower.components == [1, 2, 3])
        #expect(lower.description == "1.2.3")
        #expect(lower == upper)
    }

    @Test("允许省略段：1.2 与 1.2.0 是同一版本")
    func shortVersionEqualsPadded() throws {
        let short = try #require(AppVersion("1.2"))
        let padded = try #require(AppVersion("1.2.0"))
        #expect(short.components == [1, 2])
        #expect(short.description == "1.2")
        #expect(short == padded)
        #expect(!(short < padded))
        #expect(!(padded < short))
    }

    @Test("大于两位的数字段按数值比较")
    func comparesNumericSegments() throws {
        let older = try #require(AppVersion("1.2.9"))
        let newer = try #require(AppVersion("1.2.10"))
        #expect(older < newer)
        #expect(newer > older)
        #expect(!(newer < older))
    }

    @Test("前置零按数值解析")
    func leadingZerosAreNumeric() throws {
        let version = try #require(AppVersion("01.02.003"))
        #expect(version.components == [1, 2, 3])
        #expect(version == AppVersion("1.2.3"))
    }

    @Test("构建元数据不参与比较")
    func ignoresBuildMetadata() throws {
        let withBuild = try #require(AppVersion("1.2.3+build.4"))
        #expect(withBuild.prerelease == nil)
        #expect(withBuild == AppVersion("1.2.3"))
        #expect(withBuild.description == "1.2.3")
    }

    @Test("预发布后缀解析并保留在 description 中")
    func parsesPrerelease() throws {
        let version = try #require(AppVersion("v1.2.3-beta.1"))
        #expect(version.components == [1, 2, 3])
        #expect(version.prerelease == "beta.1")
        #expect(version.description == "1.2.3-beta.1")
    }

    @Test("首尾空白被忽略")
    func trimsWhitespace() throws {
        #expect(AppVersion("  1.2.3\n") == AppVersion("1.2.3"))
    }

    @Test(
        "非法输入返回 nil",
        arguments: [
            "",
            "   ",
            "v",
            "V",
            "abc",
            "release-1.2.3",
            "1.2.3 beta",
            "1..2",
            "1.2.",
            ".1.2",
            "1.2.x",
            "1.2.3-",
            "1.2.3 - beta",
            "-1.2.3",
            "1,2,3",
            // 超出 Int 的数字段：截断比较会给出错误结论，宁可判为非法。
            "99999999999999999999",
        ]
    )
    func rejectsInvalidInput(raw: String) {
        #expect(AppVersion(raw) == nil)
    }

    // MARK: - 比较

    @Test("同号时正式版高于预发布版")
    func releaseOutranksPrerelease() throws {
        let release = try #require(AppVersion("1.2.3"))
        let beta = try #require(AppVersion("1.2.3-beta.1"))
        #expect(beta < release)
        #expect(release > beta)
    }

    @Test("两个预发布后缀按字符串比较（契约规定）")
    func comparesPrereleaseAsString() throws {
        let alpha = try #require(AppVersion("2.0.0-alpha"))
        let beta = try #require(AppVersion("2.0.0-beta"))
        #expect(alpha < beta)
    }

    @Test("预发布之间不同数字段仍然先比数字")
    func numericSegmentsDominatePrerelease() throws {
        let newerBeta = try #require(AppVersion("1.3.0-beta.1"))
        let olderRelease = try #require(AppVersion("1.2.9"))
        #expect(olderRelease < newerBeta)
    }

    @Test("排序结果符合语义顺序")
    func sortsInAscendingOrder() throws {
        let raw = ["2.0.0", "1.2.3-beta.1", "1.10.0", "1.2.3", "1.2.10", "v1.2"]
        let sorted = raw.compactMap(AppVersion.init).sorted().map(\.description)
        #expect(sorted == ["1.2", "1.2.3-beta.1", "1.2.3", "1.2.10", "1.10.0", "2.0.0"])
    }
}
