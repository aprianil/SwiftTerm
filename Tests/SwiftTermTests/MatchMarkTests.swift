//
//  MatchMarkTests.swift
//
//  `matchMarks` lights the cells a search matched: a block of the mark's
//  fill under them, over what the row's runs and its block painted, and
//  the glyphs in the mark's ink where it has one. These read the pixels:
//  the fill where the mark is and nowhere else, the ink after the mark
//  moves (the built row is cached twice, by row and by content, and the
//  ink has to reach both), a mark over a program's own ground and inside a
//  block, a mark across a soft wrap, and a selection a mark leaves alone.
//
#if os(macOS)
import AppKit
import XCTest
@testable import SwiftTerm

final class MatchMarkTests: XCTestCase {
    private let blue = NSColor(srgbRed: 0, green: 0, blue: 1, alpha: 1)
    private let red = NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)
    private let green = NSColor(srgbRed: 0, green: 1, blue: 0, alpha: 1)

    private func makeView (cols: Int = 20, text: String) -> TerminalView {
        _ = NSApplication.shared
        var options = TerminalOptions.default
        options.cols = cols
        options.rows = 6
        let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        let view = TerminalView(frame: NSRect(x: 0, y: 0, width: 400, height: 120),
                                font: font, options: options)
        view.getTerminal().resize(cols: cols, rows: 6)
        view.nativeBackgroundColor = .black
        view.nativeForegroundColor = .white
        view.feed(byteArray: ArraySlice(Array(text.utf8)))
        return view
    }

    private func bitmap (of view: TerminalView) -> NSBitmapImageRep {
        let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep
    }

    /// Every pixel across the cells `columns` of screen row `row`.
    private func pixels (_ rep: NSBitmapImageRep, _ view: TerminalView,
                         row: Int, columns: Range<Int>) -> [NSColor] {
        let cell = view.cellDimension!
        let scale = CGFloat(rep.pixelsWide) / view.bounds.width
        let left = view.contentInsets.left
        var out: [NSColor] = []
        let y0 = Int((CGFloat(row) * cell.height + 2) * scale)
        let y1 = Int((CGFloat(row + 1) * cell.height - 2) * scale)
        let x0 = Int((left + CGFloat(columns.lowerBound) * cell.width + 1) * scale)
        let x1 = Int((left + CGFloat(columns.upperBound) * cell.width - 1) * scale)
        for y in y0..<y1 {
            for x in x0..<x1 {
                if let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) { out.append(c) }
            }
        }
        return out
    }

    /// The fill shows: most of the cells' pixels are the fill, the rest
    /// glyph. Loose, since the fill goes through the display's colour space.
    private func filled (_ px: [NSColor], _ fill: NSColor) -> Bool {
        let hits = px.filter { abs($0.redComponent - fill.redComponent) < 0.25
            && abs($0.greenComponent - fill.greenComponent) < 0.25
            && abs($0.blueComponent - fill.blueComponent) < 0.25 }
        return hits.count > px.count / 2
    }

    /// Glyph strokes in the red ink: red, with neither the fills' blue or
    /// green nor the white of an uninked glyph.
    private func inked (_ px: [NSColor], over fill: NSColor) -> Bool {
        px.filter { $0.redComponent > 0.6 && $0.greenComponent < 0.35 && $0.blueComponent < 0.5 }.count >= 5
    }

    private func whiteGlyphs (_ px: [NSColor]) -> Bool {
        px.filter { $0.redComponent > 0.7 && $0.greenComponent > 0.7 && $0.blueComponent > 0.7 }.count >= 5
    }

    func testAMarkFillsItsCellsAndNothingElse () {
        let view = makeView(text: "find the seam here")
        view.matchMarks = [.init(match: SearchMatch(row: 0, col: 9, cells: 4), fill: blue)]
        let rep = bitmap(of: view)
        XCTAssertTrue(filled(pixels(rep, view, row: 0, columns: 9..<13), blue))
        XCTAssertFalse(filled(pixels(rep, view, row: 0, columns: 4..<8), blue))
        XCTAssertFalse(filled(pixels(rep, view, row: 1, columns: 9..<13), blue))
        XCTAssertTrue(whiteGlyphs(pixels(rep, view, row: 0, columns: 9..<13)), "no ink keeps the glyphs' colour")
    }

    /// Two rows with the same words, so the second can take the first's
    /// build by content: the ink moves from one to the other and each draws
    /// what its own marks say, not what the other was built with.
    func testTheInkFollowsAStepThroughBothCaches () {
        let view = makeView(text: "seam seam\r\nseam seam")
        let first = SearchMatch(row: 0, col: 0, cells: 4)
        let second = SearchMatch(row: 1, col: 5, cells: 4)
        view.matchMarks = [.init(match: first, fill: blue, ink: red), .init(match: second, fill: green)]
        var rep = bitmap(of: view)
        XCTAssertTrue(inked(pixels(rep, view, row: 0, columns: 0..<4), over: blue))
        XCTAssertFalse(inked(pixels(rep, view, row: 1, columns: 5..<9), over: green))

        view.matchMarks = [.init(match: first, fill: green), .init(match: second, fill: blue, ink: red)]
        rep = bitmap(of: view)
        XCTAssertFalse(inked(pixels(rep, view, row: 0, columns: 0..<4), over: green), "the ink left row 0")
        XCTAssertTrue(whiteGlyphs(pixels(rep, view, row: 0, columns: 0..<4)))
        XCTAssertTrue(inked(pixels(rep, view, row: 1, columns: 5..<9), over: blue), "and reached row 1")
        XCTAssertTrue(filled(pixels(rep, view, row: 1, columns: 5..<9), blue))

        view.matchMarks = []
        rep = bitmap(of: view)
        XCTAssertTrue(whiteGlyphs(pixels(rep, view, row: 1, columns: 5..<9)), "and goes with the marks")
        XCTAssertFalse(filled(pixels(rep, view, row: 1, columns: 5..<9), blue))
    }

    /// Over a ground the program painted (a diff row) and inside a block
    /// the embedder fills (a message), the mark is on top of both.
    func testAMarkShowsOverTheRowsOwnGrounds () {
        let grey = Attribute.Color.ansi256(code: 237)
        let view = makeView(text: "\u{1b}[48;5;52m on a red ground \u{1b}[49m\r\n\r\n\u{1b}[48;5;237m echoed words \u{1b}[49m\r\n")
        view.backgroundRules = [grey: .red]
        view.blockEdges = TerminalView.BlockEdges(left: 0, right: 0)
        view.matchMarks = [
            .init(match: SearchMatch(row: 0, col: 4, cells: 3), fill: blue),
            .init(match: SearchMatch(row: 2, col: 1, cells: 6), fill: blue),
        ]
        let rep = bitmap(of: view)
        XCTAssertTrue(filled(pixels(rep, view, row: 0, columns: 4..<7), blue), "over the program's ground")
        XCTAssertTrue(filled(pixels(rep, view, row: 2, columns: 1..<7), blue), "inside the block")
    }

    func testAMarkAcrossASoftWrapLightsBothRows () {
        let view = makeView(text: String(repeating: "-", count: 18) + "seam")
        view.matchMarks = [.init(match: SearchMatch(row: 0, col: 18, cells: 4), fill: blue)]
        let rep = bitmap(of: view)
        XCTAssertTrue(filled(pixels(rep, view, row: 0, columns: 18..<20), blue))
        XCTAssertTrue(filled(pixels(rep, view, row: 1, columns: 0..<2), blue))
        XCTAssertFalse(filled(pixels(rep, view, row: 1, columns: 3..<6), blue))
    }

    /// A mark in buffer rows moves with its words when the view scrolls.
    func testAMarkScrollsWithItsWords () {
        var text = ""
        for row in 0..<20 { text += row == 3 ? "the seam\r\n" : "filler \(row)\r\n" }
        let view = makeView(text: text)
        view.matchMarks = [.init(match: SearchMatch(row: 3, col: 4, cells: 4), fill: blue)]
        view.scrollTo(row: 2)
        let rep = bitmap(of: view)
        XCTAssertTrue(filled(pixels(rep, view, row: 1, columns: 4..<8), blue))
    }

    func testMarksLeaveTheSelectionAlone () {
        let view = makeView(text: "copy these words")
        view.selection.setSelection(start: Position(col: 0, row: 0), end: Position(col: 4, row: 0))
        let before = view.getSelection()
        view.matchMarks = [.init(match: SearchMatch(row: 0, col: 5, cells: 5), fill: blue, ink: red)]
        _ = bitmap(of: view)
        view.matchMarks = []
        XCTAssertEqual(view.getSelection(), before)
        XCTAssertTrue(view.selection.active)
    }
}
#endif
