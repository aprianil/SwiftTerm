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
            text += "\u{1b}[1mbold\u{1b}[22m \u{1b}[31mred\u{1b}[39m "
            // Every other row carries an OSC 8 hyperlink and NO bare url. The
            // two take different paths through `shouldUnderlineLink`, and the
            // payload one is the only highlight that depends on the modifier
            // without depending on anything the row itself carries: a row with
            // a bare url has the scan's ranges in its key and moves on its own.
            if i.isMultiple(of: 2) {
                text += "\u{1b}]8;;https://example.com/osc/\(i)\u{1b}\\link\u{1b}]8;;\u{1b}\\ "
            } else {
                text += "https://example.com/a/b/\(i) "
            }
            text += "\u{1b}[38;5;12mbright\u{1b}[39m ▛▀▄ ──────\r\n"
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

        // The modifier decides how a link is drawn in exactly two modes, and
        // the cache is keyed on it only there. Both directions, because
        // pressing it and letting it go are two different stale rows.
        view.linkHighlightMode = .alwaysWithModifier
        assertCacheIsInvisible(view, "the modifier gate, key up")
        view.commandActive = true
        assertCacheIsInvisible(view, "the modifier gate, key down")
        view.commandActive = false
        assertCacheIsInvisible(view, "the modifier gate, released again")
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

    /// The view-wide settings whose setters only ask for a repaint: they
    /// change what every row looks like without touching a single line, so
    /// nothing about a line can tell the cache they moved.
    func testAViewWideSettingRebuildsEveryRow () {
        let view = makeView()
        view.linkHighlightMode = .always
        fill(view)
        _ = pixels(of: view)
        view.urlColor = NSColor(red: 1, green: 0, blue: 1, alpha: 1)
        assertCacheIsInvisible(view, "a new link colour")

        view.selection.setSelection(start: Position(col: 0, row: view.getTerminal().buffer.yDisp),
                                    end: Position(col: 30, row: view.getTerminal().buffer.yDisp + 4))
        _ = pixels(of: view)
        view.selectedTextBackgroundColor = NSColor(red: 1, green: 0.5, blue: 0, alpha: 1)
        assertCacheIsInvisible(view, "a new selection background")
        view.selectedTextForegroundColor = NSColor(red: 0, green: 0, blue: 1, alpha: 1)
        assertCacheIsInvisible(view, "a new selection foreground")

        view.selection.selectNone()
        _ = pixels(of: view)
        view.customBlockGlyphs = !view.customBlockGlyphs
        assertCacheIsInvisible(view, "block glyphs drawn the other way")
        view.useBrightColors = !view.useBrightColors
        assertCacheIsInvisible(view, "bright colours turned off")
    }

    func testTheSecondDrawOfAnUnchangedScreenBuildsNothing () {
        let view = makeView()
        fill(view)
        _ = pixels(of: view)
        let before = view.rowRenderCacheStats
        _ = pixels(of: view)
        let after = view.rowRenderCacheStats
        XCTAssertEqual(after.rebuilt - before.rebuilt, 0, "an unchanged screen rebuilt rows")
        XCTAssertGreaterThan(after.reused - before.reused, 0, "nothing was reused")
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

    /// A full-screen program's scroll, the way claude's agent view does it:
    /// the alternate screen, every row rewritten in place, its words one
    /// row further on. `first` is the first numbered row on the screen.
    private func paintScreen (_ view: TerminalView, from first: Int, colour: Int = 31) {
        let rows = view.getTerminal().rows
        var text = "\u{1b}[?1049h\u{1b}[?2026h"
        for row in 0..<rows {
            let n = first + row
            text += "\u{1b}[\(row + 1);1H\u{1b}[2K\u{1b}[38;2;153;153;153m│\u{1b}[39m line \(n) "
            text += "\u{1b}[1mbold\u{1b}[22m \u{1b}[\(colour)mword\u{1b}[39m ▛▀▄ ──"
        }
        text += "\u{1b}[?2026l"
        view.feed(byteArray: ArraySlice(Array(text.utf8)))
    }

    func testARepaintedScrollReusesTheRowsByWhatTheyShow () {
        let view = makeView()
        paintScreen(view, from: 1)
        _ = pixels(of: view)
        let before = view.rowRenderCacheStats
        paintScreen(view, from: 4)
        assertCacheIsInvisible(view, "a screen repainted three rows on")
        let after = view.rowRenderCacheStats
        // The draw in the assertion that reads the cache: three new rows,
        // every other row seen a frame ago on another row.
        XCTAssertLessThanOrEqual(after.rebuilt - before.rebuilt, 3,
                                 "a repainted scroll rebuilt rows it had already built")
    }

    func testTheSameWordsInAnotherColourAreBuiltAgain () {
        let view = makeView()
        paintScreen(view, from: 1)
        _ = pixels(of: view)
        paintScreen(view, from: 2, colour: 32)
        assertCacheIsInvisible(view, "the same words in green")
    }

    func testARepaintedScrollUnderASelectionDrawsTheSame () {
        let view = makeView()
        paintScreen(view, from: 1)
        _ = pixels(of: view)
        view.selectAll()
        paintScreen(view, from: 3)
        assertCacheIsInvisible(view, "a selection over a repainted scroll")
    }

    func testTheContentCacheStaysBounded () {
        let view = makeView()
        for first in stride(from: 1, to: 2000, by: 24) {
            paintScreen(view, from: first)
            _ = pixels(of: view)
        }
        XCTAssertLessThanOrEqual(view.rowRenderContentCount, max(256, 4 * view.getTerminal().rows),
                                 "the content cache grew past its bound")
    }
}
#endif
