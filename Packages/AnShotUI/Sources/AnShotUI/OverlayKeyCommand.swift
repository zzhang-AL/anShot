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
    /// ⌘P：把当前截图钉在屏幕上。
    case pin
    /// ⌘A：全选当前屏幕并确认选区。
    case selectFullScreen
    /// ⌘D：复制当前选中的标注。
    case duplicate
    /// 方向键微调位置（1px；按住 Shift 为 10px）。
    case nudge(dx: Int, dy: Int)
    /// ⌥ + 方向键微调选区宽高（1px；按住 Shift 为 5px）。
    case resizeSelection(dw: Int, dh: Int)
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

        if flags.contains(.command), !flags.contains(.control), !flags.contains(.option) {
            switch characters {
            case "a" where !flags.contains(.shift): return .selectFullScreen
            case "s": return .save
            case "c": return .copy
            case "p": return .pin
            case "d": return .duplicate
            // ⌘Z 撤销、⇧⌘Z 重做
            case "z": return flags.contains(.shift) ? .redo : .undo
            default: break
            }
        }

        // 36 = 主键盘回车，76 = 小键盘回车
        if event.keyCode == 36 || event.keyCode == 76 {
            return .copy
        }

        // ⌥ + 方向键微调选区宽高（不含 ⌘/⌃；配 Shift 步长为 5）。
        if flags.contains(.option), !flags.contains(.command), !flags.contains(.control) {
            let step = flags.contains(.shift) ? 5 : 1
            switch event.keyCode {
            case 123: return .resizeSelection(dw: -step, dh: 0)
            case 124: return .resizeSelection(dw: step, dh: 0)
            case 125: return .resizeSelection(dw: 0, dh: step)
            case 126: return .resizeSelection(dw: 0, dh: -step)
            default: break
            }
        }

        let hasCommandLike = flags.contains(.command)
            || flags.contains(.control)
            || flags.contains(.option)

        // 方向键微调（仅在不按 ⌘/⌃/⌥ 时生效；Shift 放大步长为 10）。
        if !hasCommandLike {
            let step = flags.contains(.shift) ? 10 : 1
            switch event.keyCode {
            case 123: return .nudge(dx: -step, dy: 0)
            case 124: return .nudge(dx: step, dy: 0)
            case 125: return .nudge(dx: 0, dy: step)
            case 126: return .nudge(dx: 0, dy: -step)
            default: break
            }
        }

        // 工具快捷键：只在没有 ⌘/⌃/⌥ 时生效，
        // 以免抢占系统快捷键与已注册的全局热键（⌃1）。
        if !hasCommandLike,
           let character = characters?.first,
           let tool = AnnotationTool.allCases.first(where: { $0.keyCharacter == character }) {
            return .selectTool(tool)
        }

        return nil
    }
}
