//
//  DisplayCatalog.swift
//  AnShotAutomation
//
//  显示器的枚举与描述。这是外部调用方「先看有哪些屏幕，再决定截哪块」的入口。
//
//  单位约定（与 `AnShotCapture` 保持一致，不另立一套）：
//      - `logicalSize` / `bounds` 是**逻辑点**
//      - `pixelSize` 是**物理像素**
//      - `region` 类参数一律解释为「显示器内逻辑点，原点在该显示器左上角」
//
//  为什么必须把 units 显式写进返回结构：调用方是 AI，
//  它拿不到本项目的坐标系注释，只能靠返回值自描述。少一个字段
//  就会让它把像素值当逻辑点用，而这类错误的表现是「截出来偏了」，
//  排查成本远高于多返回两个字段。
//

import AnShotCapture
import CoreGraphics
import Foundation

/// 单块显示器的可序列化描述。
public struct DisplayInfo: Codable, Sendable, Equatable {

    /// `CGDirectDisplayID`。后续截图请求用它指定目标。
    public let id: UInt32

    /// 是否为主显示器（系统菜单栏所在那块）。
    public let isMain: Bool

    /// 逻辑点尺寸。
    public let logicalSize: Size

    /// 物理像素尺寸。逻辑尺寸 × `scaleFactor` 即此值。
    public let pixelSize: Size

    /// 缩放系数（Retina 通常为 2.0）。
    public let scaleFactor: Double

    /// 在全局显示坐标系中的位置与尺寸（逻辑点，原点为主屏左上角）。
    ///
    /// 之所以暴露它：多屏时调用方需要靠它判断某块屏在主屏的左边还是右边，
    /// 否则只能猜。
    public let bounds: Rect

    /// 可序列化的尺寸。不用 `CGSize` 直接编码的原因见 `Size` 的文档。
    public struct Size: Codable, Sendable, Equatable {
        public let width: Double
        public let height: Double
    }

    /// 可序列化的矩形。
    public struct Rect: Codable, Sendable, Equatable {
        public let x: Double
        public let y: Double
        public let width: Double
        public let height: Double
    }
}

/// 显示器目录。
public enum DisplayCatalog {

    /// 枚举当前活跃的显示器。
    ///
    /// 主显示器排在最前，便于调用方「不指定就用第一个」时拿到符合直觉的结果。
    public static func all() -> [DisplayInfo] {
        let mainID = DisplayGeometry.mainDisplay()
        return DisplayGeometry.activeDisplays()
            .map { describe($0, mainID: mainID) }
            .sorted { lhs, rhs in
                // 主屏优先，其余保持系统的枚举顺序
                if lhs.isMain != rhs.isMain { return lhs.isMain }
                return false
            }
    }

    /// 描述单块显示器。
    ///
    /// 不使用 `CGSize` / `CGRect` 直接编码：它们的 `Codable` 表示
    /// 是一组 `{"width":…,"height":…}` 的嵌套对象，字段名不如自定义类型明确，
    /// 且将来若换坐标系也不必改序列化契约。
    public static func describe(
        _ displayID: CGDirectDisplayID,
        mainID: CGDirectDisplayID
    ) -> DisplayInfo {
        let bounds = DisplayGeometry.bounds(for: displayID)
        let pixelSize = DisplayGeometry.pixelSize(for: displayID)

        return DisplayInfo(
            id: displayID,
            isMain: displayID == mainID,
            logicalSize: DisplayInfo.Size(
                width: bounds.width,
                height: bounds.height
            ),
            pixelSize: DisplayInfo.Size(
                width: pixelSize.width,
                height: pixelSize.height
            ),
            scaleFactor: DisplayGeometry.scaleFactor(for: displayID),
            bounds: DisplayInfo.Rect(
                x: bounds.origin.x,
                y: bounds.origin.y,
                width: bounds.width,
                height: bounds.height
            )
        )
    }

    /// 判断某显示器 ID 当前是否存在。
    public static func exists(_ displayID: CGDirectDisplayID) -> Bool {
        DisplayGeometry.activeDisplays().contains(displayID)
    }
}
