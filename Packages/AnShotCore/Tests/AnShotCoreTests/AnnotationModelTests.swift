//
//  AnnotationModelTests.swift
//  AnShotCoreTests
//
//  标注模型、会话契约与编辑历史的单元测试。
//

import CoreGraphics
import Foundation
import Testing

@testable import AnShotCore

// MARK: - 测试夹具

// `rect(_:_:_:_:)` 来自 TestSupport.swift。
private let redStroke = StrokeStyle(color: RGBAColor(r: 1, g: 0, b: 0, a: 1), width: 4)
private let blueFill = RGBAColor(r: 0, g: 0, b: 1, a: 0.5)

/// 每种标注各一条，用于覆盖编解码。
private let allKinds: [Annotation] = [
    Annotation(kind: .rectangle(rect: rect(10, 20, 30, 40), stroke: redStroke, fill: blueFill, cornerRadius: 6)),
    Annotation(kind: .line(
        start: PixelPoint(x: 1, y: 2),
        end: PixelPoint(x: 3, y: 4),
        stroke: redStroke
    )),
    Annotation(kind: .arrow(
        start: PixelPoint(x: 5, y: 6),
        end: PixelPoint(x: 7, y: 8),
        stroke: redStroke,
        headLength: 12,
        headWidth: 8
    )),
    Annotation(kind: .text(
        origin: PixelPoint(x: 9, y: 10),
        text: "中文",
        font: .system(size: 16, weight: 600, italic: true),
        color: redStroke.color,
        background: nil,
        maxWidth: 200
    )),
    Annotation(kind: .mosaic(rect: rect(0, 0, 50, 50), mode: .pixelate, intensity: 8)),
]

// MARK: - 标注编解码

@Suite("标注 JSON 契约")
struct AnnotationJSONTests {
    @Test("五种标注均可往返编解码")
    func roundTrip() throws {
        for annotation in allKinds {
            let data = try JSONEncoder().encode(annotation)
            let decoded = try JSONDecoder().decode(Annotation.self, from: data)
            #expect(decoded == annotation)
        }
    }

    @Test("JSON 为扁平结构，type 与其余字段同级")
    func flatStructure() throws {
        let data = try JSONEncoder().encode(allKinds[0])
        let object = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )

        #expect(object["type"] as? String == "rectangle")
        #expect(object["rect"] != nil)
        #expect(object["stroke"] != nil)
        #expect(object["cornerRadius"] != nil)
        // 不应出现以类型名包裹的嵌套对象（Swift 合成枚举编码的产物）。
        #expect(object["rectangle"] == nil)
    }

    @Test("每种标注的 type 字符串符合契约")
    func typeNames() throws {
        let expected = ["rectangle", "line", "arrow", "text", "mosaic"]
        for (annotation, name) in zip(allKinds, expected) {
            let data = try JSONEncoder().encode(annotation)
            let object = try #require(
                try JSONSerialization.jsonObject(with: data) as? [String: Any]
            )
            #expect(object["type"] as? String == name)
        }
    }

    @Test("可空字段写出 null 而不是被省略")
    func nullableFieldsArePresent() throws {
        // 取一条 fill 为 nil 的矩形。
        let annotation = Annotation(kind: .rectangle(
            rect: rect(0, 0, 10, 10),
            stroke: redStroke,
            fill: nil,
            cornerRadius: 0
        ))
        let data = try JSONEncoder().encode(annotation)
        let object = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )

        #expect(object.keys.contains("fill"))
        #expect(object["fill"] is NSNull)
    }

    @Test("文本标注的字体只存描述，不含字体对象")
    func fontIsDescriptor() throws {
        let data = try JSONEncoder().encode(allKinds[3])
        let object = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let font = try #require(object["font"] as? [String: Any])

        #expect(font["family"] as? String == ".AppleSystemUIFont")
        #expect(font["size"] as? Double == 16)
        #expect(font["weight"] as? Int == 600)
        #expect(font["italic"] as? Bool == true)
    }

    @Test("未知 type 抛出可识别的错误")
    func unknownTypeThrows() throws {
        let json = """
        {"id":"3F2504E0-4F89-11D3-9A0C-0305E82C3301","type":"sticker","x":1}
        """
        let data = Data(json.utf8)

        #expect(throws: AnnotationDecodingError.self) {
            try JSONDecoder().decode(Annotation.self, from: data)
        }
    }

    @Test("缺少 type 抛出 missingType")
    func missingTypeThrows() throws {
        let json = """
        {"id":"3F2504E0-4F89-11D3-9A0C-0305E82C3301"}
        """
        let data = Data(json.utf8)

        do {
            _ = try JSONDecoder().decode(Annotation.self, from: data)
            Issue.record("应当抛出 missingType")
        } catch let error as AnnotationDecodingError {
            #expect(error == .missingType)
        }
    }

    @Test("数组解码跳过未知类型并保留其余条目")
    func listSkipsUnknownTypes() throws {
        var annotations: [[String: Any]] = []

        // 两条已知类型。
        for annotation in [allKinds[0], allKinds[4]] {
            let data = try JSONEncoder().encode(annotation)
            let object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
            annotations.append(object)
        }

        // 夹一条未来版本的未知类型。
        annotations.insert(
            ["id": UUID().uuidString, "type": "highlighter", "rect": [:]],
            at: 1
        )

        let data = try JSONSerialization.data(withJSONObject: annotations)
        let list = try JSONDecoder().decode(AnnotationList.self, from: data)

        #expect(list.annotations.count == 2)
        #expect(list.skippedCount == 1)
        #expect(list.annotations[0] == allKinds[0])
        #expect(list.annotations[1] == allKinds[4])
    }
}

