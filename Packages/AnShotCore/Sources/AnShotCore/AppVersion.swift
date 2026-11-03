//
//  AppVersion.swift
//  AnShotCore
//
//  版本号解析与比较。
//
//  ── 为什么需要它 ─────────────────────────────────────────────
//
//  自动更新的判断全部建立在「远端版本是否比当前版本新」之上。
//  这件事看起来可以退化成 `tag.compare(CFBundleShortVersionString)`，
//  但字符串比较会把 `1.2.10` 判成小于 `1.2.9`（'1' < '9'），
//  于是用户永远装不上第 10 个补丁版——而且没有任何错误，只是「已是最新」。
//
//  所以版本必须先解析成数字段再逐段比较；比较逻辑必须由测试锁定，
//  而不是藏在某个窗口控制器里靠人工点两下确认。
//  放在 `AnShotCore`（而不是 `AnShotUI`）的唯一理由：这里有测试 target。
//
//  ── 解析范围 ──────────────────────────────────────────────────
//
//  契约要求比 SemVer 宽松一点，因为 GitHub release 的 tag 是人打的：
//
//      允许前置 v/V          v1.2.3
//      允许省略段            1.2      （等价于 1.2.0）
//      允许预发布后缀        1.2.3-beta.1
//      允许构建元数据        1.2.3+build.4（按 SemVer，不参与比较）
//
//  其余一律返回 nil，由调用方给出「无法解析版本号」的可读提示；
//  这里不做「尽力猜一个数字」的兜底——猜错会让更新器静默跳过新版本，
//  比直接报错更难排查。
//

import Foundation

/// 一个可比较的版本号。
///
/// `Equatable` 与 `<` 共用同一份比较逻辑：`1.2` 与 `1.2.0` 是**相等**版本，
/// 而不是两个不同的值。这不是实现细节，而是 `Comparable` 的严格要求
///（三者必须构成全序）；若相等性只看字段数组，就会出现
/// 「既不相等、互不小于」的第三态。
public struct AppVersion: Comparable, Equatable, Sendable, CustomStringConvertible {

    /// 数字段。`1.2.3` → `[1, 2, 3]`。
    ///
    /// 保留原始段数而不是补零到三段：`description` 要能还原用户看到的写法。
    public let components: [Int]

    /// 预发布后缀，不含前导 `-`。`1.2.3-beta.1` → `"beta.1"`。
    public let prerelease: String?

    /// 解析版本字符串。
    ///
    /// - Parameter raw: 允许带 `v`/`V` 前缀、`-prerelease` 后缀与 `+build` 元数据。
    /// - Returns: 解析失败返回 nil（空串、非数字段、空的后缀等）。
    public init?(_ raw: String) {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        // 前缀只接受单个 v/V：`vv1.2` 是笔误，不该被宽容掉。
        if text.hasPrefix("v") || text.hasPrefix("V") {
            text.removeFirst()
        }

        // 构建元数据按 SemVer 不参与优先级比较，直接丢弃即可。
        if let plus = text.firstIndex(of: "+") {
            text = String(text[text.startIndex..<plus])
        }

        var numericPart = text
        var suffix: String?
        if let dash = text.firstIndex(of: "-") {
            numericPart = String(text[text.startIndex..<dash])
            suffix = String(text[text.index(after: dash)...])
        }

        // `1.2.3-` 是残缺输入：SemVer 要求预发布标识非空。
        // 放进 `prerelease = ""` 会让它和正式版比较时产生诡异结果，
        // 因此干脆视为无法解析。
        if let suffix, suffix.isEmpty { return nil }

        // 数字段：不能为空、必须全是 ASCII 数字。
        // `split(omittingEmptySubsequences: false)` 让 `1..2` 与 `1.2.` 暴露为空段，
        // 从而被拒绝，而不是被悄悄折叠成 `1.2`。
        var parsed: [Int] = []
        let parts = numericPart.split(separator: ".", omittingEmptySubsequences: false)
        guard !parts.isEmpty else { return nil }
        for part in parts {
            guard !part.isEmpty,
                  part.allSatisfy({ $0.isASCII && $0.isNumber }),
                  // 超出 Int 的段同样视为非法：真实版本号不会长到这种程度，
                  // 而截断比较会给出错误结论。
                  let value = Int(part)
            else {
                return nil
            }
            parsed.append(value)
        }
        guard !parsed.isEmpty else { return nil }

        // 预发布后缀内部不允许空白：`1.2.3 - beta` 更像句子而不是版本号。
        if let suffix, suffix.contains(where: \.isWhitespace) { return nil }

        self.components = parsed
        self.prerelease = suffix
    }

    /// 规范化写法（去掉 v 前缀，保留原有段数与后缀）。
    ///
    /// 用户文案与 `skippedVersion` 都用它，保证「同一个版本只记一次」。
    public var description: String {
        let base = components.map(String.init).joined(separator: ".")
        guard let prerelease else { return base }
        return "\(base)-\(prerelease)"
    }

    /// 逐段比较，缺的段按 0；数字相同时预发布版小于正式版。
    ///
    /// 两个预发布后缀按**字符串**比较（契约明确要求，不走 SemVer 的
    /// 点分段规则）：这样规则简单、可预期，也不依赖 tag 的作者是否规范。
    public static func < (lhs: Self, rhs: Self) -> Bool {
        let count = max(lhs.components.count, rhs.components.count)
        for index in 0..<count {
            let left = index < lhs.components.count ? lhs.components[index] : 0
            let right = index < rhs.components.count ? rhs.components[index] : 0
            if left != right { return left < right }
        }

        switch (lhs.prerelease, rhs.prerelease) {
        case (nil, nil):
            return false
        case (nil, _):
            // 正式版高于同号预发布版。
            return false
        case (_, nil):
            return true
        case let (left?, right?):
            return left < right
        }
    }

    /// 与 `<` 严格一致的相等性（见类型注释）。
    public static func == (lhs: Self, rhs: Self) -> Bool {
        !(lhs < rhs) && !(rhs < lhs)
    }
}
