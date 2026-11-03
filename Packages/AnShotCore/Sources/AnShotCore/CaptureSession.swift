//
//  CaptureSession.swift
//  AnShotCore
//
//  会话与编辑历史的契约实现。
//
//  契约见 docs/m1-capture/model.md §5（会话）、§6（编辑历史）、§8（不变量）。
//

import CoreGraphics
import Foundation

/// 底图元信息（model.md §5.2）。
///
/// 图像本身不序列化（`imageRef` 在 M1 恒为 `nil`），
/// 只保存重建与校验所需的信息。
public struct Backdrop: Codable, Equatable, Sendable {
    /// 像素宽度，必须 > 0。
    public var pixelWidth: Int

    /// 像素高度，必须 > 0。
    public var pixelHeight: Int

    /// 逻辑点→像素的比例，通常 1.0 / 2.0。
    public var scaleFactor: Double

    /// 来源显示器。
    public var displayId: UInt32?

    /// 图像引用，M1 恒为 `nil`。
    public var imageRef: String?

    public init(
        pixelWidth: Int,
        pixelHeight: Int,
        scaleFactor: Double,
        displayId: UInt32? = nil,
        imageRef: String? = nil
    ) {
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.scaleFactor = scaleFactor
        self.displayId = displayId
        self.imageRef = imageRef
    }

    /// 以像素为单位的完整范围。
    public var pixelBounds: PixelRect {
        PixelRect(
            origin: PixelPoint(x: 0, y: 0),
            size: PixelSize(width: Double(pixelWidth), height: Double(pixelHeight))
        )
    }
}

/// 一次截图会话的完整可序列化状态（model.md §5.1）。
public struct CaptureSession: Codable, Equatable, Sendable {
    /// 当前契约版本。
    ///
    /// - 版本 2：新增 `mosaicStroke`（涂抹马赛克）。
    /// - 版本 3：M3-0 新增 `numbering` / `highlight` / `measure` / `magnifier` /
    ///   `freehand` / `curvedArrow` 六种标注，`StrokeStyle` 增加 `isSketchy`。
    ///
    /// 新增枚举 case 并不保证源码兼容：读文件的一方必须能跳过未知类型，
    /// 详见 model.md §10 的兼容策略。`StrokeStyle.isSketchy` 走
    /// `decodeIfPresent` 兜底，因此 v1/v2 文件仍能正常读取。
    public static let currentSchemaVersion = 3

    public var schemaVersion: Int
    public var id: UUID
    public var createdAt: String
    public var backdrop: Backdrop
    public var selection: PixelRect
    public var annotations: [Annotation]

    /// 解码时因未知类型被跳过的标注条数。不参与序列化。
    public var skippedAnnotationCount: Int = 0

    public init(
        id: UUID = UUID(),
        createdAt: String = CaptureSession.timestamp(),
        backdrop: Backdrop,
        selection: PixelRect,
        annotations: [Annotation] = []
    ) {
        schemaVersion = CaptureSession.currentSchemaVersion
        self.id = id
        self.createdAt = createdAt
        self.backdrop = backdrop
        self.selection = selection
        self.annotations = annotations
        skippedAnnotationCount = 0
    }

    /// 当前 UTC 时间的 ISO-8601 表示。
    public static func timestamp(for date: Date = Date()) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case id
        case createdAt
        case backdrop
        case selection
        case annotations
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        id = try container.decode(UUID.self, forKey: .id)
        createdAt = try container.decode(String.self, forKey: .createdAt)
        backdrop = try container.decode(Backdrop.self, forKey: .backdrop)
        selection = try container.decode(PixelRect.self, forKey: .selection)

        // 用 AnnotationList 解码以获得「跳过未知类型」的兼容行为。
        let list = try container.decode(AnnotationList.self, forKey: .annotations)
        annotations = list.annotations
        skippedAnnotationCount = list.skippedCount
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(id, forKey: .id)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(backdrop, forKey: .backdrop)
        try container.encode(selection, forKey: .selection)
        try container.encode(annotations, forKey: .annotations)
    }
}

// MARK: - 不变量校验

/// 违反 model.md §8 不变量的情形。
public enum SessionInvariantError: Error, LocalizedError, Equatable {
    case backdropSizeInvalid(width: Int, height: Int)
    case scaleFactorInvalid(Double)
    case selectionEmpty
    case selectionOutOfBounds(PixelRect)
    case annotationOutOfBounds(id: UUID, rect: PixelRect)
    case duplicateAnnotationID(UUID)
    case unsupportedMosaicMode(MosaicMode)

    public var errorDescription: String? {
        switch self {
        case let .backdropSizeInvalid(width, height):
            return "底图尺寸非法：\(width)x\(height)"
        case let .scaleFactorInvalid(value):
            return "缩放系数非法：\(value)"
        case .selectionEmpty:
            return "选区面积必须大于 0"
        case let .selectionOutOfBounds(rect):
            return "选区超出底图范围：\(rect)"
        case let .annotationOutOfBounds(id, rect):
            return "标注 \(id) 超出底图范围：\(rect)"
        case let .duplicateAnnotationID(id):
            return "标注 ID 重复：\(id)"
        case let .unsupportedMosaicMode(mode):
            return "当前版本不支持的马赛克模式：\(mode.rawValue)"
        }
    }
}

