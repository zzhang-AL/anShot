//
//  HistoryStore.swift
//  AnShotCore
//
//  历史记录（M3-6）：本机保存的截图索引。
//
//  ── 契约（m3-advanced/model.md §7 + 流程闭环 §1）───────────
//
//  * 索引只存**元数据 + 缩略图路径 + 全尺寸文件路径**，位图不进 JSON：
//    用户保存过的图按路径引用；没保存的产物才复制一份到 `cache/`；
//  * 历史记录**引用**用户已保存的文件：用户把文件移走或删掉，条目显示为
//    「文件已丢失」，而不是报错或让整个列表不可用；
//  * 删除/淘汰只删 `cache/` 里的副本，用户文件永不触碰；
//  * 容量有上限，超出按时间淘汰最旧；
//  * 全部本机，提供一键清空。
//
//  ── 为什么缩略图单独存文件 ────────────────────────────────
//
//  把缩略图 base64 内联进索引 JSON 会让「读索引」变成「读几 MB 字符串再解码」，
//  而且任何一次写入都要重写全部缩略图。分成 `<id>.png` 后索引始终很小，
//  单条增删只动一个几十 KB 的文件。
//

import Foundation

/// 产物类型。历史面板按它显示角标，也决定「重新编辑」走哪条路径。
public enum HistoryEntryKind: String, Codable, Sendable, CaseIterable {
    case screenshot
    case longScreenshot
    case recording

    public var displayName: String {
        switch self {
        case .screenshot: return "截图"
        case .longScreenshot: return "长截图"
        case .recording: return "录屏"
        }
    }
}

/// 截图来源的应用/窗口与捕获方式。
///
/// 全部字段都是可选的：来源信息只是锦上添花，拿不到（权限不足、导入的图、
/// 旧索引）时界面应当照常显示条目，而不是让整条记录解不出来。
public struct HistorySource: Codable, Equatable, Sendable {
    public var appName: String?
    public var windowTitle: String?
    /// region / window / display / application / imported
    public var mode: String?

    public init(appName: String? = nil, windowTitle: String? = nil, mode: String? = nil) {
        self.appName = appName
        self.windowTitle = windowTitle
        self.mode = mode
    }
}

/// 一条历史记录。
public struct HistoryEntry: Codable, Equatable, Sendable, Identifiable {

    /// 稳定标识，同时是缩略图与缓存副本的文件名。
    public let id: UUID

    /// 截图保存时间，列表按它倒序。
    public let createdAt: Date

    /// 全尺寸图在磁盘上的路径。可能是用户保存的文件，也可能是历史缓存里的副本。
    public let filePath: String

    /// 图像的像素尺寸（不是文件大小），用于列表显示与「重新编辑」判断。
    public let pixelWidth: Int
    public let pixelHeight: Int

    /// 产物类型。
    public let kind: HistoryEntryKind

    /// 来源应用/窗口；拿不到时为空。
    public let source: HistorySource?

    /// `filePath` 是否位于历史缓存目录。
    ///
    /// 这是删除时的第一判据：只有缓存副本归我们所有，用户保存的文件
    /// 即使条目被删也必须留在原地。`HistoryStore` 还会核对路径确实在
    /// `cache/` 下，防止被改坏的索引误删用户文件。
    public let isCached: Bool

    /// 收藏标记。用户置顶留用的条目，淘汰时不会被优先清掉（仍受上限约束）。
    public var isFavorite: Bool

