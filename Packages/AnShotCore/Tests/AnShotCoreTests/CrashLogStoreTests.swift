//
//  CrashLogStoreTests.swift
//  AnShotCoreTests
//
//  崩溃报告索引的契约测试。
//
//  重点不是「解析器能读标准样例」，而是三条用户可感知的规则：
//  只收 anShot 的报告、解析失败也不丢条目、文件被系统清掉时详情给提示。
//  这些正是实现最容易偷懒成「解析失败就跳过」的地方。
//

import Foundation
import Testing

@testable import AnShotCore

@Suite("CrashLogStore")
struct CrashLogStoreTests {

    // MARK: - 夹具

    private func withTempDirectory(_ body: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("anshot-crashlog-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory)
    }

    @discardableResult
    private func writeIPS(
        in directory: URL,
        name: String,
        timestamp: String = "2026-09-05 18:04:23.00 +0800",
        appName: String = "anShot",
        appVersion: String = "1.0.0",
        buildVersion: String = "1",
        exceptionType: String = "EXC_BAD_ACCESS",
        signal: String = "SIGSEGV",
        terminationIndicator: String = "Segmentation fault: 11"
    ) throws -> URL {
        let header: [String: Any] = [
            "app_name": appName,
            "name": appName,
            "timestamp": timestamp,
            "app_version": appVersion,
            "build_version": buildVersion,
            "bug_type": "309",
        ]
        let payload: [String: Any] = [
            "exception": [
                "type": exceptionType,
                "signal": signal,
            ],
            "termination": [
                "namespace": "SIGNAL",
                "code": 11,
                "indicator": terminationIndicator,
            ],
        ]

        let headerData = try JSONSerialization.data(withJSONObject: header)
        let payloadData = try JSONSerialization.data(withJSONObject: payload)
        var data = headerData
        data.append(0x0A)
        data.append(payloadData)

        let url = directory.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    @discardableResult
    private func writeCrash(
        in directory: URL,
        name: String,
        process: String = "anShot",
        version: String = "1.4.2 (142)",
        dateTime: String = "2026-09-06 08:00:00.000 +0800",
        exceptionType: String = "EXC_BAD_ACCESS (SIGSEGV)",
        terminationReason: String = "Namespace SIGNAL, Code 11 Segmentation fault: 11"
    ) throws -> URL {
        let text = """
        Process:               \(process) [1234]
        Path:                  /Applications/\(process).app/Contents/MacOS/\(process)
        Identifier:            com.anshot.app
        Version:               \(version)
        Code Type:             ARM-64 (Native)
        Parent Process:        launchd [1]
        User ID:               501

        Date/Time:             \(dateTime)
        OS Version:            macOS 13.0 (22A380)
        Exception Type:        \(exceptionType)
        Exception Codes:       KERN_INVALID_ADDRESS at 0x0000000000000000
        Exception Note:        EXC_CORPSE_NOTIFY

        Termination Reason:    \(terminationReason)
        Terminating Process:   exc handler [1234]
        """
        let url = directory.appendingPathComponent(name)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func writeText(_ text: String, in directory: URL, name: String) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    // MARK: - .ips

    @Test(".ips 解析头部版本与异常摘要")
    func parsesIPSHeaderAndSummary() throws {
        try withTempDirectory { directory in
            let url = try writeIPS(
                in: directory,
                name: "anShot-2026-09-05.ips",
                timestamp: "2026-09-05 18:04:23.00 +0800",
                appVersion: "1.4.2",
                buildVersion: "142",
                exceptionType: "EXC_BAD_ACCESS",
                signal: "SIGSEGV",
                terminationIndicator: "Segmentation fault: 11"
            )

            let entries = CrashLogStore.reports(directories: [directory], limit: 10)
            #expect(entries.count == 1)

            let entry = try #require(entries.first)
            #expect(entry.url.path == url.path)
            #expect(entry.id == url.path)
            #expect(entry.kind == "ips")
            #expect(entry.appVersion == "1.4.2")
            #expect(entry.buildVersion == "142")
            #expect(entry.summary == "EXC_BAD_ACCESS · SIGSEGV · Segmentation fault: 11")

            // 2026-09-05 18:04:23 +0800 == 2026-09-05T10:04:23Z
            let expected = try #require(
                ISO8601DateFormatter().date(from: "2026-09-05T10:04:23Z")
            )
            #expect(entry.date == expected)

            let details = CrashLogStore.details(for: entry)
            #expect(details.contains("bug_type"))
            #expect(details.contains("EXC_BAD_ACCESS"))
        }
    }

    @Test(".ips 负载损坏时保留条目并用头部字段")
    func ipsKeepsEntryWhenPayloadIsBroken() throws {
        try withTempDirectory { directory in
            let header = "{\"app_name\":\"anShot\",\"timestamp\":\"2026-09-05 18:04:23.00 +0800\","
                + "\"app_version\":\"2.0.0\",\"build_version\":\"200\",\"bug_type\":\"309\"}"
            let url = try writeText(
                header + "\n{这不是合法负载",
                in: directory,
                name: "anShot-broken-payload.ips"
            )
            #expect(FileManager.default.fileExists(atPath: url.path))

            let entries = CrashLogStore.reports(directories: [directory], limit: 10)
            #expect(entries.count == 1)

            let entry = try #require(entries.first)
            #expect(entry.appVersion == "2.0.0")
            #expect(entry.buildVersion == "200")
            #expect(entry.summary.contains("无法解析"))
            #expect(CrashLogStore.details(for: entry).contains("这不是合法负载"))
        }
    }

    @Test(".ips 头部与负载都损坏时降级文本摘要且不丢条目")
    func ipsFallsBackToTextSummary() throws {
        try withTempDirectory { directory in
            _ = try writeText(
                "这不是 JSON 头\n也不是合法负载",
                in: directory,
                name: "anShot-broken.ips"
            )

            let entries = CrashLogStore.reports(directories: [directory], limit: 10)
            #expect(entries.count == 1)

            let entry = try #require(entries.first)
            #expect(entry.kind == "ips")
            #expect(!entry.summary.isEmpty)
            #expect(entry.summary.contains("无法解析"))
            #expect(entry.appVersion == nil)
            #expect(entry.date.timeIntervalSince1970 > 0)
        }
    }

    // MARK: - .crash

    @Test(".crash 解析日期、版本、异常与终止原因")
    func parsesLegacyCrashReport() throws {
        try withTempDirectory { directory in
            _ = try writeCrash(
                in: directory,
                name: "anShot-2026-09-06.crash",
                version: "1.4.2 (142)",
                dateTime: "2026-09-06 08:00:00.000 +0800",
                exceptionType: "EXC_BAD_ACCESS (SIGSEGV)",
                terminationReason: "Namespace SIGNAL, Code 11 Segmentation fault: 11"
            )

            let entries = CrashLogStore.reports(directories: [directory], limit: 10)
            #expect(entries.count == 1)

            let entry = try #require(entries.first)
            #expect(entry.kind == "crash")
            #expect(entry.appVersion == "1.4.2")
            #expect(entry.buildVersion == "142")
            #expect(entry.summary.contains("EXC_BAD_ACCESS (SIGSEGV)"))
            #expect(entry.summary.contains("Namespace SIGNAL"))

            // 2026-09-06 08:00:00 +0800 == 2026-09-06T00:00:00Z
            let expected = try #require(
                ISO8601DateFormatter().date(from: "2026-09-06T00:00:00Z")
            )
            #expect(entry.date == expected)
        }
    }

    @Test(".crash 缺少异常字段时降级文本摘要且不丢条目")
    func crashFallsBackToTextSummary() throws {
        try withTempDirectory { directory in
            _ = try writeText(
                "Process:               anShot [1234]\n这不是一份完整的崩溃报告",
                in: directory,
                name: "anShot-broken.crash"
            )

            let entries = CrashLogStore.reports(directories: [directory], limit: 10)
            #expect(entries.count == 1)

            let entry = try #require(entries.first)
            #expect(entry.kind == "crash")
            #expect(entry.summary.contains("无法解析"))
            #expect(entry.appVersion == nil)
        }
    }

    // MARK: - 过滤

    @Test("只收文件名或内容命中 anShot 的 .ips/.crash")
    func filtersByProcessName() throws {
        try withTempDirectory { directory in
            // 文件名命中。
            _ = try writeIPS(in: directory, name: "anShot-filename.ips")
            _ = try writeCrash(in: directory, name: "anShot-filename.crash")

            // 文件名不命中，但报告内容命中。
            _ = try writeIPS(
                in: directory,
                name: "Report-content.ips",
                appName: "anShot"
            )
            _ = try writeCrash(
                in: directory,
                name: "Report-content.crash",
                process: "anShot"
            )

            // 其它进程：应排除。
            _ = try writeIPS(in: directory, name: "Safari.ips", appName: "Safari")
            _ = try writeCrash(in: directory, name: "Mail.crash", process: "Mail")

            // 非目标扩展名、扩展名伪装、目录：都应排除。
            _ = try writeText("hello", in: directory, name: "notes.txt")
            _ = try writeText("hello", in: directory, name: "anShot-synced.ips.synced")
            try FileManager.default.createDirectory(
                at: directory.appendingPathComponent("anShot-directory.ips"),
                withIntermediateDirectories: true
            )

            let entries = CrashLogStore.reports(directories: [directory], limit: 10)
            #expect(entries.count == 4)
            #expect(Set(entries.map(\.kind)) == ["ips", "crash"])
            #expect(entries.allSatisfy { !$0.summary.isEmpty })
        }
    }

    @Test("进程名匹配不区分大小写")
    func processNameMatchingIsCaseInsensitive() throws {
        try withTempDirectory { directory in
            _ = try writeIPS(
                in: directory,
                name: "Report-uppercase.ips",
                appName: "ANSHOT"
            )

            let entries = CrashLogStore.reports(directories: [directory], limit: 10)
            #expect(entries.count == 1)
        }
    }

    // MARK: - 排序 / 上限 / 目录

    @Test("按日期倒序并应用 limit")
    func sortsNewestFirstAndAppliesLimit() throws {
        try withTempDirectory { directory in
            _ = try writeIPS(
                in: directory,
                name: "anShot-old.ips",
                timestamp: "2026-09-01 08:00:00.00 +0800",
                appVersion: "1.0.0"
            )
            _ = try writeIPS(
                in: directory,
                name: "anShot-middle.ips",
                timestamp: "2026-09-02 08:00:00.00 +0800",
                appVersion: "2.0.0"
            )
            _ = try writeIPS(
                in: directory,
                name: "anShot-new.ips",
                timestamp: "2026-09-03 08:00:00.00 +0800",
                appVersion: "3.0.0"
            )

            let entries = CrashLogStore.reports(directories: [directory], limit: 2)
            #expect(entries.count == 2)
            #expect(entries.map(\.appVersion) == ["3.0.0", "2.0.0"])

            #expect(CrashLogStore.reports(directories: [directory], limit: 0).isEmpty)
            #expect(CrashLogStore.reports(directories: [directory], limit: -1).isEmpty)
        }
    }

    @Test("扫描传入的 Retired 目录")
    func scansRetiredDirectory() throws {
        try withTempDirectory { directory in
            let retired = directory.appendingPathComponent("Retired", isDirectory: true)
            try FileManager.default.createDirectory(at: retired, withIntermediateDirectories: true)
            _ = try writeIPS(
                in: retired,
                name: "anShot-retired.ips",
                timestamp: "2026-09-04 08:00:00.00 +0800"
            )

            // 只传根目录时不递归，Retired 里的报告不应出现。
            #expect(CrashLogStore.reports(directories: [directory], limit: 10).isEmpty)

            let entries = CrashLogStore.reports(
                directories: [directory, retired],
                limit: 10
            )
            #expect(entries.count == 1)
            #expect(entries.first?.url.deletingLastPathComponent().path == retired.path)
        }
    }

    @Test("空目录返回空列表")
    func emptyDirectoryReturnsEmptyList() throws {
        try withTempDirectory { directory in
            #expect(CrashLogStore.reports(directories: [directory], limit: 50).isEmpty)
        }
    }

    // MARK: - 详情

    @Test("details 返回原文件内容，文件消失时返回可读提示")
    func detailsReadsFileOnDemand() throws {
        try withTempDirectory { directory in
            let url = try writeIPS(in: directory, name: "anShot-details.ips")
            let entries = CrashLogStore.reports(directories: [directory], limit: 10)
            let entry = try #require(entries.first)

            let raw = try Data(contentsOf: url)
            #expect(CrashLogStore.details(for: entry) == String(decoding: raw, as: UTF8.self))

            // 模拟系统清理：条目已经拿到，但文件在打开详情前消失。
            try FileManager.default.removeItem(at: url)
            let message = CrashLogStore.details(for: entry)
            #expect(message.contains("已不存在"))
            #expect(message.contains(url.path))
        }
    }

    @Test("details 对空文件给出明确提示")
    func detailsHandlesEmptyFile() throws {
        try withTempDirectory { directory in
            let url = try writeText("", in: directory, name: "anShot-empty.ips")
            let entries = CrashLogStore.reports(directories: [directory], limit: 10)
            let entry = try #require(entries.first)

            #expect(CrashLogStore.details(for: entry).contains("空的"))
            #expect(FileManager.default.fileExists(atPath: url.path))
        }
    }
}
