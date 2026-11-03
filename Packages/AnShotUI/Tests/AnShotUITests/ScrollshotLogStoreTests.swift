//
//  ScrollshotLogStoreTests.swift
//  AnShotUITests
//
//  长截图日志的环形缓冲语义。
//
//  ── 为什么这几条值得测 ────────────────────────────────────
//
//  这个缓冲存在的唯一理由是「事后排查断层」。它一旦坏掉，症状不是崩溃，
//  而是**排查时看到的东西是错的**：
//  * 不丢最旧的 → 内存无上界（8 Hz 下几分钟就几万条）；
//  * 丢了最新的 → 用户看到的全是历史，恰恰没有刚出问题的那一段；
//  * 会话不分段 → 两次长截图的记录绞在一起，位移与世界坐标无法对账。
//
//  最后一条最隐蔽：每条记录单看都正常，合起来却对不上，会把排查带偏。
//

import AnShotCore
import Foundation
import Testing

@testable import AnShotUI

@Suite("长截图日志 · 环形缓冲")
@MainActor
struct ScrollshotLogStoreTests {

    /// 每个用例都从干净状态开始：单例跨会话保留，正是它被设计成这样，
    /// 但也意味着用例之间必须自己隔离。
    private func freshStore() -> ScrollshotLogStore {
        let store = ScrollshotLogStore.shared
        store.clear()
        return store
    }

    @Test("超出容量：丢弃最旧的，保留最新的")
    func dropsOldestWhenFull() {
        let store = freshStore()
        store.beginSession()

        let overflow = ScrollshotLogStore.capacity + 120
        for index in 0..<overflow {
            store.appendEvent("event-\(index)")
        }

        #expect(store.entries.count == ScrollshotLogStore.capacity, "容量应被钳在 \(ScrollshotLogStore.capacity)")
        // 保留的应是**最后** capacity 条，而不是最前面那些。
        #expect(store.entries.first?.verdict == "event-\(overflow - ScrollshotLogStore.capacity)")
        #expect(store.entries.last?.verdict == "event-\(overflow - 1)")
    }

    @Test("会话分段：两次 beginSession 的记录不混在一起")
    func sessionsAreSeparated() {
        let store = freshStore()

        let first = store.beginSession()
        store.appendEvent("a1")
        store.appendEvent("a2")

        let second = store.beginSession()
        store.appendEvent("b1")

        #expect(second == first + 1, "会话序号应自增")
        let ofFirst = store.entries.filter { $0.session == first }
        let ofSecond = store.entries.filter { $0.session == second }
        // 第一次会话 = 起始行 + 两条事件；第二次会话 = 起始行 + 一条事件。
        #expect(ofFirst.count == 3, "第一次会话记录数 \(ofFirst.count)")
        #expect(ofSecond.count == 2, "第二次会话记录数 \(ofSecond.count)")
        #expect(ofSecond.allSatisfy { $0.verdict.hasPrefix("b") || $0.verdict == "session-start" })
    }

    @Test("异常标记：非 accepted 结论都属于排查对象")
    func problemsAreFlagged() {
        let store = freshStore()
        store.beginSession()
        store.appendEvent("session-cancel 用户取消")

        let entry = store.entries.last
        #expect(entry?.isProblem == true, "取消事件应被视为异常/需关注")
    }

    @Test("文本快照：空缓冲给出可读提示，有记录时含表头与数据行")
    func formattedTextShape() {
        let store = freshStore()
        #expect(store.formattedText().contains("暂无记录"))

        store.beginSession()
        store.appendEvent("session-finish 采纳=3 观察=4 输出高=900 跟丢=false")
        let text = store.formattedText()

        #expect(text.contains("结论"), "缺少表头：\(text.prefix(80))")
        #expect(text.contains("session-finish"), "缺少数据行：\(text.suffix(120))")
        // 行数 = 表头 + 分隔线 + 起始行 + 结束行。
        #expect(text.components(separatedBy: "\n").count == 4)
    }
}