// MARK: - 编辑历史

@Suite("编辑历史")
struct EditHistoryTests {
    private func state(width: Double) -> EditState {
        EditState(selection: rect(0, 0, width, 100))
    }

    @Test("会话起始只有初始状态且不可撤销")
    func initialState() {
        let history = EditHistory(initial: state(width: 10))

        #expect(history.count == 1)
        #expect(history.canUndo == false)
        #expect(history.canRedo == false)
        #expect(history.current == state(width: 10))
    }

    @Test("提交后游标指向末尾")
    func commitAdvancesCursor() {
        var history = EditHistory(initial: state(width: 10))
        history.commit(state(width: 20))

        #expect(history.count == 2)
        #expect(history.canUndo)
        #expect(history.canRedo == false)
        #expect(history.current == state(width: 20))
    }

    @Test("撤销与重做在状态间移动")
    func undoRedo() {
        var history = EditHistory(initial: state(width: 10))
        history.commit(state(width: 20))
        history.commit(state(width: 30))

        #expect(history.undo() == state(width: 20))
        #expect(history.undo() == state(width: 10))
        #expect(history.undo() == nil)
        #expect(history.canUndo == false)

        #expect(history.redo() == state(width: 20))
        #expect(history.redo() == state(width: 30))
        #expect(history.redo() == nil)
    }

    @Test("撤销后提交会丢弃重做分支")
    func commitDiscardsRedoBranch() {
        var history = EditHistory(initial: state(width: 10))
        history.commit(state(width: 20))
        history.commit(state(width: 30))

        history.undo()
        history.commit(state(width: 40))

        #expect(history.count == 3)
        #expect(history.canRedo == false)
        #expect(history.current == state(width: 40))
        #expect(history.undo() == state(width: 20))
    }

    @Test("与当前状态相同的提交被忽略")
    func identicalCommitIsIgnored() {
        var history = EditHistory(initial: state(width: 10))
        history.commit(state(width: 10))

        #expect(history.count == 1)
        #expect(history.canUndo == false)
    }

    @Test("超出容量时丢弃最旧状态且游标仍然有效")
    func capacityTrimsOldest() {
        var history = EditHistory(initial: state(width: 0), capacity: 3)

        history.commit(state(width: 1))
        history.commit(state(width: 2))
        history.commit(state(width: 3))

        #expect(history.count == 3)
        #expect(history.current == state(width: 3))
        #expect(history.undo() == state(width: 2))
        #expect(history.undo() == state(width: 1))
        #expect(history.canUndo == false)
    }

    @Test("快照之间不共享引用")
    func snapshotsAreIndependent() {
        var history = EditHistory(initial: state(width: 10))
        var annotations = [allKinds[0]]
        history.commit(EditState(selection: rect(0, 0, 20, 100), annotations: annotations))

        // 修改用于提交的数组，已保存的快照不应受影响。
        annotations.append(allKinds[1])

        #expect(history.current.annotations.count == 1)
    }
}

// MARK: - 会话契约

@Suite("会话契约")
struct CaptureSessionTests {
    private func session(annotations: [Annotation] = []) -> CaptureSession {
        CaptureSession(
            id: UUID(uuidString: "9F3C1A20-7B44-4E1D-9A8C-2D5E6F7A8B90")!,
            createdAt: "2026-09-12T13:45:00Z",
            backdrop: Backdrop(pixelWidth: 2940, pixelHeight: 1912, scaleFactor: 2, displayId: 1),
            selection: rect(400, 300, 1200, 800),
            annotations: annotations
        )
    }

    @Test("会话往返编解码")
    func roundTrip() throws {
        let original = session(annotations: allKinds)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(CaptureSession.self, from: data)

        #expect(decoded == original)
        // 版本 2 起加入 mosaicStroke（涂抹马赛克）。
        #expect(decoded.schemaVersion == 3)
        #expect(decoded.backdrop.imageRef == nil)
    }

