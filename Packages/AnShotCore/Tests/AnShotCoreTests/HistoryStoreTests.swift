//
//  HistoryStoreTests.swift
//  AnShotCoreTests
//
//  历史记录（M3-6）的存储契约测试。
//
//  重点不是「能存能读」，而是契约里三条容易被实现偷懒掉的规则：
//  只记路径不存位图、文件丢失不报错、超出上限淘汰最旧。
//

import Foundation
import Testing

@testable import AnShotCore

@Suite("HistoryStore")
struct HistoryStoreTests {

    // MARK: - 夹具

    private func makeTemp() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("anshot-history-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// 造一个「看起来像截图」的源文件；内容不重要，存在与否才是契约关心的。
    @discardableResult
    private func makeSourceFile(in directory: URL, name: String = "shot.png") throws -> URL {
        let url = directory.appendingPathComponent(name)
        try Data(repeating: 0xAB, count: 2048).write(to: url)
        return url
    }

    private func thumbnail(_ marker: UInt8 = 0x01) -> Data {
        Data(repeating: marker, count: 512)
    }

    // MARK: - 增删查改

    @Test("添加后条目进入列表且缩略图落盘")
    func addStoresEntryAndThumbnail() throws {
        let root = try makeTemp()
        let store = HistoryStore(directory: root)
        let source = try makeSourceFile(in: root)

        let entry = store.add(fileURL: source, thumbnailPNG: thumbnail(), pixelWidth: 800, pixelHeight: 600)

        #expect(store.entries.count == 1)
        #expect(entry.pixelWidth == 800)
        #expect(entry.pixelHeight == 600)
        #expect(store.thumbnailURL(for: entry) != nil)
        #expect(store.lastError == nil)
    }

    @Test("重载后条目与字段一致（真的落盘了）")
    func persistsAcrossReload() throws {
        let root = try makeTemp()
        let source = try makeSourceFile(in: root)
        let store = HistoryStore(directory: root)
        let entry = store.add(fileURL: source, thumbnailPNG: thumbnail(), pixelWidth: 1024, pixelHeight: 768)

        let reopened = HistoryStore(directory: root)

        #expect(reopened.entries.count == 1)
        #expect(reopened.entries.first?.id == entry.id)
        #expect(reopened.entries.first?.filePath == source.path)
        #expect(reopened.entries.first?.pixelWidth == 1024)
        #expect(reopened.entries.first?.pixelHeight == 768)
        #expect(reopened.thumbnailURL(for: entry) != nil)
    }

    @Test("重载后类型、来源、缓存标记与收藏状态都保留")
    func persistsMetadataAcrossReload() throws {
        let root = try makeTemp()
        let source = try makeSourceFile(in: root)
        let store = HistoryStore(directory: root)
        let sourceInfo = HistorySource(appName: "Safari", windowTitle: "示例页", mode: "window")
        let entry = store.add(
            fileURL: source,
            thumbnailPNG: nil,
            pixelWidth: 100,
            pixelHeight: 50,
            kind: .longScreenshot,
            source: sourceInfo
        )
        store.setFavorite(entry.id, isFavorite: true)

        let reopened = HistoryStore(directory: root)

        #expect(reopened.entries.first?.kind == .longScreenshot)
        #expect(reopened.entries.first?.source == sourceInfo)
        #expect(reopened.entries.first?.isCached == false)
        #expect(reopened.entries.first?.isFavorite == true)
        #expect(reopened.lastError == nil)
    }

    @Test("历史缓存：副本落在 cache/ 且标记为 isCached")
    func addCachedImageCopiesIntoCache() throws {
        let root = try makeTemp()
        let store = HistoryStore(directory: root)
        let png = Data(repeating: 0x5A, count: 12_345)
        let entry = try #require(store.addCachedImage(
            pngData: png,
            thumbnailPNG: thumbnail(),
            pixelWidth: 1600,
            pixelHeight: 900,
            kind: .screenshot,
            source: HistorySource(appName: "Xcode", mode: "window")
        ))

