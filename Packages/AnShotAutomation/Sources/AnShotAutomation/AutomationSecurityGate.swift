//
//  AutomationSecurityGate.swift
//  AnShotAutomation
//
//  MCP 与自动化后台通道的四层安全防线：
//  1. Socket 内核级 `LOCAL_PEERTOKEN` 代码签名强校验（拒绝一切外部未签名/异签名进程直连）；
//  2. 总开关 + `ANSHOT_MCP_TOKEN` 常量时间访问令牌校验（防恶意脚本借壳调用 `anShot` 二进制）；
//  3. IPC 中转输出路径沙箱校验（严格限定本用户 `0o700` 临时私有目录内，防任意文件覆盖）；
//  4. 敏感隐私应用窗口/控件树拦截（防偷窥密码管理器与系统钥匙串）。
//

import AnShotCapture
import AppKit
import CoreGraphics
import Darwin
import Foundation
import Security

/// 自动化总开关、访问令牌与敏感隐私窗口门禁。
enum AutomationSecurityGate {

    /// 从当前进程环境变量读取 `ANSHOT_MCP_TOKEN`。
    static func currentEnvironmentToken(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        guard let raw = environment[AutomationSecuritySettings.tokenEnvironmentVariable]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else {
            return nil
        }
        return raw
    }

    /// 统一授权校验：先查自动化总开关，再校验可选强制访问令牌。
    static func authorize(
        providedToken: String?,
        settings: AutomationSecuritySettings = .shared
    ) throws {
        guard settings.isAutomationEnabled else {
            throw AutomationError.invalidArgument(
                "已在 anShot 设置中关闭「MCP 与自动化后台服务」。如需恢复，请前往 anShot 设置 → 通用 → MCP 与自动化安全 开启。"
            )
        }
        guard settings.validateAccessToken(providedToken) else {
            throw AutomationError.invalidArgument(
                "访问被拒绝：anShot 已启用自动化访问令牌保护，未提供有效的 \(AutomationSecuritySettings.tokenEnvironmentVariable)。"
                + "请打开 anShot 设置 → 通用 → MCP 与自动化安全 复制令牌，并配置到 MCP 客户端环境变量中。"
            )
        }
    }

    /// 校验目标窗口或进程是否属于受保护隐私应用（密码管理器/钥匙串/系统设置）；命中时抛出明确错误。
    static func validateTargetWindowAllowed(
        pid: pid_t,
        applicationName: String?,
        settings: AutomationSecuritySettings = .shared
    ) throws {
        guard settings.protectSensitiveWindows else { return }
        let bundleID = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
        if settings.isProtectedWindow(bundleIdentifier: bundleID, applicationName: applicationName) {
            let label = applicationName ?? bundleID ?? "受保护应用"
            throw AutomationError.invalidArgument(
                "出于隐私保护，已拦截对受保护应用「\(label)」的后台自动化访问。"
                + "如需调整，请前往 anShot 设置 → 通用 → MCP 与自动化安全。"
            )
        }
    }

    /// 按 `windowID` 查出归属进程与应用名并校验是否受隐私保护。
    static func validateWindowIDAllowed(
        _ windowID: CGWindowID,
        settings: AutomationSecuritySettings = .shared
    ) throws {
        guard settings.protectSensitiveWindows else { return }
        guard let info = WindowCatalog.info(for: windowID) else { return }
        try validateTargetWindowAllowed(
            pid: info.pid,
            applicationName: info.appName,
            settings: settings
        )
    }
}

/// IPC 中转文件路径沙箱校验器（彻底封死通过 `outputPath` 覆盖用户任意文件的攻击面）。
enum AutomationPathSandbox {

