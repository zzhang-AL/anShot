//
//  CaptureArtifact.swift
//  AnShotUI
//
//  一次截图产物的统一描述。
//
//  ── 为什么需要它 ──────────────────────────────────────────────
//  复制、保存、钉住、长截图原先各自直接收尾：复制后会话关闭、保存后写历史、
//  钉住后什么都不记、长截图只进剪贴板。于是「历史」只覆盖了四种交付方式里的
//  一种，用户复制或钉住过的图再也找不回来。
//
//  产物对象把「图是什么」与「这次怎么交付」分开：历史账本记前者，
//  toast 记后者。新增一种交付方式时不必再改历史写入逻辑。
//

import AnShotCore
import CoreGraphics
import Foundation

/// 本次交付走的是哪条通道。
enum CaptureDelivery: Sendable {
    case copied
    case saved
    case pinned
    case longShot
}

/// 一次截图/长截图的产物。
///
/// `image` 与 `fileURL` 至少有一个：
/// - 保存：`fileURL` 指向用户文件，`image` 仍带着，供缩略图与界面使用；
/// - 复制/钉住：只有 `image`，历史层会把它复制进缓存目录；
/// - 长截图：只有 `image`，由结果窗口继续决定保存/复制/钉住。
struct CaptureArtifact {
    let kind: HistoryEntryKind
    let source: HistorySource?
    let image: CGImage?
    let fileURL: URL?
    let delivery: CaptureDelivery

    init(
        kind: HistoryEntryKind,
        source: HistorySource?,
        image: CGImage?,
        fileURL: URL?,
        delivery: CaptureDelivery
    ) {
        self.kind = kind
        self.source = source
        self.image = image
        self.fileURL = fileURL
        self.delivery = delivery
    }
}
