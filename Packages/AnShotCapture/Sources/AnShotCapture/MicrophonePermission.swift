//
//  MicrophonePermission.swift
//  AnShotCapture
//
//  麦克风权限。
//
//  ── 为何不照搬屏幕录制权限的推断模式 ──────────────────────────
//
//  屏幕录制权限只有 `CGPreflightScreenCaptureAccess()`，它无法区分「从未请求」
//  与「请求过但被拒」，因此 M1 才需要用 UserDefaults 记录请求历史来补足。
//
//  麦克风**有真实的授权状态 API**：`AVCaptureDevice.authorizationStatus(for: .audio)`
//  能直接给出 `.notDetermined` / `.denied` / `.restricted` / `.authorized` 四态，
//  无需任何推断，也不该引入第二套「记录历史」的状态机。
//

import AVFoundation
import Foundation

/// 麦克风权限。
public enum MicrophonePermission {

    /// 授权状态。直接映射系统给出的四态，不做二次推断。
    public enum Status: Sendable, Equatable {
        /// 尚未询问过用户。可触发系统弹窗。
        case notDetermined
        /// 已授权。
        case granted
        /// 用户明确拒绝。系统不会再弹窗，只能引导去系统设置。
        case denied
        /// 被家长控制等策略限制，用户无法自行授权。
        case restricted

        /// 是否可以开始采集。
        public var allowsCapture: Bool {
            self == .granted
        }
    }

    /// 当前授权状态。
    public static var status: Status {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .notDetermined: return .notDetermined
        case .authorized:    return .granted
        case .denied:        return .denied
        case .restricted:    return .restricted
        @unknown default:    return .denied
        }
    }

    /// 请求授权。仅在 `.notDetermined` 时会有系统弹窗。
    ///
    /// - Returns: 是否已获授权。
    @discardableResult
    public static func request() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    /// 系统设置中「麦克风」隐私面板的地址。
    public static var settingsURL: URL? {
        URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
    }
}
