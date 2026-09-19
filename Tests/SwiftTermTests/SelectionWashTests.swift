//
//  SelectionWashTests.swift
//
//  The selection's wash: drawn once per row in the selection's shape, with
//  its outer corners rounded by `selectionCornerRadius`, and kept while a
//  program that does not read the mouse writes more output.
//
#if os(macOS)
import AppKit
import XCTest
@testable import SwiftTerm

final class SelectionWashTests: XCTestCase {
    private func makeView () -> TerminalView {
        _ = NSApplication.shared
        var options = TerminalOptions.default
        options.cols = 48
        options.rows = 6
        let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        let view = TerminalView(frame: NSRect(x: 0, y: 0, width: 690, height: 120),
                                font: font, options: options)
        view.feed(byteArray: ArraySlice(Array("one two three\r\nfour five six\r\nseven eight\r\n".utf8)))
        return view
    }

    /// Output does not take the selection while the program leaves the
    /// mouse to the user; once the program turns mouse reporting on, it
    /// does.
    func testTheSelectionSurvivesOutputUnlessTheProgramReadsTheMouse () {
        let view = makeView()
        view.selection.setSelection(start: Position(col: 0, row: 0), end: Position(col: 3, row: 0))
        XCTAssertTrue(view.selection.active)
        view.feed(byteArray: ArraySlice(Array("more\r\n".utf8)))
        XCTAssertTrue(view.selection.active, "mouse reporting is off: the selection is the user's")

        // CSI ? 1000 h: the program asks for button events.
        view.feed(byteArray: ArraySlice(Array("\u{1b}[?1000h".utf8)))
        XCTAssertNotEqual(view.getTerminal().mouseMode, .off)
        view.selection.setSelection(start: Position(col: 0, row: 0), end: Position(col: 3, row: 0))
        view.feed(byteArray: ArraySlice(Array("more\r\n".utf8)))
        XCTAssertFalse(view.selection.active, "mouse reporting is on: the program's frame moved on")
    }

    /// The selection is of text: output elsewhere and a frame that writes
    /// the same words again leave it; erasing its row, writing over it or
    /// clearing the screen take it.
    func testTheSelectionGoesWhenItsTextDoes () {
        func fresh () -> TerminalView {
            let view = makeView()
            view.selection.setSelection(start: Position(col: 0, row: 1), end: Position(col: 4, row: 1))
            XCTAssertEqual(view.selection.getSelectedText(), "four")
            return view
        }
        var view = fresh()
        view.feed(byteArray: ArraySlice(Array("written below\r\n".utf8)))
        XCTAssertTrue(view.selection.active, "output on another row leaves it")

        view = fresh()
        // Row 2 (1-based) rewritten with the same words: a frame redraw.
        view.feed(byteArray: ArraySlice(Array("\u{1b}[s\u{1b}[2;1Hfour five six\u{1b}[u".utf8)))
        XCTAssertTrue(view.selection.active, "the same words again leave it")

        view = fresh()
        view.feed(byteArray: ArraySlice(Array("\u{1b}[s\u{1b}[2;1H\u{1b}[2K\u{1b}[u".utf8)))
        XCTAssertFalse(view.selection.active, "the row erased under it takes it")

        view = fresh()
        view.feed(byteArray: ArraySlice(Array("\u{1b}[s\u{1b}[2;1Hnine ten\u{1b}[u".utf8)))
        XCTAssertFalse(view.selection.active, "other words written over it take it")

        view = fresh()
        view.feed(byteArray: ArraySlice(Array("\u{1b}[2J\u{1b}[H".utf8)))
        XCTAssertFalse(view.selection.active, "a cleared screen takes it")
    }

    /// Rows dropped from the middle of the scrollback take a selection
    /// under them along with their text: what was selected stays selected.
    /// A selection on the dropped rows themselves goes with them.
    func testASelectionFollowsItsTextWhenScrollbackIsDropped () {
        let view = makeView()
        var text = ""
        for i in 0..<20 { text += "line \(i)\r\n" }
        view.feed(byteArray: ArraySlice(Array(text.utf8)))
        let terminal = view.getTerminal()
        // Rows 0..<15 are scrollback (yBase 15 with 6 rows on screen... whatever it is, read it).
        let base = terminal.buffer.yBase
        XCTAssertGreaterThan(base, 6)
        // Select on the screen: buffer rows base+1 ... base+2.
        view.selection.setSelection(start: Position(col: 1, row: base + 1), end: Position(col: 3, row: base + 2))
        let selectedText = view.selection.getSelectedText()
        XCTAssertFalse(selectedText.isEmpty)

        XCTAssertEqual(terminal.dropScrollbackRows(at: 2, count: 3), 3)
        XCTAssertTrue(view.selection.active)
        XCTAssertEqual(view.selection.start.row, base + 1 - 3)
        XCTAssertEqual(view.selection.end.row, base + 2 - 3)
        XCTAssertEqual(view.selection.getSelectedText(), selectedText, "the same text is selected")

        // Dropping the selected rows themselves ends the selection.
        view.selection.setSelection(start: Position(col: 0, row: 3), end: Position(col: 3, row: 4))
        XCTAssertEqual(terminal.dropScrollbackRows(at: 2, count: 3), 3)
        XCTAssertFalse(view.selection.active)
    }

