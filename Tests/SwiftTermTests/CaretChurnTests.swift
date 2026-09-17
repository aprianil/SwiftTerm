//
//  CaretChurnTests.swift
//
//  The caret hides and shows in place. It used to leave the view tree on
//  every `?25l` and rejoin it on every `?25h`, and each of those invalidated
//  the window's cursor rects, which AppKit rebuilds with a cursor-update
//  event when the pointer is over the window: a WindowServer round trip and
//  a hit test per output chunk of a program that hides its cursor to
//  repaint. These hold that a hide-and-show cycle, and the cursor moving out
//  of and back into the visible rows, invalidate nothing.
//
#if os(macOS)
import AppKit
import XCTest
@testable import SwiftTerm

final class CaretChurnTests: XCTestCase {
    /// A window that counts what asks it to rebuild its cursor rects.
    private final class CountingWindow: NSWindow {
        var invalidations: [String] = []
        override func invalidateCursorRects(for view: NSView) {
            invalidations.append(String(describing: type(of: view)))
            super.invalidateCursorRects(for: view)
        }
    }

    private func makeView () -> (CountingWindow, TerminalView) {
        _ = NSApplication.shared
        var options = TerminalOptions.default
        options.cols = 40
        options.rows = 4
        let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        let view = TerminalView(frame: NSRect(x: 0, y: 0, width: 400, height: 80),
                                font: font, options: options)
        let window = CountingWindow(contentRect: view.frame, styleMask: [.titled],
                                    backing: .buffered, defer: false)
        window.contentView = view
        window.invalidations = []
        return (window, view)
    }

    private func feed (_ view: TerminalView, _ text: String) {
        view.feed(byteArray: ArraySlice(Array(text.utf8)))
    }

    func testHidingAndShowingTheCursorInvalidatesNoCursorRects () {
        let (window, view) = makeView()
        let caret = try! XCTUnwrap(view.caretView)
        XCTAssertTrue(caret.superview === view, "the caret is in the tree from birth")
        XCTAssertFalse(caret.isHidden)

        for _ in 0..<20 {
            feed(view, "\u{1b}[?25l")
            XCTAssertTrue(caret.isHidden, "?25l hides the caret")
            XCTAssertTrue(caret.superview === view, "and it stays in the tree")
            feed(view, "redraw\r\n\u{1b}[?25h")
            XCTAssertFalse(caret.isHidden, "?25h shows it again")
            XCTAssertTrue(caret.superview === view)
        }
        XCTAssertEqual(window.invalidations, [],
                       "a hide-and-show cycle asks the window for nothing")
    }

    func testTheCaretScrolledOutOfViewIsHiddenInPlace () {
        let (window, view) = makeView()
        let caret = try! XCTUnwrap(view.caretView)
        // Six rows into a four-row screen, then scroll the view up so the
        // cursor's row is below the visible ones.
        feed(view, "a\r\nb\r\nc\r\nd\r\ne\r\nf")
        view.scrollUp(lines: 2)
        view.updateCursorPosition()
        XCTAssertTrue(caret.isHidden, "a caret below the visible rows is hidden")
        XCTAssertTrue(caret.superview === view)

        view.scrollDown(lines: 2)
        view.updateCursorPosition()
        XCTAssertFalse(caret.isHidden, "and shown again once its row is back")
        XCTAssertEqual(window.invalidations, [])
    }
}
#endif
