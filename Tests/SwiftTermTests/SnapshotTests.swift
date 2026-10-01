//
//  SnapshotTests.swift
//
//  Terminal.snapshot writes a terminal out as a stream another terminal can
//  restore. The property under test: for a byte stream S cut at any offset
//  k, a fresh terminal fed snapshot(of the terminal fed S[0..<k]) and then
//  S[k...] is equal to a terminal fed S whole. Equal is Terminal.digest,
//  which hashes every field the snapshot carries.
//
//  What the snapshot does not carry, and the digest leaves out by name:
//    - images (sixel, kitty graphics, iTerm) and the kitty placement state.
//      The claude fixtures here emit none; a shell program that shows one
//      loses it on restore.
//    - OSC 133 prompt state. The fork stores it on lines (the marks and the
//      continuation group) but also per cell (the role), per buffer (the
//      prompt group, its origin line, the input state) and on the terminal
//      (the submission scanner), and the line marks mean nothing without
//      the rest. A restored shell prompt is clickable again from its next
//      prompt.
//    - a cell payload that is not an OSC 8 link string.
//    - view state: yDisp and userScrolling, selection, search.
//    - Buffer.linesTop (totalLinesTrimmed): a count of what the source
//      dropped, which a restored terminal never held.
//    - what the embedder owns: the installed palette and the ground and ink
//      it set (carried only once a program sets them), reportedFocusState.
//    - identity: grapheme cluster index codes and payload atom codes differ
//      between terminals, so the digest hashes what they stand for.
//    - a half-parsed sequence longer than 64 KiB, which is restored as
//      abandoned (testOversizedSequenceIsAbandoned).
//
import Foundation
import Testing

@testable import SwiftTerm

final class SnapshotTestDelegate: TerminalDelegate {
    var sends = 0

    func send(source: Terminal, data: ArraySlice<UInt8>) {
        sends += 1
    }
}

/// SplitMix64: the generated streams have to be the same on every run.
struct SnapshotRandom {
    var state: UInt64

    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }

    mutating func below(_ bound: Int) -> Int {
        Int(next() % UInt64(bound))
    }

    mutating func pick<T>(_ items: [T]) -> T {
        items[below(items.count)]
    }
}

struct SnapshotTests {
    struct Shape {
        var cols: Int
        var rows: Int
        var scrollback: Int?
    }

    static func makeTerminal(_ shape: Shape) -> (Terminal, SnapshotTestDelegate) {
        let delegate = SnapshotTestDelegate()
        let options = TerminalOptions(cols: shape.cols, rows: shape.rows, scrollback: shape.scrollback ?? 0)
        let terminal = Terminal(delegate: delegate, options: options)
        // Synchronized output ends by itself after a second, on the main
        // queue. A test that walks a stream one byte at a time sits inside a
        // frame for longer than that.
        terminal.synchronizedOutputTimeoutSeconds = 24 * 3600
        if shape.scrollback == nil {
            // The way an embedder turns scrollback off (sidealong's live half).
            terminal.changeScrollback(nil)
        }
        return (terminal, delegate)
    }

    /// The real claude streams, recorded by sidealong at its panel's size.
    static let claudeShape = Shape(cols: 48, rows: 37, scrollback: 500)

