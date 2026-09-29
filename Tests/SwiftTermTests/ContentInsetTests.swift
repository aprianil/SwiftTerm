//
//  ContentInsetTests.swift
//
//  `contentInsets` puts a margin between the view's edge and column 0. These
//  hold that the columns come from the width left over, that the frame a grid
//  asks for grows by the margin, that the caret and a click land on the same
//  column the glyphs are drawn at, and that a row's ink starts past the
//  margin in the pixels.
//
#if os(macOS)
import AppKit
import XCTest
@testable import SwiftTerm

final class ContentInsetTests: XCTestCase {
    private let inset: CGFloat = 14

    private func makeView () -> TerminalView {
        _ = NSApplication.shared
        var options = TerminalOptions.default
        options.cols = 40
        options.rows = 4
        let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        let view = TerminalView(frame: NSRect(x: 0, y: 0, width: 400, height: 80),
                                font: font, options: options)
        view.nativeBackgroundColor = .black
        view.nativeForegroundColor = .white
        return view
    }

    private func bitmap (of view: TerminalView) -> NSBitmapImageRep {
        let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep
    }

    /// What the view keeps for its scroller, measured rather than assumed:
    /// the columns are counted from the width left after it, margin or no.
    private func scrollerAllowance (_ view: TerminalView) -> CGFloat {
        view.bounds.width - view.getEffectiveWidth(size: view.bounds.size)
    }

    func testTheColumnsComeFromTheWidthLeftOver () {
        let view = makeView()
        let cell = view.cellDimension!
        let allowance = scrollerAllowance(view)
        XCTAssertEqual(view.terminal.cols, Int((view.bounds.width - allowance) / cell.width))

        view.contentInsets = NSEdgeInsets(top: 0, left: inset, bottom: 0, right: inset)
        XCTAssertEqual(view.terminal.cols,
                       Int((view.bounds.width - allowance - 2 * inset) / cell.width),
                       "the margin is taken off the width before the columns are counted")
    }

    func testTheOptimalFrameGrowsByTheInsets () {
        let view = makeView()
        let cell = view.cellDimension!
        let allowance = scrollerAllowance(view)
        let plain = view.getOptimalFrameSize()
        XCTAssertEqual(plain.width, cell.width * CGFloat(view.terminal.cols) + allowance,
                       accuracy: 0.001)

        view.contentInsets = NSEdgeInsets(top: 3, left: inset, bottom: 5, right: inset)
        // The grid shrank with the margin, so the frame is measured against
        // the grid the view holds now, not the one it held before.
        let inset = view.getOptimalFrameSize()
        XCTAssertEqual(inset.width,
                       cell.width * CGFloat(view.terminal.cols) + allowance + 2 * self.inset,
                       accuracy: 0.001,
                       "the frame a grid asks for is wider than the grid by the margin")
        XCTAssertEqual(inset.height,
                       cell.height * CGFloat(view.terminal.rows) + 3 + 5,
                       accuracy: 0.001)
    }

    func testAClickJustPastTheInsetIsColumnZero () {
        let view = makeView()
        view.contentInsets = NSEdgeInsets(top: 0, left: inset, bottom: 0, right: inset)
        let cell = view.cellDimension!
        let y = view.frame.height - cell.height / 2

        XCTAssertEqual(view.calculateMouseHit(at: CGPoint(x: inset + 1, y: y)).grid.col, 0,
                       "a point one past the margin is the first column")
        XCTAssertEqual(view.calculateMouseHit(at: CGPoint(x: inset + cell.width + 1, y: y)).grid.col, 1)
        XCTAssertEqual(view.calculateMouseHit(at: CGPoint(x: 1, y: y)).grid.col, 0,
                       "and a point inside the margin still clamps to it")
    }

    func testTheCaretSitsPastTheInset () {
        let view = makeView()
        view.feed(byteArray: ArraySlice(Array("ab".utf8)))
        // The caret is moved on the next display pass, which is queued; ask
        // for it here rather than waiting a frame.
        view.updateCursorPosition()
        let cell = view.cellDimension!
        let plain = view.caretFrame.origin.x
        XCTAssertEqual(plain, 2 * cell.width, accuracy: 0.001)

        view.contentInsets = NSEdgeInsets(top: 0, left: inset, bottom: 0, right: inset)
        XCTAssertEqual(view.caretFrame.origin.x, inset + 2 * cell.width, accuracy: 0.001,
                       "the caret follows the column it is on")
    }

    /// Whether any pixel of the column of pixels at `x` carries ink: the row
    /// is drawn white on black, so anything above the floor is a glyph.
    private func hasInk (_ rep: NSBitmapImageRep, view: TerminalView, x: Int, row: Int) -> Bool {
        let cell = view.cellDimension!
        let scale = CGFloat(rep.pixelsWide) / view.bounds.width
        let y0 = Int(CGFloat(row) * cell.height * scale) + 1
        let y1 = Int(CGFloat(row + 1) * cell.height * scale) - 1
        for y in y0..<y1 {
            if let c = rep.colorAt(x: x, y: y), c.brightnessComponent > 0.2 {
                return true
            }
        }
        return false
    }

    func testTheRowsInkStartsPastTheInset () {
        let view = makeView()
        view.feed(byteArray: ArraySlice(Array("MMMM".utf8)))
        let before = bitmap(of: view)
        let scale = CGFloat(before.pixelsWide) / view.bounds.width
        XCTAssertTrue(hasInk(before, view: view, x: Int(2 * scale), row: 0),
                      "with no margin the first glyph is drawn at the view's edge")

        view.contentInsets = NSEdgeInsets(top: 0, left: inset, bottom: 0, right: inset)
        let after = bitmap(of: view)
        for x in stride(from: 1, to: Int((inset - 1) * scale), by: 2) {
            XCTAssertFalse(hasInk(after, view: view, x: x, row: 0),
                           "no ink inside the margin, at x \(CGFloat(x) / scale)")
        }
        let cell = view.cellDimension!
        var inkPastTheMargin = false
        for x in stride(from: Int(inset * scale), to: Int((inset + 4 * cell.width) * scale), by: 1) {
            if hasInk(after, view: view, x: x, row: 0) { inkPastTheMargin = true; break }
        }
        XCTAssertTrue(inkPastTheMargin, "and the glyphs are drawn past it")
    }
}
#endif
