//
//  BackgroundOverrideTests.swift
//
//  `backgroundColorOverrides` draws a background the program named in one
//  colour in another, alpha included, and only backgrounds. These hold that
//  the substitution reaches the drawn attributes, leaves every other colour
//  alone, and that setting it and clearing it both reach the pixels.
//
#if os(macOS)
import AppKit
import XCTest
@testable import SwiftTerm

final class BackgroundOverrideTests: XCTestCase {
    private let grey = Attribute.Color.ansi256(code: 237)
    private let veil = NSColor(white: 1, alpha: 0.5)

    private func makeView () -> TerminalView {
        _ = NSApplication.shared
        var options = TerminalOptions.default
        options.cols = 40
        options.rows = 4
        let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        let view = TerminalView(frame: NSRect(x: 0, y: 0, width: 400, height: 80),
                                font: font, options: options)
        view.feed(byteArray: ArraySlice(Array("\u{1b}[48;5;237m echoed \u{1b}[49m plain \u{1b}[48;5;16m black \u{1b}[49m\r\n".utf8)))
        return view
    }

    private func pixels (of view: TerminalView) -> Data {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return Data() }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let bytes = rep.bitmapData else { return Data() }
        return Data(bytes: bytes, count: rep.bytesPerRow * rep.pixelsHigh)
    }

    func testTheNamedBackgroundIsDrawnInTheOverrideAndNothingElseMoves () {
        let view = makeView()
        let greyAttr = Attribute(fg: .defaultColor, bg: grey, style: [])
        let blackAttr = Attribute(fg: .defaultColor, bg: .ansi256(code: 16), style: [])
        let greyAsFg = Attribute(fg: grey, bg: .defaultColor, style: [])
        let before = view.getAttributes(greyAttr, withUrl: false)?[.backgroundColor] as? NSColor

        view.backgroundColorOverrides = [grey: veil]
        XCTAssertEqual(view.getAttributes(greyAttr, withUrl: false)?[.backgroundColor] as? NSColor, veil)
        XCTAssertEqual(view.getAttributes(blackAttr, withUrl: false)?[.backgroundColor] as? NSColor,
                       view.mapColor(color: .ansi256(code: 16), isFg: false, isBold: false),
                       "a background that was not named keeps its colour")
        XCTAssertNotEqual(view.getAttributes(greyAsFg, withUrl: false)?[.foregroundColor] as? NSColor, veil,
                          "the same colour as a foreground is not touched")

        view.backgroundColorOverrides = [:]
        XCTAssertEqual(view.getAttributes(greyAttr, withUrl: false)?[.backgroundColor] as? NSColor, before,
                       "clearing the override restores the program's colour")
    }

    func testTheOverrideReachesThePixelsBothWays () {
        let view = makeView()
        let atRest = pixels(of: view)
        view.backgroundColorOverrides = [grey: veil]
        let veiled = pixels(of: view)
        XCTAssertNotEqual(atRest, veiled, "the override must change what is drawn")
        view.backgroundColorOverrides = [:]
        XCTAssertEqual(pixels(of: view), atRest, "and clearing it must draw what was there")
    }
}
#endif
