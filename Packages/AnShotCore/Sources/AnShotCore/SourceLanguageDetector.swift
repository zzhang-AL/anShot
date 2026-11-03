//
//  SourceLanguageDetector.swift
//  AnShotCore
//
//  源语言检测。
//
//  ── 为什么它不从属于 TextTranslator ──────────────────────────
//
//  检测用的是 `NLLanguageRecognizer`：本机、离线、无系统版本门槛。
//  而 `TextTranslator` 整体标了 macOS 26.0——把检测放在那里面，会让
//  「系统版本不够」这个**恰恰最需要云端翻译方案**的场景，连带失去源语言提示。
//
//  云端 provider 把检测结果当提示用（拿不到也能自己判断），所以这项能力
//  必须能在低版本系统上正常工作。
//

import Foundation
import NaturalLanguage

/// 从文本判定源语言。
public enum SourceLanguageDetector {

    /// 从识别出的行里判定主要语言。
    ///
    /// 输入是 OCR **已经识别出来的文本**，不重新理解一次图像，
    /// 因此不会产生两套互相矛盾的判断。
    ///
    /// - Parameter lines: OCR 行。
    /// - Returns: BCP-47 标识（如 `zh-Hans`、`en`）；判断不出时返回 `nil`。
    public static func detect(in lines: [OCRTextLine]) -> String? {
        let text = lines.map(\.text).joined(separator: "\n")
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        return recognizer.dominantLanguage?.rawValue
    }
}