    /// Which corners a row's wash rounds: a lone word rounds all four; a
    /// paragraph rounds its outline's convex corners (the first row's top,
    /// the last row's bottom, the two steps) and the corners where its rows
    /// run into each other stay square.
    func testOnlyTheOuterCornersAreRounded () {
        let view = makeView()
        view.selectionCornerRadius = 3
        let rect = CGRect(x: 0, y: 0, width: 100, height: 20)
        func rounded (_ path: CGPath) -> Set<String> {
            // A rounded corner is one the path does not pass through: the
            // arc cuts it off.
            var corners: Set<String> = []
            for (name, point) in [("bottomLeft", CGPoint(x: rect.minX, y: rect.minY)),
                                  ("bottomRight", CGPoint(x: rect.maxX, y: rect.minY)),
                                  ("topRight", CGPoint(x: rect.maxX, y: rect.maxY)),
                                  ("topLeft", CGPoint(x: rect.minX, y: rect.maxY))] {
                if !path.contains(point.applying(CGAffineTransform(translationX: point.x == rect.minX ? 0.5 : -0.5,
                                                                    y: point.y == rect.minY ? 0.5 : -0.5))) {
                    corners.insert(name)
                }
            }
            return corners
        }
        let word = view.selectionPath(rect, columns: 4..<9, above: nil, below: nil)
        XCTAssertEqual(rounded(word), ["bottomLeft", "bottomRight", "topRight", "topLeft"])

        // A paragraph from column 4 of the first row to column 9 of the last.
        let first = view.selectionPath(rect, columns: 4..<48, above: nil, below: 0..<48)
        XCTAssertEqual(rounded(first), ["topLeft", "topRight"], "its bottom runs into the full row under it")
        let middle = view.selectionPath(rect, columns: 0..<48, above: 4..<48, below: 0..<9)
        XCTAssertEqual(rounded(middle), ["topLeft", "bottomRight"],
                       "the step corners, where the first row starts late and the last ends early")
        let last = view.selectionPath(rect, columns: 0..<9, above: 0..<48, below: nil)
        XCTAssertEqual(rounded(last), ["bottomLeft", "bottomRight"])

        // Two rows that only touch at a point: both corners there are free.
        let touching = view.selectionPath(rect, columns: 0..<9, above: 9..<20, below: nil)
        XCTAssertEqual(rounded(touching), ["bottomLeft", "bottomRight", "topRight", "topLeft"])

        // Radius 0 is the square wash, whatever the neighbours.
        view.selectionCornerRadius = 0
        XCTAssertEqual(rounded(view.selectionPath(rect, columns: 4..<9, above: nil, below: nil)), [])
    }

    /// The wash is one fill per row, in the selection colour, drawn after
    /// the runs' own backgrounds: a selected cell on a named background
    /// gets both.
    func testTheWashIsDrawnOverTheRunsOwnBackground () throws {
        let view = makeView()
        view.selectionCornerRadius = 3
        view.selectedTextBackgroundColor = NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.5)
        view.nativeBackgroundColor = .black
        // Row 0 on a red background.
        view.feed(byteArray: ArraySlice(Array("\u{1b}[H\u{1b}[41mred text here\u{1b}[0m".utf8)))
        view.selection.setSelection(start: Position(col: 0, row: 0), end: Position(col: 8, row: 0))
        let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        // A pixel inside the wash, on the red, well inside the first cell's
        // top half where no glyph ink sits: red under white at half.
        let cell = view.getOptimalFrameSize().width / 48
        let rowHeight = view.getOptimalFrameSize().height / 6
        let x = Int(cell * 0.5 * rep.size.width / view.bounds.width * CGFloat(rep.pixelsWide) / rep.size.width)
        let y = Int((rowHeight * 0.15) * CGFloat(rep.pixelsHigh) / view.bounds.height)
        let pixel = try XCTUnwrap(rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
        XCTAssertGreaterThan(pixel.redComponent, 0.7, "the red is still there")
        XCTAssertGreaterThan(pixel.greenComponent, 0.3, "and the wash is over it")
        XCTAssertGreaterThan(pixel.blueComponent, 0.3)
    }
}
#endif