    static func fixtures() -> [(name: String, bytes: [UInt8])] {
        guard let directory = Bundle.module.url(forResource: "claude", withExtension: nil),
              let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else {
            return []
        }
        return files.filter { $0.pathExtension == "raw" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .compactMap { url in
                (try? Data(contentsOf: url)).map { (url.lastPathComponent, [UInt8]($0)) }
            }
    }

    // MARK: - Generated streams

    static let words = ["ls", "claude", "hello world", "x", "The quick brown fox", "0123456789", "~/Developer", "  ", "a b c"]
    static let wide = ["漢", "字", "🎉", "한", "✅"]
    static let clusters = ["e\u{301}", "👨\u{200D}👩\u{200D}👧", "❤\u{FE0F}", "🇩🇪", "👍🏽", "a\u{308}\u{301}", "✳"]

    /// A random mix of everything a snapshot has to carry: text of both
    /// widths, clusters, SGR, cursor moves, erases, inserts and deletes,
    /// scroll regions, the alternate screen, saved cursors, links, titles
    /// and modes.
    static func generatedStream(seed: UInt64, cols: Int, rows: Int) -> [UInt8] {
        var random = SnapshotRandom(state: seed)
        var text = ""
        let steps = 30 + random.below(50)
        for _ in 0..<steps {
            switch random.below(40) {
            case 0...8:
                text += random.pick(words)
            case 9, 10:
                text += random.pick(wide)
            case 11, 12:
                text += random.pick(clusters)
            case 13:
                if random.below(2) == 0 {
                    text += String(repeating: random.pick(["=", "漢", "ab"]), count: 1 + random.below(cols))
                } else {
                    for line in 0..<(4 + random.below(rows)) {
                        text += "line \(line)\r\n"
                    }
                }
            case 14, 15:
                text += random.pick(["\r\n", "\n", "\r", "\u{8}", "\t", "\n\n\n"])
            case 16...18:
                text += "\u{1b}[" + random.pick([
                    "0", "1", "2", "3", "4", "4:3", "4:5", "21", "5", "7", "8", "9", "22", "24", "27",
                    "31", "42", "93", "104", "38;5;196", "48;5;22", "38;2;10;200;30", "48;2;1;2;3",
                    "58;5;9", "58;2;9;8;7", "59", "39", "49", "1;4;38;5;33;48;2;40;40;40", "",
                ]) + "m"
            case 19, 20:
                text += "\u{1b}[\(1 + random.below(rows));\(1 + random.below(cols + 1))H"
            case 21:
                text += "\u{1b}[\(1 + random.below(4))" + random.pick(["A", "B", "C", "D", "E", "F", "G", "d"])
            case 22, 23:
                text += "\u{1b}[" + random.pick(["K", "1K", "2K", "J", "1J", "2J", "3J", "3X", "12X"])
            case 24:
                text += "\u{1b}[" + random.pick(["@", "3@", "P", "2P", "L", "2L", "M", "S", "2S", "T", "b", "3b"])
            case 25:
                let top = 1 + random.below(rows - 1)
                text += random.pick(["\u{1b}[\(top);\(top + 1 + random.below(rows - top))r", "\u{1b}[r", "\u{1b}M", "\u{1b}D", "\u{1b}E"])
            case 26:
                text += "\u{1b}[?" + random.pick(["1049", "47", "1047", "1048"]) + random.pick(["h", "l"])
            case 27:
                text += random.pick(["\u{1b}7", "\u{1b}8", "\u{1b}[s", "\u{1b}[u"])
            case 28:
                text += random.pick(["\u{1b}]8;;https://example.com/\(random.below(3))\u{1b}\\", "\u{1b}]8;;\u{1b}\\",
                                     "\u{1b}]8;id=a;file:///tmp/x\u{7}"])
            case 29:
                text += random.pick(["\u{1b}]0;✳ claude\u{7}", "\u{1b}]2;title \(random.below(9))\u{1b}\\", "\u{1b}]1;icon\u{7}",
                                     "\u{1b}[22;0t", "\u{1b}[23;0t", "\u{1b}[22;2t", "\u{1b}]7;file:///Users/x\u{7}"])
            case 30...32:
                text += "\u{1b}[?" + random.pick(["1", "5", "6", "7", "12", "25", "45", "66", "69", "1000", "1002", "1003",
                                                   "1004", "1005", "1006", "1007", "1015", "1016", "2004", "2026", "2031",
                                                   "1243", "2500", "2501"]) + random.pick(["h", "l"])
            case 33:
                text += "\u{1b}[" + random.pick(["4", "20", "8"]) + random.pick(["h", "l"])
            case 34:
                let left = 1 + random.below(cols - 1)
                text += random.pick(["\u{1b}[\(left);\(left + 1 + random.below(cols - left))s", "\u{1b}H", "\u{1b}[g", "\u{1b}[3g",
                                     "\u{1b}#6", "\u{1b}#3", "\u{1b}#5", "\u{1b}[1 k", "\u{1b}[2 k"])
            case 35:
                text += random.pick(["\u{1b}[>1u", "\u{1b}[>5u", "\u{1b}[<u", "\u{1b}[=3;1u", "\u{1b}[=8;2u",
                                     "\u{1b}[\(random.below(7)) q", "\u{1b}[>1s", "\u{1b}[>0s", "\u{1b}=", "\u{1b}>"])
            case 36:
                text += random.pick(["\u{1b}(0", "\u{1b}(B", "\u{1b})0", "\u{e}", "\u{f}", "\u{1b}n", "\u{1b}[62\"p", "\u{1b}[65\"p"])
            case 37:
                text += random.pick(["\u{1b}]4;1;rgb:ff/00/00\u{7}", "\u{1b}]104\u{7}", "\u{1b}]10;#102030\u{7}",
                                     "\u{1b}]11;rgb:00/00/40\u{1b}\\", "\u{1b}]12;#ffffff\u{7}", "\u{1b}]112\u{7}"])
            case 38:
                text += random.pick(["\u{1b}[?1s", "\u{1b}[?2500;2501s", "\u{1b}[?2500;2501r", "\u{1b}[>2t", "\u{1b}[>2T"])
            default:
                text += random.pick(["\u{1b}[!p", "\u{1b}c", "\u{1b}[6n", "\u{1b}[c"])
            }
        }
        return [UInt8](text.utf8)
    }

    // MARK: - The property

    /// Everything the digest hashes, as text, so that a mismatch can say
    /// which field it was.
    static func describe(_ terminal: Terminal, includeScrollback: Bool) -> [String] {
        var out: [String] = []
        func color(_ color: Attribute.Color) -> String {
            switch color {
            case .defaultColor: return "d"
            case .defaultInvertedColor: return "i"
            case .ansi256(let code): return "p\(code)"
            case .trueColor(let r, let g, let b): return "t\(r),\(g),\(b)"
            }
        }
        func charset(_ table: [UInt8: String]?) -> String {
            guard let table else { return "nil" }
            return CharSets.all.filter { $0.value == table }.keys.min().map { String($0) } ?? "unknown"
        }
        func attribute(_ a: Attribute) -> String {
            "\(color(a.fg))/\(color(a.bg))/\(a.style.rawValue)/\(a.underlineStyle.rawValue)/\(a.underlineColor.map(color) ?? "n")"
        }
        func buffer(_ name: String, _ b: Buffer) {
            let top = min(max(b.yBase, 0), max(b.lines.count - terminal.rows, 0))
            let from = includeScrollback ? 0 : top
            let to = min(top + terminal.rows, b.lines.count)
            out.append("\(name) rows \(max(to - from, 0))")
            if from < to {
                for row in from..<to {
                    let line = b.lines[row]
                    var text = "\(name)[\(row - from)] w=\(line.isWrapped) r=\(line.renderMode) b=\(line.bidiState):"
                    for x in 0..<min(line.count, terminal.cols) {
                        let cell = line[x]
                        let scalars = cell.code == 0 ? "0" : terminal.getCharacter(for: cell).unicodeScalars
                            .map { String($0.value, radix: 16) }.joined(separator: ".")
                        var item = " \(scalars)w\(cell.width)"
                        if cell.attribute != CharData.defaultAttr {
                            item += "{\(attribute(cell.attribute))}"
                        }
                        if cell.payload.code != 0 {
                            item += "<\(cell.payload.target as? String ?? "?")>"
                        }
                        text += item
                    }
                    out.append(text)
                }
            }
            out.append("\(name) cursor \(b.x),\(b.y) region \(b.scrollTop)-\(b.scrollBottom) margins \(b.marginLeft)-\(b.marginRight)")
            out.append("\(name) tabs \(b.tabStops.prefix(terminal.cols).map { $0 ? "1" : "0" }.joined())")
            out.append("\(name) saved \(b.savedX),\(b.savedY) \(attribute(b.savedAttr)) cs=\(charset(b.savedCharset)) o=\(b.savedOriginMode) m=\(b.savedMarginMode) w=\(b.savedWraparound) r=\(b.savedReverseWraparound)")
            out.append("\(name) keyboard \(terminal.snapshotKeyboardMode(alternate: b === terminal.altBuffer))")
        }
        buffer("normal", terminal.normalBuffer)
        buffer("alt", terminal.altBuffer)
        out.append("active alt=\(terminal.isCurrentBufferAlternate) pen=\(attribute(terminal.snapshotPen)) link=\(terminal.snapshotActiveHyperlink ?? "nil")")
        let charsets = terminal.snapshotCharsets
        out.append("charsets level=\(terminal.gLevel) current=\(charset(charsets.current)) g=\(charsets.designated.map(charset))")
        out.append("modes appCursor=\(terminal.applicationCursor) keypad=\(terminal.applicationKeypad) paste=\(terminal.bracketedPasteMode) focus=\(terminal.sendFocus) mouse=\(terminal.mouseMode) proto=\(terminal.snapshotMouseProtocol) shift=\(terminal.mouseShiftCapture) altScroll=\(terminal.alternateScrollMode)")
        out.append("modes hidden=\(terminal.cursorHidden) style=\(terminal.options.cursorStyle) blink=\(terminal.cursorBlink) origin=\(terminal.originMode) margin=\(terminal.marginMode) insert=\(terminal.insertMode) wrap=\(terminal.wraparound) rwrap=\(terminal.reverseWraparound) reverse=\(terminal.reverseColors)")
        out.append("modes lf=\(terminal.lineFeedMode) smooth=\(terminal.smoothScroll) c132=\(terminal.allow80To132) sync=\(terminal.synchronizedOutputActive) conformance=\(terminal.conformance) 8bit=\(terminal.cc.send8bit)")
        out.append("bidi \(terminal.currentBidiState) swap=\(terminal.bidiArrowKeySwap) saved=\(terminal.snapshotSavedBidiPrivateModes.sorted { $0.key < $1.key })")
        out.append("title modes \(terminal.xtermTitleSetHex) \(terminal.xtermTitleQueryHex) \(terminal.xtermTitleSetUtf) \(terminal.xtermTitleQueryUtf)")
        out.append("titles \(terminal.terminalTitle)|\(terminal.iconTitle)|\(terminal.terminalTitleStack)|\(terminal.terminalIconStack)|\(terminal.hostCurrentDirectory ?? "nil")|\(terminal.hostCurrentDocument ?? "nil")")
        var colors = ""
        for index in 0..<terminal.ansiColors.count where terminal.ansiColors[index] != terminal.defaultAnsiColors[index] {
            colors += " \(index)=\(terminal.ansiColors[index].formatAsXcolor())"
        }
        out.append("colors\(colors) fg=\(terminal.programSetForegroundColor ? terminal.foregroundColor.formatAsXcolor() : "-") bg=\(terminal.programSetBackgroundColor ? terminal.backgroundColor.formatAsXcolor() : "-") cursor=\(terminal.programSetCursorColor ? terminal.cursorColor?.formatAsXcolor() ?? "nil" : "-")")
        out.append("parser \(terminal.parser.currentState) overflow=\(terminal.parser.pendingOverflow) pending=\(terminal.parser.pendingBytes) partial=\(terminal.snapshotPartialCharacter)")
        return out
    }

    static func firstDifference(_ a: Terminal, _ b: Terminal, includeScrollback: Bool) -> String {
        let left = describe(a, includeScrollback: includeScrollback)
        let right = describe(b, includeScrollback: includeScrollback)
        for index in 0..<max(left.count, right.count) {
            let l = index < left.count ? left[index] : "(none)"
            let r = index < right.count ? right[index] : "(none)"
            if l != r {
                return "\n  restored: \(l)\n  expected: \(r)"
            }
        }
        return " (digests differ, descriptions do not: the digest hashes a field describe() omits)"
    }

    static func printable(_ bytes: ArraySlice<UInt8>) -> String {
        var text = ""
        for byte in bytes {
            switch byte {
            case 0x1b: text += "␛"
            case 0x20..<0x7f: text += String(UnicodeScalar(byte))
            default: text += String(format: "\\x%02x", byte)
            }
        }
        return text
    }

    /// Cuts `stream` at every offset in `offsets` and checks the property.
    /// Returns the first failure, or nil.
    ///
    /// - Parameter restoreShape: the terminal the snapshot is fed to, when
    ///   it is not the same shape as the source.
    static func roundTripFailure(stream: [UInt8], shape: Shape, includeScrollback: Bool,
                                 restoreShape: Shape? = nil, stride step: Int = 1) -> String? {
        // The delegates are held: a terminal keeps its delegate weakly and
        // treats a missing one as an untrusted process.
        let (whole, wholeDelegate) = makeTerminal(restoreShape ?? shape)
        whole.feed(byteArray: stream)
        let expected = whole.digest(includeScrollback: includeScrollback)

        let (source, sourceDelegate) = makeTerminal(shape)
        defer { withExtendedLifetime((wholeDelegate, sourceDelegate)) {} }
        var fed = 0
        var k = 0
        while k <= stream.count {
            source.feed(buffer: stream[fed..<k])
            fed = k
            let snapshot = source.snapshot(includeScrollback: includeScrollback)
            let (restored, delegate) = makeTerminal(restoreShape ?? shape)
            restored.feed(byteArray: snapshot)
            if delegate.sends != 0 {
                return "cut at \(k): restoring sent \(delegate.sends) replies"
            }
            if restored.digest(includeScrollback: includeScrollback) != source.digest(includeScrollback: includeScrollback) {
                return "cut at \(k) (after \(printable(stream[max(0, k - 24)..<k]))): the restored terminal is not the source"
                    + firstDifference(restored, source, includeScrollback: includeScrollback)
            }
            restored.feed(buffer: stream[k...])
            if restored.digest(includeScrollback: includeScrollback) != expected {
                return "cut at \(k) (after \(printable(stream[max(0, k - 24)..<k]))): restore then the rest is not the stream fed whole"
                    + firstDifference(restored, whole, includeScrollback: includeScrollback)
            }
            if k == stream.count {
                break
            }
            k = min(k + step, stream.count)
        }
        return nil
    }

    // MARK: - Tests

    @Test(arguments: fixtures().map(\.name))
    func testRoundTripAtEveryOffset(fixture: String) throws {
        let bytes = try #require(SnapshotTests.fixtures().first { $0.name == fixture }?.bytes)
        let failure = SnapshotTests.roundTripFailure(stream: bytes, shape: SnapshotTests.claudeShape, includeScrollback: true)
        #expect(failure == nil, "\(fixture): \(failure ?? "")")
    }

    @Test(arguments: Array(0..<200))
    func testRoundTripAtEveryOffsetGenerated(seed: Int) {
        // 26 rows, not fewer: a terminal is built at 80 by 25 and then
        // resized, which leaves a shorter one's alternate buffer with room
        // for 25 lines until the first time it is cleared. A restored
        // terminal's has never been cleared, so below 25 rows the two can
        // differ in how much the alternate screen keeps above itself.
        let shape = Shape(cols: 20, rows: 26, scrollback: 30)
        let stream = SnapshotTests.generatedStream(seed: UInt64(seed), cols: shape.cols, rows: shape.rows)
        let failure = SnapshotTests.roundTripFailure(stream: stream, shape: shape, includeScrollback: true)
        #expect(failure == nil, "seed \(seed): \(failure ?? "")")
    }

    @Test func testFixturesArePresent() {
        #expect(SnapshotTests.fixtures().count >= 21)
    }

    /// sidealong's two halves: the screen alone into a terminal with no
    /// scrollback, and everything into one with a cap, with a stream long
    /// enough that the cap trims.
    @Test func testRoundTripWithAndWithoutScrollback() throws {
        let capped = Shape(cols: 48, rows: 37, scrollback: 40)
        let none = Shape(cols: 48, rows: 37, scrollback: nil)
        var long = [UInt8]()
        for fixture in SnapshotTests.fixtures() {
            long.append(contentsOf: fixture.bytes)
        }
        for line in 0..<200 {
            long.append(contentsOf: "\u{1b}[3\(line % 8)mscrolled line \(line) that is long enough to wrap around the right edge\u{1b}[m\r\n".utf8)
        }
        let (trimmed, delegate) = SnapshotTests.makeTerminal(capped)
        trimmed.feed(byteArray: long)
        #expect(trimmed.normalBuffer.lines.count == capped.rows + 40, "the stream fills the scrollback")
        #expect(trimmed.normalBuffer.linesTop > 0, "and trims it")
        withExtendedLifetime(delegate) {}

        // A stride that is not a round number, so the cuts land everywhere
        // in a sequence over the length of the stream.
        var failure = SnapshotTests.roundTripFailure(stream: long, shape: capped, includeScrollback: true, stride: 211)
        #expect(failure == nil, "capped, with scrollback: \(failure ?? "")")
        failure = SnapshotTests.roundTripFailure(stream: long, shape: capped, includeScrollback: false,
                                                 restoreShape: none, stride: 211)
        #expect(failure == nil, "screen alone into a terminal without scrollback: \(failure ?? "")")
        failure = SnapshotTests.roundTripFailure(stream: long, shape: none, includeScrollback: true, stride: 211)
        #expect(failure == nil, "no scrollback at either end: \(failure ?? "")")

        for seed in 0..<40 {
            let stream = SnapshotTests.generatedStream(seed: UInt64(1000 + seed), cols: 20, rows: 26)
            failure = SnapshotTests.roundTripFailure(stream: stream, shape: Shape(cols: 20, rows: 26, scrollback: 5),
                                                     includeScrollback: false,
                                                     restoreShape: Shape(cols: 20, rows: 26, scrollback: nil), stride: 7)
            #expect(failure == nil, "generated \(seed), screen alone: \(failure ?? "")")
        }
    }

    /// Everything that makes a terminal answer when it is fed live: the
    /// queries themselves, and focus reporting, which reports when it is
    /// turned on.
    @Test func testRestoreNeverAnswers() {
        let shape = Shape(cols: 48, rows: 37, scrollback: 100)
        let (source, sourceDelegate) = SnapshotTests.makeTerminal(shape)
        source.feed(text: "\u{1b}[?1004h\u{1b}[c\u{1b}[>c\u{1b}[6n\u{1b}[?u\u{1b}]11;?\u{7}\u{1b}]10;?\u{7}\u{1b}[?2026$p\u{1b}[18t\u{1b}[>1u\u{1b}[?1000;1006h")
        #expect(sourceDelegate.sends > 0, "the source answered its program")
        #expect(source.sendFocus)

        for includeScrollback in [true, false] {
            let (restored, delegate) = SnapshotTests.makeTerminal(shape)
            restored.feed(byteArray: source.snapshot(includeScrollback: includeScrollback))
            #expect(delegate.sends == 0)
            #expect(restored.sendFocus, "focus reporting is on without having reported")
            #expect(restored.digest(includeScrollback: includeScrollback) == source.digest(includeScrollback: includeScrollback))
            restored.setTerminalFocus(false)
            #expect(delegate.sends == 1, "and it reports the next change")
        }

        // The same over every real stream, whole and cut inside a query.
        for fixture in SnapshotTests.fixtures() {
            for cut in [fixture.bytes.count, fixture.bytes.count / 2, fixture.bytes.count / 3] {
                let (terminal, held) = SnapshotTests.makeTerminal(SnapshotTests.claudeShape)
                terminal.feed(buffer: fixture.bytes[0..<cut])
                let (restored, delegate) = SnapshotTests.makeTerminal(SnapshotTests.claudeShape)
                restored.feed(byteArray: terminal.snapshot(includeScrollback: true))
                #expect(delegate.sends == 0, "\(fixture.name) cut at \(cut)")
                withExtendedLifetime(held) {}
            }
        }
    }

    /// A restored terminal has the same wrap flags, so it reflows to the
    /// same rows when the panel changes width.
    @Test func testRestoredTerminalReflowsTheSame() {
        let shape = Shape(cols: 48, rows: 37, scrollback: 500)
        var streams = SnapshotTests.fixtures().map(\.bytes)
        var prose = [UInt8]()
        for paragraph in 0..<60 {
            prose.append(contentsOf: "\u{1b}[1mparagraph \(paragraph)\u{1b}[m " .utf8)
            prose.append(contentsOf: String(repeating: "wörds that wrap 漢字 ", count: 1 + paragraph % 9).utf8)
            prose.append(contentsOf: "\r\n".utf8)
        }
        streams.append(prose)

        for (index, stream) in streams.enumerated() {
            for (cols, rows) in [(30, 37), (80, 37), (48, 20), (61, 50)] {
                let (source, sourceDelegate) = SnapshotTests.makeTerminal(shape)
                source.feed(byteArray: stream)
                let (restored, delegate) = SnapshotTests.makeTerminal(shape)
                restored.feed(byteArray: source.snapshot(includeScrollback: true))
                #expect(restored.digest(includeScrollback: true) == source.digest(includeScrollback: true))
                source.resize(cols: cols, rows: rows)
                restored.resize(cols: cols, rows: rows)
                #expect(restored.digest(includeScrollback: true) == source.digest(includeScrollback: true),
                        "stream \(index) resized to \(cols)x\(rows):\(SnapshotTests.firstDifference(restored, source, includeScrollback: true))")
                withExtendedLifetime((sourceDelegate, delegate)) {}
            }
        }
    }

