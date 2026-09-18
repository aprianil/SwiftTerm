//
//  ImplicitLinkCacheTests.swift
//
//  The implicit-link scan remembers each group against the lines it read, so a
//  screen where one row changed re-runs the regex for that row's group and
//  compares pointers for the rest. Like the row render cache, its one
//  requirement is that it be invisible: every test here drives a screen through
//  a series of single-row edits and demands that the remembered answer equals
//  the answer a terminal that has never scanned before gives for the same
//  bytes.
//
//  The comparison terminal is built by replaying the same feed, so nothing in
//  the production path is opened up for the test to poke at.
//
import Foundation
import XCTest

@testable import SwiftTerm

final class ImplicitLinkCacheTests: XCTestCase {
    private final class Silent: TerminalDelegate {
        func send(source: Terminal, data: ArraySlice<UInt8>) {}
    }

    private let silent = Silent()
    private static let cols = 48
    private static let rows = 20

    private func makeTerminal() -> Terminal {
        var options = TerminalOptions.default
        options.cols = Self.cols
        options.rows = Self.rows
        options.scrollback = 200
        return Terminal(delegate: silent, options: options)
    }

    /// Put `text` on `row` and clear the rest of it, the way a full-screen
    /// program repaints one line.
    private func rewrite(_ row: Int, _ text: String) -> String {
        "\u{1b}[\(row + 1);1H\u{1b}[2K" + text
    }

    /// Drive one screen through its edits, checking after every one that the
    /// cached answer is the answer from scratch. Checked twice per step: over
    /// the visible window, which is what a view asks for, and over the whole
    /// buffer, which mixes cached anchors with ones this terminal has never
    /// seen.
    private func assertTheCacheIsInvisible(_ steps: [String], _ label: String,
                                           file: StaticString = #filePath, line: UInt = #line) {
        let live = makeTerminal()
        var applied: [String] = []
        for (index, step) in steps.enumerated() {
            live.feed(text: step)
            applied.append(step)

            let fresh = makeTerminal()
            for earlier in applied { fresh.feed(text: earlier) }

            let top = live.displayBuffer.yDisp
            XCTAssertEqual(top, fresh.displayBuffer.yDisp,
                           "\(label) step \(index): the two terminals are not on the same screen",
                           file: file, line: line)

            let visibleCached = live.implicitLinkRanges(startRow: top, endRow: top + live.rows - 1)
            let visibleFresh = fresh.implicitLinkRanges(startRow: top, endRow: top + fresh.rows - 1)
            XCTAssertEqual(visibleCached, visibleFresh,
                           "\(label) step \(index): the visible screen came back stale",
                           file: file, line: line)

            let wholeCached = live.implicitLinkRanges(startRow: 0,
                                                      endRow: live.displayBuffer.lines.count - 1)
            let wholeFresh = fresh.implicitLinkRanges(startRow: 0,
                                                      endRow: fresh.displayBuffer.lines.count - 1)
            XCTAssertEqual(wholeCached, wholeFresh,
                           "\(label) step \(index): the buffer came back stale",
                           file: file, line: line)
        }
    }

    /// A coding agent's screen: timestamps, `key: value` lines and file paths
    /// with a line number on the end. Every one of those rows holds a colon, so
    /// every one of them is a group the scan has to build and regex, which is
    /// what made a full rescan per repaint cost 20 to 30 ms.
    private static let claudeScreen: [String] = [
        "> can you look at the pane switch",
        "",
        "  I read Sources/sidealong/TerminalPane.swift:802",
        "  and Sources/sidealong/AppDelegate.swift:487",
        "",
        "  [2026-09-18 07:04:49.368] app pane shows 3f2a",
        "  [2026-09-18 07:04:49.412] app attach paint: 9.7 ms",
        "  status: running   model: opus   effort: high",
        "  branch: automatic-workspaces   ahead: 4",
        "  docs/decisions/20-session-grid.md:118 has the note",
        "  see https://developer.apple.com/documentation/appkit",
        "",
        "  ctrl-c: interrupt   esc: back   ?: help",
    ]

