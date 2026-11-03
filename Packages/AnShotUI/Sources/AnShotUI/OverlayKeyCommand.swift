//
//  OverlayKeyCommand.swift
//  AnShotUI
//
//  覆盖层的按键语义：把一次按键解析成命令。
//
//  ── 为什么只解析、不执行 ──────────────────────────────────
//
//  执行要回调控制器、改编辑器状态，那是 `OverlayView` 的事；而「哪个键对应
//  哪个动作」是纯查表。分开之后这层可以在没有窗口、没有选区的情况下断言，
//  而它出错的症状恰恰是「按了没反应」——用户看不到任何报错，最难查的一类。
//
//  ── 阶段归属不在这里 ──────────────────────────────────────
//
//  选取目标、录制准备、文字编辑三个阶段会把键盘整个接管（见
//  `OverlayView.keyDown` 的前三段）：那些不是「命令」，而是「键盘属于谁」，
//  必须在解析之前决定，否则回车会在面板开着时把会话截掉。
//

import AnShotCore
import AppKit

/// 覆盖层的按键命令。
enum OverlayKeyCommand: Equatable {
    /// ESC：结束会话。
    case cancel
    /// ⌘S：保存。
    case save
    /// ⌘C 或回车：拷贝。
    ///
    /// 两者等价是刻意的：会话里「拷贝」就是收尾动作，回车是截图工具最通用的
    /// 收尾方式（「框完就能走」）。
    case copy
    case undo
    case redo
    /// 字母键：切换工具。
    case selectTool(AnnotationTool)

    /// 解析一次按键；不认识时返回 nil（调用方交给 `super.keyDown`）。
    static func parse(_ event: NSEvent) -> OverlayKeyCommand? {
        let characters = event.charactersIgnoringModifiers?.lowercased()
        let flags = event.modifierFlags

        // 53 = Escape。放在最前面：任何修饰键下它都表示「退出」。
        if event.keyCode == 53 {
            return .cancel
        }

        if flags.contains(.command) {
            switch characters {
            case "s": return .save
            case "c": return .copy
            // ⌘Z 撤销、⇧⌘Z 重做
            case "z": return flags.contains(.shift) ? .redo : .undo
            default: break
            }
        }

        // 36 = 主键盘回车，76 = 小键盘回车
        if event.keyCode == 36 || event.keyCode == 76 {
            return .copy
        }

        // 工具快捷键：只在没有 ⌘/⌃/⌥ 时生效，
        // 以免抢占系统快捷键与已注册的全局热键（⌃1）。
        let hasCommandLike = flags.contains(.command)
            || flags.contains(.control)
            || flags.contains(.option)
        if !hasCommandLike,
           let character = characters?.first,
           let tool = AnnotationTool.allCases.first(where: { $0.keyCharacter == character }) {
            return .selectTool(tool)
        }

        return nil
    }
}
