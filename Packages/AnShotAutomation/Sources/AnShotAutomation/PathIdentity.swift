//
//  PathIdentity.swift
//  AnShotAutomation
//
//  路径同一性判定。
//
//  ── 为什么不能直接比较字符串 ─────────────────────────────────
//
//  下面两个路径指向同一个文件，但字符串不相等：
//
//      /tmp/a.png
//      /tmp/./a.png
//
//  再加上符号链接（macOS 上 `/tmp` 本身就是一个指向 `/private/tmp` 的链接），
//  字符串比较几乎必然漏判。而这里漏判的后果不是「报个错」——
//  是**截图被报告覆盖**：PNG 先写成功，紧接着 JSON 写到同一个文件上，
//  调用方拿到一个后缀是 `.png` 却装着 JSON 的文件，退出码还是 0。
//
//  因此凡是「判断两个路径是不是同一个目标」的地方，一律经本类型，
//  统一走 `resolvingSymlinksInPath` + `standardizedFileURL`。
//

import Foundation

/// 路径同一性。
enum PathIdentity {

    /// 把一个路径规范化为可用于相等比较的形式。
    ///
    /// ── 为何不能只调 `resolvingSymlinksInPath()` ────────────────
    ///
    /// 实测：它对**不存在**的路径不解析中间链接。
    /// 而本工具处理的恰恰是「将要创建的文件」（截图与报告都还没写），
    /// 于是 `<dir>/alias/shot.png`（alias 是指向 real 的链接）
    /// 会原样返回，与 `<dir>/real/shot.png` 判定为不同——
    /// 那正是会导致「报告覆盖截图」的漏判。
    ///
    /// 所以这里自己走：从目标向上找到第一个**存在**的祖先，
    /// 对它做符号链接解析，再把不存在的部分接回去。
    ///
    /// - Parameter path: 绝对或带 `~` 的路径。
    /// - Returns: 规范化后的绝对路径。
    static func canonical(_ path: String) -> String {
        canonical(URL(fileURLWithPath: (path as NSString).expandingTildeInPath))
    }

    /// 同上，接受 URL。
    static func canonical(_ url: URL) -> String {
        var current = url.standardizedFileURL
        var missingComponents: [String] = []

        while !FileManager.default.fileExists(atPath: current.path) {
            let name = current.lastPathComponent
            // 到达根或拿不到名字就停下，避免死循环
            guard !name.isEmpty else { break }
            missingComponents.insert(name, at: 0)

            let parent = current.deletingLastPathComponent()
            guard parent.path != current.path else { break }
            current = parent
        }

        // 到此 current 是第一个存在的祖先（或根）。它可能存在符号链接。
        var resolved = current.resolvingSymlinksInPath()
        for name in missingComponents {
            resolved.appendPathComponent(name)
        }

        return resolved.standardizedFileURL.path
    }

    /// 两个路径是否指向同一个目标。
    static func areSame(_ lhs: String, _ rhs: String) -> Bool {
        canonical(lhs) == canonical(rhs)
    }
}