    @Test("契约要求的字段全部出现")
    func requiredFieldsPresent() throws {
        let data = try JSONEncoder().encode(session())
        let object = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )

        #expect(object["schemaVersion"] as? Int == 3)
        #expect(object["id"] != nil)
        #expect(object["createdAt"] as? String == "2026-09-12T13:45:00Z")
        #expect(object["selection"] != nil)
        #expect(object["annotations"] is [Any])
        #expect(object["backdrop"] != nil)
    }

    @Test("解码时跳过未知标注类型而不使整个会话失败")
    func decodeSkipsUnknownAnnotation() throws {
        let valid = try JSONEncoder().encode(session(annotations: [allKinds[0]]))
        var object = try #require(
            try JSONSerialization.jsonObject(with: valid) as? [String: Any]
        )
        var annotations = try #require(object["annotations"] as? [[String: Any]])
        annotations.append(["id": UUID().uuidString, "type": "futureTool"])
        object["annotations"] = annotations

        let data = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(CaptureSession.self, from: data)

        #expect(decoded.annotations.count == 1)
        #expect(decoded.skippedAnnotationCount == 1)
    }

    @Test("合法会话通过不变量校验")
    func validatePasses() throws {
        try session(annotations: allKinds).validate()
    }

    @Test("选区为空时校验失败")
    func validateRejectsEmptySelection() {
        var subject = session()
        subject.selection = rect(100, 100, 0, 0)

        #expect(throws: SessionInvariantError.selectionEmpty) {
            try subject.validate()
        }
    }

    @Test("选区越界时校验失败")
    func validateRejectsOutOfBoundsSelection() {
        var subject = session()
        subject.selection = rect(2800, 1800, 400, 400)

        #expect(throws: SessionInvariantError.self) {
            try subject.validate()
        }
    }

    @Test("标注越界时校验失败")
    func validateRejectsOutOfBoundsAnnotation() {
        let annotation = Annotation(kind: .rectangle(
            rect: rect(2900, 300, 200, 200),
            stroke: redStroke,
            fill: nil,
            cornerRadius: 0
        ))

        #expect(throws: SessionInvariantError.self) {
            try session(annotations: [annotation]).validate()
        }
    }

    @Test("标注 ID 重复时校验失败")
    func validateRejectsDuplicateAnnotationID() {
        let id = UUID()
        let first = Annotation(id: id, kind: .line(
            start: PixelPoint(x: 500, y: 400),
            end: PixelPoint(x: 600, y: 500),
            stroke: redStroke
        ))
        let second = Annotation(id: id, kind: .line(
            start: PixelPoint(x: 700, y: 400),
            end: PixelPoint(x: 800, y: 500),
            stroke: redStroke
        ))

        #expect(throws: SessionInvariantError.duplicateAnnotationID(id)) {
            try session(annotations: [first, second]).validate()
        }
    }

    @Test("预留的马赛克模式在校验时被拒绝")
    func validateRejectsUnsupportedMosaicMode() {
        let annotation = Annotation(kind: .mosaic(
            rect: rect(500, 400, 100, 100),
            mode: .blur,
            intensity: 8
        ))

        #expect(throws: SessionInvariantError.unsupportedMosaicMode(.blur)) {
            try session(annotations: [annotation]).validate()
        }
    }

    @Test("缩放系数非法时校验失败")
    func validateRejectsInvalidScaleFactor() {
        var subject = session()
        subject.backdrop.scaleFactor = 0

        #expect(throws: SessionInvariantError.scaleFactorInvalid(0)) {
            try subject.validate()
        }
    }
}

// MARK: - 基础类型

@Suite("模型基础类型")
struct ModelPrimitiveTests {
    @Test("RGBAColor 分量在契约范围内往返")
    func colorRoundTrip() throws {
        let color = RGBAColor(r: 0.25, g: 0.5, b: 0.75, a: 1)
        let data = try JSONEncoder().encode(color)
        let decoded = try JSONDecoder().decode(RGBAColor.self, from: data)

        #expect(decoded == color)
    }

    @Test("马赛克模式只在 pixelate 时可渲染")
    func mosaicRenderability() {
        #expect(MosaicMode.pixelate.isRenderable)
        #expect(MosaicMode.blur.isRenderable == false)
        #expect(MosaicMode.solid.isRenderable == false)
    }

    @Test("包围盒对线类标注取两点极值")
    func boundingRectForLine() {
        let annotation = Annotation(kind: .line(
            start: PixelPoint(x: 30, y: 10),
            end: PixelPoint(x: 10, y: 50),
            stroke: redStroke
        ))

        #expect(annotation.boundingRect == rect(10, 10, 20, 40))
    }
}
