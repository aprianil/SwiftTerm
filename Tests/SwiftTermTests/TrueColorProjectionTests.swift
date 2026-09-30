//
//  TrueColorProjectionTests.swift
//
//  `trueColorProjection` draws every truecolor the program names, foreground
//  and background, through the embedder's function, and nothing else: the
//  palette, the default pair and an override keep their colours.
//
#if os(macOS)
import AppKit
import XCTest
@testable import SwiftTerm

final class TrueColorProjectionTests: XCTestCase {
    private let marked = NSColor(srgbRed: 0.1, green: 0.2, blue: 0.3, alpha: 1)

    private func makeView () -> TerminalView {
        _ = NSApplication.shared
        var options = TerminalOptions.default
        options.cols = 40
        options.rows = 4
        let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        let view = TerminalView(frame: NSRect(x: 0, y: 0, width: 400, height: 80),
                                font: font, options: options)
        view.feed(byteArray: ArraySlice(Array("\u{1b}[38;2;215;119;87;48;2;34;92;43m diff \u{1b}[0m \u{1b}[31m red \u{1b}[0m\r\n".utf8)))
        return view
    }

    private func pixels (of view: TerminalView) -> Data {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return Data() }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let bytes = rep.bitmapData else { return Data() }
        return Data(bytes: bytes, count: rep.bytesPerRow * rep.pixelsHigh)
    }

    func testTrueColoursAreProjectedAndNothingElse () {
        let view = makeView()
        var seen: [(NSColor, Bool)] = []
        view.trueColorProjection = { color, fg in seen.append((color, fg)); return self.marked }
        let orange = Attribute.Color.trueColor(red: 215, green: 119, blue: 87)
        let fill = Attribute.Color.trueColor(red: 34, green: 92, blue: 43)
        XCTAssertEqual(view.mapColor(color: orange, isFg: true, isBold: false), marked)
        XCTAssertEqual(view.mapColor(color: fill, isFg: false, isBold: false), marked)
        XCTAssertNotEqual(view.mapColor(color: .ansi256(code: 1), isFg: true, isBold: false), marked,
                          "a palette colour is the palette's")
        XCTAssertNotEqual(view.mapColor(color: .defaultColor, isFg: true, isBold: false), marked)
        XCTAssertEqual(Set(seen.map(\.1)), [true, false], "both sides pass, and say which")

        let count = seen.count
        _ = view.mapColor(color: orange, isFg: true, isBold: false)
        XCTAssertEqual(seen.count, count, "once per distinct colour")

        view.backgroundColorOverrides = [fill: NSColor.red]
        XCTAssertEqual(view.mapColor(color: fill, isFg: false, isBold: false), NSColor.red, "an override wins")
    }

    func testTheProjectionReachesThePixelsBothWays () {
        let view = makeView()
        let atRest = pixels(of: view)
        view.trueColorProjection = { _, _ in self.marked }
        XCTAssertNotEqual(atRest, pixels(of: view))
        view.trueColorProjection = nil
        XCTAssertEqual(pixels(of: view), atRest)
    }
}
#endif
