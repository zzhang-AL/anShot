//
//  RecordingError.swift
//  AnShotCore
//
//  录制失败原因。契约见 docs/m2-recording/model.md §6。
//

import Foundation

/// 录制失败原因。
public enum RecordingError: Error, Sendable, Equatable, LocalizedError {

    /// 缺少**屏幕录制**权限。
    case permissionDenied

    /// 缺少**麦克风**权限。
    ///
    /// **不能复用 `.permissionDenied`**：它只说「屏幕录制」，
    /// 用户在系统设置里翻到那一项发现明明是开着的，
    /// 于是永远找不到真正要开的是麦克风——多麦克风录制会无声地失败。
    case microphonePermissionDenied

    /// 目标窗口/应用/显示器已不存在。
    case scopeUnavailable

    /// 已有会话在进行中，会话实例不可复用。
    case alreadyRunning

    /// 流已启动但在超时内没有收到任何完整帧。
    case timedOut

    /// 用户主动取消。
    case cancelled

    /// 请求了当前系统版本不支持的组合（如 13.0 上的 HEVC + 特定分辨率）。
    case unsupportedConfiguration(String)

    /// SCStream 报错。
    case streamFailed(String)

    /// 写入器报错（磁盘满、编码器不支持）。
    case writerFailed(String)

    /// GIF 转码失败（临时影片已落盘，但逐帧转 GIF 出错）。
    ///
    /// **为什么不复用 `.writerFailed`**：「写入文件失败：无法创建 GIF 输出」
    /// 是把转码失败伪装成 IO 失败，会把用户引向磁盘权限方向去排查，
    /// 而真实原因通常在转码这一侧。
    ///
    /// 归入「保留已录内容」的一类：转码失败后调用方应当把**临时影片**
    /// 交给用户（见 `shouldKeepPartialOutput`）。
    case gifExportFailed(String)

    public var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "缺少屏幕录制权限"
        case .microphonePermissionDenied:
            return "缺少麦克风权限"
        case .scopeUnavailable:
            return "录制目标已不存在"
        case .alreadyRunning:
            return "已有录制会话在进行中"
        case .timedOut:
            return "等待首帧超时，屏幕可能长时间无变化"
        case .cancelled:
            return "录制已取消"
        case .unsupportedConfiguration(let detail):
            return "当前系统不支持该录制配置：\(detail)"
        case .streamFailed(let detail):
            return "捕获流中断：\(detail)"
        case .writerFailed(let detail):
            return "写入文件失败：\(detail)"
        case .gifExportFailed(let detail):
            return "GIF 生成失败：\(detail)"
        }
    }

    /// 失败时已录内容是否值得保留。
    ///
    /// 契约（`model.md` §5）：`failed` 状态也可能产出可用文件，
    /// 由 UI 决定是否保留。此处给出统一的判断依据，避免各处自行猜测。
    ///
    /// **调用方不得绕开它**：本判据曾经零引用，于是「磁盘上其实躺着一个
    /// 可用文件」这件事只有日志知道，而日志不是给用户看的。
    public var shouldKeepPartialOutput: Bool {
        switch self {
        case .streamFailed, .writerFailed, .gifExportFailed:
            return true
        case .permissionDenied, .microphonePermissionDenied, .scopeUnavailable,
             .alreadyRunning, .timedOut, .cancelled, .unsupportedConfiguration:
            return false
        }
    }
}