    /// 校验跨进程中转 `outputPath` 必须严格位于本用户 `0o700` 的 `anshot-ipc-*` 私有临时目录内，
    /// 不得包含 `..` 路径穿越、不得经过符号链接目录、且不得覆盖已存在目标。
    static func validateTransferOutputPath(
        _ rawPath: String,
        allowedTempRoot: URL = FileManager.default.temporaryDirectory
    ) throws -> URL {
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.hasPrefix("/") else {
            throw AutomationError.invalidArgument("非法的中转输出路径：必须为非空绝对路径。")
        }

        let rawSegments = trimmed.split(separator: "/")
        let url = URL(fileURLWithPath: trimmed)
        let components = url.pathComponents
        guard !rawSegments.contains(".."), !components.contains("..") else {
            throw AutomationError.invalidArgument("非法的中转输出路径：禁止包含上级目录遍历组件（..）。")
        }

        let parentURL = url.deletingLastPathComponent()
        let parentName = parentURL.lastPathComponent
        guard parentName.hasPrefix("anshot-ipc-") else {
            throw AutomationError.invalidArgument("非法的中转输出路径：仅允许写入 anShot 私有 IPC 临时目录。")
        }

        // 严格校验父目录必须是真实目录（非软链接）、属主为当前用户且权限收紧为 0700。
        var parentStat = stat()
        guard lstat(parentURL.path, &parentStat) == 0 else {
            throw AutomationError.invalidArgument("中转输出目录不存在：\(parentURL.path)")
        }
        let fileType = parentStat.st_mode & S_IFMT
        guard fileType == S_IFDIR else {
            throw AutomationError.invalidArgument("非法的中转输出目录：不允许为符号链接或非目录对象。")
        }
        guard parentStat.st_uid == geteuid() else {
            throw AutomationError.invalidArgument("非法的中转输出目录：属主不匹配当前用户。")
        }
        guard (parentStat.st_mode & 0o077) == 0 else {
            throw AutomationError.invalidArgument("非法的中转输出目录：目录权限必须限制为仅当前用户可访问（0700）。")
        }

        // 用 realpath 校验父目录是系统临时目录根的直接子目录，防止任意位置伪造 anshot-ipc-* 目录。
        guard let resolvedRoot = realpathString(allowedTempRoot.path),
              let resolvedParent = realpathString(parentURL.path) else {
            throw AutomationError.invalidArgument("无法规范化中转输出目录路径。")
        }
        let parentContainer = URL(fileURLWithPath: resolvedParent).deletingLastPathComponent().path
        guard parentContainer == resolvedRoot else {
            throw AutomationError.invalidArgument("非法的中转输出路径：超出允许的私有临时目录边界。")
        }

        // 拒绝覆盖已存在的目标文件或符号链接。
        var targetStat = stat()
        if lstat(url.path, &targetStat) == 0 {
            throw AutomationError.invalidArgument("非法的中转输出路径：目标文件已存在，拒绝覆盖。")
        }

        return URL(fileURLWithPath: resolvedParent).appendingPathComponent(url.lastPathComponent)
    }

    private static func realpathString(_ path: String) -> String? {
        guard let cString = realpath(path, nil) else { return nil }
        defer { free(cString) }
        return String(cString: cString)
    }
}

/// 基于 macOS 内核 `LOCAL_PEERTOKEN`（`audit_token_t`）与 Security 框架的对端代码签名校验器。
///
/// 彻底封死同用户下的 Python / Node / curl / 恶意二进制直接连接 `automation.sock` 盗用权限。
enum PeerCodeSignatureVerifier {

    /// `SecRequirement` 为不可变 CoreFoundation 对象，可安全跨线程只读共享。
    private struct SendableRequirement: @unchecked Sendable {
        let value: SecRequirement
    }

    /// 缓存当前进程自身的代码签名 Designated Requirement（只提取一次）。
    private static let selfDesignatedRequirement: SendableRequirement? = {
        guard Bundle.main.bundleURL.pathExtension == "app" else {
            // 非 `.app` 打包环境（如 `swift test` 未签名测试宿主）不强制要求自身签名。
            return nil
        }
        var selfCode: SecCode?
        guard SecCodeCopySelf([], &selfCode) == errSecSuccess, let selfCode else {
            return nil
        }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(selfCode, [], &staticCode) == errSecSuccess,
              let staticCode else {
            return nil
        }
        var requirement: SecRequirement?
        guard SecCodeCopyDesignatedRequirement(staticCode, [], &requirement) == errSecSuccess,
              let requirement else {
            return nil
        }
        return SendableRequirement(value: requirement)
    }()

    /// 校验已 `accept` 的客户端 Socket 对端是否具备与当前 `anShot.app` 相同的代码签名身份。
    ///
    /// - 在已签名的 `.app` 正式环境中：必须通过 `LOCAL_PEERTOKEN`（`audit_token_t`）+
    ///   `SecCodeCheckValidity` 同签名校验，否则立即拒绝连接。
    /// - 在未签名的开发测试进程中（无 `.app` bundle）：回退为已通过的同 UID 校验。
    static func verifySameSignedApplication(_ clientFD: Int32) -> Bool {
        guard let requirement = selfDesignatedRequirement?.value else {
            // 测试宿主（xctest）不是 .app 时放行；正式 .app 若签名异常则宁可拒绝。
            return Bundle.main.bundleURL.pathExtension != "app"
        }

        var token = audit_token_t()
        var tokenSize = socklen_t(MemoryLayout<audit_token_t>.size)
        let rc = withUnsafeMutableBytes(of: &token) { raw in
            getsockopt(clientFD, SOL_LOCAL, LOCAL_PEERTOKEN, raw.baseAddress, &tokenSize)
        }
        guard rc == 0, tokenSize == socklen_t(MemoryLayout<audit_token_t>.size) else {
            return false
        }

        let tokenData = withUnsafeBytes(of: token) { Data($0) }
        let attributes: NSDictionary = [
            kSecGuestAttributeAudit as String: tokenData
        ]
        var peerCode: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &peerCode) == errSecSuccess,
              let peerCode else {
            return false
        }

        return SecCodeCheckValidity(peerCode, [], requirement) == errSecSuccess
    }
}
