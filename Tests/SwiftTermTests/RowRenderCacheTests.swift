//
//  RowRenderCacheTests.swift
//
//  The per-row render cache has one job and one requirement: it must be
//  invisible. Every test here draws a screen twice with the cache and once
//  without it, and demands the same pixels, so a stale row shows up as a
//  failure rather than as a smear on someone's terminal.
//
#if os(macOS)
import AppKit
import XCTest
@testable import SwiftTerm

final class RowRenderCacheTests: XCTestCase {
    private func makeView (rows: Int = 24, cols: Int = 48) -> TerminalView {
        _ = NSApplication.shared
        var options = TerminalOptions.default
        options.cols = cols
        options.rows = rows
        options.scrollback = 500
        let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        let view = TerminalView(frame: NSRect(x: 0, y: 0, width: 690, height: 300),
                                font: font, options: options)
        view.getTerminal().resize(cols: cols, rows: rows)
        view.frame = view.getOptimalFrameSize()
        return view
    }

    private func fill (_ view: TerminalView, lines: Int = 200) {
        var text = ""
        for i in 1...lines {
            text += "\u{1b}[38;2;153;153;153m│\u{1b}[39m row \(i) "
            text += "\u{1b}[1mbold\u{1b}[22m \u{1b}[31mred\u{1b}[39m https://example.com/a/b/\(i) "
            text += "──────\r\n"
        }
        view.feed(byteArray: ArraySlice(Array(text.utf8)))
    }

    private func pixels (of view: TerminalView) -> Data {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            return Data()
        }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let bytes = rep.bitmapData else { return Data() }
        return Data(bytes: bytes, count: rep.bytesPerRow * rep.pixelsHigh)
    }

    /// Draws `view` from the cache and without it, and demands they match.
    private func assertCacheIsInvisible (_ view: TerminalView, _ what: String,
                                         file: StaticString = #filePath, line: UInt = #line)
    {
        rowRenderCacheEnabled = true
        _ = pixels(of: view)                 // fills the cache
        let fromCache = pixels(of: view)     // and this draw reads it
        rowRenderCacheEnabled = false
        let built = pixels(of: view)
        rowRenderCacheEnabled = true
        XCTAssertFalse(fromCache.isEmpty, "\(what): nothing was drawn", file: file, line: line)
        XCTAssertEqual(fromCache, built, "\(what): the cached draw differs", file: file, line: line)
    }

    override func tearDown () {
        rowRenderCacheEnabled = true
        super.tearDown()
    }

    func testAnUnchangedScreenDrawsTheSame () {
        let view = makeView()
        fill(view)
        assertCacheIsInvisible(view, "an unchanged screen")
    }

    func testARowThatChangedIsRebuilt () {
        let view = makeView()
        fill(view)
        _ = pixels(of: view)
        view.feed(byteArray: ArraySlice(Array("\u{1b}[31mchanged\u{1b}[39m".utf8)))
        assertCacheIsInvisible(view, "a row that changed")
    }

    func testAScrolledScreenDrawsTheSame () {
        let view = makeView()
        fill(view)
        _ = pixels(of: view)
        view.scrollTo(row: view.getTerminal().buffer.yDisp - 3)
        assertCacheIsInvisible(view, "a screen scrolled by three rows")
    }

    func testASelectionIsNotMissedAndNotStranded () {
        let view = makeView()
        fill(view)
        let top = view.getTerminal().buffer.yDisp
        _ = pixels(of: view)
        view.selection.setSelection(start: Position(col: 2, row: top + 3),
                                    end: Position(col: 20, row: top + 5))
        assertCacheIsInvisible(view, "a fresh selection")
        view.selection.shiftExtend(row: top + 9, col: 30)
        assertCacheIsInvisible(view, "an extended selection")
        view.selection.selectNone()
        assertCacheIsInvisible(view, "a cleared selection")
    }

    func testALinkHighlightIsNotMissed () {
        let view = makeView()
        view.linkHighlightMode = .always
        fill(view)
        assertCacheIsInvisible(view, "urls underlined at rest")
        view.linkHighlightMode = .hover
        assertCacheIsInvisible(view, "urls no longer underlined")
    }

    func testAColorChangeRebuildsEveryRow () {
        let view = makeView()
        fill(view)
        _ = pixels(of: view)
        view.installColors(Color.vgaColors)
        assertCacheIsInvisible(view, "a new palette")
    }

    func testAFontChangeRebuildsEveryRow () {
        let view = makeView()
        fill(view)
        _ = pixels(of: view)
        view.font = NSFont.monospacedSystemFont(ofSize: 15, weight: .regular)
        assertCacheIsInvisible(view, "a bigger font")
    }

    func testABlinkPhaseRebuildsEveryRow () {
        let view = makeView()
        view.feed(text: "\u{1b}[5mblinking text on the first row\u{1b}[25m\r\n")
        _ = pixels(of: view)
        view.setTextBlinkVisibleForTesting(false)
        assertCacheIsInvisible(view, "the hidden half of a blink")
        view.setTextBlinkVisibleForTesting(true)
        assertCacheIsInvisible(view, "the visible half of a blink")
    }

    func testTheSecondDrawOfAnUnchangedScreenBuildsNothing () {
        let view = makeView()
        fill(view)
        _ = pixels(of: view)
        view.rowRenderCacheHits = 0
        view.rowRenderCacheMisses = 0
        _ = pixels(of: view)
        XCTAssertEqual(view.rowRenderCacheMisses, 0, "an unchanged screen rebuilt rows")
        XCTAssertGreaterThan(view.rowRenderCacheHits, 0, "nothing was reused")
    }

    func testTheCacheStaysTheSizeOfTheScreen () {
        let view = makeView()
        fill(view)
        for _ in 0..<40 {
            view.feed(byteArray: ArraySlice(Array("one more line\r\n".utf8)))
            _ = pixels(of: view)
        }
        XCTAssertLessThanOrEqual(view.rowRenderCache.count, view.getTerminal().rows + 2,
                                 "the cache grew past the visible rows")
    }
}
#endif
