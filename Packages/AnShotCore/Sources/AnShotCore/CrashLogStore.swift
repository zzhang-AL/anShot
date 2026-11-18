//
//  CrashLogStore.swift
//  AnShotCore
//
//  系统崩溃报告的**只读索引**：把 `~/Library/Logs/DiagnosticReports` 里
//  anShot 的 `.ips` / `.crash` 报告变成列表需要的一行信息。
//
//  ── 为什么只做「索引」而不搬文件 ──────────────────────────────
//
//  崩溃报告归系统所有：系统会按自己的策略把旧报告移进 `Retired/`、
//  压缩、甚至清理。如果这里复制或删除，用户在其他诊断工具里就看不到
//  同一份证据了。所以 Store 不写盘、不删除，`details(for:)` 也只按需
//  读取原文件；文件被系统清掉时返回一句可读说明，而不是报错或丢掉条目。
//
//  ── 为什么两种格式都要自己解析 ────────────────────────────────
//
//  macOS 12+ 的 `.ips` 是「首行 JSON 头 + 余下 JSON 负载」，旧格式
//  `.crash` 是带缩进键值对的纯文本。系统并不保证字段齐全（挂起/资源
//  报告可以没有 exception），也不保证每个第三方工具写出的文件都严格
//  合法。因此解析必须**逐字段容错**：拿不到结构化字段就退化成文本摘要，
//  条目仍然保留——「少一行摘要」比「报告从列表里消失」代价小得多。
//
//  文本格式里 `Version: 1.2.3 (45)` 同时包含应用版本与构建号；
//  `.ips` 则在头部把它们拆成 `app_version` / `build_version` 两个字段。
//  两者在这里被归一成同一组值，UI 不需要知道报告格式。
//

import Foundation

/// 一条崩溃报告的索引信息。
///
/// 只保留列表需要的字段：完整内容可能几百 KB，打开窗口时不应该把
/// 所有报告都读进内存。`details(for:)` 负责按需读取原文。
public struct CrashLogEntry: Identifiable, Equatable, Sendable {

    /// 文件路径。作为 `id` 使用，因为同一份报告在列表里只应出现一次。
    public let id: String
    public let url: URL
    /// 报告时间；解析失败时退化为文件修改时间，保证排序仍有意义。
    public let date: Date
    public let appVersion: String?
    public let buildVersion: String?
    /// `"ips"` 或 `"crash"`，用于列表上的类型标记。
    public let kind: String
    /// 异常类型 / 信号 / termination reason 拼成的短句，供列表直接展示。
    public let summary: String

    public init(
        url: URL,
        date: Date,
        appVersion: String? = nil,
        buildVersion: String? = nil,
        kind: String,
        summary: String
    ) {
        self.id = url.path
        self.url = url
        self.date = date
        self.appVersion = appVersion
        self.buildVersion = buildVersion
        self.kind = kind
        self.summary = summary
    }
}

/// 崩溃报告的只读访问入口。
///
/// 无实例状态：报告的来源是文件系统，Store 只是把一次扫描的结果整理成
/// 值类型数组。这样 UI 刷新时不需要管理存储对象的生命周期。
public enum CrashLogStore {

    // MARK: - 目录

    /// 默认扫描目录（用户级优先，系统级兜底）。
    ///
    /// 同时返回 `Retired/`：系统把旧报告移进去而不是删除，用户的
    /// 「上周那一次崩溃」很可能只存在于那里。系统级目录在沙盒/权限
    /// 不允许时会被扫描静默跳过。
    public static func defaultDirectories() -> [URL] {
        let fileManager = FileManager.default
        let userRoot = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/DiagnosticReports", isDirectory: true)
        let systemRoot = URL(
            fileURLWithPath: "/Library/Logs/DiagnosticReports",
            isDirectory: true
        )
        return [
            userRoot,
            userRoot.appendingPathComponent("Retired", isDirectory: true),
            systemRoot,
            systemRoot.appendingPathComponent("Retired", isDirectory: true),
        ]
    }

