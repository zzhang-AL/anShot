//
//  WindowFrameProbe.swift
//  AnShotCapture
//
//  读取某个窗口**当前**的屏幕矩形。
//
//  ── 为什么需要单独查询 ────────────────────────────────────
//
//  窗口录制录的是窗口本身：窗口一移动或缩放，录制区域就变了，屏幕上的范围框
//  必须跟着走，否则它指示的边界与成片不符。
//
//  三个看起来可用、实际都不行的信号：
//  * `SCWindow.frame` 是枚举那一刻的快照，录制期间不更新；
//  * `SCStreamFrameInfoContentRect` 文档原文是「size and location of content
//    **in surface**」——它给的是内容在帧缓冲内的位置，不是内容在屏幕上的位置；
//  * 别人的窗口没有 `NSWindow` 通知可订阅，辅助功能路线又要额外权限。
//
//  所以只能重新查询。查询本身很便宜：只查`.optionIncludingWindow` 这一个窗口，
//  不是枚举整屏窗口（后者实测约 8.5ms，跟随是周期性调用，不值得付）。
//

import CoreGraphics
import Foundation

/// 窗口实时几何查询。
public enum WindowFrameProbe {

    /// 指定窗口当前的矩形：**全局左上原点点坐标**（与 `SCWindow.frame` 同语义）。
    ///
    /// - Returns: 窗口已不存在或不在屏上时为 `nil`（调用方应保持上一次的显示，
    ///   而不是把范围框藏起来——录制仍在继续，框突然消失只会让人以为录崩了）。
    public static func frame(of windowID: CGWindowID) -> CGRect? {
        guard let list = CGWindowListCopyWindowInfo(
            [.optionIncludingWindow, .excludeDesktopElements],
            windowID
        ) as? [[String: Any]],
        let info = list.first,
        // 逐键取值而不是 `CGRect(dictionaryRepresentation:)`：后者要 CFDictionary，
        // 而从 `Any` 条件转换到 CF 类型会被编译器判为「总是成功」而报警。
        let bounds = info[kCGWindowBounds as String] as? [String: NSNumber],
        let x = bounds["X"]?.doubleValue,
        let y = bounds["Y"]?.doubleValue,
        let width = bounds["Width"]?.doubleValue,
        let height = bounds["Height"]?.doubleValue,
        width >= 1,
        height >= 1 else {
            return nil
        }
        return CGRect(x: x, y: y, width: width, height: height)
    }
}
