//
//  UpdateService.swift
//  AnShotUI
//
//  GitHub Releases 的查询与缓存。
//
//  ── 为什么不用 Sparkle ───────────────────────────────────────
//
//  项目约束是「无第三方依赖」，而更新只需要三件事：读一个 JSON、
//  下载一个 zip、校验后替换 bundle。Sparkle 解决的是「多频道 + 增量包 +
//  签名 appcast」这一类更大问题，代价是引入整套框架与嵌套代码签名。
//  这里用 GitHub API 直接实现，代价是必须自己处理速率限制与缓存。
//
//  ── 缓存为什么是必需的 ───────────────────────────────────────
//
//  GitHub 对**未认证**请求限制为每小时 60 次，按 IP 计。菜单栏程序每 24
//  小时检查一次，看似离上限很远；但同一出口 IP（公司、家庭路由器后）可能
//  有很多台机器，而且用户手动点「检查更新」也会计数。
//
//  所以这里走标准的 `ETag` / `If-None-Match`：第二次起回 304，
//  GitHub **不计入**速率限制，响应体也为空。缓存的正是上一次的 JSON
//  与 ETag——304 不代表「没有新版本」，只代表「和上次看到的一样」，
//  所以仍然要用缓存里的 release 与当前版本比较。
//
//  ── 404 不是错误 ─────────────────────────────────────────────
//
//  仓库还没有发布任何 release 时，`/releases/latest` 返回 404。
//  这对一个刚建仓库的项目是正常状态，弹「检查更新失败」只会让用户困惑。
//  但它也**不能**被显示成「已是最新」——那是在撒谎（根本还没有版本可更新）。
//  因此 `UpdateCheckResult` 增加 `.noRelease` 一档，UI 据此给出准确文案。
//

import AnShotCore
import Foundation

// MARK: - 结果类型

/// 一个可安装的发布版本。
struct UpdateRelease: Equatable, Sendable {
    /// 从 tag 解析出的版本号。
    let version: AppVersion
    /// 原始 tag（可能带 v 前缀），用于向用户展示与排查。
    let tag: String
    /// release 标题；为空时退回 tag。
    let title: String
    /// 发布说明，纯文本（GitHub 上是 Markdown，但这里不做渲染）。
    let notes: String
    /// 发布页 URL，失败时永远可以退回到这里手动下载。
    let pageURL: URL
    /// zip 资产下载地址；没有 zip 时为 nil（窗口会禁用「下载并安装」）。
    let zipURL: URL?
    /// `SHA256SUMS` 资产地址；没有时为 nil。
    let checksumURL: URL?
    /// 资产自带的 `digest`（GitHub 新字段，形如 `sha256:…`）。
    let expectedSHA256: String?
    /// zip 资产大小（字节）；未知为 0。
    let size: Int
    let publishedAt: Date?
}

/// 一次检查的结论。
enum UpdateCheckResult: Equatable, Sendable {
    /// GitHub 上还没有任何发布版本（404）。与「已是最新」是两件事。
    case noRelease
    /// 远端版本不高于当前版本。
    case upToDate(current: AppVersion)
    /// 有可用的新版本。
    case available(UpdateRelease)
}

/// 检查失败的**用户可读**原因。
enum UpdateCheckError: LocalizedError, Sendable {
    case network(String)
    case invalidResponse
    case httpStatus(Int)
    case rateLimited(reset: Date?)
    case unparsableVersion(String)

    var errorDescription: String? {
        switch self {
        case .network(let detail):
            return "网络请求失败：\(detail)"
        case .invalidResponse:
            return "GitHub 返回了无法识别的响应。"
        case .httpStatus(let code):
            return "GitHub 返回了 HTTP \(code)。"
        case .rateLimited(let reset):
            if let reset {
                let formatter = DateFormatter()
                // 只关心「大概什么时候能再试」，用中等的本地时间就够了。
                formatter.dateStyle = .none
                formatter.timeStyle = .short
                return "GitHub 接口请求过于频繁，请在 \(formatter.string(from: reset)) 之后重试。"
            }
            return "GitHub 接口请求过于频繁，请稍后再试。"
        case .unparsableVersion(let tag):
            return "无法解析发布版本号「\(tag)」。"
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .network, .invalidResponse, .httpStatus:
            return "检查网络后重试；也可以直接打开发布页手动下载。"
        case .rateLimited:
            return "稍后重试，或直接打开发布页查看。"
        case .unparsableVersion:
            return "请打开发布页手动下载，并把这个 tag 反馈给开发者。"
        }
    }
}