    // MARK: - 扫描

    /// 扫描并解析崩溃报告。
    ///
    /// - Parameters:
    ///   - processName: 进程名。只收**文件名或报告内容**里出现该名字的报告，
    ///     `anShot Helper` 这类子进程报告也会命中。
    ///   - directories: 为 nil 时使用 `defaultDirectories()`；传入时只扫描给定目录
    ///     （测试用临时目录走这条路径）。
    ///   - limit: 最多返回多少条。按报告时间倒序，先排序再截断。
    public static func reports(
        processName: String = "anShot",
        directories: [URL]? = nil,
        limit: Int = 50
    ) -> [CrashLogEntry] {
        guard limit > 0, !processName.isEmpty else { return [] }

        let roots = directories ?? defaultDirectories()
        var candidates: [CandidateReport] = []

        for url in candidateFiles(in: roots) {
            guard let candidate = inspectCandidate(url: url, processName: processName) else {
                continue
            }
            candidates.append(candidate)
        }

        // 先按头部时间戳倒序截断前 `limit` 条，再解析完整 `.ips` payload 摘要。
        candidates.sort { lhs, rhs in
            if lhs.sortDate != rhs.sortDate {
                return lhs.sortDate > rhs.sortDate
            }
            // 同一秒内的报告没有内在顺序；用路径保证每次刷新结果稳定，
            // 避免列表在刷新时无谓地跳动。
            return lhs.url.path < rhs.url.path
        }

        var entries: [CrashLogEntry] = []
        entries.reserveCapacity(min(limit, candidates.count))
        for candidate in candidates.prefix(limit) {
            guard let data = readData(at: candidate.url) else { continue }
            let parsed: ParsedReport
            switch candidate.kind {
            case "ips":
                parsed = parseIPS(data: data, preParsedHeader: candidate.ipsHeader)
            default:
                parsed = parseCrash(data: data)
            }

            entries.append(CrashLogEntry(
                url: candidate.url,
                date: parsed.date ?? candidate.sortDate,
                appVersion: parsed.appVersion,
                buildVersion: parsed.buildVersion,
                kind: candidate.kind,
                summary: parsed.summary
            ))
        }

        return entries
    }

    /// 轻量统计匹配的崩溃报告数量（最多计数到 `limit` 即提前停止，不解析完整负载）。
    public static func reportCount(
        processName: String = "anShot",
        directories: [URL]? = nil,
        limit: Int = 50
    ) -> Int {
        guard limit > 0, !processName.isEmpty else { return 0 }
        let roots = directories ?? defaultDirectories()
        var count = 0
        for url in candidateFiles(in: roots) {
            if matchesCandidateProcess(url: url, processName: processName) != nil {
                count += 1
                if count >= limit {
                    return limit
                }
            }
        }
        return count
    }

    // MARK: - 详情

    /// 按需读取报告原文。
    ///
    /// 不做格式化/裁剪：崩溃报告的价值往往在用户没预料到的行里，
    /// 由 UI 原样展示才能让人自己判断。文件已被系统清理时返回可读提示，
    /// 而不是抛出错误或返回空串。
    public static func details(for entry: CrashLogEntry) -> String {
        let url = entry.url
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              !isDirectory.boolValue
        else {
            return """
            报告文件已不存在。

            \(url.path)

            系统可能已经清理了这条日志，或它被移动/重命名了。
            """
        }

        do {
            let data = try Data(contentsOf: url, options: [.mappedIfSafe])
            guard !data.isEmpty else {
                return "报告文件是空的。\n\n\(url.path)"
            }
            // 崩溃报告理论上应是 UTF-8；用 replacement 解码而不是
            // `String(contentsOf:)`，这样个别二进制片段不会让整份详情变成错误页。
            return String(decoding: data, as: UTF8.self)
        } catch {
            return """
            无法读取报告文件：\(error.localizedDescription)

            \(url.path)
            """
        }
    }

