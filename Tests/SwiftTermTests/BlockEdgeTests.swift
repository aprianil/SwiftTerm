//
//  BlockEdgeTests.swift
//
//  `blockEdges` runs a ruled block's fill from the view's own left edge to
//  its right, rather than from its first grey cell to its last. These read
//  the pixels on a block row, on a row without one, and on the blank rows
//  that lend the block its padding.
//
#if os(macOS)
import AppKit
import XCTest
@testable import SwiftTerm

final class BlockEdgeTests: XCTestCase {
    private let grey = Attribute.Color.ansi256(code: 237)
    private let inset: CGFloat = 14

    /// Row 0 blank, row 1 the block, row 2 blank, row 3 plain words: the
    /// block has a blank row on each side, which is what the padding lend
    /// asks for.
    private func makeView () -> TerminalView {
        _ = NSApplication.shared
        var options = TerminalOptions.default
        options.cols = 40
        options.rows = 6
        let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        let view = TerminalView(frame: NSRect(x: 0, y: 0, width: 400, height: 120),
                                font: font, options: options)
        view.nativeBackgroundColor = .black
        view.contentInsets = NSEdgeInsets(top: 0, left: inset, bottom: 0, right: inset)
        view.feed(byteArray: ArraySlice(Array("\r\n\u{1b}[48;5;237m echoed words \u{1b}[49m\r\n\r\nplain row".utf8)))
        view.backgroundRules = [grey: .red]
        view.backgroundRuleWidth = 2
        return view
    }

    private func bitmap (of view: TerminalView) -> NSBitmapImageRep {
        let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep
    }

    /// The colour at a point given in the view's own points: `x` from its
    /// left edge, `row` a screen row and `within` how far down that row.
    private func colour (_ rep: NSBitmapImageRep, _ view: TerminalView,
                         x: CGFloat, row: Int, within: CGFloat = 0.5) -> NSColor {
        let cell = view.cellDimension!
        let scale = CGFloat(rep.pixelsWide) / view.bounds.width
        return rep.colorAt(x: Int(x * scale),
                           y: Int((CGFloat(row) + within) * cell.height * scale))!
    }

    /// The view's scroller sits over its own right edge and would answer for
    /// the block's pixels there, so the block's right edge is put clear of
    /// it and the reading taken on either side of that.
    private func rightEdge (_ view: TerminalView) -> CGFloat {
        let scroller = view.bounds.width - view.getEffectiveWidth(size: view.bounds.size)
            - view.contentInsets.left - view.contentInsets.right
        return scroller + 8
    }

    private func assertRed (_ c: NSColor, _ what: String) {
        XCTAssertGreaterThan(c.redComponent, 0.8, what)
        XCTAssertLessThan(c.greenComponent, 0.2, what)
    }
    private func assertFill (_ c: NSColor, _ what: String) {
        // The block's grey: lighter than the window's black, and not the rule.
        XCTAssertGreaterThan(c.brightnessComponent, 0.05, what)
        XCTAssertLessThan(c.redComponent - c.greenComponent, 0.05, what)
    }
    private func assertGround (_ c: NSColor, _ what: String) {
        XCTAssertLessThan(c.brightnessComponent, 0.05, what)
    }

    func testTheBlockRunsFromTheEdgesItWasGiven () {
        let view = makeView()
        let right = rightEdge(view)
        view.blockEdges = TerminalView.BlockEdges(left: 4, right: right)
        let rep = bitmap(of: view)
        let width = view.bounds.width

        assertGround(colour(rep, view, x: 2, row: 1), "outside the block's left edge is the window's own")
        assertRed(colour(rep, view, x: 5, row: 1), "the rule sits at the block's left edge")
        assertFill(colour(rep, view, x: 8, row: 1), "and the fill runs on from it")
        assertFill(colour(rep, view, x: inset - 2, row: 1), "through the margin the text is inset by")
        assertFill(colour(rep, view, x: inset + 4, row: 1), "and over the cells themselves")
        assertFill(colour(rep, view, x: width - right - 2, row: 1), "out to the block's right edge")
        assertGround(colour(rep, view, x: width - right + 2, row: 1), "and no further")
    }

    func testARowWithoutABlockIsUntouched () {
        let view = makeView()
        view.blockEdges = TerminalView.BlockEdges(left: 4, right: rightEdge(view))
        let rep = bitmap(of: view)
        assertGround(colour(rep, view, x: 5, row: 3), "no rule on a row the program left plain")
        assertGround(colour(rep, view, x: 8, row: 3), "and no fill")
    }

