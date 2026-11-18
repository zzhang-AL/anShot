//
//  UpdateInstaller.swift
//  AnShotUI
//
//  下载、校验、解压、安装新版本。
//
//  ── 顺序为什么不能变 ─────────────────────────────────────────
//
//  每一步都在**削弱**后一步的可信度，所以顺序固定为：
//
//      zip → SHA256 → 解压 → codesign → bundle id / 版本 → 替换
//
//  只做 codesign 不校验哈希是不够的：签名只证明「这个包是某个签名者做的」，
//  不证明「它就是这次发布声称的那个包」。只校验哈希不验签名也不够：
//  哈希值本身来自同一个下载源，源被替换时两者会一起变。
//
//  ── 安装为什么要写脚本 ───────────────────────────────────────
//
//  App 不能在运行期间替换自己的 bundle：`mv` 掉正在执行的文件后，
//  进程后续任何一次代码页换入都可能失败，而且失败时已经没有任何界面
//  能告诉用户发生了什么。因此真正做「备份 → 替换 → 重启」的是一段
//  `/bin/sh` 脚本：应用先把它需要的所有内容准备好（新 bundle 已复制到
//  同一卷的临时名），启动脚本，然后自行退出。脚本失败时会回滚并写日志。
//
//  ── 只在 /Applications 自安装 ────────────────────────────────
//
//  从 `~/Downloads` 或 `~/Desktop` 启动的副本没有稳定的安装位置，
//  在那里替换只会让用户下次仍打开旧副本。因此非 /Applications 一律拒绝，
//  并引导用户去发布页手动下载——这比「装了个看不见的地方」诚实得多。
//

import AnShotCore
import AppKit
import CryptoKit
import Darwin
import Foundation
import os
import Security

/// 下载 / 校验 / 安装的用户可读错误。
///
/// 每个 case 都必须能直接显示给用户：更新失败时界面只有这一句话，
/// 日志是给开发者看的，不能要求用户去翻 Console。
enum UpdateInstallError: LocalizedError, Sendable {
    case noAsset
    case checksumUnavailable
    case checksumMismatch
    case unzipFailed
    case signatureInvalid
    case notInApplications
    case notWritable
    case installFailed(String)

    var errorDescription: String? {
        switch self {
        case .noAsset:
            return "这个版本没有提供 zip 安装包。"
        case .checksumUnavailable:
            return "发布页没有提供可用的 SHA256 校验和，已停止自动安装。"
        case .checksumMismatch:
            return "下载内容与 SHA256 校验和不一致，可能被篡改或传输损坏。"
        case .unzipFailed:
            return "解压安装包失败，下载可能不完整。"
        case .signatureInvalid:
            return "安装包的代码签名校验未通过。"
        case .notInApplications:
            return "anShot 不在「应用程序」文件夹中，无法自动替换。"
        case .notWritable:
            return "「应用程序」文件夹不可写，无法自动安装。"
        case .installFailed(let reason):
            return reason
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .noAsset, .checksumUnavailable, .checksumMismatch, .unzipFailed, .signatureInvalid:
            return "请打开发布页手动下载安装包。"
        case .notInApplications:
            return "请把下载的新版本拖入「应用程序」文件夹后再打开。"
        case .notWritable:
            return "请手动把新版本拖入「应用程序」，或在系统设置中授予写入权限。"
        case .installFailed:
            return "可以重试，或打开发布页手动下载。"
        }
    }
}

/// 下载与安装。
///
/// 接口按契约固定为 `download(_:progress:)` + `installAndRelaunch(appURL:)`。
/// `onStageChange` 是额外补充：契约要求窗口展示「校验中」，
/// 而校验发生在 `download` 内部；把阶段作为回调上报比在签名里加参数
/// 更不容易破坏调用方。
@MainActor
final class UpdateInstaller {

    /// 安装包必须声明的 bundle id。与 `project.yml` 的 `PRODUCT_BUNDLE_IDENTIFIER` 一致。
    nonisolated static let expectedBundleIdentifier = "com.anshot.app"

    /// 允许自安装的目录。
    nonisolated static let applicationsPath = "/Applications"

    /// 下载 zip 安装包体积安全上限（200 MiB）。
    nonisolated static let maximumDownloadBytes: Int64 = 200 * 1024 * 1024

    /// 解压后应用包总体积安全上限（500 MiB），防范压缩炸弹。
    nonisolated static let maximumExtractedBytes: UInt64 = 500 * 1024 * 1024

