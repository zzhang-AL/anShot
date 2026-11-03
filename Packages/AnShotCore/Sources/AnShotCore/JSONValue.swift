//
//  JSONValue.swift
//  AnShotCore
//
//  任意 JSON 值的通用中间表示。
//
//  存在的理由是容错解码的**游标推进问题**：
//  在 `UnkeyedDecodingContainer` 上直接 `try container.decode(T.self)` 时，
//  解码失败不会推进游标，于是「失败就跳过继续」的循环会变成死循环。
//  先解码成本类型可保证游标前进；只有遇到无法表示的 JSON 内容
//  （例如超出 `Double` 范围的数值）才会抛错，而那属于非法输入。
//
//  整数与浮点分开保存，以减少 Int ↔ Double 往返带来的意外
//  （例如把 `600` 写成 `600.0`，使 `FontDescriptor.weight` 这类整数字段解不回来）。
//  注意这并不构成「任意 JSON 数值都能无损往返」的保证。
//

import Foundation

/// 任意 JSON 值的通用表示。
///
/// 不承诺对任意数值无损往返：超出 `Double` 范围的数字会被拒绝。
public enum JSONValue: Codable, Equatable, Sendable {
    case object([String: JSONValue])
    case array([JSONValue])
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case null

    public init(from decoder: Decoder) throws {
        // 依次尝试各容器类型；键值容器与数组容器都能成功时以键值为准，
        // 因为「对象」是标注的唯一顶层形态。
        if let container = try? decoder.container(keyedBy: JSONKey.self) {
            var result: [String: JSONValue] = [:]
            for key in container.allKeys {
                result[key.stringValue] = try container.decode(JSONValue.self, forKey: key)
            }
            self = .object(result)
            return
        }

        if var container = try? decoder.unkeyedContainer() {
            var result: [JSONValue] = []
            while !container.isAtEnd {
                result.append(try container.decode(JSONValue.self))
            }
            self = .array(result)
            return
        }

        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "无法识别的 JSON 值"
                )
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case let .object(fields):
            var container = encoder.container(keyedBy: JSONKey.self)
            for (name, value) in fields {
                guard let key = JSONKey(stringValue: name) else {
                    continue
                }
                try container.encode(value, forKey: key)
            }

        case let .array(items):
            var container = encoder.unkeyedContainer()
            for item in items {
                try container.encode(item)
            }

        case let .string(value):
            var container = encoder.singleValueContainer()
            try container.encode(value)

        case let .int(value):
            var container = encoder.singleValueContainer()
            try container.encode(value)

        case let .double(value):
            var container = encoder.singleValueContainer()
            try container.encode(value)

        case let .bool(value):
            var container = encoder.singleValueContainer()
            try container.encode(value)

        case .null:
            var container = encoder.singleValueContainer()
            try container.encodeNil()
        }
    }

    /// 取对象字段。
    public subscript(field: String) -> JSONValue? {
        guard case let .object(fields) = self else {
            return nil
        }
        return fields[field]
    }

    /// 以字符串读取。
    public var stringValue: String? {
        guard case let .string(value) = self else {
            return nil
        }
        return value
    }

    /// 把本值重新编码后按目标类型解码。
    ///
    /// 用于「原始 JSON → 强类型模型」的二次解析：走到这一步时
    /// 容器游标已经安全前进，因此解析失败可以放心跳过。
    public func decode<T: Decodable>(as type: T.Type) throws -> T {
        let data = try JSONEncoder().encode(self)
        return try JSONDecoder().decode(T.self, from: data)
    }
}

/// 动态键，供 `JSONValue` 与任意字段名互操作。
private struct JSONKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }

    init?(stringValue: String) {
        self.stringValue = stringValue
    }

    init?(intValue: Int) {
        return nil
    }
}