    func testAClaudeShapedScreenSurvivesSingleRowEdits() {
        var steps: [String] = [Self.claudeScreen.joined(separator: "\r\n")]
        // The spinner row, rewritten over and over, which is the case the cache
        // exists for.
        for frame in ["⠋", "⠙", "⠹", "⠸"] {
            steps.append(rewrite(1, "  \(frame) Thinking: reading the pane"))
        }
        // A path row gaining and losing a link.
        steps.append(rewrite(2, "  I read Sources/sidealong/SplitTerminalView.swift:209"))
        steps.append(rewrite(2, "  I read nothing at all"))
        // A row that never held a colon growing one.
        steps.append(rewrite(1, "  plain prose with no punctuation of note"))
        steps.append(rewrite(1, "  now with a path: Package.swift:16 on it"))
        // The row under a link, which is the probe row a group walks onto and
        // rejects: a cache that did not watch it would miss this.
        steps.append(rewrite(11, "https://developer.apple.com/documentation/appkit/nsview"))
        steps.append(rewrite(11, ""))
        assertTheCacheIsInvisible(steps, "claude screen")
    }

    /// A url too long for the row, so the buffer wraps it and the group walks
    /// through `isWrapped` rather than the seam heuristic. The edits grow and
    /// shrink the wrap, which moves the group's last row.
    func testAWrappedUrlSurvivesEditsAtBothEnds() {
        let long = "https://developer.apple.com/documentation/appkit/nsview/1483329-hittest"
            + "/and/some/more/path/to/push/it/over/three/rows/of/this/terminal"
        var steps: [String] = ["intro line\r\n" + long + "\r\ntail line\r\n"]
        steps.append(rewrite(0, "intro line rewritten"))
        steps.append(rewrite(0, "intro line rewritten with a path: Sources/x.swift:1"))
        // The row after the wrap, which the forward walk reads and rejects.
        steps.append(rewrite(5, "tail line with its own https://example.com"))
        steps.append(rewrite(5, "tail"))
        assertTheCacheIsInvisible(steps, "wrapped url")
    }

    /// Output scrolling under the screen: every line keeps its content and
    /// changes its index, which is the case a cache that spoke in absolute rows
    /// would throw itself away on.
    func testScrollingKeepsTheAnswerRight() {
        var steps: [String] = [Self.claudeScreen.joined(separator: "\r\n") + "\r\n"]
        for row in 0..<30 {
            steps.append("  streamed row \(row) at Sources/sidealong/File\(row).swift:\(row)\r\n")
        }
        assertTheCacheIsInvisible(steps, "scrolling output")
    }

    /// Prose with no colon in it never reaches the regex at all, and the rows
    /// that do are the ones the gate lets through. Both paths are cached, so
    /// both have to come back right.
    func testAScreenWithNoLinksStaysEmpty() {
        var steps: [String] = ["the quick brown fox jumps over the lazy dog\r\n"
                               + "and then it does it again, at some length\r\n"]
        steps.append(rewrite(0, "still nothing here"))
        steps.append(rewrite(0, "now: a colon, but no link"))
        assertTheCacheIsInvisible(steps, "no links")

        let terminal = makeTerminal()
        terminal.feed(text: "the quick brown fox jumps over the lazy dog\r\n")
        let top = terminal.displayBuffer.yDisp
        XCTAssertTrue(terminal.implicitLinkRanges(startRow: top, endRow: top + terminal.rows - 1).isEmpty)
    }

