//
//  ForegroundOverrideTests.swift
//
//  `foregroundColorOverrides` draws a foreground the program named in one
//  colour in another, whatever the palette resolves that colour to, and only
//  foregrounds. These hold that the substitution reaches the drawn
//  attributes, beats `foregroundRetone`, leaves every other colour alone,
//  and that setting it and clearing it both reach the pixels.
//
#if os(macOS)
import AppKit
import XCTest
@testable import SwiftTerm

final class ForegroundOverrideTests: XCTestCase {
    private let orange = Attribute.Color.ansi256(code: 174)
    private let warm = NSColor(srgbRed: 0.65, green: 0.36, blue: 0, alpha: 1)

    private func makeView () -> TerminalView {
        _ = NSApplication.shared
        var options = TerminalOptions.default
        options.cols = 40
        options.rows = 4
        let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        let view = TerminalView(frame: NSRect(x: 0, y: 0, width: 400, height: 80),
                                font: font, options: options)
        view.feed(byteArray: ArraySlice(Array("\u{1b}[38;5;174m \u{2590}\u{259b}\u{2588}\u{2588}\u{2588}\u{259c}\u{258c}\u{1b}[39m plain\r\n".utf8)))
        return view
    }

    private func pixels (of view: TerminalView) -> Data {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return Data() }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let bytes = rep.bitmapData else { return Data() }
        return Data(bytes: bytes, count: rep.bytesPerRow * rep.pixelsHigh)
    }

    func testTheNamedForegroundIsDrawnInTheOverrideAndNothingElseMoves () {
        let view = makeView()
        let named = Attribute(fg: orange, bg: .defaultColor, style: [])
        let other = Attribute(fg: .ansi256(code: 173), bg: .defaultColor, style: [])
        let asBackground = Attribute(fg: .defaultColor, bg: orange, style: [])
        let before = view.getAttributes(named, withUrl: false)?[.foregroundColor] as? NSColor

        view.foregroundColorOverrides = [orange: warm]
        XCTAssertEqual(view.getAttributes(named, withUrl: false)?[.foregroundColor] as? NSColor, warm)
        XCTAssertNotEqual(view.getAttributes(other, withUrl: false)?[.foregroundColor] as? NSColor, warm,
                          "a foreground that was not named keeps its colour")
        XCTAssertNotEqual(view.getAttributes(asBackground, withUrl: false)?[.backgroundColor] as? NSColor, warm,
                          "the same colour as a background is not touched")

        view.foregroundRetone = { _ in NSColor.red }
        XCTAssertEqual(view.getAttributes(named, withUrl: false)?[.foregroundColor] as? NSColor, warm,
                       "the override wins over the re-tone")
        view.foregroundRetone = nil

        view.foregroundColorOverrides = [:]
        XCTAssertEqual(view.getAttributes(named, withUrl: false)?[.foregroundColor] as? NSColor, before,
                       "clearing the override restores the program's colour")
    }

    func testTheOverrideReachesThePixelsBothWaysBlockElementsIncluded () {
        let view = makeView()
        let atRest = pixels(of: view)
        view.foregroundColorOverrides = [orange: warm]
        XCTAssertNotEqual(atRest, pixels(of: view), "the override must change what is drawn")
        view.foregroundColorOverrides = [:]
        XCTAssertEqual(pixels(of: view), atRest, "and clearing it must draw what was there")
    }
}
#endif
