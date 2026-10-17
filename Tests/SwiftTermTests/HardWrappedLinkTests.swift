//
//  HardWrappedLinkTests.swift
//
//  A program that wraps its own output (claude draws every row itself) breaks
//  a long link over rows that carry no wrap flag. The rows join when the upper
//  one is full, which is what a break inside a word leaves behind, and not
//  when it stops short, which is a break at a space with the next word under
//  it. Rows are 48 wide, the panel's width; the shapes are claude's, measured
//  2026-10-16.
//
import Foundation
import XCTest

@testable import SwiftTerm

final class HardWrappedLinkTests: XCTestCase {
    private final class Silent: TerminalDelegate {
        func send(source: Terminal, data: ArraySlice<UInt8>) {}
    }
    private let silent = Silent()

    private func terminal(_ rows: [String]) -> Terminal {
        var options = TerminalOptions.default
        options.cols = 48
        options.rows = 12
        let t = Terminal(delegate: silent, options: options)
        t.feed(text: rows.joined(separator: "\r\n"))
        return t
    }

    /// Each row's links at rest, as the text each one opens.
    private func links(_ rows: [String]) -> [Int: [String]] {
        terminal(rows).implicitLinkHits(startRow: 0, endRow: 11).mapValues { $0.map(\.text) }
    }

    /// claude's echo of your message: 47 columns of text, then one of its
    /// background, so the row is written out to the edge with a blank.
    private func echoRow(_ text: String) -> String {
        "\u{1b}[48;5;236m" + text.padding(toLength: 48, withPad: " ", startingAt: 0) + "\u{1b}[0m"
    }

    func testAUrlBrokenInsideYourEchoedMessageIsOneLink() {
        let url = "http://127.0.0.1:8765/glitches.html?layout#layout"
        let found = links([
            echoRow("❯ [Image #26] (snap · http://127.0.0.1:8765/gli"),
            echoRow("  tches.html?layout#layout)"),
        ])
        XCTAssertEqual(found[0], [url])
        XCTAssertEqual(found[1], [url])
    }

    func testAUrlOverThreeEchoedRowsIsOneLink() {
        let url = "https://example.com/one/two/three/four/five/six/seven/eight/nine/ten/eleven"
        let found = links([
            echoRow("❯ see https://example.com/one/two/three/four/fi"),
            echoRow("  ve/six/seven/eight/nine/ten/eleven"),
        ].flatMap { [$0] })
        XCTAssertEqual(found[0], [url])
        XCTAssertEqual(found[1], [url])
        let longer = "https://example.com/" + String(repeating: "abcdefghij/", count: 8)
        let rows = [
            echoRow("❯ " + String(longer.prefix(45))),
            echoRow("  " + String(longer.dropFirst(45).prefix(45))),
            echoRow("  " + String(longer.dropFirst(90))),
        ]
        let three = links(rows)
        XCTAssertEqual(three[0], [longer])
        XCTAssertEqual(three[1], [longer])
        XCTAssertEqual(three[2], [longer])
    }

    func testAUrlBrokenAtTheEdgeOfAReplyIsOneLink() {
        let url = "https://example.com/alpha/beta/gamma/delta/epsilon/zeta/eta/theta"
        let found = links([
            "⏺ The page you want lives at",
            "  https://example.com/alpha/beta/gamma/delta/eps",
            "  ilon/zeta/eta/theta, so open it whenever",
        ])
        XCTAssertEqual(found[1], [url])
        XCTAssertEqual(found[2], [url])
    }

    /// A row that stops short of the edge was broken at a space: what starts
    /// the next row is a word, and the link ends where it ended.
    func testTheWordUnderAUrlThatStopsShortIsNotPartOfIt() {
        let found = links([
            "⏺ Open https://example.com/abc/def/ghi/jklm",
            "  and then reload the page.",
        ])
        XCTAssertEqual(found[0], ["https://example.com/abc/def/ghi/jklm"])
        XCTAssertNil(found[1])
        // One column short, and the row not written out to the edge.
        let short = links([
            "⏺ Open it at https://example.com/abc/def/ghi/jk",
            "  and then reload the page.",
        ])
        XCTAssertEqual(short[0], ["https://example.com/abc/def/ghi/jk"])
        XCTAssertNil(short[1])
    }