    func testTheLentPaddingTakesTheSameEdges () {
        let view = makeView()
        let right = rightEdge(view)
        view.blockEdges = TerminalView.BlockEdges(left: 4, right: right)
        view.backgroundBlockPadding = view.cellDimension.height * 0.5
        let rep = bitmap(of: view)
        let width = view.bounds.width

        // Row 0 lends its lower half, row 2 its upper half.
        assertFill(colour(rep, view, x: 8, row: 0, within: 0.8), "the row above lends the block its air")
        assertRed(colour(rep, view, x: 5, row: 0, within: 0.8), "with the rule running through it")
        assertFill(colour(rep, view, x: width - right - 2, row: 0, within: 0.8), "out to the same right edge")
        assertGround(colour(rep, view, x: width - right + 2, row: 0, within: 0.8), "and no further")
        assertGround(colour(rep, view, x: 8, row: 0, within: 0.2), "and no further up than it lent")

        assertFill(colour(rep, view, x: 8, row: 2, within: 0.2), "the row below lends the same")
        assertRed(colour(rep, view, x: 5, row: 2, within: 0.2), "rule and all")
        assertGround(colour(rep, view, x: 8, row: 2, within: 0.8), "and no further down")
    }

    func testWithoutEdgesTheBlockIsStillItsOwnCells () {
        let view = makeView()
        let rep = bitmap(of: view)
        assertGround(colour(rep, view, x: 5, row: 1), "nothing is drawn in the margin until the edges are set")
        assertRed(colour(rep, view, x: inset + 1, row: 1), "the rule is at the block's first cell")
        assertFill(colour(rep, view, x: inset + 6, row: 1), "and the fill is the cells it painted")
    }
    func testTheRuleIsDrawnWhereItWasPut () {
        let view = makeView()
        view.blockEdges = TerminalView.BlockEdges(left: 4, right: rightEdge(view))
        view.blockRuleX = 0
        let rep = bitmap(of: view)

        assertRed(colour(rep, view, x: 1, row: 1), "the rule is at the x it was given")
        assertGround(colour(rep, view, x: 3, row: 1), "the ground shows between it and the block")
        assertFill(colour(rep, view, x: 6, row: 1), "and the block starts at its own edge")
        assertFill(colour(rep, view, x: inset - 2, row: 1), "and runs on through the text margin")
        assertGround(colour(rep, view, x: 1, row: 3), "a row the program left plain has no rule")
    }

    func testTheRuleAtTheGivenXCarriesThroughTheLentPadding () {
        let view = makeView()
        view.blockEdges = TerminalView.BlockEdges(left: 4, right: rightEdge(view))
        view.blockRuleX = 0
        view.backgroundBlockPadding = view.cellDimension.height * 0.5
        let rep = bitmap(of: view)

        assertRed(colour(rep, view, x: 1, row: 0, within: 0.8), "the pad above carries the rule")
        assertRed(colour(rep, view, x: 1, row: 2, within: 0.2), "and so does the pad below")
        assertGround(colour(rep, view, x: 1, row: 0, within: 0.2), "no further up than the pad reaches")
        assertGround(colour(rep, view, x: 1, row: 2, within: 0.8), "nor further down")
    }

    /// The rounded corners are read where a 1 pt radius bites: the outer
    /// pixel of the rule's right-hand corner, which a square rule fills.
    func testTheRulesRightCornersRoundWhereTheBlockEnds () {
        let view = makeView()
        view.blockEdges = TerminalView.BlockEdges(left: 4, right: rightEdge(view))
        view.blockRuleX = 0
        // A rule wide enough that one pixel of its corner is unambiguously
        // inside a square one and outside a rounded one.
        let ruleWidth: CGFloat = 6
        view.backgroundRuleWidth = ruleWidth
        let cell = view.cellDimension!
        let scale = CGFloat(bitmap(of: view).pixelsWide) / view.bounds.width

        func cornerAlpha (_ rep: NSBitmapImageRep, top: Bool) -> CGFloat {
            // Half a point in from the rule's right edge and from the row's
            // outer edge: inside a square corner, outside a rounded one.
            let x = Int((ruleWidth - 0.5) * scale)
            let y = top ? Int((cell.height + 0.5) * scale)
                        : Int((2 * cell.height - 0.5) * scale)
            return rep.colorAt(x: x, y: y)!.redComponent
        }

        let square = bitmap(of: view)
        XCTAssertGreaterThan(cornerAlpha(square, top: true), 0.8, "a square rule fills its top corner")
        XCTAssertGreaterThan(cornerAlpha(square, top: false), 0.8, "and its bottom one")

        view.blockRuleCornerRadius = ruleWidth
        let rounded = bitmap(of: view)
        XCTAssertLessThan(cornerAlpha(rounded, top: true), 0.2, "a rounded rule gives its top corner back")
        XCTAssertLessThan(cornerAlpha(rounded, top: false), 0.2, "and its bottom one")
        // The left edge stays square: the rule is a tab, not a pill.
        let left = rounded.colorAt(x: Int(0.5 * scale), y: Int((cell.height + 0.5) * scale))!
        XCTAssertGreaterThan(left.redComponent, 0.8, "the left corners stay square")
    }
}
#endif
