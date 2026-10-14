//
//  SearchAllTests.swift
//
//  `searchAll` finds every literal, case-insensitive match that starts in
//  a range of buffer rows, keeps the newest when there are more than the
//  limit, never reads past the range's end, and places a match that
//  crosses a soft wrap on the row it starts on.
//
#if os(macOS)
import AppKit
import XCTest
@testable import SwiftTerm

final class SearchAllTests: XCTestCase {
    private func makeView (cols: Int = 20, rows: Int = 6, text: String) -> TerminalView {
        _ = NSApplication.shared
        var options = TerminalOptions.default
        options.cols = cols
        options.rows = rows
        options.scrollback = 500
        let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        let view = TerminalView(frame: NSRect(x: 0, y: 0, width: 400, height: 120),
                                font: font, options: options)
        view.getTerminal().resize(cols: cols, rows: rows)
        view.feed(byteArray: ArraySlice(Array(text.utf8)))
        return view
    }

    func testLiteralCaseInsensitiveTopToBottom () {
        let view = makeView(text: "a Seam here\r\nnone\r\nseam and SEAM\r\na.b axb")
        let all = view.searchAll("seam", rows: 0..<4, limit: 100)
        XCTAssertEqual(all, [
            SearchMatch(row: 0, col: 2, cells: 4),
            SearchMatch(row: 2, col: 0, cells: 4),
            SearchMatch(row: 2, col: 9, cells: 4),
        ])
        XCTAssertEqual(view.searchAll("a.b", rows: 0..<4, limit: 100),
                       [SearchMatch(row: 3, col: 0, cells: 3)], "a dot is a dot, not any character")
    }

    func testRowsOutsideTheRangeNeverMatch () {
        let view = makeView(text: "seam 0\r\nseam 1\r\nseam 2\r\nseam 3")
        XCTAssertEqual(view.searchAll("seam", rows: 1..<3, limit: 100).map(\.row), [1, 2])
        XCTAssertEqual(view.searchAll("seam", rows: 3..<3, limit: 100), [])
        XCTAssertEqual(view.searchAll("seam", rows: 2..<99, limit: 100).map(\.row), [2, 3])
    }

    func testTheNewestAreKeptAtTheCap () {
        var text = ""
        for row in 0..<40 { text += "x\(row) x\r\n" }
        let view = makeView(text: text)
        let all = view.searchAll("x", rows: 0..<40, limit: 5)
        XCTAssertEqual(all.count, 5)
        // Rows 37, 38 and 39 hold two each: the cap takes the last five.
        XCTAssertEqual(all.map(\.row), [37, 38, 38, 39, 39])
        XCTAssertEqual(all.first?.col, 4, "the cap splits a row from its right end")
    }

    func testAMatchAcrossASoftWrapStartsOnItsFirstRow () {
        // 20 columns: "seam" starts at column 18 and wraps onto the next row.
        let view = makeView(text: String(repeating: "-", count: 18) + "seam tail")
        XCTAssertTrue(view.getTerminal().buffer.lines[1].isWrapped)
        XCTAssertEqual(view.searchAll("seam", rows: 0..<2, limit: 10),
                       [SearchMatch(row: 0, col: 18, cells: 4)])
        XCTAssertEqual(view.searchAll("tail", rows: 0..<2, limit: 10),
                       [SearchMatch(row: 1, col: 3, cells: 4)])
        XCTAssertEqual(view.searchAll("tail", rows: 0..<1, limit: 10), [],
                       "a match is kept by the row it starts on")
    }

    func testWideGlyphsCountTwoCells () {
        let view = makeView(text: "日本 seam")
        XCTAssertEqual(view.searchAll("seam", rows: 0..<1, limit: 10),
                       [SearchMatch(row: 0, col: 5, cells: 4)])
    }

    func testNonASCIILowercasesAndMapsToCells () {
        let view = makeView(text: "ÇA va 日本語 x seam")
        XCTAssertEqual(view.searchAll("ça va", rows: 0..<1, limit: 10), [SearchMatch(row: 0, col: 0, cells: 5)])
        XCTAssertEqual(view.searchAll("本語", rows: 0..<1, limit: 10), [SearchMatch(row: 0, col: 8, cells: 4)])
        XCTAssertEqual(view.searchAll("seam", rows: 0..<1, limit: 10), [SearchMatch(row: 0, col: 15, cells: 4)])
    }