    /// 安装脚本等待旧进程退出的最大重试次数（150 * 0.2s = 30s）。
    nonisolated static let processWaitMaxIterations = 150

    /// 当前运行实例与更新包的签名者身份描述（用于同源校验）。
    struct SigningIdentity: Equatable, Sendable {
        let isAdhoc: Bool
        let teamIdentifier: String?
        let certificateDigests: [String]
    }

    /// 安装阶段。窗口据此在「下载中 / 校验中」之间切换文案。
    enum Stage: Sendable {
        case downloading
        case verifyingChecksum
        case unpacking
        case validatingSignature
    }

    /// 阶段变化回调；在 MainActor 上调用。
    var onStageChange: ((Stage) -> Void)?

    private let session: URLSession
    private let fileManager: FileManager

    /// 当前这次下载的临时目录，下次下载开始时清掉，避免临时目录堆积。
    private var currentWorkDirectory: URL?

    /// 与 `AnShotLog` 同一 subsystem；category 只用在这一处，
    /// 因此没有为它新增全局常量（`AnShotLog` 由别的任务维护）。
    private let logger = Logger(subsystem: AnShotLog.subsystem, category: "update")

    init(session: URLSession = .shared, fileManager: FileManager = .default) {
        self.session = session
        self.fileManager = fileManager
    }

    // MARK: - 下载

    /// 下载并验证一个发布版本。
    ///
    /// - Parameters:
    ///   - release: 目标发布。没有 zip 时抛 `.noAsset`。
    ///   - progress: 0…1 的下载进度；在 MainActor 上调用。
    /// - Returns: 通过哈希、签名、bundle id 与版本校验的 `.app` URL（位于临时目录）。
    func download(
        _ release: UpdateRelease,
        progress: @escaping (Double) -> Void
    ) async throws -> URL {
        guard let zipURL = release.zipURL else { throw UpdateInstallError.noAsset }

        let workDirectory = try makeWorkDirectory()
        defer { currentWorkDirectory = workDirectory }

        onStageChange?(.downloading)
        progress(0)

        let zipFile = workDirectory.appendingPathComponent(Self.safeFileName(for: zipURL))
        try await downloadFile(
            zipURL,
            to: zipFile,
            expectedSize: release.size,
            progress: progress
        )
        progress(1)

        onStageChange?(.verifyingChecksum)
        let expected = try await resolveExpectedChecksum(release, zipFileName: zipFile.lastPathComponent)
        let actual = try await Self.sha256HexInBackground(of: zipFile)
        guard actual == expected else {
            logger.error("SHA256 不匹配：期望 \(expected, privacy: .public)，实际 \(actual, privacy: .public)")
            throw UpdateInstallError.checksumMismatch
        }

        onStageChange?(.unpacking)
        let extracted = try await Self.unzipInBackground(
            zipFile,
            into: workDirectory.appendingPathComponent("unzipped", isDirectory: true)
        )

        onStageChange?(.validatingSignature)
        try await validate(extracted, expecting: release)
        return extracted
    }