    /// **The bottom of the buffer, where the row below does not exist yet.**
    ///
    /// A url broken by the program rather than by the terminal ends a row
    /// within a few cells of the right edge and on a character a url can
    /// continue with, and the row under it carries the rest. The group walk
    /// looks for that row. On the screen's LAST row there is nothing to look
    /// at, and the answer is "this link is one row long"; one line of output
    /// later the screen has scrolled, the continuation is there, and nothing
    /// about the row itself has changed to say so. The line the cache has to
    /// watch is the one that was not there. Found in review, 2026-09-18.
    ///
    /// The filler is what puts the url on the last line: a buffer always holds
    /// a whole screen, so a url typed into the middle of one has blank rows
    /// under it that the walk reads and remembers, and a cache that only
    /// watches the rows it read is right about that case by luck.
    func testAGroupAtTheBottomJoinsTheRowThatArrivesUnderIt() {
        // 47 columns of 48, so the terminal does not wrap it, ending past the
        // continuation threshold (cols - cols / 5 = 39) on a character a url
        // can go on with.
        let upper = "see https://apple.com/documentation/appkit/nsv-"
        XCTAssertEqual(upper.count, 47, "one column short of the width, or the terminal wraps it")
        var steps: [String] = [String(repeating: "a line of output\r\n", count: Self.rows - 1) + upper]
        // The continuation, one line of output later: the newline scrolls the
        // screen, which is what makes a row under the url exist at all.
        steps.append("\r\nhittest and then some words")
        steps.append(rewrite(Self.rows - 1, "and the continuation rewritten away"))
        assertTheCacheIsInvisible(steps, "bottom seam")
    }

    /// A resize rewrites what a row is, so everything measured at the old width
    /// has to go.
    func testAResizeThrowsTheCacheAway() {
        let terminal = makeTerminal()
        terminal.feed(text: Self.claudeScreen.joined(separator: "\r\n"))
        let top = terminal.displayBuffer.yDisp
        _ = terminal.implicitLinkRanges(startRow: top, endRow: top + terminal.rows - 1)

        terminal.resize(cols: 80, rows: Self.rows)
        let afterResize = terminal.implicitLinkRanges(startRow: terminal.displayBuffer.yDisp,
                                                      endRow: terminal.displayBuffer.yDisp + terminal.rows - 1)

        var options = TerminalOptions.default
        options.cols = 80
        options.rows = Self.rows
        options.scrollback = 200
        let fresh = Terminal(delegate: silent, options: options)
        fresh.feed(text: Self.claudeScreen.joined(separator: "\r\n"))
        let expected = fresh.implicitLinkRanges(startRow: fresh.displayBuffer.yDisp,
                                                endRow: fresh.displayBuffer.yDisp + fresh.rows - 1)
        XCTAssertEqual(afterResize, expected, "the cache survived a resize it cannot describe")
    }

    /// The point of the thing, in a number: repainting one row of a screen full
    /// of colons costs a fraction of what the screen costs cold.
    func testARepaintCostsAFractionOfAColdScan() {
        let terminal = makeTerminal()
        terminal.feed(text: Self.claudeScreen.joined(separator: "\r\n"))
        let top = terminal.displayBuffer.yDisp
        let bottom = top + terminal.rows - 1

        let cold = CFAbsoluteTimeGetCurrent()
        _ = terminal.implicitLinkRanges(startRow: top, endRow: bottom)
        let coldMs = (CFAbsoluteTimeGetCurrent() - cold) * 1000

        var warm: [Double] = []
        for frame in 0..<20 {
            terminal.feed(text: rewrite(1, "  frame \(frame) of a spinner"))
            let started = CFAbsoluteTimeGetCurrent()
            _ = terminal.implicitLinkRanges(startRow: top, endRow: bottom)
            warm.append((CFAbsoluteTimeGetCurrent() - started) * 1000)
        }
        let median = warm.sorted()[warm.count / 2]
        print(String(format: "  implicit link scan: cold %.2f ms, one row repainted %.2f ms",
                     coldMs, median))
        XCTAssertLessThan(median, coldMs,
                          "a one-row repaint cost as much as the whole screen: the cache is not working")
    }
}
