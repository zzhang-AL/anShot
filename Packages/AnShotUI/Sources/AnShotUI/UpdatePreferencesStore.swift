//
//  UpdatePreferencesStore.swift
//  AnShotUI
//
//  自动更新的用户偏好。
//
//  ── 为什么单独一个 store ─────────────────────────────────────
//
//  这三个值有三类读者：设置页「关于」的开关、自动检查的定时器、
//  更新窗口的「稍后」按钮。塞进任何一方都会让其余两方反向依赖它
//  （例如定时器依赖设置窗口的视图控制器毫无道理）。这里只做存取，
//  不做判断——「现在该不该检查」的规则放在 `shouldAutoCheck`，
//  因为它是这三个值的**唯一组合语义**，放在别处就会被复制成两份。
//
//  ── 为什么默认值要显式判空 ───────────────────────────────────
//
//  `UserDefaults.bool(forKey:)` 在键不存在时返回 `false`，与「用户关掉了」
//  无法区分。首启默认必须自动检查，因此这里用 `object(forKey:) == nil`
//  判断「从未设置过」，而不是读 bool 的默认值。
//

import Foundation

@MainActor
final class UpdatePreferencesStore {

    /// 全局实例。更新相关的偏好只有一个真实来源。
    static let shared = UpdatePreferencesStore()

    private enum Key {
        static let autoCheck = "update.autoCheck"
        static let lastCheckAt = "update.lastCheckAt"
        static let skippedVersion = "update.skippedVersion"
    }

    private let defaults: UserDefaults

    /// - Parameter defaults: 可注入以便测试；App 内始终用 `.standard`。
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// 是否允许自动检查更新。默认 true。
    var autoCheckUpdates: Bool {
        get {
            // 键不存在 = 从未选择过 = 默认开启。
            guard defaults.object(forKey: Key.autoCheck) != nil else { return true }
            return defaults.bool(forKey: Key.autoCheck)
        }
        set { defaults.set(newValue, forKey: Key.autoCheck) }
    }

    /// 上一次**成功**完成检查的时间。
    ///
    /// 失败时刻意不写：否则一次断网就会把下一次自动检查推迟 24 小时，
    /// 用户只能等明天。
    var lastCheckAt: Date? {
        get { defaults.object(forKey: Key.lastCheckAt) as? Date }
        set {
            if let newValue {
                defaults.set(newValue, forKey: Key.lastCheckAt)
            } else {
                defaults.removeObject(forKey: Key.lastCheckAt)
            }
        }
    }

    /// 用户点过「稍后」的版本（`AppVersion.description` 的规范写法）。
    ///
    /// 只影响**自动检查**的提示；手动检查仍然展示新版本。
    var skippedVersion: String? {
        get {
            let raw = defaults.string(forKey: Key.skippedVersion)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return (raw?.isEmpty == false) ? raw : nil
        }
        set {
            if let newValue, !newValue.isEmpty {
                defaults.set(newValue, forKey: Key.skippedVersion)
            } else {
                defaults.removeObject(forKey: Key.skippedVersion)
            }
        }
    }

    /// 现在是否应当自动检查。
    ///
    /// 只回答「满足节流条件吗」，不判断有没有新版本：
    /// 是否需要联网由调用方决定，这样定时器与首启检查可以共用同一规则。
    ///
    /// - Parameters:
    ///   - now: 当前时间（注入以便测试，不用假时钟）。
    ///   - interval: 最短间隔，App 内为 24 小时。
    func shouldAutoCheck(now: Date, interval: TimeInterval) -> Bool {
        guard autoCheckUpdates else { return false }
        guard let lastCheckAt else { return true }
        // 时间回拨（用户改了系统时间）时 lastCheckAt 可能在未来：
        // 此时按「还不到时间」处理，而不是立刻检查——宁可晚一点，
        // 也不要因为时钟异常反复请求 GitHub（未认证请求有速率限制）。
        return now.timeIntervalSince(lastCheckAt) >= interval
    }
}
