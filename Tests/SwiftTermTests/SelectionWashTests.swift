//
//  SelectionWashTests.swift
//
//  The selection's wash, kept while a program that does not read the
//  mouse writes more output.
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
}
#endif
