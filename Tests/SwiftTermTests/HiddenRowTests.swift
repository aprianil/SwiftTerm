//
//  HiddenRowTests.swift
//
//  `hiddenRows` leaves a viewport row out of the draw: no glyphs, none of
//  the background a program painted on it, only a `rowBands` band that
//  covers it. These read the pixels on a hidden row and its neighbours,
//  hold that the buffer keeps every cell, and that hiding rebuilds no rows.
//
#if os(macOS)
import AppKit
import XCTest
@testable import SwiftTerm

final class HiddenRowTests: XCTestCase {
    private let grey = Attribute.Color.ansi256(code: 237)

    /// Row 0 plain words, row 1 words on a background the program named,
    /// row 2 plain words again.
    private func makeView () -> TerminalView {
        _ = NSApplication.shared
        var options = TerminalOptions.default
        options.cols = 40
        options.rows = 6
        let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        let view = TerminalView(frame: NSRect(x: 0, y: 0, width: 400, height: 120),
                                font: font, options: options)
        view.nativeBackgroundColor = .black
        view.nativeForegroundColor = .white
        view.feed(byteArray: ArraySlice(Array("MMMM\r\n\u{1b}[48;5;237mMMMMMMMM\u{1b}[49m\r\nMMMM".utf8)))
        return view
    }

    private func bitmap (of view: TerminalView) -> NSBitmapImageRep {
        let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep
    }

    /// Whether anything but the window's own colour is drawn across the
    /// first few cells of a row.
    private func hasAnything (_ rep: NSBitmapImageRep, _ view: TerminalView, row: Int) -> Bool {
        let cell = view.cellDimension!
        let scale = CGFloat(rep.pixelsWide) / view.bounds.width
        let y0 = Int((CGFloat(row) * cell.height + 1) * scale)
        let y1 = Int((CGFloat(row + 1) * cell.height - 1) * scale)
        for y in y0..<y1 {
            for x in 0..<Int(4 * cell.width * scale) {
                if let c = rep.colorAt(x: x, y: y), c.brightnessComponent > 0.05 {
                    return true
                }
            }
        }
        return false
    }

    func testAHiddenRowDrawsNothing () {
        let view = makeView()
        let before = bitmap(of: view)
        XCTAssertTrue(hasAnything(before, view, row: 0))
        XCTAssertTrue(hasAnything(before, view, row: 1))
        XCTAssertTrue(hasAnything(before, view, row: 2))

        view.hiddenRows = [1]
        let after = bitmap(of: view)
        XCTAssertTrue(hasAnything(after, view, row: 0), "the row above is drawn as ever")
        XCTAssertFalse(hasAnything(after, view, row: 1),
                       "the hidden row loses its glyphs and the background under them")
        XCTAssertTrue(hasAnything(after, view, row: 2), "the row below is drawn as ever")

        view.hiddenRows = []
        XCTAssertTrue(hasAnything(bitmap(of: view), view, row: 1), "and it comes back")
    }

    func testTheBufferKeepsWhatTheDrawLost () {
        let view = makeView()
        view.hiddenRows = [1]
        _ = bitmap(of: view)
        let line = view.terminal.buffer.lines[1]
        XCTAssertEqual(Int(line[0].code), Int(UnicodeScalar("M").value),
                       "the glyph is still in the buffer")
        XCTAssertEqual(line[0].attribute.bg, grey,
                       "and so is the background the program named")
    }

    func testABandStillShowsThroughAHiddenRow () {
        let view = makeView()
        view.hiddenRows = [1]
        view.rowBands = [TerminalView.RowBand(rows: 1...1, fill: .blue)]
        let rep = bitmap(of: view)
        let cell = view.cellDimension!
        let scale = CGFloat(rep.pixelsWide) / view.bounds.width
        let c = rep.colorAt(x: Int(2 * cell.width * scale),
                            y: Int(1.5 * cell.height * scale))!
        XCTAssertGreaterThan(c.blueComponent, 0.8, "the band under a hidden row is still drawn")
        XCTAssertLessThan(c.redComponent, 0.2, "and nothing of the row's own is drawn over it")
    }

    func testHidingARowRebuildsNoRows () {
        let view = makeView()
        _ = bitmap(of: view)
        let built = view.rowRenderCacheStats
        XCTAssertGreaterThan(built.rebuilt, 0, "the first draw builds the rows")

        view.hiddenRows = [1]
        _ = bitmap(of: view)
        XCTAssertEqual(view.rowRenderCacheStats.rebuilt, built.rebuilt,
                       "hiding a row is decided when it is drawn, so nothing is built again")

        view.hiddenRows = []
        _ = bitmap(of: view)
        XCTAssertEqual(view.rowRenderCacheStats.rebuilt, built.rebuilt,
                       "and the row that comes back was kept, not built again")
    }
}
#endif