// MARK: - 服务

/// GitHub Releases 查询。
///
/// 刻意做成实例而不是全静态：`URLSession` 与 `UserDefaults` 都能注入，
/// 这样缓存逻辑（304 命中、缓存损坏后重取）不需要真的联网也能验证。
@MainActor
final class UpdateService {

    /// 契约指定的端点。
    static let latestReleaseEndpoint = URL(
        string: "https://api.github.com/repos/zzhang-AL/anShot/releases/latest"
    )!

    /// 手动下载的兜底入口（所有失败态都保留它）。
    static let releasesPage = URL(string: "https://github.com/zzhang-AL/anShot/releases")!

    private enum CacheKey {
        static let etag = "update.latestRelease.etag"
        static let body = "update.latestRelease.body"
    }

    private let session: URLSession
    private let defaults: UserDefaults

    init(session: URLSession = .shared, defaults: UserDefaults = .standard) {
        self.session = session
        self.defaults = defaults
    }

    /// 查询最新版本并与 `currentVersion` 比较。
    ///
    /// 网络与 JSON 错误统一抛 `UpdateCheckError`；404 返回 `.noRelease`。
    func check(currentVersion: AppVersion) async throws -> UpdateCheckResult {
        try await fetch(currentVersion: currentVersion, sendingConditionalRequest: true)
    }

    // MARK: - 请求

    private func fetch(
        currentVersion: AppVersion,
        sendingConditionalRequest: Bool
    ) async throws -> UpdateCheckResult {
        var request = URLRequest(url: Self.latestReleaseEndpoint)
        request.httpMethod = "GET"
        // 20 秒足够覆盖慢速网络，又不至于让「检查中」无限转圈。
        request.timeoutInterval = 20
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        // GitHub API 要求 User-Agent；不设置会被 403 拒绝。
        request.setValue("anShot", forHTTPHeaderField: "User-Agent")
        // 固定 API 版本，避免将来默认版本变化导致字段改名（GitHub 的兼容承诺）。
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")

        if sendingConditionalRequest, let etag = defaults.string(forKey: CacheKey.etag) {
            request.setValue(etag, forHTTPHeaderField: "If-None-Match")
        }

        let fetched: (Data, URLResponse)
        do {
            fetched = try await session.data(for: request)
        } catch {
            throw UpdateCheckError.network(error.localizedDescription)
        }
        let (data, response) = fetched

        guard let http = response as? HTTPURLResponse else {
            throw UpdateCheckError.invalidResponse
        }

        switch http.statusCode {
        case 200:
            let payload = try decode(data)
            // ETag 与响应体一起缓存；二者必须成对，否则 304 时无从还原。
            if let etag = http.value(forHTTPHeaderField: "ETag"), !etag.isEmpty {
                defaults.set(etag, forKey: CacheKey.etag)
            } else {
                defaults.removeObject(forKey: CacheKey.etag)
            }
            defaults.set(data, forKey: CacheKey.body)
            return result(from: try makeRelease(from: payload), currentVersion: currentVersion)

        case 304:
            // 与上次相同的 release。缓存缺失或损坏时不能当成「无更新」，
            // 必须去掉条件重发一次（304 只可能出现在我们带了 ETag 的请求上）。
            guard let cached = defaults.data(forKey: CacheKey.body),
                  let payload = try? decode(cached)
            else {
                defaults.removeObject(forKey: CacheKey.etag)
                defaults.removeObject(forKey: CacheKey.body)
                return try await fetch(currentVersion: currentVersion, sendingConditionalRequest: false)
            }
            return result(from: try makeRelease(from: payload), currentVersion: currentVersion)

        case 404:
            return .noRelease

        case 403 where http.value(forHTTPHeaderField: "X-RateLimit-Remaining") == "0":
            throw UpdateCheckError.rateLimited(reset: Self.resetDate(from: http))

        default:
            throw UpdateCheckError.httpStatus(http.statusCode)
        }
    }

    // MARK: - 解码

    private func decode(_ data: Data) throws -> GitHubRelease {
        do {
            return try JSONDecoder().decode(GitHubRelease.self, from: data)
        } catch {
            throw UpdateCheckError.invalidResponse
        }
    }

