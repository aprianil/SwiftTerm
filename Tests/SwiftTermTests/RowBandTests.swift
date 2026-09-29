//
//  RowBandTests.swift
//
//  `rowBands` paints a run of viewport rows in one colour under everything
//  those rows draw. These read the pixels inside a band, in the strips its
//  trims leave out, on the rows either side of it, and hold that setting a
//  band rebuilds no rows: it is decided when a row is drawn, not when it is
//  built.
//
#if os(macOS)
import AppKit
import XCTest
@testable import SwiftTerm

final class RowBandTests: XCTestCase {
    private func makeView () -> TerminalView {
        _ = NSApplication.shared
        var options = TerminalOptions.default
        options.cols = 40
        options.rows = 6
        let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        let view = TerminalView(frame: NSRect(x: 0, y: 0, width: 400, height: 120),
                                font: font, options: options)
        view.nativeBackgroundColor = .black
        view.feed(byteArray: ArraySlice(Array("one\r\ntwo\r\nthree\r\nfour".utf8)))
        return view
    }

    private func bitmap (of view: TerminalView) -> NSBitmapImageRep {
        let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep
    }

    private func colour (_ rep: NSBitmapImageRep, _ view: TerminalView,
                         x: CGFloat, row: Int, within: CGFloat = 0.5) -> NSColor {
        let cell = view.cellDimension!
        let scale = CGFloat(rep.pixelsWide) / view.bounds.width
        return rep.colorAt(x: Int(x * scale),
                           y: Int((CGFloat(row) + within) * cell.height * scale))!
    }

    /// An x with no glyph on any row: the rows carry a word each at the
    /// left, and a reading taken over one would answer for its ink.
    private let clearOfInk: CGFloat = 200

    private func assertBand (_ c: NSColor, _ what: String) {
        XCTAssertGreaterThan(c.blueComponent, 0.8, what)
        XCTAssertLessThan(c.redComponent, 0.2, what)
    }
    private func assertGround (_ c: NSColor, _ what: String) {
        XCTAssertLessThan(c.blueComponent, 0.1, what)
    }

    func testTheBandCoversItsRowsAndNoOthers () {
        let view = makeView()
        view.rowBands = [TerminalView.RowBand(rows: 1...2, fill: .blue)]
        let rep = bitmap(of: view)

        assertGround(colour(rep, view, x: clearOfInk, row: 0), "the row above the band is untouched")
        assertBand(colour(rep, view, x: clearOfInk, row: 1), "the band's first row is filled")
        assertBand(colour(rep, view, x: clearOfInk, row: 2), "and its last")
        assertGround(colour(rep, view, x: clearOfInk, row: 3), "the row below is untouched")
        assertBand(colour(rep, view, x: clearOfInk, row: 1, within: 0.1), "and with no trims it fills the row whole")
        assertBand(colour(rep, view, x: clearOfInk, row: 2, within: 0.9), "top to bottom")
    }

    func testTheTrimsTakeTheEndsOff () {
        let view = makeView()
        let cell = view.cellDimension!
        view.rowBands = [TerminalView.RowBand(rows: 1...2, fill: .blue,
                                              trimTop: cell.height * 0.5,
                                              trimBottom: cell.height * 0.5)]
        let rep = bitmap(of: view)

        assertGround(colour(rep, view, x: clearOfInk, row: 1, within: 0.2), "the first row's top is trimmed away")
        assertBand(colour(rep, view, x: clearOfInk, row: 1, within: 0.8), "and the rest of it is the band")
        assertBand(colour(rep, view, x: clearOfInk, row: 2, within: 0.2), "the last row starts as the band")
        assertGround(colour(rep, view, x: clearOfInk, row: 2, within: 0.8), "and its bottom is trimmed away")
    }

    func testTheBandTakesTheBlocksEdgesWhenThereAreAny () {
        let view = makeView()
        view.contentInsets = NSEdgeInsets(top: 0, left: 14, bottom: 0, right: 14)
        view.rowBands = [TerminalView.RowBand(rows: 1...1, fill: .blue)]
        assertBand(colour(bitmap(of: view), view, x: 2, row: 1),
                   "with no edges the band is the view's full width")

        view.blockEdges = TerminalView.BlockEdges(left: 8, right: 8)
        let rep = bitmap(of: view)
        assertGround(colour(rep, view, x: 2, row: 1), "with edges it starts at the left one")
        assertBand(colour(rep, view, x: 12, row: 1), "and runs on from there")
    }

    func testABandRebuildsNoRows () {
        let view = makeView()
        _ = bitmap(of: view)
        let built = view.rowRenderCacheStats
        XCTAssertGreaterThan(built.rebuilt, 0, "the first draw builds the rows")

        view.rowBands = [TerminalView.RowBand(rows: 1...2, fill: .blue)]
        _ = bitmap(of: view)
        let after = view.rowRenderCacheStats
        XCTAssertEqual(after.rebuilt, built.rebuilt,
                       "a band is decided when a row is drawn, so no row is built again")
        XCTAssertGreaterThan(after.reused, built.reused, "every row on screen was reused")
    }
}
#endif