    private func makeWorkDirectory() throws -> URL {
        if let currentWorkDirectory {
            try? fileManager.removeItem(at: currentWorkDirectory)
            self.currentWorkDirectory = nil
        }
        // 每次下载一个独立目录：重试时不会读到上一次的半个 zip。
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("anShot-update-\(UUID().uuidString)", isDirectory: true)
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw UpdateInstallError.installFailed("无法创建临时下载目录：\(error.localizedDescription)")
        }
        return directory
    }

    private func downloadFile(
        _ url: URL,
        to destination: URL,
        expectedSize: Int,
        progress: @escaping (Double) -> Void
    ) async throws {
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.setValue("anShot", forHTTPHeaderField: "User-Agent")

        // 代理只负责把字节数写进一个线程安全的盒子；进度由主线程上的
        // ticker 读取。同时强制执行最大下载字节上限（200 MiB）。
        let probe = DownloadProbe(
            expectedBytes: Int64(expectedSize),
            maximumBytes: Self.maximumDownloadBytes
        )
        let ticker = Task { @MainActor in
            while !Task.isCancelled {
                progress(probe.fraction)
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }

        let result: Result<(URL, URLResponse), Error>
        do {
            result = .success(try await session.download(for: request, delegate: probe))
        } catch {
            result = .failure(error)
        }

        // 先停稳 ticker 再让调用方切到「校验中」：取消是异步的，
        // 直接返回会让一次迟到的进度回调把窗口从「校验中」打回「下载中」。
        ticker.cancel()
        _ = await ticker.value

        if probe.didExceedLimit {
            throw UpdateInstallError.installFailed("安装包体积超过安全上限（200 MiB），已停止下载。")
        }

        let downloaded: (URL, URLResponse)
        switch result {
        case .success(let payload):
            downloaded = payload
        case .failure(let error):
            throw UpdateInstallError.installFailed("下载安装包失败：\(error.localizedDescription)")
        }
        let (temporaryURL, response) = downloaded

        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw UpdateInstallError.installFailed("下载安装包失败：HTTP \(status)。")
        }

        if let attributes = try? fileManager.attributesOfItem(atPath: temporaryURL.path),
           let fileSize = (attributes[.size] as? NSNumber)?.int64Value,
           fileSize > Self.maximumDownloadBytes {
            try? fileManager.removeItem(at: temporaryURL)
            throw UpdateInstallError.installFailed("安装包体积超过安全上限（200 MiB），已停止下载。")
        }

        do {
            if fileManager.fileExists(atPath: destination.path) {
                try fileManager.removeItem(at: destination)
            }
            try fileManager.moveItem(at: temporaryURL, to: destination)
        } catch {
            throw UpdateInstallError.installFailed("保存下载内容失败：\(error.localizedDescription)")
        }
    }

    // MARK: - 校验和

    /// 优先用资产自带的 digest，其次下载 `SHA256SUMS`；两者都没有则拒绝安装。
    private func resolveExpectedChecksum(
        _ release: UpdateRelease,
        zipFileName: String
    ) async throws -> String {
        if let expected = release.expectedSHA256?.lowercased(),
           UpdateService.isSHA256Hex(expected) {
            return expected
        }

        guard let checksumURL = release.checksumURL else {
            throw UpdateInstallError.checksumUnavailable
        }

        var request = URLRequest(url: checksumURL)
        request.timeoutInterval = 20
        request.setValue("anShot", forHTTPHeaderField: "User-Agent")

        let fetched: (Data, URLResponse)
        do {
            fetched = try await session.data(for: request)
        } catch {
            logger.error("下载校验和失败：\(error.localizedDescription, privacy: .public)")
            throw UpdateInstallError.checksumUnavailable
        }
        let (data, response) = fetched
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw UpdateInstallError.checksumUnavailable
        }

        // 校验和文件永远不该这么大；超限说明拿到的不是它。
        guard data.count <= 256 * 1024 else { throw UpdateInstallError.checksumUnavailable }

        let text = String(decoding: data, as: UTF8.self)
        guard let parsed = Self.parseChecksum(text, fileName: zipFileName) else {
            throw UpdateInstallError.checksumUnavailable
        }
        return parsed
    }

    /// 从 `SHA256SUMS` 文本里取出目标文件的哈希。
    ///
    /// 兼容三种常见写法：
    ///     <hex>  anShot-1.2.3.zip        （GNU coreutils）
    ///     <hex> *anShot-1.2.3.zip        （二进制模式标记）
    ///     SHA256 (anShot-1.2.3.zip) = <hex>
    /// 以及只有一行哈希、没有文件名的情况。
    static func parseChecksum(_ text: String, fileName: String) -> String? {
        let target = fileName.lowercased()
        var loneChecksum: String?
        for rawLine in text.split(whereSeparator: \.isNewline) {
            // `split` 给出的是 Substring；Foundation 的 trimming 只对 String 生效。
            let line = String(rawLine).trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            // 分隔符包含 `*`：GNU 用它标记二进制模式，不拆开的话
            // 文件名会带上前导星号，永远匹配不上。
            let tokens = line
                .split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "*" })
                .map(String.init)
            guard let hash = tokens.first(where: { UpdateService.isSHA256Hex($0.lowercased()) }) else {
                continue
            }
            if tokens.count == 1 {
                loneChecksum = hash.lowercased()
                continue
            }
            if line.lowercased().contains(target) {
                return hash.lowercased()
            }
        }
        return loneChecksum
    }

    // MARK: - 解压

    private nonisolated static func unzipInBackground(_ zip: URL, into directory: URL) async throws -> URL {
        try await Task.detached(priority: .userInitiated) {
            try UpdateInstaller.unzip(zip, into: directory)
        }.value
    }

    private nonisolated static func unzip(_ zip: URL, into directory: URL) throws -> URL {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw UpdateInstallError.unzipFailed
        }

        // `ditto -x -k` 是 macOS 上解 zip 并保留 resource fork / 符号链接
        // 的可靠方式；`unzip` 会丢元数据，解出来的 .app 可能签名失效。
        let result: ToolResult
        do {
            result = try runTool("/usr/bin/ditto", ["-x", "-k", zip.path, directory.path])
        } catch {
            throw UpdateInstallError.unzipFailed
        }
        guard result.status == 0 else { throw UpdateInstallError.unzipFailed }

        let contents: [URL]
        do {
            contents = try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles]
            )
        } catch {
            throw UpdateInstallError.unzipFailed
        }

        // 严格拒绝顶层 .app 为符号链接，防止目录遍历欺骗。
        let apps = contents.filter { candidate in
            guard candidate.pathExtension.lowercased() == "app" else { return false }
            let values = try? candidate.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            return values?.isSymbolicLink != true && values?.isDirectory == true
        }

        // 先认名字，再退回到「唯一一个 .app」。
        let selectedApp: URL
        if let named = apps.first(where: { $0.lastPathComponent == "anShot.app" }) {
            selectedApp = named
        } else if apps.count == 1, let only = apps.first {
            selectedApp = only
        } else {
            throw UpdateInstallError.unzipFailed
        }

        // 解压后全量巡检：拒绝任何指向包外的符号链接，并限制总解压大小防止压缩炸弹。
        try validateExtractedBundle(at: selectedApp, maxBytes: maximumExtractedBytes)
        return selectedApp
    }

    /// 巡检解压后的应用包：禁止顶层及内部符号链接逃逸到包外，并强制总字节上限。
    nonisolated static func validateExtractedBundle(
        at appURL: URL,
        maxBytes: UInt64 = maximumExtractedBytes,
        fileManager: FileManager = .default
    ) throws {
        let topValues = try? appURL.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
        guard topValues?.isSymbolicLink != true, topValues?.isDirectory == true else {
            throw UpdateInstallError.unzipFailed
        }

        let resolvedRoot = appURL.standardizedFileURL.resolvingSymlinksInPath()
        let rootPath = resolvedRoot.path
        let rootPrefix = rootPath.hasSuffix("/") ? rootPath : (rootPath + "/")

        guard let enumerator = fileManager.enumerator(
            at: appURL,
            includingPropertiesForKeys: [.isSymbolicLinkKey, .isRegularFileKey, .fileSizeKey],
            options: []
        ) else {
            throw UpdateInstallError.unzipFailed
        }

        var totalBytes: UInt64 = 0
        for case let itemURL as URL in enumerator {
            let values = try? itemURL.resourceValues(
                forKeys: [.isSymbolicLinkKey, .isRegularFileKey, .fileSizeKey]
            )
            if values?.isSymbolicLink == true {
                // 逐条解析符号链接目标真实路径，必须严格落在解压包目录内。
                let destinationPath: String
                do {
                    destinationPath = try fileManager.destinationOfSymbolicLink(atPath: itemURL.path)
                } catch {
                    throw UpdateInstallError.installFailed("安装包内包含无法读取的符号链接，已停止安装。")
                }
                let rawTargetURL: URL
                if destinationPath.hasPrefix("/") {
                    rawTargetURL = URL(fileURLWithPath: destinationPath)
                } else {
                    rawTargetURL = itemURL.deletingLastPathComponent()
                        .appendingPathComponent(destinationPath)
                }
                let resolvedTarget = rawTargetURL.standardizedFileURL.resolvingSymlinksInPath().path
                guard resolvedTarget == rootPath || resolvedTarget.hasPrefix(rootPrefix) else {
                    throw UpdateInstallError.installFailed("安装包内包含越界符号链接，已停止安装。")
                }
                continue
            }

            if values?.isRegularFile == true, let size = values?.fileSize, size > 0 {
                let (nextTotal, overflow) = totalBytes.addingReportingOverflow(UInt64(size))
                if overflow || nextTotal > maxBytes {
                    throw UpdateInstallError.installFailed("解压后的安装包体积超过安全上限，已停止安装。")
                }
                totalBytes = nextTotal
            }
        }
    }

    // MARK: - 签名与身份校验

    private func validate(_ appURL: URL, expecting release: UpdateRelease) async throws {
        // 先用 Security 框架执行全架构严格签名验证并核对同源签名身份。
        let signatureOK = await Self.verifySignatureInBackground(of: appURL, logger: logger)
        guard signatureOK else {
            throw UpdateInstallError.signatureInvalid
        }

        guard let bundle = Bundle(url: appURL) else {
            throw UpdateInstallError.installFailed("解压出的安装包不是有效的应用（缺少 Info.plist）。")
        }

        // bundle id 是「这是不是 anShot」的唯一可靠判据：
        // 签名只证明来源，不证明身份。
        let identifier = bundle.bundleIdentifier ?? "（缺失）"
        guard identifier == Self.expectedBundleIdentifier else {
            throw UpdateInstallError.installFailed(
                "安装包的应用标识是「\(identifier)」，不是 anShot，已停止安装。"
            )
        }

        let rawVersion = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        guard let rawVersion, let appVersion = AppVersion(rawVersion) else {
            throw UpdateInstallError.installFailed("安装包缺少可读的版本号，已停止安装。")
        }
        // 用语义相等而不是字符串相等：发布 tag 可能是 v1.2，而 Info.plist 写 1.2.0。
        guard appVersion == release.version else {
            throw UpdateInstallError.installFailed(
                "安装包版本 \(appVersion) 与发布版本 \(release.version) 不一致，已停止安装。"
            )
        }
        if let expectedBuild = release.buildNumber,
           let rawBuild = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
           let actualBuild = Int(rawBuild.trimmingCharacters(in: .whitespacesAndNewlines)),
           actualBuild != expectedBuild {
            throw UpdateInstallError.installFailed(
                "安装包构建号 \(actualBuild) 与发布构建号 \(expectedBuild) 不一致，已停止安装。"
            )
        }
    }

    private nonisolated static func verifySignatureInBackground(
        of appURL: URL,
        logger: Logger
    ) async -> Bool {
        await Task.detached(priority: .userInitiated) {
            verifySignatureSynchronously(of: appURL, logger: logger)
        }.value
    }

    /// 使用 Security 框架验证候选包签名有效性，并强制要求签名者身份与当前运行实例同源。
    private nonisolated static func verifySignatureSynchronously(of appURL: URL, logger: Logger) -> Bool {
        var candidateStaticCode: SecStaticCode?
        let createStatus = SecStaticCodeCreateWithPath(appURL as CFURL, [], &candidateStaticCode)
        guard createStatus == errSecSuccess, let candidateCode = candidateStaticCode else {
            logger.error("创建候选包 SecStaticCode 失败：OSStatus \(createStatus, privacy: .public)")
            return false
        }

        // 严格校验所有架构与嵌套代码资源签名。
        let validationFlags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate)
        var validityError: Unmanaged<CFError>?
        let validityStatus = SecStaticCodeCheckValidityWithErrors(
            candidateCode,
            validationFlags,
            nil,
            &validityError
        )
        guard validityStatus == errSecSuccess else {
            let reason = (validityError?.takeRetainedValue() as Error?)?.localizedDescription ?? "OSStatus \(validityStatus)"
            logger.error("SecStaticCode 签名校验失败：\(reason, privacy: .public)")
            return false
        }

        // 获取候选包签名信息（Team ID 与证书链）。
        var candidateInfoRef: CFDictionary?
        let infoFlags = SecCSFlags(rawValue: kSecCSSigningInformation)
        guard SecCodeCopySigningInformation(candidateCode, infoFlags, &candidateInfoRef) == errSecSuccess,
              let candidateDict = candidateInfoRef as? [AnyHashable: Any] else {
            logger.error("读取候选包签名信息失败")
            return false
        }
        let candidateIdentity = extractSigningIdentity(from: candidateDict)

        // 获取当前运行实例的签名信息（SecCodeCopySelf -> SecCodeCopySigningInformation）。
        var selfCode: SecCode?
        var selfStaticCode: SecStaticCode?
        var selfInfoRef: CFDictionary?
        guard SecCodeCopySelf([], &selfCode) == errSecSuccess,
              let currentCode = selfCode,
              SecCodeCopyStaticCode(currentCode, [], &selfStaticCode) == errSecSuccess,
              let currentStaticCode = selfStaticCode,
              SecCodeCopySigningInformation(currentStaticCode, infoFlags, &selfInfoRef) == errSecSuccess,
              let selfDict = selfInfoRef as? [AnyHashable: Any] else {
            logger.error("读取当前实例签名信息失败，拒绝替换")
            return false
        }
        let currentIdentity = extractSigningIdentity(from: selfDict)

        guard isSignerCompatible(current: currentIdentity, candidate: candidateIdentity) else {
            logger.error("安装包签名者身份与当前实例不一致或为无锚点 Ad-hoc 构建，已拒绝")
            return false
        }
        return true
    }

    /// 从 `SecCodeCopySigningInformation` 返回字典中提取签名者身份。
    nonisolated static func extractSigningIdentity(from info: [AnyHashable: Any]) -> SigningIdentity {
        let rawFlags = (info[kSecCodeInfoFlags] as? NSNumber)?.uint32Value ?? 0
        let isAdhoc = (rawFlags & SecCodeSignatureFlags.adhoc.rawValue) != 0
        let teamID = (info[kSecCodeInfoTeamIdentifier] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedTeam = (teamID?.isEmpty == false) ? teamID : nil

        var digests: [String] = []
        if let certificates = info[kSecCodeInfoCertificates] as? [SecCertificate] {
            for cert in certificates {
                let data = SecCertificateCopyData(cert) as Data
                let digest = SHA256.hash(data: data).map { String(format: "%02x", Int($0)) }.joined()
                digests.append(digest)
            }
        }
        return SigningIdentity(
            isAdhoc: isAdhoc,
            teamIdentifier: normalizedTeam,
            certificateDigests: digests
        )
    }

    /// 校验当前运行实例与候选更新包的签名者是否严格同源，且均非无锚点 Ad-hoc 构建。
    nonisolated static func isSignerCompatible(
        current: SigningIdentity,
        candidate: SigningIdentity
    ) -> Bool {
        // 禁止无锚点 Ad-hoc 构建绕过同源检查进行静默自动替换。
        guard !current.isAdhoc, !candidate.isAdhoc else {
            return false
        }
        if let currentTeam = current.teamIdentifier, let candidateTeam = candidate.teamIdentifier {
            return currentTeam == candidateTeam
        }
        // 无 Team ID 时（如企业/自签锚点证书）要求双方证书链非空且叶证书或根证书指纹一致。
        guard let currentLeaf = current.certificateDigests.first,
              let candidateLeaf = candidate.certificateDigests.first else {
            return false
        }
        if currentLeaf == candidateLeaf {
            return true
        }
        if let currentRoot = current.certificateDigests.last,
           let candidateRoot = candidate.certificateDigests.last {
            return currentRoot == candidateRoot
        }
        return false
    }

    // MARK: - 安装

    /// 把已验证的 app 交给退出后运行的脚本，完成备份、替换与重启。
    ///
    /// 返回时脚本已经启动、新 bundle 已经复制到目标卷；调用方随后应当
    /// 调用 `NSApplication.shared.terminate(nil)` 让脚本继续。
    /// 校验目标应用路径解析符号链接后是否真正位于 `/Applications` 目录下。
    nonisolated static func isValidApplicationsTarget(_ targetURL: URL) -> Bool {
        let resolvedTarget = targetURL.standardizedFileURL.resolvingSymlinksInPath()
        guard resolvedTarget.pathExtension.lowercased() == "app" else {
            return false
        }
        let parent = resolvedTarget.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath()
        let applications = URL(fileURLWithPath: Self.applicationsPath, isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let appsPrefix = applications.path.hasSuffix("/") ? applications.path : (applications.path + "/")
        return parent.path == applications.path || parent.path.hasPrefix(appsPrefix)
    }

    func installAndRelaunch(appURL: URL) throws {
        let target = Bundle.main.bundleURL.standardizedFileURL.resolvingSymlinksInPath()
        guard Self.isValidApplicationsTarget(target) else {
            throw UpdateInstallError.notInApplications
        }

        let parent = target.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath()
        guard fileManager.isWritableFile(atPath: parent.path) else {
            throw UpdateInstallError.notWritable
        }

        let stamp = Self.timestamp()
        let staged = parent.appendingPathComponent(".anShot-update-\(stamp).app", isDirectory: true)
        let backup = parent.appendingPathComponent(".anShot-backup-\(stamp).app", isDirectory: true)

        // 先在同一卷上准备新 bundle：跨卷 rename 会失败，而失败发生在
        // 应用退出之后就无法提示。复制失败还能在这里报给用户。
        do {
            if fileManager.fileExists(atPath: staged.path) {
                try fileManager.removeItem(at: staged)
            }
            try fileManager.copyItem(at: appURL, to: staged)
        } catch {
            throw UpdateInstallError.installFailed(
                "无法把新版本复制到「应用程序」文件夹：\(error.localizedDescription)"
            )
        }

        Self.removeStaleArtifacts(in: parent, keeping: [staged.lastPathComponent], fileManager: fileManager)

        do {
            let scriptURL = try writeInstallScript(
                target: target,
                staged: staged,
                backup: backup
            )
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = [scriptURL.path]
            // 脚本自己写日志；这里丢弃输出，避免继承的管道阻塞子进程。
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
        } catch {
            try? fileManager.removeItem(at: staged)
            throw UpdateInstallError.installFailed("无法启动安装脚本：\(error.localizedDescription)")
        }

        // 新 bundle 已复制走，临时目录可以立刻回收。
        if let currentWorkDirectory {
            try? fileManager.removeItem(at: currentWorkDirectory)
            self.currentWorkDirectory = nil
        }
    }

    /// 清掉上一次失败留下的暂存/备份目录，避免 /Applications 里越堆越多。
    ///
    /// 只删自己命名规则下的隐藏目录，且保留本次正在使用的 staged。
    /// 用 `contentsOfDirectory`（不带 `.skipsHiddenFiles`）是因为这些目录本身
    /// 以 `.` 开头，跳过隐藏项等于什么也找不到。
    private static func removeStaleArtifacts(
        in directory: URL,
        keeping names: Set<String>,
        fileManager: FileManager
    ) {
        guard let entries = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ) else {
            return
        }
        for entry in entries where !names.contains(entry.lastPathComponent) {
            let name = entry.lastPathComponent
            guard name.hasPrefix(".anShot-update-") || name.hasPrefix(".anShot-backup-") else {
                continue
            }
            try? fileManager.removeItem(at: entry)
        }
    }

    /// 生成安装脚本并写盘。
    ///
    /// 脚本内容全部用单引号路径（`shellQuote`），避免 /Applications 下
    /// 出现空格或特殊字符时被 shell 拆开。
    private func writeInstallScript(target: URL, staged: URL, backup: URL) throws -> URL {
        let logPath = ("~/Library/Logs/anShot/update-install.log" as NSString).expandingTildeInPath
        let script = """
        #!/bin/sh
        # anShot 更新安装脚本：在 App 退出后执行。
        # 失败时回滚到备份并重新打开旧版本；所有输出写入日志。
        set -u

        TARGET=\(Self.shellQuote(target.path))
        STAGED=\(Self.shellQuote(staged.path))
        BACKUP=\(Self.shellQuote(backup.path))
        APP_PID=\(ProcessInfo.processInfo.processIdentifier)
        LOG=\(Self.shellQuote(logPath))

        mkdir -p "$(dirname "$LOG")" 2>/dev/null
        exec >>"$LOG" 2>&1
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] 开始安装：$TARGET"

        rollback() {
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] 安装失败：$1"
            # 只有确实做过备份才动 TARGET：如果备份步骤就失败了，
            # TARGET 仍是完好的旧版本，删掉它等于把用户的应用程序弄丢。
            if [ -d "$BACKUP" ]; then
                rm -rf "$TARGET"
                mv "$BACKUP" "$TARGET"
                echo "已回滚到旧版本"
            fi
            rm -rf "$STAGED"
            open "$TARGET"
            exit 1
        }

        # 等旧进程真正退出：加上最大等待次数上限（150 次 = 30s），避免死循环。
        WAIT_COUNT=0
        while kill -0 "$APP_PID" 2>/dev/null; do
            WAIT_COUNT=$((WAIT_COUNT + 1))
            if [ "$WAIT_COUNT" -ge \(Self.processWaitMaxIterations) ]; then
                rollback "等待旧版本进程退出超时"
            fi
            sleep 0.2
        done
        sleep 0.3

        if [ -d "$TARGET" ]; then
            rm -rf "$BACKUP"
            mv "$TARGET" "$BACKUP" || rollback "无法备份旧版本"
        fi

        mv "$STAGED" "$TARGET" || rollback "无法替换应用"

        # 遵循 Gatekeeper 安全边界：不再静默剥离 com.apple.quarantine 隔离属性。

        open "$TARGET" || rollback "无法重新启动 anShot"
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] 安装完成"
        rm -f "$0"
        exit 0
        """

        let directory = fileManager.temporaryDirectory
        let scriptURL = directory.appendingPathComponent(
            ".anshot-install-\(ProcessInfo.processInfo.processIdentifier)-\(Self.timestamp())-\(UUID().uuidString).sh"
        )
        do {
            try Self.writeExecutableScriptAtomically(script, to: scriptURL)
        } catch {
            throw UpdateInstallError.installFailed("无法写入安装脚本：\(error.localizedDescription)")
        }
        return scriptURL
    }

    /// 一步以 `0700` 权限原子创建安装脚本并写入内容，消除先写再改权的竞争窗口。
    nonisolated static func writeExecutableScriptAtomically(_ script: String, to url: URL) throws {
        let fd = Darwin.open(url.path, O_WRONLY | O_CREAT | O_EXCL, S_IRWXU)
        guard fd >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        try handle.write(contentsOf: Data(script.utf8))
        try handle.synchronize()
        try handle.close()
    }

    // MARK: - 工具

    private nonisolated static func runToolInBackground(
        _ executable: String,
        _ arguments: [String]
    ) async throws -> ToolResult {
        try await Task.detached(priority: .userInitiated) {
            try UpdateInstaller.runTool(executable, arguments)
        }.value
    }

    private nonisolated static func sha256HexInBackground(of url: URL) async throws -> String {
        do {
            return try await Task.detached(priority: .userInitiated) {
                try UpdateInstaller.sha256Hex(of: url)
            }.value
        } catch {
            throw UpdateInstallError.installFailed("读取下载内容失败：\(error.localizedDescription)")
        }
    }

    /// 流式计算 SHA256：安装包可能有几十 MB，整份读进内存没有必要。
    nonisolated static func sha256Hex(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var hasher = SHA256()
        while true {
            let chunk = try handle.read(upToCount: 1 << 20) ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", Int($0)) }.joined()
    }

    /// 运行一个命令行工具并合并读取 stdout/stderr。
    ///
    /// 必须在 `readToEnd()` 之后再 `waitUntilExit()`：反过来的话，
    /// 输出超过管道缓冲区（64KB）时子进程会卡在 write 上永不退出。
    nonisolated static func runTool(_ executable: String, _ arguments: [String]) throws -> ToolResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        try process.run()
        let data = try pipe.fileHandleForReading.readToEnd() ?? Data()
        process.waitUntilExit()

        let output = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return ToolResult(status: process.terminationStatus, output: output)
    }

    /// 把任意字符串包成单引号 shell 参数。
    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func safeFileName(for url: URL) -> String {
        let name = url.lastPathComponent
        guard !name.isEmpty, name != "/", name != ".", name != "..", !name.hasPrefix(".") else {
            return "anShot-update.zip"
        }
        return name
    }

    private static func timestamp() -> String {
        let formatter = DateFormatter()
        // 只用于生成目录名：月份/小时用定长，排序自然按时间。
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }
}