        let cachedURL = store.cacheDirectoryURL()
            .appendingPathComponent("\(entry.id.uuidString).png")
        #expect(entry.isCached)
        #expect(entry.filePath == cachedURL.path)
        #expect(entry.kind == .screenshot)
        #expect(FileManager.default.fileExists(atPath: cachedURL.path))
        let storedPNG = try Data(contentsOf: cachedURL)
        #expect(storedPNG == png)
        #expect(store.thumbnailURL(for: entry) != nil)
        #expect(store.lastError == nil)
        // 缓存副本不是缩略图：索引仍只有元数据。
        let index = try Data(contentsOf: root.appendingPathComponent("index.json"))
        #expect(index.count < 4096, "索引不应承载位图，实测 \(index.count) 字节")
    }

    @Test("删除缓存条目时连带删除 cache/ 副本与缩略图")
    func removeDeletesCachedCopy() throws {
        let root = try makeTemp()
        let store = HistoryStore(directory: root)
        let entry = try #require(store.addCachedImage(
            pngData: Data(repeating: 0x01, count: 256),
            thumbnailPNG: thumbnail(),
            pixelWidth: 10,
            pixelHeight: 10,
            kind: .screenshot
        ))
        let cachedURL = entry.fileURL
        #expect(FileManager.default.fileExists(atPath: cachedURL.path))

        store.remove(entry.id)

        #expect(store.entries.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: cachedURL.path))
        #expect(store.thumbnailURL(for: entry) == nil)
    }

    @Test("缓存写入失败：返回 nil、记录错误、不留下坏条目")
    func addCachedImageFailureReturnsNil() throws {
        let root = try makeTemp()
        // 用同名文件占住 cache 目录的位置，制造写入失败。
        try Data().write(to: root.appendingPathComponent("cache"))
        let store = HistoryStore(directory: root)

        let entry = store.addCachedImage(
            pngData: Data(repeating: 0x01, count: 64),
            thumbnailPNG: thumbnail(),
            pixelWidth: 1,
            pixelHeight: 1,
            kind: .screenshot
        )

        #expect(entry == nil)
        #expect(store.lastError != nil)
        #expect(store.entries.isEmpty)
    }

    @Test("旧索引（缺少新字段）按默认值解码，不当作损坏")
    func legacyIndexDecodesDefaults() throws {
        let root = try makeTemp()
        let id = UUID()
        // 旧版本写出的索引：没有 kind/source/isCached/isFavorite。
        let legacy = """
        [
          {
            "id": "\(id.uuidString)",
            "createdAt": "2024-05-01T10:00:00Z",
            "filePath": "/tmp/legacy-shot.png",
            "pixelWidth": 640,
            "pixelHeight": 480
          }
        ]
        """
        try Data(legacy.utf8).write(to: root.appendingPathComponent("index.json"))

        let store = HistoryStore(directory: root)

        let entry = try #require(store.entries.first)
        #expect(store.entries.count == 1)
        #expect(store.lastError == nil)
        #expect(entry.id == id)
        #expect(entry.filePath == "/tmp/legacy-shot.png")
        #expect(entry.kind == .screenshot)
        #expect(entry.source == nil)
        #expect(entry.isCached == false)
        #expect(entry.isFavorite == false)
        // 旧索引没有被改名留档，说明它被正常读懂了。
        #expect(!FileManager.default.fileExists(
            atPath: root.appendingPathComponent("index.corrupted.json").path
        ))
    }

    @Test("收藏状态跨 reload 保持")
    func favoriteSurvivesReload() throws {
        let root = try makeTemp()
        let store = HistoryStore(directory: root)
        let kept = store.add(
            fileURL: try makeSourceFile(in: root, name: "a.png"),
            thumbnailPNG: nil, pixelWidth: 1, pixelHeight: 1
        )
        let other = store.add(
            fileURL: try makeSourceFile(in: root, name: "b.png"),
            thumbnailPNG: nil, pixelWidth: 1, pixelHeight: 1
        )

        store.setFavorite(kept.id, isFavorite: true)

        var reopened = HistoryStore(directory: root)
        #expect(reopened.entries.first { $0.id == kept.id }?.isFavorite == true)
        #expect(reopened.entries.first { $0.id == other.id }?.isFavorite == false)

        reopened.setFavorite(kept.id, isFavorite: false)
        reopened = HistoryStore(directory: root)
        #expect(reopened.entries.first { $0.id == kept.id }?.isFavorite == false)
    }

    @Test("列表按时间倒序，最新在前")
    func ordersNewestFirst() throws {
        let root = try makeTemp()
        let store = HistoryStore(directory: root)
        let older = store.add(
            fileURL: try makeSourceFile(in: root, name: "a.png"),
            thumbnailPNG: nil, pixelWidth: 10, pixelHeight: 10
        )
        let newer = store.add(
            fileURL: try makeSourceFile(in: root, name: "b.png"),
            thumbnailPNG: nil, pixelWidth: 20, pixelHeight: 20
        )

        #expect(store.entries.map(\.id) == [newer.id, older.id])
        #expect(store.entries.first?.createdAt ?? .distantPast >= store.entries.last?.createdAt ?? .distantFuture)
    }

    // MARK: - 契约：只记路径，不存位图

    @Test("索引里只有元数据与路径，没有大块位图数据")
    func indexCarriesNoBitmapPayload() throws {
        let root = try makeTemp()
        let store = HistoryStore(directory: root)
        // 源文件故意做大：如果实现把图塞进索引，索引体积会跟着涨。
        let source = root.appendingPathComponent("big.png")
        try Data(repeating: 0xCD, count: 4 * 1024 * 1024).write(to: source)

        store.add(fileURL: source, thumbnailPNG: thumbnail(), pixelWidth: 3000, pixelHeight: 2000)

        let index = try Data(contentsOf: root.appendingPathComponent("index.json"))
        #expect(index.count < 4096, "索引不应承载位图，实测 \(index.count) 字节")

        let json = String(decoding: index, as: UTF8.self)
        // JSONEncoder 会把路径里的 `/` 转义成 `\/`，比较前先还原。
        #expect(json.replacingOccurrences(of: "\\/", with: "/").contains(source.path))
        // 全尺寸位图不被复制第二份：目录里只有索引 + 缩略图 + 源文件本身。
        let names = try FileManager.default.contentsOfDirectory(atPath: root.path).sorted()
        #expect(names == ["big.png", "index.json", "thumbnails"])
    }

    // MARK: - 契约：文件丢失不报错

    @Test("源文件被移走后条目标记为文件已丢失，且不产生错误")
    func missingSourceIsReportedNotThrown() throws {
        let root = try makeTemp()
        let store = HistoryStore(directory: root)
        let source = try makeSourceFile(in: root)
        let entry = store.add(fileURL: source, thumbnailPNG: thumbnail(), pixelWidth: 100, pixelHeight: 100)
        #expect(entry.isFilePresent)

        try FileManager.default.removeItem(at: source)

        #expect(entry.isFilePresent == false)
        // 重新读索引不能因为文件丢失而失败或丢弃条目。
        let reopened = HistoryStore(directory: root)
        #expect(reopened.entries.count == 1)
        #expect(reopened.entries.first?.isFilePresent == false)
        #expect(reopened.lastError == nil)
    }

    @Test("清理丢失条目只删引用，不动现有文件")
    func removeMissingFilesKeepsExistingOnes() throws {
        let root = try makeTemp()
        let store = HistoryStore(directory: root)
        let kept = try makeSourceFile(in: root, name: "kept.png")
        let doomed = try makeSourceFile(in: root, name: "doomed.png")
        let keptEntry = store.add(fileURL: kept, thumbnailPNG: nil, pixelWidth: 1, pixelHeight: 1)
        store.add(fileURL: doomed, thumbnailPNG: nil, pixelWidth: 1, pixelHeight: 1)
        try FileManager.default.removeItem(at: doomed)

        let removed = store.removeMissingFiles()

        #expect(removed == 1)
        #expect(store.entries.map(\.id) == [keptEntry.id])
        #expect(FileManager.default.fileExists(atPath: kept.path))
    }

    @Test("批量清理丢失条目：缩略图一并删除，且索引落盘后可读回")
    func removeMissingFilesPersistsOnce() throws {
        let root = try makeTemp()
        let store = HistoryStore(directory: root)
        let kept = try makeSourceFile(in: root, name: "kept.png")
        let keptEntry = store.add(fileURL: kept, thumbnailPNG: thumbnail(1), pixelWidth: 1, pixelHeight: 1)
        var doomedEntries: [HistoryEntry] = []
        for index in 0..<3 {
            let doomed = try makeSourceFile(in: root, name: "doomed-\(index).png")
            doomedEntries.append(store.add(
                fileURL: doomed, thumbnailPNG: thumbnail(UInt8(index + 2)), pixelWidth: 1, pixelHeight: 1
            ))
            try FileManager.default.removeItem(at: doomed)
        }

        #expect(store.removeMissingFiles() == 3)

        for entry in doomedEntries {
            #expect(store.thumbnailURL(for: entry) == nil)
        }
        #expect(store.thumbnailURL(for: keptEntry) != nil)
        // 重新打开：索引里只剩保留的那条
        #expect(HistoryStore(directory: root).entries.map(\.id) == [keptEntry.id])
    }

    // MARK: - 契约：容量上限

    @Test("超出上限淘汰最旧的，并删除其缩略图")
    func trimsOldestBeyondLimit() throws {
        let root = try makeTemp()
        let store = HistoryStore(directory: root, maximumEntries: 3)
        let source = try makeSourceFile(in: root)
        var added: [HistoryEntry] = []
        for index in 0..<5 {
            added.append(store.add(
                fileURL: source,
                thumbnailPNG: thumbnail(UInt8(index)),
                pixelWidth: index, pixelHeight: index
            ))
        }

        #expect(store.entries.count == 3)
        // 留下的是最后 3 条，最新在最前。
        #expect(store.entries.map(\.id) == [added[4].id, added[3].id, added[2].id])
        // 被淘汰条目的缩略图必须一起清理，否则目录会随时间无限增长。
        #expect(store.thumbnailURL(for: added[0]) == nil)
        #expect(store.thumbnailURL(for: added[1]) == nil)
        #expect(store.thumbnailURL(for: added[4]) != nil)
        #expect(HistoryStore(directory: root).entries.count == 3)
    }

    @Test("淘汰时删除缓存副本，但不碰用户保存的文件")
    func trimsDeleteCachedCopiesOnly() throws {
        let root = try makeTemp()
        let store = HistoryStore(directory: root, maximumEntries: 2)
        let userFile = try makeSourceFile(in: root, name: "user.png")

        let evicted = try #require(store.addCachedImage(
            pngData: Data(repeating: 0x11, count: 128),
            thumbnailPNG: thumbnail(1), pixelWidth: 1, pixelHeight: 1, kind: .screenshot
        ))
        let keptUser = store.add(
            fileURL: userFile, thumbnailPNG: thumbnail(2),
            pixelWidth: 1, pixelHeight: 1
        )
        let keptCached = try #require(store.addCachedImage(
            pngData: Data(repeating: 0x33, count: 128),
            thumbnailPNG: thumbnail(3), pixelWidth: 1, pixelHeight: 1, kind: .screenshot
        ))

        #expect(store.entries.map(\.id) == [keptCached.id, keptUser.id])
        // 被淘汰的缓存副本与缩略图都清掉。
        #expect(!FileManager.default.fileExists(atPath: evicted.filePath))
        #expect(store.thumbnailURL(for: evicted) == nil)
        // 用户文件不归历史所有，淘汰不能动它。
        #expect(FileManager.default.fileExists(atPath: userFile.path))
        #expect(FileManager.default.fileExists(atPath: keptCached.filePath))
        #expect(HistoryStore(directory: root).entries.count == 2)
    }

    // MARK: - 契约：删除不影响源文件

    @Test("删除条目与一键清空都不动源文件")
    func removeAndClearKeepSourceFiles() throws {
        let root = try makeTemp()
        let store = HistoryStore(directory: root)
        let first = try makeSourceFile(in: root, name: "one.png")
        let second = try makeSourceFile(in: root, name: "two.png")
        let firstEntry = store.add(fileURL: first, thumbnailPNG: thumbnail(), pixelWidth: 1, pixelHeight: 1)
        store.add(fileURL: second, thumbnailPNG: thumbnail(), pixelWidth: 1, pixelHeight: 1)

        store.remove(firstEntry.id)

        #expect(store.entries.count == 1)
        #expect(FileManager.default.fileExists(atPath: first.path), "删引用不该删用户的图")

        store.clear()

        #expect(store.entries.isEmpty)
        #expect(FileManager.default.fileExists(atPath: first.path))
        #expect(FileManager.default.fileExists(atPath: second.path))
        #expect(HistoryStore(directory: root).entries.isEmpty)
    }

    @Test("cached 标记与缓存路径不一致时仍不删用户文件")
    func cachedFlagAloneCannotDeleteUserFile() throws {
        let root = try makeTemp()
        let store = HistoryStore(directory: root)
        let userFile = try makeSourceFile(in: root, name: "user.png")
        // 模拟被改坏的索引：用户文件却标了 isCached。
        let entry = store.add(
            fileURL: userFile, thumbnailPNG: nil,
            pixelWidth: 1, pixelHeight: 1, cached: true
        )

        store.remove(entry.id)

        #expect(FileManager.default.fileExists(atPath: userFile.path))
    }

    @Test("一键清空后缩略图目录一并移除")
    func clearRemovesThumbnails() throws {
        let root = try makeTemp()
        let store = HistoryStore(directory: root)
        let entry = store.add(
            fileURL: try makeSourceFile(in: root),
            thumbnailPNG: thumbnail(), pixelWidth: 1, pixelHeight: 1
        )
        #expect(store.thumbnailURL(for: entry) != nil)

        store.clear()

        #expect(!FileManager.default.fileExists(
            atPath: root.appendingPathComponent("thumbnails").path
        ))
    }

    @Test("一键清空后缓存目录一并移除，索引仍可读")
    func clearRemovesCache() throws {
        let root = try makeTemp()
        let store = HistoryStore(directory: root)
        let entry = try #require(store.addCachedImage(
            pngData: Data(repeating: 0x77, count: 512),
            thumbnailPNG: thumbnail(), pixelWidth: 1, pixelHeight: 1, kind: .screenshot
        ))
        let cachedURL = entry.fileURL
        #expect(FileManager.default.fileExists(atPath: store.cacheDirectoryURL().path))

        store.clear()

        #expect(!FileManager.default.fileExists(atPath: cachedURL.path))
        #expect(!FileManager.default.fileExists(atPath: store.cacheDirectoryURL().path))
        #expect(HistoryStore(directory: root).entries.isEmpty)
    }

    // MARK: - 健壮性

    @Test("索引损坏时降级为空列表并留档，不抛错")
    func corruptedIndexDegradesGracefully() throws {
        let root = try makeTemp()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("{ 这不是 JSON".utf8).write(to: root.appendingPathComponent("index.json"))

        let store = HistoryStore(directory: root)

        #expect(store.entries.isEmpty)
        #expect(store.lastError != nil)
        // 损坏的索引被改名保留，而不是被静默删除。
        #expect(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("index.corrupted.json").path
        ))
    }

    @Test("缩略图写入失败不影响条目本身")
    func thumbnailFailureDoesNotDropEntry() throws {
        let root = try makeTemp()
        // 用一个「同名文件」占住缩略图目录的位置，制造写入失败。
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data().write(to: root.appendingPathComponent("thumbnails"))
        let store = HistoryStore(directory: root)

        let entry = store.add(
            fileURL: try makeSourceFile(in: root),
            thumbnailPNG: thumbnail(), pixelWidth: 1, pixelHeight: 1
        )

        #expect(store.entries.contains { $0.id == entry.id })
        #expect(store.lastError != nil)
        #expect(store.thumbnailURL(for: entry) == nil)
    }
}
