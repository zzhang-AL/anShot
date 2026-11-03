//
//  OutputPathTests.swift
//  AnShotCoreTests
//
//  产物路径唯一化的契约测试。
//
//  重点不是「能拼出 -2」，而是三条容易被实现偷懒掉的规则：
//  不存在时原样返回、序号从 2 起、序号空间用尽时**绝不覆盖**。
//

import Foundation
import Testing

@testable import AnShotCore

@Suite("OutputPath 产物路径唯一化")
struct OutputPathTests {

    private let directory = URL(fileURLWithPath: "/tmp/anshot-tests", isDirectory: true)

    /// 用给定的「已占用集合」构造判据，不触碰真实文件系统。
    private func exists(_ occupied: Set<String>) -> (URL) -> Bool {
        { occupied.contains($0.path) }
    }

    @Test("未被占用时原样返回")
    func returnsBaseWhenFree() {
        let base = directory.appendingPathComponent("anShot-录制-20260913-120000.gif")
        #expect(OutputPath.unique(base: base, fileExists: exists([])) == base)
    }

    @Test("被占用时从 -2 起递增")
    func appendsSequenceStartingAtTwo() {
        let base = directory.appendingPathComponent("a.gif")
        let second = directory.appendingPathComponent("a-2.gif")
        let third = directory.appendingPathComponent("a-3.gif")

        #expect(OutputPath.unique(base: base, fileExists: exists([base.path])) == second)
        #expect(
            OutputPath.unique(base: base, fileExists: exists([base.path, second.path])) == third
        )
    }

    @Test("无扩展名的路径也能拼序号")
    func handlesPathWithoutExtension() {
        let base = directory.appendingPathComponent("anShot-录制")
        let expected = directory.appendingPathComponent("anShot-录制-2")
        #expect(OutputPath.unique(base: base, fileExists: exists([base.path])) == expected)
    }

    @Test("候选路径：0 为原路径，之后 -2、-3；无扩展名时不留结尾的点")
    func candidateNaming() {
        let base = directory.appendingPathComponent("截图 18-30-05.png")
        #expect(OutputPath.candidate(for: base, attempt: 0) == base)
        #expect(
            OutputPath.candidate(for: base, attempt: 1)
                == directory.appendingPathComponent("截图 18-30-05-2.png")
        )
        #expect(
            OutputPath.candidate(for: base, attempt: 2)
                == directory.appendingPathComponent("截图 18-30-05-3.png")
        )
        let bare = directory.appendingPathComponent("shot")
        #expect(OutputPath.candidate(for: bare, attempt: 1).lastPathComponent == "shot-2")
    }

    @Test("序号空间用尽时退化为唯一后缀而非覆盖")
    func fallsBackToUniqueSuffixWhenExhausted() {
        let base = directory.appendingPathComponent("a.gif")
        // 判据恒为真：模拟一个被占满的目录
        let result = OutputPath.unique(base: base, fileExists: { _ in true })

        #expect(result != base)
        #expect(result.pathExtension == "gif")
        #expect(result.lastPathComponent.hasPrefix("a-"))
    }

    @Test("GIF 的回退影片与 GIF 同目录同名、换成 mp4")
    func fallbackMovieKeepsLocationAndStem() {
        let gif = directory.appendingPathComponent("anShot-录制-20260913-120000.gif")
        let expected = directory.appendingPathComponent("anShot-录制-20260913-120000.mp4")
        #expect(OutputPath.fallbackMovie(forGIFAt: gif) == expected)
    }

    @Test("回退影片路径再经唯一化，不会覆盖同名的既有影片")
    func fallbackMovieIsUniqueAgain() {
        let gif = directory.appendingPathComponent("a.gif")
        let movie = directory.appendingPathComponent("a.mp4")
        let second = directory.appendingPathComponent("a-2.mp4")

        let resolved = OutputPath.unique(
            base: OutputPath.fallbackMovie(forGIFAt: gif),
            fileExists: exists([movie.path])
        )
        #expect(resolved == second)
    }
}