/// 命令行工具的输出。
struct ToolResult: Sendable {
    let status: Int32
    let output: String
}

// MARK: - 下载进度

/// 把 URLSession 的写入回调转成「已下载 / 总大小」。
///
/// 单独一个对象是必须的：任务级 delegate 的回调在 URLSession 的队列上，
/// 而进度必须回到 MainActor。共享状态用锁保护，避免 ticker 读到半个值。
private final class DownloadProbe: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {

    private let lock = NSLock()
    private let maximumBytes: Int64
    private var expected: Int64
    private var written: Int64 = 0
    private var exceededLimit = false

    init(expectedBytes: Int64, maximumBytes: Int64) {
        self.expected = expectedBytes
        self.maximumBytes = maximumBytes
        super.init()
    }

    var fraction: Double {
        lock.lock()
        defer { lock.unlock() }
        guard expected > 0 else { return 0 }
        return min(1, Double(written) / Double(expected))
    }

    var didExceedLimit: Bool {
        lock.lock()
        defer { lock.unlock() }
        return exceededLimit
    }

    /// 协议要求实现，但下载结果由 `URLSession.download(for:delegate:)` 的
    /// async 返回值接管；这里不移动临时文件，只保留协议一致性。
    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {}

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        var shouldCancel = false
        lock.lock()
        // 服务器的 Content-Length 比资产元数据更准，有就以它为准。
        if totalBytesExpectedToWrite > 0 {
            expected = totalBytesExpectedToWrite
        }
        written = totalBytesWritten
        if totalBytesWritten > maximumBytes
            || (totalBytesExpectedToWrite > 0 && totalBytesExpectedToWrite > maximumBytes) {
            exceededLimit = true
            shouldCancel = true
        }
        lock.unlock()

        if shouldCancel {
            downloadTask.cancel()
        }
    }
}