    public init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        filePath: String,
        pixelWidth: Int,
        pixelHeight: Int,
        kind: HistoryEntryKind = .screenshot,
        source: HistorySource? = nil,
        isCached: Bool = false,
        isFavorite: Bool = false
    ) {
        self.id = id
        self.createdAt = createdAt
        self.filePath = filePath
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.kind = kind
        self.source = source
        self.isCached = isCached
        self.isFavorite = isFavorite
    }

    /// 旧索引里没有 `kind/source/isCached/isFavorite`，必须给默认值，
    /// 否则升级后第一次启动会把用户的历史记录整体判为「索引损坏」。
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        filePath = try container.decode(String.self, forKey: .filePath)
        pixelWidth = try container.decode(Int.self, forKey: .pixelWidth)
        pixelHeight = try container.decode(Int.self, forKey: .pixelHeight)
        kind = try container.decodeIfPresent(HistoryEntryKind.self, forKey: .kind) ?? .screenshot
        source = try container.decodeIfPresent(HistorySource.self, forKey: .source)
        isCached = try container.decodeIfPresent(Bool.self, forKey: .isCached) ?? false
        isFavorite = try container.decodeIfPresent(Bool.self, forKey: .isFavorite) ?? false
    }

    private enum CodingKeys: String, CodingKey {
        case id, createdAt, filePath, pixelWidth, pixelHeight
        case kind, source, isCached, isFavorite
    }

    /// 源文件是否还在。
    ///
    /// 契约明确要求这里**不抛错**：用户整理文件是正常操作，界面需要区分
    /// 「列表坏了」与「这张图被移走了」。
    public var isFilePresent: Bool {
        FileManager.default.fileExists(atPath: filePath)
    }

    /// 源文件所在 URL。
    public var fileURL: URL {
        URL(fileURLWithPath: filePath)
    }
}

/// 历史记录存储。
///
/// 非 `Sendable`：它持有可变状态且被主线程独占访问（界面只有一个入口），
/// 需要跨线程时由调用方自行加锁——本项目没有这种用法。
public final class HistoryStore {

    /// 索引文件名。
    private static let indexFileName = "index.json"

    /// 缩略图目录名。
    private static let thumbnailsDirectoryName = "thumbnails"

    /// 全尺寸缓存副本目录名。
    private static let cacheDirectoryName = "cache"

    private let directory: URL
    private let thumbnailsDirectory: URL
    private let cacheDirectory: URL
    private let fileManager: FileManager

    /// 条目上限；超出时淘汰最旧的。
    public let maximumEntries: Int

    /// 当前条目，**按时间倒序**（最新在前）。
    public private(set) var entries: [HistoryEntry] = []

    /// 最近一次操作的错误（界面用它提示，不打断流程）。
    public private(set) var lastError: String?

    /// - Parameters:
    ///   - directory: 索引与缩略图的存放目录。
    ///   - maximumEntries: 条目上限。
    ///   - fileManager: 便于测试注入。
    public init(
        directory: URL,
        maximumEntries: Int = 200,
        fileManager: FileManager = .default
    ) {
        self.directory = directory
        self.thumbnailsDirectory = directory.appendingPathComponent(Self.thumbnailsDirectoryName)
        self.cacheDirectory = directory.appendingPathComponent(Self.cacheDirectoryName)
        self.maximumEntries = max(1, maximumEntries)
        self.fileManager = fileManager
        reload()
    }