    /// A row the program writes over is read again; the rows above it are
    /// not, and still match.
    func testARowWrittenOverIsReadAgain () {
        let view = makeView(text: "keep this\r\nold words")
        XCTAssertEqual(view.searchAll("old", rows: 0..<6, limit: 10).map(\.row), [1])
        view.feed(byteArray: ArraySlice(Array("\r\u{1b}[2Knew words".utf8)))
        XCTAssertEqual(view.searchAll("old", rows: 0..<6, limit: 10), [])
        XCTAssertEqual(view.searchAll("new", rows: 0..<6, limit: 10).map(\.row), [1])
        XCTAssertEqual(view.searchAll("keep", rows: 0..<6, limit: 10).map(\.row), [0])
    }

    /// A full scrollback trims a line off the top for each one that comes
    /// in: every match is still on the row that holds it.
    func testRowsStayRightThroughATrim () {
        var options = TerminalOptions.default
        options.cols = 20
        options.rows = 4
        options.scrollback = 10
        let view = TerminalView(frame: NSRect(x: 0, y: 0, width: 400, height: 120),
                                font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular), options: options)
        view.getTerminal().resize(cols: 20, rows: 4)
        func feed (_ from: Int, _ to: Int) {
            view.feed(byteArray: ArraySlice(Array((from..<to).map { "tok\($0)x\r\n" }.joined().utf8)))
        }
        feed(0, 8)
        XCTAssertEqual(view.searchAll("tok3x", rows: 0..<99, limit: 10).map(\.row), [3])
        feed(8, 30)
        let terminal = view.getTerminal()
        XCTAssertGreaterThan(terminal.buffer.totalLinesTrimmed, 0)
        for token in 17..<30 {
            let rows = view.searchAll("tok\(token)x", rows: 0..<99, limit: 10).map(\.row)
            XCTAssertEqual(rows.count, 1, "tok\(token)")
            let text = rows.first.flatMap { terminal.getScrollInvariantLine(row: $0 + terminal.buffer.totalLinesTrimmed) }?
                .translateToString(trimRight: true)
            XCTAssertEqual(text, "tok\(token)x")
        }
        XCTAssertEqual(view.searchAll("tok3x", rows: 0..<99, limit: 10), [], "trimmed away")
    }

    func testTheAlternateScreenAndBackAreEachTheirOwn () {
        let view = makeView(text: "main words\r\n")
        XCTAssertEqual(view.searchAll("main", rows: 0..<6, limit: 10).count, 1)
        view.feed(byteArray: ArraySlice(Array("\u{1b}[?1049halt words".utf8)))
        XCTAssertEqual(view.searchAll("main", rows: 0..<6, limit: 10), [])
        XCTAssertEqual(view.searchAll("alt", rows: 0..<6, limit: 10).count, 1)
        view.feed(byteArray: ArraySlice(Array("\u{1b}[?1049l".utf8)))
        XCTAssertEqual(view.searchAll("main", rows: 0..<6, limit: 10).count, 1)
        XCTAssertEqual(view.searchAll("alt", rows: 0..<6, limit: 10), [])
    }

    /// A row read at one width is not served at another.
    func testAWidthChangeReadsAfresh () {
        let view = makeView(text: "seam")
        XCTAssertEqual(view.searchAll("seam", rows: 0..<6, limit: 10), [SearchMatch(row: 0, col: 0, cells: 4)])
        view.getTerminal().resize(cols: 30, rows: 6)
        view.feed(byteArray: ArraySlice(Array("\u{1b}[2;26Hseam".utf8)))
        XCTAssertEqual(view.searchAll("seam", rows: 0..<6, limit: 10),
                       [SearchMatch(row: 0, col: 0, cells: 4), SearchMatch(row: 1, col: 25, cells: 4)])
    }

    func testPreparedAndForgottenSearchesFindTheSame () {
        let view = makeView(text: "one seam\r\ntwo seam")
        view.prepareSearchAll(rows: 0..<6)
        XCTAssertEqual(view.searchAll("seam", rows: 0..<6, limit: 10).map(\.row), [0, 1])
        view.forgetSearchAll()
        XCTAssertEqual(view.searchAll("seam", rows: 0..<6, limit: 10).map(\.row), [0, 1])
    }

    func testAnEmptyTermMatchesNothing () {
        let view = makeView(text: "anything")
        XCTAssertEqual(view.searchAll("", rows: 0..<1, limit: 10), [])
        XCTAssertEqual(view.searchAll("any", rows: 0..<1, limit: 0), [])
    }

    func testAFeedIsSeenByTheNextSearch () {
        let view = makeView(text: "one\r\n")
        XCTAssertEqual(view.searchAll("two", rows: 0..<6, limit: 10), [])
        view.feed(byteArray: ArraySlice(Array("two".utf8)))
        XCTAssertEqual(view.searchAll("two", rows: 0..<6, limit: 10), [SearchMatch(row: 1, col: 0, cells: 3)])
    }
}
#endif
