//
//  UpdateModuleTests.swift
//  AnShotUITests
//
//  自动更新模块单元测试：版本比较（含构建号热修）、SHA256 校验、
//  符号链接逃逸拦截、解压体积上限、同源签名身份、路径校验、偏好存储与服务缓存。
//

import AnShotCore
import CryptoKit
import Foundation
import os
import Testing

@testable import AnShotUI

@Suite("自动更新 · 全模块安全与逻辑校验")
@MainActor
struct UpdateModuleTests {

    // MARK: - 版本比较与热修识别

    @Test("语义版本比较与同版本下构建号热修识别")
    func versionAndBuildComparison() throws {
        let v123 = try #require(AppVersion("1.2.3"))
        let v124 = try #require(AppVersion("1.2.4"))
        let v1210 = try #require(AppVersion("1.2.10"))
        let v123Beta = try #require(AppVersion("1.2.3-beta.1"))

        #expect(UpdateService.isNewer(
            releaseVersion: v124, releaseBuild: nil,
            currentVersion: v123, currentBuild: nil
        ))
        #expect(UpdateService.isNewer(
            releaseVersion: v1210, releaseBuild: nil,
            currentVersion: v124, currentBuild: nil
        ))
        #expect(UpdateService.isNewer(
            releaseVersion: v123, releaseBuild: nil,
            currentVersion: v123Beta, currentBuild: nil
        ))
        #expect(!UpdateService.isNewer(
            releaseVersion: v123, releaseBuild: nil,
            currentVersion: v124, currentBuild: nil
        ))

        // 同语义版本下通过 build 号识别热修更新。
        #expect(UpdateService.isNewer(
            releaseVersion: v123, releaseBuild: 16,
            currentVersion: v123, currentBuild: 15
        ))
        #expect(!UpdateService.isNewer(
            releaseVersion: v123, releaseBuild: 15,
            currentVersion: v123, currentBuild: 15
        ))
        #expect(!UpdateService.isNewer(
            releaseVersion: v123, releaseBuild: 14,
            currentVersion: v123, currentBuild: 15
        ))
        #expect(!UpdateService.isNewer(
            releaseVersion: v123, releaseBuild: nil,
            currentVersion: v123, currentBuild: 15
        ))
    }

    @Test("从 tag 与标题提取构建号后缀")
    func extractBuildNumberFromTags() {
        #expect(UpdateService.extractBuildNumber(from: "v1.2.3+42") == 42)
        #expect(UpdateService.extractBuildNumber(from: "1.2.3+build.99") == 99)
        #expect(UpdateService.extractBuildNumber(from: "1.2.3-rc.1+108") == 108)
        #expect(UpdateService.extractBuildNumber(from: "anShot 1.2.3 (205)") == 205)
        #expect(UpdateService.extractBuildNumber(from: "v1.2.3") == nil)
        #expect(UpdateService.extractBuildNumber(from: nil) == nil)
    }

    // MARK: - SHA256 与校验和解析

    @Test("流式 SHA256 计算与多种 SHA256SUMS 格式解析")
    func sha256AndChecksumParsing() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("anshot-sha-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let payload = Data("anShot-release-payload-\(UUID().uuidString)".utf8)
        let fileURL = dir.appendingPathComponent("anShot-1.2.3.zip")
        try payload.write(to: fileURL)

        let expectedHex = SHA256.hash(data: payload).map { String(format: "%02x", Int($0)) }.joined()
        let computed = try UpdateInstaller.sha256Hex(of: fileURL)
        #expect(computed == expectedHex)
        #expect(UpdateService.isSHA256Hex(computed))
        #expect(!UpdateService.isSHA256Hex("not-a-sha256"))

        let gnuSum = "# comment\n\(expectedHex)  anShot-1.2.3.zip\n"
        #expect(UpdateInstaller.parseChecksum(gnuSum, fileName: "anShot-1.2.3.zip") == expectedHex)

        let binaryModeSum = "\(expectedHex) *anShot-1.2.3.zip"
        #expect(UpdateInstaller.parseChecksum(binaryModeSum, fileName: "anShot-1.2.3.zip") == expectedHex)

        let bsdSum = "SHA256 (anShot-1.2.3.zip) = \(expectedHex.uppercased())"
        #expect(UpdateInstaller.parseChecksum(bsdSum, fileName: "anShot-1.2.3.zip") == expectedHex)

        let loneSum = "\(expectedHex)\n"
        #expect(UpdateInstaller.parseChecksum(loneSum, fileName: "other.zip") == expectedHex)
    }

    // MARK: - 符号链接逃逸与解压体积上限

    @Test("巡检解压包拦截包外越界软链并放行包内合法软链")
    func symlinkTraversalProtection() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("anshot-symlink-test-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let outsideFile = root.appendingPathComponent("secret.txt")
        try Data("secret".utf8).write(to: outsideFile)

        // 1. 合法应用包（含包内相对符号链接）：应校验通过
        let safeApp = root.appendingPathComponent("Safe.app", isDirectory: true)
        let safeMacOS = safeApp.appendingPathComponent("Contents/MacOS", isDirectory: true)
        let safeResources = safeApp.appendingPathComponent("Contents/Resources", isDirectory: true)
        try fm.createDirectory(at: safeMacOS, withIntermediateDirectories: true)
        try fm.createDirectory(at: safeResources, withIntermediateDirectories: true)
        let realAsset = safeResources.appendingPathComponent("data.bin")
        try Data(repeating: 0xAB, count: 64).write(to: realAsset)
        try fm.createSymbolicLink(
            atPath: safeMacOS.appendingPathComponent("data-link").path,
            withDestinationPath: "../Resources/data.bin"
        )
        try UpdateInstaller.validateExtractedBundle(at: safeApp)

        // 2. 顶层 .app 为符号链接：应被拦截
        let topLevelSymlinkApp = root.appendingPathComponent("TopLink.app")
        try fm.createSymbolicLink(at: topLevelSymlinkApp, withDestinationURL: safeApp)
        #expect(throws: Error.self) {
            try UpdateInstaller.validateExtractedBundle(at: topLevelSymlinkApp)
        }

        // 3. 包内相对路径逃逸到包外：应被拦截
        let evilRelativeApp = root.appendingPathComponent("EvilRelative.app", isDirectory: true)
        let evilRes = evilRelativeApp.appendingPathComponent("Contents/Resources", isDirectory: true)
        try fm.createDirectory(at: evilRes, withIntermediateDirectories: true)
        try fm.createSymbolicLink(
            atPath: evilRes.appendingPathComponent("escape").path,
            withDestinationPath: "../../../secret.txt"
        )
        #expect(throws: Error.self) {
            try UpdateInstaller.validateExtractedBundle(at: evilRelativeApp)
        }

        // 4. 包内绝对路径指向包外：应被拦截
        let evilAbsoluteApp = root.appendingPathComponent("EvilAbsolute.app", isDirectory: true)
        let evilAbsRes = evilAbsoluteApp.appendingPathComponent("Contents/Resources", isDirectory: true)
        try fm.createDirectory(at: evilAbsRes, withIntermediateDirectories: true)
        try fm.createSymbolicLink(
            atPath: evilAbsRes.appendingPathComponent("abs-escape").path,
            withDestinationPath: outsideFile.path
        )
        #expect(throws: Error.self) {
            try UpdateInstaller.validateExtractedBundle(at: evilAbsoluteApp)
        }
    }

    @Test("解压后总字节超出安全上限时熔断")
    func extractedSizeLimitEnforced() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("anshot-size-test-\(UUID().uuidString)", isDirectory: true)
        let contentsDir = root.appendingPathComponent("Oversized.app/Contents/Resources", isDirectory: true)
        try fm.createDirectory(at: contentsDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let largeBlob = contentsDir.appendingPathComponent("blob.bin")
        try Data(repeating: 0xCD, count: 4096).write(to: largeBlob)

        let appURL = root.appendingPathComponent("Oversized.app", isDirectory: true)
        // 超过 2048 上限必须抛错
        #expect(throws: Error.self) {
            try UpdateInstaller.validateExtractedBundle(at: appURL, maxBytes: 2048)
        }
        // 放宽到 8192 则通过
        try UpdateInstaller.validateExtractedBundle(at: appURL, maxBytes: 8192)
    }

    // MARK: - 签名身份、路径与原子脚本权限

    @Test("同源签名者身份校验拒绝 Ad-hoc 与跨团队签名")
    func signerIdentityCompatibility() {
        let teamA = UpdateInstaller.SigningIdentity(
            isAdhoc: false,
            teamIdentifier: "TEAM123456",
            certificateDigests: ["leafA", "rootA"]
        )
        let teamASame = UpdateInstaller.SigningIdentity(
            isAdhoc: false,
            teamIdentifier: "TEAM123456",
            certificateDigests: ["leafA2", "rootA"]
        )
        let teamB = UpdateInstaller.SigningIdentity(
            isAdhoc: false,
            teamIdentifier: "OTHERTEAM9",
            certificateDigests: ["leafB", "rootB"]
        )
        let adhoc = UpdateInstaller.SigningIdentity(
            isAdhoc: true,
            teamIdentifier: nil,
            certificateDigests: []
        )
        let certOnly1 = UpdateInstaller.SigningIdentity(
            isAdhoc: false,
            teamIdentifier: nil,
            certificateDigests: ["leaf1", "rootShared"]
        )
        let certOnly2 = UpdateInstaller.SigningIdentity(
            isAdhoc: false,
            teamIdentifier: nil,
            certificateDigests: ["leaf2", "rootShared"]
        )

        #expect(UpdateInstaller.isSignerCompatible(current: teamA, candidate: teamASame))
        #expect(!UpdateInstaller.isSignerCompatible(current: teamA, candidate: teamB))
        #expect(!UpdateInstaller.isSignerCompatible(current: adhoc, candidate: teamA))
        #expect(!UpdateInstaller.isSignerCompatible(current: teamA, candidate: adhoc))
        #expect(!UpdateInstaller.isSignerCompatible(current: adhoc, candidate: adhoc))
        #expect(UpdateInstaller.isSignerCompatible(current: certOnly1, candidate: certOnly2))
    }

    @Test("校验 /Applications 路径判定及原子创建 0700 安装脚本")
    func applicationsPathAndAtomicScriptPermissions() throws {
        #expect(UpdateInstaller.isValidApplicationsTarget(URL(fileURLWithPath: "/Applications/anShot.app")))
        #expect(UpdateInstaller.isValidApplicationsTarget(URL(fileURLWithPath: "/Applications/Utilities/anShot.app")))
        #expect(!UpdateInstaller.isValidApplicationsTarget(URL(fileURLWithPath: "/Applications2/anShot.app")))
        #expect(!UpdateInstaller.isValidApplicationsTarget(URL(fileURLWithPath: "/Users/demo/Downloads/anShot.app")))

        let fm = FileManager.default
        let dir = fm.temporaryDirectory
            .appendingPathComponent("anshot-script-test-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }

        let scriptURL = dir.appendingPathComponent("install.sh")
        try UpdateInstaller.writeExecutableScriptAtomically("#!/bin/sh\necho ok\n", to: scriptURL)

        let attrs = try fm.attributesOfItem(atPath: scriptURL.path)
        let perms = (attrs[.posixPermissions] as? NSNumber)?.intValue
        #expect(perms == 0o700)

        // O_EXCL 必须拒绝覆盖已有同名脚本
        #expect(throws: Error.self) {
            try UpdateInstaller.writeExecutableScriptAtomically("#!/bin/sh\necho overwrite\n", to: scriptURL)
        }
    }

    // MARK: - 偏好存储与节流

    @Test("更新偏好默认值、忽略版本归一化及 24h 节流逻辑")
    func updatePreferencesStoreBehavior() throws {
        let suite = "com.anshot.test.update-prefs.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = UpdatePreferencesStore(defaults: defaults)
        #expect(store.autoCheckUpdates == true)

        store.autoCheckUpdates = false
        #expect(store.autoCheckUpdates == false)
        store.autoCheckUpdates = true

        store.skippedVersion = "   "
        #expect(store.skippedVersion == nil)
        store.skippedVersion = " 1.2.3 (16) "
        #expect(store.skippedVersion == "1.2.3 (16)")

        let now = Date(timeIntervalSince1970: 1_700_000_000)
        // 从未检查过：允许检查
        #expect(store.shouldAutoCheck(now: now, interval: 86_400))

        // 1 小时前刚检查过：节流阻止
        store.lastCheckAt = now.addingTimeInterval(-3600)
        #expect(!store.shouldAutoCheck(now: now, interval: 86_400))

        // 24 小时前检查过：放行
        store.lastCheckAt = now.addingTimeInterval(-86_400)
        #expect(store.shouldAutoCheck(now: now, interval: 86_400))

        // 系统时钟回拨（lastCheckAt 在未来）：安全拒绝，防止频繁请求触发限流
        store.lastCheckAt = now.addingTimeInterval(3600)
        #expect(!store.shouldAutoCheck(now: now, interval: 86_400))
    }

    // MARK: - UpdateService 响应与 ETag 缓存

    @Test("UpdateService 处理 200 热修版本、304 ETag 缓存与 404 无发布版本")
    func updateServiceNetworkAndCaching() async throws {
        let suite = "com.anshot.test.update-service.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [UpdateMockURLProtocol.self]
        let session = URLSession(configuration: config)
        let service = UpdateService(session: session, defaults: defaults)

        let sha = String(repeating: "a", count: 64)
        let jsonPayload = """
        {
          "tag_name": "v1.2.3+16",
          "name": "anShot 1.2.3 (16)",
          "body": "热修补丁",
          "html_url": "https://github.com/zzhang-AL/anShot/releases/tag/v1.2.3%2B16",
          "published_at": "2026-11-18T10:00:00Z",
          "assets": [
            {
              "name": "anShot-1.2.3.zip",
              "size": 1024000,
              "browser_download_url": "https://example.com/anShot-1.2.3.zip",
              "digest": "sha256:\(sha)"
            }
          ]
        }
        """

        // 1. 200 返回新构建号版本
        UpdateMockURLProtocol.setHandler { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["ETag": "\"v123-16\""]
            )!
            return (response, Data(jsonPayload.utf8))
        }
        let v123 = try #require(AppVersion("1.2.3"))
        let firstResult = try await service.check(currentVersion: v123, currentBuild: 15)
        guard case .available(let release) = firstResult else {
            Issue.record("期望返回 .available，实际为 \(firstResult)")
            return
        }
        #expect(release.version == v123)
        #expect(release.buildNumber == 16)
        #expect(release.expectedSHA256 == sha)

        // 2. 304 命中本地 ETag 缓存，验证发送了 If-None-Match 且返回最新状态
        UpdateMockURLProtocol.setHandler { request in
            #expect(request.value(forHTTPHeaderField: "If-None-Match") == "\"v123-16\"")
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 304,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Data())
        }
        let cachedResult = try await service.check(currentVersion: v123, currentBuild: 16)
        #expect(cachedResult == .upToDate(current: v123))

        // 3. 404 返回 .noRelease
        UpdateMockURLProtocol.setHandler { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 404,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Data())
        }
        let emptyResult = try await service.check(currentVersion: v123, currentBuild: 16)
        #expect(emptyResult == .noRelease)
    }
}

/// 隔离网络测试桩，避免测试过程中发起真实 GitHub HTTP 请求。
private final class UpdateMockURLProtocol: URLProtocol, @unchecked Sendable {

    typealias RequestHandler = @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)

    private static let handlerStorage = OSAllocatedUnfairLock<RequestHandler?>(initialState: nil)

    static func setHandler(_ block: @escaping RequestHandler) {
        handlerStorage.withLock { $0 = block }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let current = Self.handlerStorage.withLock { $0 }

        guard let current else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
            return
        }
        do {
            let (response, data) = try current(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