    /// 应用默认目录：`~/Library/Application Support/anShot/history/`。
    public static func defaultDirectory(
        fileManager: FileManager = .default
    ) -> URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        return base
            .appendingPathComponent("anShot", isDirectory: true)
            .appendingPathComponent("history", isDirectory: true)
    }

    /// 缩略图文件路径（不存在时为 nil）。
    public func thumbnailURL(for entry: HistoryEntry) -> URL? {
        let url = thumbnailsDirectory.appendingPathComponent("\(entry.id.uuidString).png")
        return fileManager.fileExists(atPath: url.path) ? url : nil
    }

    /// 全尺寸缓存副本的存放目录（`history/cache/`）。
    ///
    /// 只返回路径、不保证已存在：`add` 第一条普通记录时不该凭空建一个空目录，
    /// 否则「索引里只有元数据」这类对目录结构的断言会被无谓地打破。
    public func cacheDirectoryURL() -> URL {
        cacheDirectory
    }

    // MARK: - 读写

    /// 从磁盘重新读取索引。
    ///
    /// 索引损坏时**不抛错**：历史记录是便利功能，读不出来就当空的重新开始，
    /// 而不是让应用起不来。损坏内容会被改名保留，避免静默丢弃用户数据。
    public func reload() {
        lastError = nil
        guard fileManager.fileExists(atPath: indexURL.path) else {
            entries = []
            return
        }
        do {
            let data = try Data(contentsOf: indexURL)
            // 解码策略必须与 persist() 的编码策略**对称**：只设一边会让
            // 写出去的索引自己读不回来（实测报「not in the correct format」）。
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            entries = try decoder.decode([HistoryEntry].self, from: data)
                .sorted { $0.createdAt > $1.createdAt }
        } catch {
            lastError = "历史索引读取失败：\(error.localizedDescription)"
            preserveCorruptedIndex()
            entries = []
        }
    }

    /// 追加一条记录（引用磁盘上已有的全尺寸图）。
    ///
    /// - Parameters:
    ///   - fileURL: 已保存到磁盘的全尺寸图。
    ///   - thumbnailPNG: 小尺寸缩略图的 PNG 数据。
    ///   - pixelWidth: 全尺寸图的像素宽。
    ///   - pixelHeight: 全尺寸图的像素高。
    ///   - kind: 产物类型；默认按普通截图处理。
    ///   - source: 来源应用/窗口。
    ///   - cached: `fileURL` 是否位于缓存目录。只有 `true` 时删除条目才会连带删文件。
    @discardableResult
    public func add(
        fileURL: URL,
        thumbnailPNG: Data?,
        pixelWidth: Int,
        pixelHeight: Int,
        kind: HistoryEntryKind = .screenshot,
        source: HistorySource? = nil,
        cached: Bool = false
    ) -> HistoryEntry {
        lastError = nil
        let entry = HistoryEntry(
            filePath: fileURL.path,
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight,
            kind: kind,
            source: source,
            isCached: cached
        )
        writeThumbnail(thumbnailPNG, for: entry)
        insert(entry)
        return entry
    }

    /// 把一张 PNG 复制进历史缓存目录（`cache/<uuid>.png`）并生成条目。
    ///
    /// 未保存到用户目录的产物（例如直接复制走的截图、临时捕获）也要能出现在
    /// 历史里，就靠这份副本续命；写盘失败时没有可供引用的文件，返回 nil
    /// 并留下 `lastError`，而不是造一条注定「文件已丢失」的坏记录。
    @discardableResult
    public func addCachedImage(
        pngData: Data,
        thumbnailPNG: Data?,
        pixelWidth: Int,
        pixelHeight: Int,
        kind: HistoryEntryKind,
        source: HistorySource? = nil
    ) -> HistoryEntry? {
        lastError = nil
        let id = UUID()
        let cachedURL = cacheDirectory.appendingPathComponent("\(id.uuidString).png")
        do {
            try fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
            try pngData.write(to: cachedURL, options: .atomic)
        } catch {
            lastError = "历史缓存写入失败：\(error.localizedDescription)"
            return nil
        }

        let entry = HistoryEntry(
            id: id,
            filePath: cachedURL.path,
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight,
            kind: kind,
            source: source,
            isCached: true
        )
        writeThumbnail(thumbnailPNG, for: entry)
        insert(entry)
        return entry
    }

    /// 设置收藏状态。
    ///
    /// 收藏是条目自身的属性，不改排序：用户按时间找图时，位置跳动比高亮更烦人。
    public func setFavorite(_ id: UUID, isFavorite: Bool) {
        lastError = nil
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        guard entries[index].isFavorite != isFavorite else { return }
        entries[index].isFavorite = isFavorite
        persist()
    }

    /// 删除一条记录（连同它的缩略图与缓存副本）。
    ///
    /// **不动用户文件**：历史记录是引用，删掉引用不等于删掉用户的图。
    public func remove(_ id: UUID) {
        lastError = nil
        guard let entry = entries.first(where: { $0.id == id }) else { return }
        entries.removeAll { $0.id == id }
        deleteArtifacts(for: entry)
        persist()
    }

    /// 一键清空（契约要求的隐私保证）。
    ///
    /// 同样**不动用户文件**，只清索引、缩略图与缓存目录。
    public func clear() {
        lastError = nil
        entries.removeAll()
        try? fileManager.removeItem(at: thumbnailsDirectory)
        try? fileManager.removeItem(at: cacheDirectory)
        persist()
    }

    /// 移除所有源文件已丢失的条目（用户主动整理）。
    ///
    /// 缓存与用户文件一视同仁：文件不在了，条目就只剩一个打不开的壳。
    /// 只写一次索引：逐条调用 `remove` 会让删 N 条就重写 N 次 `index.json`。
    public func removeMissingFiles() -> Int {
        let missing = entries.filter { !$0.isFilePresent }
        guard !missing.isEmpty else { return 0 }
        lastError = nil
        let missingIDs = Set(missing.map(\.id))
        entries.removeAll { missingIDs.contains($0.id) }
        for entry in missing {
            deleteArtifacts(for: entry)
        }
        persist()
        return missing.count
    }

    /// 超出上限时按时间淘汰最旧。
    private func trim() {
        guard entries.count > maximumEntries else { return }
        let dropped = entries[maximumEntries...]
        for entry in dropped {
            deleteArtifacts(for: entry)
        }
        entries.removeSubrange(maximumEntries...)
    }

    // MARK: - 产物文件

    /// 把条目追加到最前并落盘。
    private func insert(_ entry: HistoryEntry) {
        entries.insert(entry, at: 0)
        trim()
        persist()
    }

    /// 写缩略图；失败只记错误，不影响条目本身。
    private func writeThumbnail(_ pngData: Data?, for entry: HistoryEntry) {
        guard let pngData else { return }
        do {
            try fileManager.createDirectory(
                at: thumbnailsDirectory,
                withIntermediateDirectories: true
            )
            try pngData.write(
                to: thumbnailsDirectory.appendingPathComponent("\(entry.id.uuidString).png")
            )
        } catch {
            // 缩略图写不进去不该让整条记录失败：列表可以退化显示占位图标。
            lastError = "缩略图写入失败：\(error.localizedDescription)"
        }
    }

    /// 删除条目自己的派生文件：缩略图，以及（且仅是）缓存的副本。
    private func deleteArtifacts(for entry: HistoryEntry) {
        try? fileManager.removeItem(
            at: thumbnailsDirectory.appendingPathComponent("\(entry.id.uuidString).png")
        )
        removeCachedCopyIfOwned(by: entry)
    }

    /// 只删除缓存目录内的副本。
    ///
    /// 除 `isCached` 外再按路径兜一层：索引可能被旧版本或手工编辑成
    /// 「用户文件 + isCached = true」，那种情况下也不能删用户的图。
    private func removeCachedCopyIfOwned(by entry: HistoryEntry) {
        guard entry.isCached else { return }
        let cachePrefix = cacheDirectory.standardizedFileURL.path + "/"
        let filePath = entry.fileURL.standardizedFileURL.path
        guard filePath.hasPrefix(cachePrefix) else { return }
        try? fileManager.removeItem(atPath: filePath)
    }

    /// 写回索引。
    private func persist() {
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(entries).write(to: indexURL, options: .atomic)
        } catch {
            lastError = "历史索引写入失败：\(error.localizedDescription)"
        }
    }

    /// 把损坏的索引改名留档，不静默删除。
    private func preserveCorruptedIndex() {
        let broken = directory.appendingPathComponent("index.corrupted.json")
        try? fileManager.removeItem(at: broken)
        try? fileManager.moveItem(at: indexURL, to: broken)
    }

    private var indexURL: URL {
        directory.appendingPathComponent(Self.indexFileName)
    }
}
