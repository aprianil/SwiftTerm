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

#if os(macOS)
final class BackgroundRuleTests: XCTestCase {
    private let grey = Attribute.Color.ansi256(code: 237)

    private func makeView () -> TerminalView {
        _ = NSApplication.shared
        var options = TerminalOptions.default
        options.cols = 40
        options.rows = 4
        let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        let view = TerminalView(frame: NSRect(x: 0, y: 0, width: 400, height: 80),
                                font: font, options: options)
        view.nativeBackgroundColor = .black
        view.feed(byteArray: ArraySlice(Array("\u{1b}[48;5;237m echoed words                    \u{1b}[49m\r\nplain row\r\n".utf8)))
        return view
    }

    private func bitmap (of view: TerminalView) -> NSBitmapImageRep {
        let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep
    }

    func testTheRuleIsDrawnAtTheLeftOfTheNamedRowsOnly () {
        let view = makeView()
        let cell = view.cellDimension!
        let before = bitmap(of: view)
        view.backgroundRules = [grey: .red]
        view.backgroundRuleWidth = 2
        let after = bitmap(of: view)
        let scale = CGFloat(after.pixelsWide) / view.bounds.width
        // The block is row 0, at the top; the bitmap's origin is its top-left.
        let ruleX = Int(1 * scale)
        let ruleY = Int(cell.height * 0.5 * scale)
        let plainY = Int(cell.height * 1.5 * scale)
        let redAfter = after.colorAt(x: ruleX, y: ruleY)!
        XCTAssertGreaterThan(redAfter.redComponent, 0.9, "the rule is red at the block's left edge")
        XCTAssertLessThan(redAfter.greenComponent, 0.1)
        let redBefore = before.colorAt(x: ruleX, y: ruleY)!
        XCTAssertLessThan(redBefore.redComponent, 0.5, "and was not there before")
        let plain = after.colorAt(x: ruleX, y: plainY)!
        XCTAssertLessThan(plain.redComponent, 0.5, "a row without the background has no rule")
        // Past the rule's width the fill is the block's own grey, not red.
        let pastRule = after.colorAt(x: Int(cell.width * 0.8 * scale), y: ruleY)!
        XCTAssertLessThan(pastRule.redComponent, 0.5)
    }

    func testTheRuleComposesWithTheOverride () {
        let view = makeView()
        view.backgroundColorOverrides = [grey: NSColor(white: 0, alpha: 0.5)]
        view.backgroundRules = [grey: .red]
        let cell = view.cellDimension!
        let after = bitmap(of: view)
        let scale = CGFloat(after.pixelsWide) / view.bounds.width
        let rule = after.colorAt(x: Int(1 * scale), y: Int(cell.height * 0.5 * scale))!
        XCTAssertGreaterThan(rule.redComponent, 0.9, "the rule keys on the colour the program named, not the one drawn")
    }
}
#endif

#if os(macOS)
final class BackgroundBlockPaddingTests: XCTestCase {
    private let grey = Attribute.Color.ansi256(code: 237)

    /// Row 0 blank, row 1 the block, row 2 blank, row 3 text.
    private func makeView (rowAbove: String = "") -> TerminalView {
        _ = NSApplication.shared
        var options = TerminalOptions.default
        options.cols = 40
        options.rows = 5
        let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        let view = TerminalView(frame: NSRect(x: 0, y: 0, width: 400, height: 100),
                                font: font, options: options)
        view.nativeBackgroundColor = .black
        view.backgroundColorOverrides = [grey: .blue]
        view.backgroundRules = [grey: .red]
        view.backgroundRuleWidth = 2
        view.feed(byteArray: ArraySlice(Array("\(rowAbove)\r\n\u{1b}[48;5;237m echoed words                    \u{1b}[49m\r\n\r\ntext\r\n".utf8)))
        return view
    }

    private func bitmap (of view: TerminalView) -> NSBitmapImageRep {
        let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep
    }

    func testABlankNeighbourLendsTheBlockItsPadding () {
        let view = makeView()
        let cell = view.cellDimension!
        let scale = CGFloat(bitmap(of: view).pixelsWide) / view.bounds.width
        let midX = Int(cell.width * 10 * scale)
        let ruleX = Int(1 * scale)
        // Two points into the blank row above the block, and two into the one below.
        let aboveY = Int((cell.height * 1 - 2) * scale)
        let belowY = Int((cell.height * 2 + 2) * scale)

        let bare = bitmap(of: view)
        XCTAssertLessThan(bare.colorAt(x: midX, y: aboveY)!.blueComponent, 0.5, "no padding by default")
        XCTAssertLessThan(bare.colorAt(x: midX, y: belowY)!.blueComponent, 0.5)

        view.backgroundBlockPadding = 6
        let padded = bitmap(of: view)
        XCTAssertGreaterThan(padded.colorAt(x: midX, y: aboveY)!.blueComponent, 0.9, "the fill reaches into the blank row above")
        XCTAssertGreaterThan(padded.colorAt(x: midX, y: belowY)!.blueComponent, 0.9, "and into the one below")
        XCTAssertGreaterThan(padded.colorAt(x: ruleX, y: aboveY)!.redComponent, 0.9, "the rule comes with it")
        XCTAssertGreaterThan(padded.colorAt(x: ruleX, y: belowY)!.redComponent, 0.9)
        // Beyond the padding the blank row is still blank.
        let farY = Int((cell.height * 2 + 6 + 3) * scale)
        XCTAssertLessThan(padded.colorAt(x: midX, y: farY)!.blueComponent, 0.5)
        // And the words' own row is untouched: still the fill, no red past the rule.
        let wordsY = Int((cell.height * 1.5) * scale)
        XCTAssertGreaterThan(padded.colorAt(x: midX, y: wordsY)!.blueComponent, 0.9)
    }

    func testANeighbourWithContentLendsNothing () {
        let view = makeView(rowAbove: "a line of text above")
        view.backgroundBlockPadding = 6
        let cell = view.cellDimension!
        let rep = bitmap(of: view)
        let scale = CGFloat(rep.pixelsWide) / view.bounds.width
        let aboveY = Int((cell.height * 1 - 2) * scale)
        let belowY = Int((cell.height * 2 + 2) * scale)
        let midX = Int(cell.width * 30 * scale)
        XCTAssertLessThan(rep.colorAt(x: midX, y: aboveY)!.blueComponent, 0.5, "a row with words on it is not drawn over")
        XCTAssertGreaterThan(rep.colorAt(x: midX, y: belowY)!.blueComponent, 0.9, "the blank row below still lends")
    }
}
#endif
