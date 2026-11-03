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
        var entries: [CrashLogEntry] = []

        for url in candidateFiles(in: roots) {
            let kind = url.pathExtension.lowercased()
            guard kind == "ips" || kind == "crash" else { continue }

            // 文件名命中时不必先读内容；文件名没命中才去报告正文里找进程名。
            // 这样即使 DiagnosticReports 里有几百份其它 app 的报告，也只读
            // 每份的头部而不是整份。
            let nameMatches = matches(name: url.lastPathComponent, processName: processName)
            guard nameMatches || contentMentions(
                processName: processName,
                in: url,
                kind: kind
            ) else {
                continue
            }

            guard let data = readData(at: url) else { continue }

            let parsed: ParsedReport
            switch kind {
            case "ips":
                parsed = parseIPS(data: data)
            default:
                parsed = parseCrash(data: data)
            }

            // 报告时间解析失败时用文件修改时间：排序仍能反映「新旧」，
            // 也不会因为一份格式怪异的报告把它排到列表最末。
            let fallbackDate = modificationDate(of: url) ?? Date(timeIntervalSince1970: 0)
            entries.append(CrashLogEntry(
                url: url,
                date: parsed.date ?? fallbackDate,
                appVersion: parsed.appVersion,
                buildVersion: parsed.buildVersion,
                kind: kind,
                summary: parsed.summary
            ))
        }

        entries.sort { lhs, rhs in
            if lhs.date != rhs.date {
                return lhs.date > rhs.date
            }
            // 同一秒内的报告没有内在顺序；用路径保证每次刷新结果稳定，
            // 避免列表在刷新时无谓地跳动。
            return lhs.url.path < rhs.url.path
        }

        return Array(entries.prefix(limit))
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

    // MARK: - 进程名匹配

    private static func matches(name value: String, processName: String) -> Bool {
        value.range(
            of: processName,
            options: [.caseInsensitive, .diacriticInsensitive]
        ) != nil
    }

    /// 文件名未命中时的兜底：读取报告头部，找进程名。
    ///
    /// `.ips` 的 `app_name` / `name` / `bundleID` 都在首行 JSON 头里；
    /// `.crash` 的 `Process:` / `Path:` 在文件开头几行。16 KB 足够覆盖
    /// 这两种定位，又不会为了过滤去读几百 KB 的线程栈。
    private static func contentMentions(
        processName: String,
        in url: URL,
        kind: String
    ) -> Bool {
        guard let prefix = readPrefix(at: url) else { return false }

        switch kind {
        case "ips":
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
            headerLine = headerLine.trimmingCharacters(in: .whitespacesAndNewlines)

            if let header = jsonObject(from: Data(headerLine.utf8)) {
                let names = [
                    stringValue(header["app_name"]),
                    stringValue(header["name"]),
                    stringValue(header["bundleID"]),
                ].compactMap { $0 }
                if !names.isEmpty {
                    return names.contains { matches(name: $0, processName: processName) }
                }
            }
            // 头部不是合法 JSON 时，至少用原始首行做一次包含判断；
            // 解析失败的报告仍可能带着进程名。
            return matches(name: headerLine, processName: processName)

        default:
            let text = String(decoding: prefix, as: UTF8.self)
            let lines = text.split(whereSeparator: \.isNewline)
            let values = ["Process", "Path"].compactMap {
                crashValue(for: $0, in: lines)
            }
            return values.contains { matches(name: $0, processName: processName) }
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
    private static func parseIPS(data: Data) -> ParsedReport {
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

        let header = jsonObject(from: Data(headerLine.utf8))
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

    // MARK: - 日期

    /// 系统报告里的时间戳没有统一 ISO 格式：`.ips` 头用
    /// `2026-09-05 18:04:23.00 +0800`，`.crash` 的 `Date/Time` 也类似。
    /// 按「带几分之一秒、带不带时区」逐级尝试。
    private static func parseDate(_ raw: String) -> Date? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }

        let patterns = [
            "yyyy-MM-dd HH:mm:ss.SSSSSS Z",
            "yyyy-MM-dd HH:mm:ss.SSS Z",
            "yyyy-MM-dd HH:mm:ss.SS Z",
            "yyyy-MM-dd HH:mm:ss.S Z",
            "yyyy-MM-dd HH:mm:ss Z",
            "yyyy-MM-dd'T'HH:mm:ss.SSSZ",
            "yyyy-MM-dd'T'HH:mm:ssZ",
        ]
        for pattern in patterns {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            // 所有 pattern 都带时区；这里设 UTC 只是避免 formatter 的默认值
            // 影响解析（字符串里的 Z 会覆盖它）。
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = pattern
            formatter.isLenient = false
            if let date = formatter.date(from: value) {
                return date
            }
        }

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = iso.date(from: value) {
            return date
        }
        iso.formatOptions = [.withInternetDateTime]
        return iso.date(from: value)
    }

    /// 老式 `.crash` 的 `Date/Time` 可能写成
    /// `2026-09-06 at 08:00:00 +0800`。
    private static func parseLooseDate(_ raw: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd 'at' HH:mm:ss Z"
        return formatter.date(from: raw.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