    /// The space between two links is where a wrapper breaks the row.
    func testARowThatBeginsWithASchemeBeginsItsOwnLink() {
        let found = links([
            "  https://example.com/abc/def/ghi/jklmnopqrstuv",
            "  https://other.com/x for the rest.",
        ])
        XCTAssertEqual(found[0], ["https://example.com/abc/def/ghi/jklmnopqrstuv"])
        XCTAssertEqual(found[1], ["https://other.com/x"])
    }

    /// The pointer and the click read the same link as the scan at rest,
    /// from either row.
    func testHoverAndClickReadTheWholeLinkFromEitherRow() {
        let url = "http://127.0.0.1:8765/glitches.html?layout#layout"
        let t = terminal([
            echoRow("❯ [Image #26] (snap · http://127.0.0.1:8765/gli"),
            echoRow("  tches.html?layout#layout)"),
        ])
        XCTAssertEqual(t.link(at: .buffer(Position(col: 30, row: 0)), mode: .explicitAndImplicit), url)
        XCTAssertEqual(t.link(at: .buffer(Position(col: 5, row: 1)), mode: .explicitAndImplicit), url)
        // The padding at the edge is not part of the link.
        XCTAssertNil(t.link(at: .buffer(Position(col: 47, row: 0)), mode: .explicitAndImplicit))
    }

    /// A wrapper that breaks after a link's own `/` stops the row short and
    /// still continues the link, when what follows reads as more of it.
    func testABreakAfterASlashJoinsMoreLinkButNotAWord() {
        let found = links([
            "⏺ docs: https://example.com/abc/def/ghijk/",
            "  jkl/mno.html for it",
        ])
        XCTAssertEqual(found[0], ["https://example.com/abc/def/ghijk/jkl/mno.html"])
        let word = links([
            "⏺ docs: https://example.com/abc/def/ghijk/",
            "  and then reload.",
        ])
        XCTAssertEqual(word[0], ["https://example.com/abc/def/ghijk/"])
        XCTAssertNil(word[1])
    }

    /// A sentence that ends on a link is often followed by a filename, so a
    /// short row's closing `.` ends the link.
    func testAFilenameAfterASentenceEndingOnALinkIsItsOwn() {
        let found = links([
            "⏺ Docs live at https://example.com/docs/guide.",
            "  README.md explains the rest.",
        ])
        XCTAssertEqual(found[0], ["https://example.com/docs/guide"])
    }

    /// A url carried in another url's query goes on past a full row that
    /// stops on the `=`.
    func testAUrlInsideAQueryJoinsOverTheRow() {
        let found = links([
            "  https://a.example.com/login?next=abcdefghijk=",
            "https://b.example.com/cb",
        ])
        XCTAssertEqual(found[0], ["https://a.example.com/login?next=abcdefghijk=https://b.example.com/cb"])
    }

    /// Where claude breaks a long url is not the edge: a tool result wraps
    /// five columns in, and its own wrapper leaves a column or two (all
    /// three measured at 48 columns, 2026-10-17). A short row joins onto
    /// what reads as more link.
    func testAUrlClaudeBreaksShortOfTheEdgeIsOneLink() {
        let url = "https://claude.ai/artifact/PBRDQWn8Aiqt5dWb5tXsmp"
        let tool = links([
            "  ⎿  Updated https://claude.ai/artifact/PBR",
            "     DQWn8Aiqt5dWb5tXsmp",
        ])
        XCTAssertEqual(tool[0], [url])
        XCTAssertEqual(tool[1], [url])
        let reply = links([
            "  called logo patches: ⧉ https://claude.ai/ar",
            "  tifact/PBRDQWn8Aiqt5dWb5tXsmp",
        ])
        XCTAssertEqual(reply[0], [url])
        XCTAssertEqual(reply[1], [url])
        let echo = links([
            echoRow("  new page called logo patches: X https://clau"),
            echoRow("  de.ai/artifact/PBRDQWn8Aiqt5dWb5tXsmp"),
        ])
        XCTAssertEqual(echo[0], [url])
        XCTAssertEqual(echo[1], [url])
    }

    /// A word of prose under a short row is the next word, capitalised or
    /// with an apostrophe in it.
    func testProseUnderAShortRowIsNotPartOfTheLink() {
        for word in ["Then reload it.", "don't reload it.", "well-known."] {
            let found = links([
                "⏺ It is at https://example.com/docs/intro/abc",
                "  " + word,
            ])
            XCTAssertEqual(found[0], ["https://example.com/docs/intro/abc"], word)
            XCTAssertNil(found[1], word)
        }
    }
}