    /// 读取并脱敏报告原文：将本机家目录替换为 `~`，并掩码设备与事件标识符。
    public static func redactedDetails(for entry: CrashLogEntry) -> String {
        redactSensitiveContent(in: details(for: entry))
    }

    /// 对崩溃文本执行隐私脱敏。
    static func redactSensitiveContent(in rawText: String) -> String {
        var text = rawText

        // 1. 替换本机家目录路径为 `~`（先长后短，避免前缀残留）。
        let home = FileManager.default.homeDirectoryForCurrentUser
        let homeCandidates = Set([
            home.standardizedFileURL.path,
            home.path,
            NSHomeDirectory(),
        ].filter { !$0.isEmpty && $0 != "/" })
        for path in homeCandidates.sorted(by: { $0.count > $1.count }) {
            let normalized = path.hasSuffix("/") ? String(path.dropLast()) : path
            guard !normalized.isEmpty else { continue }
            text = text.replacingOccurrences(of: normalized, with: "~")
        }

        // 2. 掩码 `.ips` JSON 中的 `crashReporterKey` / `anonUUID` / `incident`。
        text = RedactionPatterns.jsonIdentifiers.stringByReplacingMatches(
            in: text,
            range: NSRange(text.startIndex..<text.endIndex, in: text),
            withTemplate: "$1\"<redacted>\""
        )

        // 3. 掩码 `.crash` 纯文本键值行中的标识符。
        text = RedactionPatterns.textIdentifiers.stringByReplacingMatches(
            in: text,
            range: NSRange(text.startIndex..<text.endIndex, in: text),
            withTemplate: "$1$2<redacted>"
        )

        return text
    }

    // MARK: - 扫描辅助

    /// 枚举目录下的 `.ips` / `.crash` 普通文件。
    private static func candidateFiles(in directories: [URL]) -> [URL] {
        let fileManager = FileManager.default
        var seenDirectories = Set<String>()
        var seenFiles = Set<String>()
        var urls: [URL] = []

        for directory in directories {
            let root = directory.standardizedFileURL
            guard seenDirectories.insert(root.path).inserted else { continue }

            // 目录不存在（Retired 尚未创建）或没有权限时直接跳过：
            // 「没有报告」和「读不了某个目录」对用户是同一件事。
            guard let children = try? fileManager.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else {
                continue
            }

            for child in children {
                let ext = child.pathExtension.lowercased()
                guard ext == "ips" || ext == "crash" else { continue }
                let values = try? child.resourceValues(forKeys: [.isRegularFileKey])
                guard values?.isRegularFile == true else { continue }

                let standardized = child.standardizedFileURL
                guard seenFiles.insert(standardized.path).inserted else { continue }
                urls.append(standardized)
            }
        }

        return urls
    }

    private static func readData(at url: URL) -> Data? {
        try? Data(contentsOf: url, options: [.mappedIfSafe])
    }