    /// The palette and the ground are the embedder's. A snapshot carries a
    /// colour only when a program set it.
    @Test func testRestoreKeepsTheEmbeddersPalette() {
        let shape = Shape(cols: 48, rows: 37, scrollback: 100)
        let palette = (0..<16).map { Color(red: UInt16($0) * 0x1000, green: 0x8000, blue: 0xffff - UInt16($0) * 0x1000) }
        let ground = Color(red: 0xfafa, green: 0xf5f5, blue: 0xf0f0)
        let ink = Color(red: 0x1111, green: 0x2222, blue: 0x3333)
        func same(_ a: Color, _ b: Color) -> Bool {
            a.red == b.red && a.green == b.green && a.blue == b.blue
        }
        func embedded() -> (Terminal, SnapshotTestDelegate) {
            let (terminal, delegate) = SnapshotTests.makeTerminal(shape)
            terminal.installPalette(colors: palette)
            terminal.backgroundColor = ground
            terminal.foregroundColor = ink
            return (terminal, delegate)
        }

        // A source that never touched a colour, with the stock palette.
        let (source, sourceDelegate) = SnapshotTests.makeTerminal(shape)
        source.feed(text: "\u{1b}[31mred\u{1b}[48;5;200m and pink\u{1b}[m\r\n")
        let (restored, delegate) = embedded()
        let before = restored.ansiColors.map { ($0.red, $0.green, $0.blue) }
        restored.feed(byteArray: source.snapshot(includeScrollback: true))
        #expect(same(restored.backgroundColor, ground))
        #expect(same(restored.foregroundColor, ink))
        for index in 0..<restored.ansiColors.count {
            #expect(before[index] == (restored.ansiColors[index].red, restored.ansiColors[index].green, restored.ansiColors[index].blue),
                    "palette entry \(index) is still the embedder's")
        }
        #expect(restored.digest(includeScrollback: true) == source.digest(includeScrollback: true),
                "the embedder's colours are not part of the digest")

        // A program that set colours: those travel, the rest stay.
        // (The ground first: setting it rebuilds the palette.)
        source.feed(text: "\u{1b}]11;rgb:00/00/40\u{7}\u{1b}]4;3;rgb:12/34/56\u{7}")
        let (second, secondDelegate) = embedded()
        second.feed(byteArray: source.snapshot(includeScrollback: true))
        #expect(same(second.ansiColors[3], Color(red: 0x1212, green: 0x3434, blue: 0x5656)))
        #expect(same(second.ansiColors[2], palette[2]))
        #expect(same(second.backgroundColor, Color(red: 0, green: 0, blue: 0x4040)))
        #expect(same(second.foregroundColor, ink))
        #expect(second.digest(includeScrollback: true) == source.digest(includeScrollback: true))
        withExtendedLifetime((sourceDelegate, delegate, secondDelegate)) {}
    }

    /// A sequence the parser has been inside for more than 64 KiB is not
    /// carried: the restored parser is left inside an empty sequence of the
    /// same kind, so the rest of the payload is swallowed and what follows
    /// it parses.
    @Test func testOversizedSequenceIsAbandoned() {
        let shape = Shape(cols: 48, rows: 37, scrollback: 100)
        let openers: [String] = ["\u{1b}]52;c;", "\u{1b}_G", "\u{1b}Pq", "\u{1b}^"]
        for opener in openers {
            let (source, sourceDelegate) = SnapshotTests.makeTerminal(shape)
            source.feed(text: "before\r\n" + opener)
            source.feed(byteArray: [UInt8](repeating: 0x41, count: EscapeSequenceParser.maximumPendingBytes + 10))
            #expect(source.parser.pendingOverflow)
            let snapshot = source.snapshot(includeScrollback: true)
            #expect(snapshot.count < 4096, "the payload is not in the snapshot")

            let (restored, delegate) = SnapshotTests.makeTerminal(shape)
            restored.feed(byteArray: snapshot)
            #expect(restored.parser.currentState == source.parser.currentState)
            let rest = "AAAA\u{1b}\\after\u{1b}[1;31mwards"
            source.feed(text: rest)
            restored.feed(text: rest)
            #expect(delegate.sends == 0)
            #expect(restored.parser.currentState == .ground)
            #expect(restored.digest(includeScrollback: true) == source.digest(includeScrollback: true),
                    "\(SnapshotTests.printable([UInt8](opener.utf8)[...])):\(SnapshotTests.firstDifference(restored, source, includeScrollback: true))")
            withExtendedLifetime(sourceDelegate) {}
        }
    }

    /// A title with a character whose UTF-8 has a byte in 0x80 to 0x9f
    /// ("✳" is E2 9C B3, and claude titles every chat with it) parses the
    /// same wherever a read cuts it. The byte used to end the string when
    /// it came first in a read.
    @Test func testTitleSurvivesAReadCutInsideACharacter() {
        let stream = [UInt8]("\u{1b}]0;✳ claude · ärger\u{7}after".utf8)
        for cut in 0...stream.count {
            let (terminal, delegate) = SnapshotTests.makeTerminal(Shape(cols: 20, rows: 4, scrollback: 0))
            terminal.feed(buffer: stream[0..<cut])
            terminal.feed(buffer: stream[cut...])
            #expect(terminal.terminalTitle == "✳ claude · ärger", "cut at \(cut)")
            #expect(terminal.normalBuffer.lines[0].translateToString(trimRight: true) == "after", "cut at \(cut)")
            withExtendedLifetime(delegate) {}
        }
    }

    /// The private sequences can arrive in any feed. None of them may trap,
    /// whatever follows the verb.
    @Test func testPrivateSequencesSurviveBadInput() {
        let (terminal, delegate) = SnapshotTests.makeTerminal(Shape(cols: 10, rows: 4, scrollback: 5))
        let bodies = [
            "", "nope", "wrap;1;2", "bidi", "bidi;x", "bidi;99999999999999999999", "saved", "saved;1", "saved;-1;-1;1;1;1;1;-",
            "saved;99999;99999;2;2;2;2;999", "charsets", "charsets;9;-;-;-;-;-", "charsets;0;48;300;x;;-", "cells",
            "cells;d;d;0;0;n;", "cells;d;d;0;0;n;9", "cells;d;d;0;0;n;1zz", "cells;d;d;0;0;n;1110000", "cells;d;d;0;0;n;1d800",
            "cells;q;d;0;0;n;161", "cells;d;d;999;0;n;161", "cells;d;d;0;77;n;161", "cells;d;d;0;0;q;161",
            "cells;t1000000;p999;0;0;n;161", "cells;d;d;0;0;n;161,161,161,161,161,161,161,161,161,161,161,161,161",
            "cells;d;d;0;0;n;21f468.200d.1f469,0,2,1..,1.61", "cells;d;d;0;0;n;161.62.63.64", "pendingwrap;;;", "focus;1",
        ]
        for body in bodies {
            terminal.feed(text: "\u{1b}[2;9H\u{1b}_swiftterm-snapshot;\(body)\u{1b}\\ok")
        }
        terminal.feed(text: "\u{1b}_swiftterm-snapsho\u{1b}\\\u{1b}_s\u{1b}\\\u{1b}_swiftterm-snapshot\u{1b}\\")
        _ = terminal.snapshot(includeScrollback: true)
        _ = terminal.digest(includeScrollback: true)
        #expect(delegate.sends == 0)
    }

    // MARK: - Cost

    static func milliseconds(best runs: Int, _ body: () -> Void) -> Double {
        var best = Double.infinity
        for _ in 0..<runs {
            let start = DispatchTime.now().uptimeNanoseconds
            body()
            best = min(best, Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
        }
        return best
    }

    static var isOptimized: Bool {
        var debug = false
        assert({ debug = true; return true }())
        return !debug
    }

    /// sidealong's daemon mirror at its cap: 48x34 with 3000 full lines of
    /// scrollback, coloured the way a chat is. The numbers are printed in
    /// any build and held to their budgets in a release one:
    ///
    ///     swift test -c release --filter SnapshotTests/testSnapshotCost
    @Test func testSnapshotCost() {
        let shape = Shape(cols: 48, rows: 34, scrollback: 3000)
        let (source, sourceDelegate) = SnapshotTests.makeTerminal(shape)
        var stream = [UInt8]()
        for line in 0..<3100 {
            stream.append(contentsOf: "\u{1b}[38;5;\(line % 200 + 16)m\(line) \u{1b}[1mbold\u{1b}[22m and \u{1b}[48;5;236mshaded\u{1b}[49m text \u{1b}[38;2;\(line % 255);120;200mto the edge of row\u{1b}[m\r\n".utf8)
        }
        source.feed(byteArray: stream)
        #expect(source.normalBuffer.lines.count == 3034)

        var history = [UInt8]()
        var screen = [UInt8]()
        let historyCost = SnapshotTests.milliseconds(best: 5) { history = source.snapshot(includeScrollback: true) }
        let screenCost = SnapshotTests.milliseconds(best: 20) { screen = source.snapshot(includeScrollback: false) }
        var restored: Terminal? = nil
        var delegates: [SnapshotTestDelegate] = []
        let restoreCost = SnapshotTests.milliseconds(best: 5) {
            let (terminal, delegate) = SnapshotTests.makeTerminal(shape)
            terminal.feed(byteArray: history)
            restored = terminal
            delegates.append(delegate)
        }
        var digest: UInt64 = 0
        let digestCost = SnapshotTests.milliseconds(best: 50) { digest = source.digest(includeScrollback: false) }
        let fullDigestCost = SnapshotTests.milliseconds(best: 5) { _ = source.digest(includeScrollback: true) }

        #expect(restored?.digest(includeScrollback: true) == source.digest(includeScrollback: true))
        #expect(restored?.digest(includeScrollback: false) == digest)
        withExtendedLifetime((sourceDelegate, delegates)) {}

        let build = SnapshotTests.isOptimized ? "release" : "debug"
        print(String(format: "SNAPSHOT COST (%@, 48x34, 3000 lines): snapshot(true) %.2f ms, %d KiB; restore %.2f ms; snapshot(false) %.3f ms, %d bytes; digest(false) %.3f ms; digest(true) %.2f ms",
                     build, historyCost, history.count / 1024, restoreCost, screenCost, screen.count, digestCost, fullDigestCost))
        if SnapshotTests.isOptimized {
            #expect(historyCost <= 10)
            #expect(restoreCost <= 20)
            #expect(screenCost <= 0.5)
            #expect(digestCost <= 0.2)
        }
    }

    /// What tracking the half-parsed tail costs a feed. Printed, not held
    /// to a number: run it on the commit before and on this one and compare.
    /// The stream is agent-back.raw, the whole of the footer probe's
    /// capture, sixty-four times over, fed in 4 KiB reads the way a pty
    /// delivers it.
    ///
    ///     swift test -c release --filter SnapshotTests/testParseCost
    @Test func testParseCost() throws {
        let capture = try #require(SnapshotTests.fixtures().first { $0.name == "agent-back.raw" }?.bytes)
        var stream = [UInt8]()
        for _ in 0..<64 {
            stream.append(contentsOf: capture)
        }
        var delegates: [SnapshotTestDelegate] = []
        let cost = SnapshotTests.milliseconds(best: 5) {
            let (terminal, delegate) = SnapshotTests.makeTerminal(SnapshotTests.claudeShape)
            delegates.append(delegate)
            var offset = 0
            while offset < stream.count {
                let end = min(offset + 4096, stream.count)
                terminal.feed(buffer: stream[offset..<end])
                offset = end
            }
        }
        withExtendedLifetime(delegates) {}
        print(String(format: "PARSE COST (%@): %d KiB in 4 KiB reads, best of 5: %.2f ms",
                     SnapshotTests.isOptimized ? "release" : "debug", stream.count / 1024, cost))
    }
}