extension CaptureSession {
    /// 校验会话是否满足全部不变量。
    ///
    /// 解码得到的会话**不会**在解码时自动校验（宽容读取），
    /// 由调用方在渲染前调用此方法，以避免一个损坏字段导致整个文件不可读。
    public func validate() throws {
        guard backdrop.pixelWidth > 0, backdrop.pixelHeight > 0 else {
            throw SessionInvariantError.backdropSizeInvalid(
                width: backdrop.pixelWidth,
                height: backdrop.pixelHeight
            )
        }
        guard backdrop.scaleFactor > 0 else {
            throw SessionInvariantError.scaleFactorInvalid(backdrop.scaleFactor)
        }
        guard selection.isNonEmpty else {
            throw SessionInvariantError.selectionEmpty
        }

        let bounds = backdrop.pixelBounds
        guard contains(bounds, selection) else {
            throw SessionInvariantError.selectionOutOfBounds(selection)
        }

        var seenIDs = Set<UUID>()
        for annotation in annotations {
            guard seenIDs.insert(annotation.id).inserted else {
                throw SessionInvariantError.duplicateAnnotationID(annotation.id)
            }

            let rect = annotation.boundingRect
            // 文字标注的包围盒是零尺寸（排版前无法得知宽高），跳过范围检查。
            if rect.isNonEmpty, !contains(bounds, rect) {
                throw SessionInvariantError.annotationOutOfBounds(id: annotation.id, rect: rect)
            }

            // 两种马赛克共用同一套像素化判定，模式校验也要覆盖到涂抹。
            switch annotation.kind {
            case let .mosaic(_, mode, _), let .mosaicStroke(_, _, mode, _):
                if !mode.isRenderable {
                    throw SessionInvariantError.unsupportedMosaicMode(mode)
                }
            default:
                break
            }
        }
    }

    /// `inner` 是否完全落在 `outer` 内（含容差，吸收浮点误差）。
    private func contains(_ outer: PixelRect, _ inner: PixelRect) -> Bool {
        let tolerance = 0.5
        return inner.origin.x >= outer.origin.x - tolerance
            && inner.origin.y >= outer.origin.y - tolerance
            && inner.origin.x + inner.size.width <= outer.origin.x + outer.size.width + tolerance
            && inner.origin.y + inner.size.height <= outer.origin.y + outer.size.height + tolerance
    }
}

// MARK: - 编辑状态与历史

/// 一次编辑的完整状态快照（model.md §6.1）。
public struct EditState: Equatable, Sendable {
    public var selection: PixelRect
    public var annotations: [Annotation]

    public init(selection: PixelRect, annotations: [Annotation] = []) {
        self.selection = selection
        self.annotations = annotations
    }
}

/// 基于值快照的撤销/重做栈（model.md §6）。
///
/// 保存的是 `EditState` 值快照而**不是位图**，也因此不需要命令模式：
/// 快照用更少的代码获得相同效果，且不会出现「撤销逻辑本身有 bug」的缺陷。
///
/// 量级参考：100 个标注约 10 KB，50 步历史约 500 KB。
public struct EditHistory: Equatable, Sendable {
    /// 默认保留的状态数上限。
    ///
    /// 超出后丢弃最旧状态：截图会话不会产生大量编辑，
    /// 上限只用于兜住极端操作（例如长按删除键）导致的内存增长。
    public static let defaultCapacity = 100

    private let capacity: Int

    /// 状态序列，索引 0 为会话起始状态。
    public private(set) var states: [EditState]

    /// 当前所处状态在 `states` 中的索引。
    public private(set) var cursor: Int

    /// 以初始状态建立历史。
    public init(initial: EditState, capacity: Int = EditHistory.defaultCapacity) {
        self.capacity = max(1, capacity)
        states = [initial]
        cursor = 0
    }

    /// 当前状态。
    public var current: EditState {
        states[cursor]
    }

    /// 是否可以撤销。
    public var canUndo: Bool {
        cursor > 0
    }

    /// 是否可以重做。
    public var canRedo: Bool {
        cursor < states.count - 1
    }

    /// 已提交（含撤销后仍保留）的状态数。
    public var count: Int {
        states.count
    }

    /// 提交一次编辑。
    ///
    /// 丢弃 `cursor` 之后的状态（重做分支），追加新状态并把游标移到末尾。
    /// 与当前状态相同的提交会被忽略，避免产生「撤销一次却没有变化」的空步。
    public mutating func commit(_ state: EditState) {
        guard state != current else {
            return
        }

        if cursor < states.count - 1 {
            states.removeSubrange((cursor + 1) ..< states.count)
        }

        states.append(state)
        cursor = states.count - 1

        // 超出上限时从头部丢弃，游标同步前移。
        if states.count > capacity {
            let overflow = states.count - capacity
            states.removeFirst(overflow)
            cursor -= overflow
        }
    }

    /// 撤销一步，返回新的当前状态；不可撤销时返回 `nil`。
    @discardableResult
    public mutating func undo() -> EditState? {
        guard canUndo else {
            return nil
        }
        cursor -= 1
        return current
    }

    /// 重做一步，返回新的当前状态；不可重做时返回 `nil`。
    @discardableResult
    public mutating func redo() -> EditState? {
        guard canRedo else {
            return nil
        }
        cursor += 1
        return current
    }
}