    private func makeRelease(from payload: GitHubRelease) throws -> UpdateRelease {
        // tag 是唯一权威来源；有些仓库把版本写在标题里而没有 tag 前缀，
        // 因此标题作为第二次尝试，而不是直接判失败。
        guard let version = AppVersion(payload.tagName) ?? AppVersion(payload.name ?? "") else {
            throw UpdateCheckError.unparsableVersion(payload.tagName)
        }

        let zipAsset = Self.pickZip(from: payload.assets)
        let checksumAsset = Self.pickChecksum(from: payload.assets)
        let title = (payload.name?.isEmpty == false ? payload.name : nil) ?? payload.tagName

        return UpdateRelease(
            version: version,
            tag: payload.tagName,
            title: title,
            notes: payload.body ?? "",
            pageURL: URL(string: payload.htmlURL) ?? Self.releasesPage,
            zipURL: zipAsset.flatMap { URL(string: $0.browserDownloadURL) },
            checksumURL: checksumAsset.flatMap { URL(string: $0.browserDownloadURL) },
            expectedSHA256: zipAsset.flatMap { $0.digest }.flatMap(Self.sha256Digest),
            size: zipAsset?.size ?? 0,
            publishedAt: payload.publishedAt.flatMap { Self.parseDate($0) }
        )
    }

    private func result(
        from release: UpdateRelease,
        currentVersion: AppVersion
    ) -> UpdateCheckResult {
        // 只有严格更高才算更新：本地构建版本比 release 新时（开发机常见）
        // 不能被提示「降级」。
        guard release.version > currentVersion else {
            return .upToDate(current: currentVersion)
        }
        return .available(release)
    }

    // MARK: - 字段选择

    /// 优先选名字里带 anShot 的 zip，其次任意 zip。
    ///
    /// 发布页可能同时挂调试符号包（`*.dSYM.zip`）：把符号包当安装包下载，
    /// 后面所有校验都会失败，而且失败信息指向「解压/签名」而不是「选错了资产」。
    private static func pickZip(from assets: [GitHubAsset]) -> GitHubAsset? {
        let zips = assets.filter { $0.name.lowercased().hasSuffix(".zip") }
        guard !zips.isEmpty else { return nil }
        let installable = zips.filter {
            let name = $0.name.lowercased()
            return !name.contains("dsym") && !name.contains("symbols")
        }
        let pool = installable.isEmpty ? zips : installable
        return pool.first { $0.name.lowercased().contains("anshot") } ?? pool.first
    }

    private static func pickChecksum(from assets: [GitHubAsset]) -> GitHubAsset? {
        assets.first { asset in
            let name = asset.name.uppercased()
            return !name.hasSuffix(".ZIP") && (name.contains("SHA256") || name.contains("CHECKSUM"))
        }
    }

    /// 解析 GitHub 的 `digest` 字段（形如 `sha256:abc…`）。
    ///
    /// 校验和只在能确认是 64 位十六进制时才采用：把一个格式不对的值
    /// 拿去比较只会得到「校验失败」，让用户误以为下载被篡改。
    private static func sha256Digest(_ raw: String) -> String? {
        let lower = raw.lowercased()
        guard lower.hasPrefix("sha256:") else { return nil }
        let value = String(lower.dropFirst("sha256:".count))
        guard isSHA256Hex(value) else { return nil }
        return value
    }

    static func isSHA256Hex(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy { $0.isHexDigit }
    }

    private static func parseDate(_ raw: String?) -> Date? {
        guard let raw, !raw.isEmpty else { return nil }
        // GitHub 的格式是 ISO8601；不同卡片偶尔带小数秒，两种都试。
        let plain = ISO8601DateFormatter()
        if let date = plain.date(from: raw) { return date }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: raw)
    }

    private static func resetDate(from response: HTTPURLResponse) -> Date? {
        guard let raw = response.value(forHTTPHeaderField: "X-RateLimit-Reset"),
              let seconds = TimeInterval(raw)
        else {
            return nil
        }
        return Date(timeIntervalSince1970: seconds)
    }
}

// MARK: - GitHub JSON

/// `/releases/latest` 的响应。只声明用得到的字段：
/// 多声明一个字段就多一处「上游改名即解码失败」的风险。
private struct GitHubRelease: Decodable {
    let tagName: String
    let name: String?
    let body: String?
    let htmlURL: String
    let publishedAt: String?
    let assets: [GitHubAsset]

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case name
        case body
        case htmlURL = "html_url"
        case publishedAt = "published_at"
        case assets
    }
}

private struct GitHubAsset: Decodable {
    let name: String
    let size: Int?
    let browserDownloadURL: String
    /// GitHub 自 2024 起提供的资产摘要；老资产为 null。
    let digest: String?

    enum CodingKeys: String, CodingKey {
        case name
        case size
        case browserDownloadURL = "browser_download_url"
        case digest
    }
}
