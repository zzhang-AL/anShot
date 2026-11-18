//
//  PinNotice.swift
//  AnShotUI
//
//  固定截图的非模态提示（「已达上限」「已隐藏全部固定截图」）。
//
//  ── 为什么不用 NSAlert ────────────────────────────────────
//
//  它出现的两个时刻都**不能被打断**：
//
//    1. 用户刚点「钉住」但被上限挡下——他要么继续标注，要么去关掉几张再回来；
//    2. 用户刚按下「隐藏全部」热键——他的下一个动作通常就是去看屏幕。
//
//  `runModal` 会把这两个流程都截成两段：一个模态框等着被点掉，
//  而屏幕上真正发生变化的东西在它后面。
//
//  所以这里只「说一句就走」：不接管焦点、不接受键盘、不挡鼠标，到点自己消失。
//

import AppKit

/// 固定截图非模态提示门面，内部统一收敛至支持多行与全屏空间的 `ToastPresenter`。
@MainActor
final class PinNotice {

    /// 提示停留时长。够读完多行中文说明，又不至于长久遮挡桌面内容。
    private static let duration: TimeInterval = 2.6

    /// 显示一条固定截图相关提示；重复调用将直接替换为最新文案。
    func show(_ text: String) {
        ToastPresenter.show(text, duration: Self.duration)
    }
}