    /// 只读取文件头部，用于判断「文件名没命中」的报告是否属于目标进程。
    private static func readPrefix(at url: URL, maxBytes: Int = 16 * 1024) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        return try? handle.read(upToCount: maxBytes)
    }

    private static func modificationDate(of url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate
    }

    // MARK: - 进程名匹配与轻量头解析

    private struct CandidateReport {
        let url: URL
        let kind: String
        let sortDate: Date
        let ipsHeader: [String: Any]?
    }

    /// 判断候选文件是否匹配目标进程，并返回轻量头部读取结果（仅 `reportCount` 使用）。
    private static func matchesCandidateProcess(url: URL, processName: String) -> String? {
        let kind = url.pathExtension.lowercased()
        guard kind == "ips" || kind == "crash" else { return nil }
        if matches(name: url.lastPathComponent, processName: processName) {
            return kind
        }
        return contentMentions(processName: processName, in: url, kind: kind) ? kind : nil
    }

    /// 阶段 1 轻量读取：仅解析 `.ips` 首行 JSON header 或 `.crash` 前 16KB 头部，
    /// 提取进程归属与时间戳，避免对超出 `limit` 的报告读取并解析完整 JSON payload。
    private static func inspectCandidate(url: URL, processName: String) -> CandidateReport? {
        let kind = url.pathExtension.lowercased()
        guard kind == "ips" || kind == "crash" else { return nil }
        let nameMatches = matches(name: url.lastPathComponent, processName: processName)
        let fallbackDate = modificationDate(of: url) ?? Date(timeIntervalSince1970: 0)

        switch kind {
        case "ips":
            guard let firstLine = readIPSHeaderLine(at: url) else {
                return nameMatches ? CandidateReport(url: url, kind: kind, sortDate: fallbackDate, ipsHeader: nil) : nil
            }
            let header = jsonObject(from: Data(firstLine.utf8))
            if !nameMatches {
                guard ipsHeaderMentions(processName: processName, header: header, rawLine: firstLine) else {
                    return nil
                }
            }
            let date = stringValue(header?["timestamp"]).flatMap(parseDate) ?? fallbackDate
            return CandidateReport(url: url, kind: kind, sortDate: date, ipsHeader: header)

        default:
            guard let prefix = readPrefix(at: url) else {
                return nameMatches ? CandidateReport(url: url, kind: kind, sortDate: fallbackDate, ipsHeader: nil) : nil
            }
            let text = String(decoding: prefix, as: UTF8.self)
            let lines = text.split(whereSeparator: \.isNewline)
            if !nameMatches {
                let processMatched = crashValue(for: "Process", in: lines).map {
                    matches(name: $0, processName: processName)
                } ?? false
                guard processMatched else { return nil }
            }
            let rawDate = crashValue(for: "Date/Time", in: lines)
            let date = rawDate.flatMap(parseDate) ?? rawDate.flatMap(parseLooseDate) ?? fallbackDate
            return CandidateReport(url: url, kind: kind, sortDate: date, ipsHeader: nil)
        }
    }

    private static func readIPSHeaderLine(at url: URL) -> String? {
        guard let prefix = readPrefix(at: url) else { return nil }
        let headerData: Data
        if let newline = prefix.firstIndex(of: 0x0A) {
            headerData = Data(prefix[..<newline])
        } else {
            headerData = prefix
        }

        var headerLine = String(decoding: headerData, as: UTF8.self)
        if headerLine.hasPrefix("\u{FEFF}") {
            headerLine.removeFirst()
        }
        return headerLine.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func ipsHeaderMentions(
        processName: String,
        header: [String: Any]?,
        rawLine: String
    ) -> Bool {
        if let header {
            let names = [
                stringValue(header["app_name"]),
                stringValue(header["name"]),
                stringValue(header["bundleID"]),
            ].compactMap { $0 }
            if !names.isEmpty {
                return names.contains { matches(name: $0, processName: processName) }
            }
        }
        return matches(name: rawLine, processName: processName)
    }

    private static func matches(name value: String, processName: String) -> Bool {
        value.range(
            of: processName,
            options: [.caseInsensitive, .diacriticInsensitive]
        ) != nil
    }

    /// 文件名未命中时的兜底：读取报告头部，找进程名。
    ///
    /// `.ips` 的 `app_name` / `name` / `bundleID` 都在首行 JSON 头里；
    /// `.crash` 仅匹配 `Process:` 字段（避免 `Path:` 中的目录名误匹配其他进程）。
    private static func contentMentions(
        processName: String,
        in url: URL,
        kind: String
    ) -> Bool {
        switch kind {
        case "ips":
            guard let headerLine = readIPSHeaderLine(at: url) else { return false }
            let header = jsonObject(from: Data(headerLine.utf8))
            return ipsHeaderMentions(processName: processName, header: header, rawLine: headerLine)

        default:
            guard let prefix = readPrefix(at: url) else { return false }
            let text = String(decoding: prefix, as: UTF8.self)
            let lines = text.split(whereSeparator: \.isNewline)
            guard let process = crashValue(for: "Process", in: lines) else { return false }
            return matches(name: process, processName: processName)
        }
    }

    // MARK: - .ips 解析

    private struct ParsedReport {
        var date: Date?
        var appVersion: String?
        var buildVersion: String?
        var summary: String
    }

    /// 解析 macOS 12+ 的 `.ips`：首行 JSON 头 + 余下 JSON 负载。
    ///
    /// 头与负载分别解析：头部通常完好，即使负载被截断（写盘时崩溃、
    /// 第三方工具截取）也仍能拿到版本和时间。
    private static func parseIPS(data: Data, preParsedHeader: [String: Any]? = nil) -> ParsedReport {
        let headerData: Data
        let payloadData: Data
        if let newline = data.firstIndex(of: 0x0A) {
            headerData = Data(data[..<newline])
            payloadData = Data(data[data.index(after: newline)...])
        } else {
            headerData = data
            payloadData = Data()
        }

        var headerLine = String(decoding: headerData, as: UTF8.self)
        if headerLine.hasPrefix("\u{FEFF}") {
            headerLine.removeFirst()
        }
        headerLine = headerLine.trimmingCharacters(in: .whitespacesAndNewlines)

        let header = preParsedHeader ?? jsonObject(from: Data(headerLine.utf8))
        let payload = jsonObject(from: payloadData)

        let dateText = stringValue(header?["timestamp"])
            ?? stringValue(payload?["captureTime"])
        let appVersion = stringValue(header?["app_version"])
            ?? stringValue(payload?["app_version"])
        let buildVersion = stringValue(header?["build_version"])
            ?? stringValue(payload?["build_version"])

        return ParsedReport(
            date: dateText.flatMap(parseDate),
            appVersion: appVersion,
            buildVersion: buildVersion,
            summary: ipSummary(
                header: header,
                payload: payload,
                headerLine: headerLine,
                payloadText: String(decoding: payloadData.prefix(4096), as: UTF8.self)
            )
        )
    }

    private static func ipSummary(
        header: [String: Any]?,
        payload: [String: Any]?,
        headerLine: String,
        payloadText: String
    ) -> String {
        var parts: [String] = []

        if let exception = payload.flatMap({ objectValue($0["exception"]) }) {
            if let type = stringValue(exception["type"]) {
                parts.append(type)
            }
            if let signal = stringValue(exception["signal"]) {
                parts.append(signal)
            }
        }

        if let termination = payload.flatMap({ objectValue($0["termination"]) }) {
            // `indicator` 是系统给出的人话原因（如 Segmentation fault: 11）；
            // 没有它时退回 namespace + code，至少保留信号类别。
            if let indicator = stringValue(termination["indicator"])
                ?? stringValue(termination["reason"]) {
                parts.append(indicator)
            } else if let namespace = stringValue(termination["namespace"]) {
                if let code = stringValue(termination["code"]) {
                    parts.append("\(namespace) \(code)")
                } else {
                    parts.append(namespace)
                }
            }
        }

        // 少数报告把终止原因放在顶层字符串里。
        if parts.isEmpty, let reason = stringValue(payload?["terminationReason"]) {
            parts.append(reason)
        }

        if !parts.isEmpty {
            return deduplicatedJoined(parts)
        }

        // 负载缺失或不是合法 JSON：给出可读的降级摘要，而不是空串。
        if payload == nil {
            let excerpt = firstMeaningfulLine(in: payloadText)
                ?? headerLine
            let trimmed = excerpt.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return "无法解析报告详情：\(String(trimmed.prefix(140)))"
            }
            return "报告内容为空（原始文本见详情）"
        }

        // 挂起/资源类报告本来就没有 exception/termination。
        if let bugType = stringValue(header?["bug_type"]) {
            return "未提供异常信息（报告类型 \(bugType)）"
        }
        return "未提供异常信息（原始文本见详情）"
    }

    // MARK: - .crash 解析

    /// 解析旧版纯文本 `.crash`。
    ///
    /// 这些键都在文件头部，且格式为 `Key:` 后跟若干空格；逐行查找比
    /// 「先建模型再解码」更耐受不同 macOS 版本增删的字段。
    private static func parseCrash(data: Data) -> ParsedReport {
        let text = String(decoding: data, as: UTF8.self)
        let lines = text.split(whereSeparator: \.isNewline)

        let versionValue = crashValue(for: "Version", in: lines)
        let version = parseVersion(versionValue)

        let rawDate = crashValue(for: "Date/Time", in: lines)
        // 极老的报告把日期写成 `Date/Time:       2026-09-06 at 08:00:00 +0800`。
        let date = rawDate.flatMap(parseDate) ?? rawDate.flatMap(parseLooseDate)

        var parts: [String] = []
        if let exceptionType = crashValue(for: "Exception Type", in: lines) {
            parts.append(exceptionType)
        }
        if let terminationReason = crashValue(for: "Termination Reason", in: lines) {
            parts.append(terminationReason)
        }

        let summary: String
        if parts.isEmpty {
            let excerpt = firstMeaningfulLine(in: text) ?? ""
            let trimmed = excerpt.trimmingCharacters(in: .whitespacesAndNewlines)
            summary = trimmed.isEmpty
                ? "报告内容为空（原始文本见详情）"
                : "无法解析报告详情：\(String(trimmed.prefix(140)))"
        } else {
            summary = deduplicatedJoined(parts)
        }

        return ParsedReport(
            date: date,
            appVersion: version.app,
            buildVersion: version.build,
            summary: summary
        )
    }

    /// 读取 `Key: value` 形式的行。
    private static func crashValue(for key: String, in lines: [Substring]) -> String? {
        let prefix = key.lowercased() + ":"
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.lowercased().hasPrefix(prefix) else { continue }
            let value = trimmed
                .dropFirst(prefix.count)
                .trimmingCharacters(in: .whitespaces)
            return value.isEmpty ? nil : value
        }
        return nil
    }

    /// 把 `1.2.3 (45)` 拆成应用版本与构建号。
    private static func parseVersion(_ raw: String?) -> (app: String?, build: String?) {
        guard let raw else { return (nil, nil) }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return (nil, nil) }

        guard let open = value.firstIndex(of: "("),
              let close = value.lastIndex(of: ")"),
              open < close
        else {
            return (value, nil)
        }

        let app = String(value[..<open]).trimmingCharacters(in: .whitespaces)
        let build = String(value[value.index(after: open)..<close])
            .trimmingCharacters(in: .whitespaces)
        return (app.isEmpty ? nil : app, build.isEmpty ? nil : build)
    }

    // MARK: - 通用解析

    private static func jsonObject(from data: Data) -> [String: Any]? {
        let trimmed = data.drop(while: {
            $0 == 0x20 || $0 == 0x0A || $0 == 0x0D || $0 == 0x09
        })
        guard !trimmed.isEmpty else { return nil }
        return (try? JSONSerialization.jsonObject(with: Data(trimmed))) as? [String: Any]
    }

    private static func objectValue(_ value: Any?) -> [String: Any]? {
        value as? [String: Any]
    }

    private static func stringValue(_ value: Any?) -> String? {
        switch value {
        case let string as String:
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        case let number as NSNumber:
            // build_version 偶尔被写成数字；统一转成字符串，UI 不必分类型处理。
            return number.stringValue
        default:
            return nil
        }
    }

    private static func firstMeaningfulLine(in text: String) -> String? {
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return trimmed
            }
        }
        return nil
    }

    /// 去掉相邻重复项：`.ips` 的 type 与 signal 有时都是 `EXC_CRASH`，
    /// 直接拼接会得到「EXC_CRASH · EXC_CRASH」。
    private static func deduplicatedJoined(_ parts: [String]) -> String {
        var result: [String] = []
        for part in parts where !part.isEmpty {
            if result.last != part {
                result.append(part)
            }
        }
        return result.joined(separator: " · ")
    }

    // MARK: - 日期与脱敏静态缓存

    private enum RedactionPatterns {
        static let jsonIdentifiers = try! NSRegularExpression(
            pattern: #"("(?:crashReporterKey|anonUUID|incident)"\s*:\s*)"([^"\\]*(?:\\.[^"\\]*)*)""#,
            options: [.caseInsensitive]
        )
        static let textIdentifiers = try! NSRegularExpression(
            pattern: #"(^|\n)([ \t]*(?:Incident Identifier|Anonymous UUID|CrashReporter Key|crashReporterKey|anonUUID|incident)[ \t]*:[ \t]*)([^\r\n]+)"#,
            options: [.caseInsensitive]
        )
    }

    /// 线程安全的静态日期解析器缓存，避免遍历报告时反复创建 `DateFormatter`。
    private final class DateParserCache: @unchecked Sendable {
        static let shared = DateParserCache()

        private let lock = NSLock()
        private let formatters: [DateFormatter]
        private let looseFormatter: DateFormatter
        private let isoWithFraction: ISO8601DateFormatter
        private let isoBasic: ISO8601DateFormatter

        private init() {
            let posix = Locale(identifier: "en_US_POSIX")
            let utc = TimeZone(secondsFromGMT: 0)
            let patterns = [
                "yyyy-MM-dd HH:mm:ss.SSSSSS Z",
                "yyyy-MM-dd HH:mm:ss.SSS Z",
                "yyyy-MM-dd HH:mm:ss.SS Z",
                "yyyy-MM-dd HH:mm:ss.S Z",
                "yyyy-MM-dd HH:mm:ss Z",
                "yyyy-MM-dd'T'HH:mm:ss.SSSZ",
                "yyyy-MM-dd'T'HH:mm:ssZ",
            ]
            self.formatters = patterns.map { pattern in
                let formatter = DateFormatter()
                formatter.locale = posix
                formatter.timeZone = utc
                formatter.dateFormat = pattern
                formatter.isLenient = false
                return formatter
            }
            let loose = DateFormatter()
            loose.locale = posix
            loose.timeZone = utc
            loose.dateFormat = "yyyy-MM-dd 'at' HH:mm:ss Z"
            self.looseFormatter = loose

            let frac = ISO8601DateFormatter()
            frac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            self.isoWithFraction = frac

            let basic = ISO8601DateFormatter()
            basic.formatOptions = [.withInternetDateTime]
            self.isoBasic = basic
        }

        func parseDate(_ value: String) -> Date? {
            lock.lock()
            defer { lock.unlock() }
            for formatter in formatters {
                if let date = formatter.date(from: value) {
                    return date
                }
            }
            if let date = isoWithFraction.date(from: value) {
                return date
            }
            return isoBasic.date(from: value)
        }

        func parseLooseDate(_ value: String) -> Date? {
            lock.lock()
            defer { lock.unlock() }
            return looseFormatter.date(from: value)
        }
    }

    /// 系统报告里的时间戳没有统一 ISO 格式：`.ips` 头用
    /// `2026-09-05 18:04:23.00 +0800`，`.crash` 的 `Date/Time` 也类似。
    /// 复用静态日期解析器按「带几分之一秒、带不带时区」逐级尝试。
    private static func parseDate(_ raw: String) -> Date? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        return DateParserCache.shared.parseDate(value)
    }

    /// 老式 `.crash` 的 `Date/Time` 可能写成
    /// `2026-09-06 at 08:00:00 +0800`。
    private static func parseLooseDate(_ raw: String) -> Date? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        return DateParserCache.shared.parseLooseDate(value)
    }
}
