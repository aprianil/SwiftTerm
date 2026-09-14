//
//  AlwaysHoverLinkTests.swift
//
//  `.always` underlines every link so a url reads as clickable before it is
//  pointed at. These hold the other half: pointing at one picks it out, in
//  its own colour with a solid underline and the pointing hand, and the
//  pick follows the pointer, leaves with it, and never shows a stale row.
//
#if os(macOS)
import AppKit
import XCTest
@testable import SwiftTerm

final class AlwaysHoverLinkTests: XCTestCase {
    private func makeView () -> TerminalView {
        _ = NSApplication.shared
        var options = TerminalOptions.default
        options.cols = 48
        options.rows = 6
        let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        let view = TerminalView(frame: NSRect(x: 0, y: 0, width: 690, height: 120),
                                font: font, options: options)
        view.linkHighlightMode = .always
        view.urlColor = .systemBlue
        view.hoveredUrlColor = .white
        // Row 0: a bare url from column 5 to 27. Row 1: plain text.
        view.feed(byteArray: ArraySlice(Array("see: https://example.com/a/b now\r\nplain row\r\n".utf8)))
        return view
    }

    private func pixels (of view: TerminalView) -> Data {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return Data() }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let bytes = rep.bitmapData else { return Data() }
        return Data(bytes: bytes, count: rep.bytesPerRow * rep.pixelsHigh)
    }

    private func assertCacheIsInvisible (_ view: TerminalView, _ what: String,
                                         file: StaticString = #filePath, line: UInt = #line)
    {
        rowRenderCacheEnabled = true
        _ = pixels(of: view)
        let fromCache = pixels(of: view)
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

    func testAlwaysTracksThePointer () {
        let view = makeView()
        XCTAssertTrue(view.shouldTrackMouse(), "a mode that picks out the hovered link needs the pointer")
    }

    func testPointingAtALinkPicksItOutAndLeavingDropsIt () {
        let view = makeView()
        let top = view.getTerminal().buffer.yDisp
        XCTAssertNil(view.linkHighlightRange)
        XCTAssertEqual(view.hoverCursor, .iBeam)

        view.updateHoverLink(at: Position(col: 10, row: top))
        let range = view.linkHighlightRange
        XCTAssertNotNil(range, "the url under the pointer is the pick")
        XCTAssertEqual(range?.first?.row, top)
        XCTAssertTrue(range?.first?.range.contains(10) ?? false)
        XCTAssertEqual(view.hoverCursor, .pointingHand)
        XCTAssertTrue(view.isHoveredLink(row: top, column: 10, width: 1))
        XCTAssertFalse(view.isHoveredLink(row: top, column: 1, width: 1), "the word before the url is not picked")

        // Along the same url: the same pick, nothing dropped and rescanned.
        view.updateHoverLink(at: Position(col: 20, row: top))
        XCTAssertEqual(view.linkHighlightRange, range)

        // Off it: the pick and the hand go.
        view.updateHoverLink(at: Position(col: 3, row: top + 1))
        XCTAssertNil(view.linkHighlightRange)
        XCTAssertEqual(view.hoverCursor, .iBeam)
    }

    func testTheHoveredLinkDrawsInItsOwnColourWithASolidUnderline () {
        let view = makeView()
        let attr = Attribute(fg: .defaultColor, bg: .defaultColor, style: [])
        let rest = view.getAttributes(attr, withUrl: true)
        let hovered = view.getAttributes(attr, withUrl: true, hovered: true)
        XCTAssertEqual(rest?[.foregroundColor] as? NSColor, .systemBlue)
        XCTAssertEqual(hovered?[.foregroundColor] as? NSColor, .white)
        XCTAssertEqual(rest?[SwiftTermUnderlineStyleKey] as? Int, Int(UnderlineStyle.dashed.rawValue))
        XCTAssertEqual(hovered?[SwiftTermUnderlineStyleKey] as? Int, Int(UnderlineStyle.single.rawValue))

        // No hover colour set: the colour stays, the underline still answers.
        view.hoveredUrlColor = nil
        let quiet = view.getAttributes(attr, withUrl: true, hovered: true)
        XCTAssertEqual(quiet?[.foregroundColor] as? NSColor, .systemBlue)
        XCTAssertEqual(quiet?[SwiftTermUnderlineStyleKey] as? Int, Int(UnderlineStyle.single.rawValue))
    }

    func testThePickChangesThePixelsAndNeverStrandsARow () {
        let view = makeView()
        let top = view.getTerminal().buffer.yDisp
        assertCacheIsInvisible(view, "at rest")
        let atRest = pixels(of: view)

        view.updateHoverLink(at: Position(col: 10, row: top))
        assertCacheIsInvisible(view, "the url picked")
        let picked = pixels(of: view)
        XCTAssertNotEqual(atRest, picked, "the picked url must look different from the url at rest")

        view.updateHoverLink(at: Position(col: 3, row: top + 1))
        assertCacheIsInvisible(view, "the pick dropped")
        XCTAssertEqual(pixels(of: view), atRest, "with the pointer gone the screen is what it was")
    }
}
#endif
