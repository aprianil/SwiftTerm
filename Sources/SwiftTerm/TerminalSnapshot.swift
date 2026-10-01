//
//  TerminalSnapshot.swift
//  SwiftTerm
//
//  A terminal's whole state written out as a byte stream that, fed to a
//  fresh terminal of the same size, rebuilds it: both buffers, scrollback,
//  cursors, the pen, every mode, and the sequence the parser was halfway
//  through. An embedder that keeps one terminal as the source of truth (a
//  daemon that owns the pty) uses it to hand a second terminal (the view)
//  that state, instead of replaying a tail of the byte stream and hoping the
//  cursor-relative moves in it land where they did the first time.
//
//  The stream is an escape stream, so it restores through the ordinary
//  parser into any Terminal, the one inside a TerminalView included:
//
//      a blank screen              the pen, the modes that change what a
//                                  position means, both cleared
//      bidi state                  before any row, so new rows inherit it
//      normal buffer rows          oldest first, CR LF between, which
//                                  scrolls the old ones into scrollback
//      alternate buffer rows       entered with ?47h
//      each buffer's own state     margins, region, tab stops, keyboard
//                                  flags, saved cursor, cursor
//      modes, titles, colours      ordinary sequences
//      pen, link, charsets
//      the half-parsed tail        verbatim, last
//
//  Whatever a delegate hears about (mouse mode, cursor style, titles,
//  colours, the active buffer) is set with the ordinary sequence, so a
//  restoring view learns it the way it always does. State no ordinary
//  sequence can set without a side effect goes in a fork-private APC string,
//  `ESC _ swiftterm-snapshot;<verb>;<args> ESC \`, which every other
//  terminal ignores and no program emits:
//
//      wrap            the cursor's line continues the one above
//      pendingwrap     the cursor sits past the last column
//      focus           focus reporting on, without the report ?1004h sends
//      bidi            the cursor's line's BiDi state
//      saved           the buffer's saved cursor (DECSC), pen included
//      charsets        G0 to G3, the shift level, the active table
//      cells           a run of cells exactly as given, for the ones
//                      printing cannot rebuild (below)
//
//  A live feed may carry these too, so each verb only reaches state a
//  program can already reach with ordinary sequences, and each checks its
//  arguments.
//
//  Rows are printed, with SGR only where the attribute changes, CHA over
//  blank cells and ECH for erased ones. Printing is only used for a cell it
//  is certain to rebuild: a single scalar of its own width that the print
//  path will not try to combine with its neighbour. Everything else (a
//  grapheme cluster, half of a wide character whose other half was
//  overwritten, an attribute SGR cannot name) goes in a `cells` run. The row
//  comes out the same either way; `cells` is the path that cannot be wrong.
//
//  `wrap` is written on the row it marks, after the CR LF that reached the
//  row and before the row's text. A row that will end up in scrollback is
//  marked while it is still on screen, and the scroll carries the flag.
//
//  Restoring sends nothing: the stream holds no query, and focus reporting
//  is set by `focus`, which does not report.
//
//  Not carried, and left out of `digest` for the same reason:
//    - images (sixel, kitty, iTerm) and the kitty placement state
//    - OSC 133 prompt state: the marks and the continuation group on a
//      line, the role on a cell, the buffer's prompt group and input state
//    - a payload that is not an OSC 8 link
//    - view state: the scroll position, selection, search
//    - `totalLinesTrimmed`, which counts what the source dropped
//    - what the embedder owns: the installed palette, the ground and ink it
//      set, whether the view has focus
//

import Foundation

private let snapshotPrefix: [UInt8] = Array("swiftterm-snapshot;".utf8)

extension Terminal {
    /// A byte stream that rebuilds this terminal: fed to a fresh Terminal
    /// with the same cols, rows and scrollback setting, the result is equal
    /// to this one in every field `digest` covers. Contains no query. Ends
    /// with any half-parsed sequence, verbatim.
    ///
    /// - Parameter includeScrollback: false writes the screen alone; true
    ///   writes the scrollback above it first, oldest line first.
    public func snapshot(includeScrollback: Bool) -> [UInt8] {
        var writer = SnapshotWriter(terminal: self)
        writer.write(includeScrollback: includeScrollback)
        return writer.out
    }

    /// A hash over every field the round trip promises: the cells of both
    /// buffers with their attributes and links, each line's wrap flag,
    /// cursors and saved cursors, the pen, every mode, titles, the colours a
    /// program set, and the half-parsed sequence. Two terminals with the
    /// same digest show the same thing and will answer the next byte the
    /// same way. The file header lists what it leaves out.
    ///
    /// - Parameter includeScrollback: false hashes the screen alone, so a
    ///   terminal with scrollback and one without can be compared.
    public func digest(includeScrollback: Bool) -> UInt64 {
        var hasher = SnapshotHasher(terminal: self)
        hasher.hash(includeScrollback: includeScrollback)
        return hasher.value
    }
}

// MARK: - Shared

private extension BidiPresentationState {
    var snapshotBits: Int {
        (supportMode == .explicit ? 1 : 0)
            | (autodetectDirection ? 2 : 0)
            | (fallbackDirection == .rightToLeft ? 4 : 0)
            | (boxMirroring ? 8 : 0)
    }

    init(snapshotBits bits: Int) {
        self.init(supportMode: bits & 1 != 0 ? .explicit : .implicit,
                  autodetectDirection: bits & 2 != 0,
                  fallbackDirection: bits & 4 != 0 ? .rightToLeft : .leftToRight,
                  boxMirroring: bits & 8 != 0)
    }
}

/// The designator a charset table was selected with (`ESC ( 0` is 0x30), or
/// nil for the default. Tables are compared by content, the lowest
/// designator winning, so two names for one table restore the same.
private func snapshotCharsetKey(_ table: [UInt8: String]?) -> UInt8? {
    guard let table else { return nil }
    var found: UInt8? = nil
    for (key, value) in CharSets.all where value == table {
        if found == nil || key < found! {
            found = key
        }
    }
    return found
}

/// The lines a snapshot or digest covers: the screen, and what is above it
/// when asked.
private func snapshotRowRange(of buffer: Buffer, rows: Int, includeScrollback: Bool) -> Range<Int> {
    let count = buffer.lines.count
    let top = min(max(buffer.yBase, 0), max(count - rows, 0))
    return (includeScrollback ? 0 : top)..<min(top + rows, count)
}

private func snapshotDefaultTabStops(cols: Int, width: Int) -> [Bool] {
    var stops = [Bool](repeating: false, count: cols)
    for index in stride(from: 0, to: cols, by: max(width, 1)) {
        stops[index] = true
    }
    return stops
}

private func snapshotCursorStyleCode(_ style: CursorStyle) -> Int {
    switch style {
    case .blinkBlock: return 1
    case .steadyBlock: return 2
    case .blinkUnderline: return 3
    case .steadyUnderline: return 4
    case .blinkBar: return 5
    case .steadyBar: return 6
    }
}

private func snapshotRenderModeCode(_ mode: BufferLine.RenderLineMode) -> UInt8 {
    switch mode {
    case .single: return 0x35       // ESC # 5
    case .doubleWidth: return 0x36  // ESC # 6
    case .doubledTop: return 0x33   // ESC # 3
    case .doubledDown: return 0x34  // ESC # 4
    }
}

/// True when printing `scalar` writes one cell of `width` columns and never
/// reaches for the cell before it. Mirrors the tests in
/// `Terminal.handlePrint`: anything that function might combine is not
/// printable here and goes in a `cells` run.
private func snapshotPrintsAsOneCell(_ value: UInt32, width: Int) -> Bool {
    if value >= 0x20 && value < 0x7f {
        return width == 1
    }
    guard value >= 0xa0, let scalar = Unicode.Scalar(value) else {
        return false
    }
    guard width == 1 || width == 2, UnicodeUtil.columnWidth(rune: scalar) == width else {
        return false
    }
    if value == 0x200D
        || UnicodeUtil.isVariationSelector(value)
        || UnicodeUtil.isEmojiModifier(value)
        || UnicodeUtil.isRegionalIndicator(scalar) {
        return false
    }
    if value >= 0x0300 && scalar.properties.canonicalCombiningClass != .notReordered {
        return false
    }
    return true
}

// MARK: - Writer

private struct SnapshotWriter {
    unowned let terminal: Terminal
    var out: [UInt8] = []

    // The restoring terminal's state as the stream so far leaves it.
    private var pen = CharData.defaultAttr
    private var link: String? = nil
    private var cursorX = 0

    // Cells in a run share one payload atom; look its string up once.
    private var payloadCode: UInt16 = 0
    private var payloadLink: String? = nil

    private let cols: Int
    private let rows: Int
    private let terminalBidi: BidiPresentationState

    init(terminal: Terminal) {
        self.terminal = terminal
        cols = terminal.cols
        rows = terminal.rows
        terminalBidi = terminal.currentBidiState
    }

    // MARK: Bytes

    private mutating func put(_ text: StaticString) {
        text.withUTF8Buffer { out.append(contentsOf: $0) }
    }

    private mutating func put(_ value: Int) {
        if value < 10 && value >= 0 {
            out.append(0x30 + UInt8(value))
            return
        }
        out.append(contentsOf: String(value).utf8)
    }

    private mutating func csi(_ value: Int, _ final: StaticString) {
        put("\u{1b}[")
        put(value)
        put(final)
    }

    private mutating func verb(_ text: StaticString) {
        put("\u{1b}_swiftterm-snapshot;")
        put(text)
        put("\u{1b}\\")
    }

    private mutating func hex(_ value: UInt32) {
        out.append(contentsOf: String(value, radix: 16).utf8)
    }

    /// A string as an OSC payload: the parser drops controls inside one,
    /// and BEL or ESC would end it.
    private mutating func putOscText(_ text: String) {
        for byte in text.utf8 where byte >= 0x20 && byte != 0x7f {
            out.append(byte)
        }
    }

    // MARK: Stream

    mutating func write(includeScrollback: Bool) {
        let normal = terminal.normalBuffer
        let alt = terminal.altBuffer
        out.reserveCapacity((includeScrollback ? normal.lines.count : rows) * (cols + 16) + 512)

        // The contract is a fresh terminal, which needs none of this. It is
        // here so that one which has only used its normal screen restores
        // too: a blank screen, an empty scrollback, and the four modes that
        // would bend the positions below. It is not ESC c, which rebuilds
        // the normal buffer from the options and would hand a terminal whose
        // scrollback was turned off one that reflows.
        put("\u{1b}[m\u{1b}[4l\u{1b}[?6l\u{1b}[?69l\u{1b}[r\u{1b}[H\u{1b}[2J\u{1b}[3J")
        writeBidiState()

        writeLines(of: normal, includeScrollback: includeScrollback)

        if terminal.isCurrentBufferAlternate {
            writeBufferState(normal, alternate: false, cleared: false)
            leaveRow()
            put("\u{1b}[?47h")
            writeLines(of: alt, includeScrollback: includeScrollback)
            writeBufferState(alt, alternate: true, cleared: false)
        } else {
            if alt.lines.count > 0 {
                // Left with ?47l: its rows were kept.
                leaveRow()
                put("\u{1b}[?47h")
                writeLines(of: alt, includeScrollback: includeScrollback)
                writeBufferState(alt, alternate: true, cleared: false)
                put("\u{1b}[?47l")
            } else if bufferHasState(alt, alternate: true) {
                // Empty, but its tab stops, keyboard flags and saved cursor
                // outlive the clear that ?1047l does on the way out.
                leaveRow()
                put("\u{1b}[?1047h")
                writeBufferState(alt, alternate: true, cleared: true)
                put("\u{1b}[?1047l")
            }
            writeBufferState(normal, alternate: false, cleared: false)
        }

        writeModes()
        writeTitles()
        writeColors()

        setPen(terminal.snapshotPen)
        setLink(terminal.snapshotActiveHyperlink)
        writeCharsets()

        put(terminal.cursorHidden ? "\u{1b}[?25l" : "\u{1b}[?25h")
        if terminal.synchronizedOutputActive {
            put("\u{1b}[?2026h")
        }
        writeTail()
    }

    /// Setting a BiDi mode with the cursor at the start of a paragraph
    /// rewrites that paragraph's rows, so the terminal's own state goes in
    /// first, at home on a blank screen. Every row after that is created
    /// with it, and only a row that differs needs saying.
    private mutating func writeBidiState() {
        for (mode, value) in terminal.snapshotSavedBidiPrivateModes.sorted(by: { $0.key < $1.key }) {
            csi(mode, value ? "h" : "l", private: true)
            csi(mode, "s", private: true)
        }
        let state = terminal.currentBidiState
        put(state.supportMode == .implicit ? "\u{1b}[8h" : "\u{1b}[8l")
        put(state.autodetectDirection ? "\u{1b}[?2501h" : "\u{1b}[?2501l")
        put(state.fallbackDirection == .rightToLeft ? "\u{1b}[2 k" : "\u{1b}[1 k")
        put(state.boxMirroring ? "\u{1b}[?2500h" : "\u{1b}[?2500l")
        put(terminal.bidiArrowKeySwap ? "\u{1b}[?1243h" : "\u{1b}[?1243l")
    }

    private mutating func csi(_ value: Int, _ final: StaticString, private: Bool) {
        put("\u{1b}[?")
        put(value)
        put(final)
    }

    // MARK: Rows

    /// The new row a line feed scrolls in is filled with the pen's
    /// background, so leave every row on the default one.
    private mutating func leaveRow() {
        if pen.bg != .defaultColor {
            put("\u{1b}[49m")
            pen = Attribute(fg: pen.fg, bg: .defaultColor, style: pen.style,
                            underlineStyle: pen.underlineStyle, underlineColor: pen.underlineColor)
        }
    }

    /// The alternate buffer is read the same way as the normal one: its
    /// line list can be longer than the screen (it is sized when the
    /// terminal is made, before the terminal knows its rows), and what
    /// scrolled above the screen is its scrollback in all but name.
    private mutating func writeLines(of buffer: Buffer, includeScrollback: Bool) {
        put("\u{1b}[H")
        let range = snapshotRowRange(of: buffer, rows: rows, includeScrollback: includeScrollback)
        let first = range.lowerBound
        let last = range.upperBound
        guard first < last else { return }
        let lines = buffer.lines
        for row in first..<last {
            if row > first {
                leaveRow()
                out.append(0x0d)
                out.append(0x0a)
            }
            let line = lines[row]
            if line.isWrapped {
                verb("wrap")
            }
            if line.renderMode != .single {
                put("\u{1b}#")
                out.append(snapshotRenderModeCode(line.renderMode))
            }
            if line.bidiState != terminalBidi {
                put("\u{1b}_swiftterm-snapshot;bidi;")
                put(line.bidiState.snapshotBits)
                put("\u{1b}\\")
            }
            writeRow(line)
        }
    }

    private enum CellKind {
        case blank
        case erased
        case narrow
        case wide
        case raw
    }

    /// True for an attribute SGR can name exactly.
    private func isSGRExpressible(_ attribute: Attribute) -> Bool {
        if attribute.fg == .defaultInvertedColor || attribute.bg == .defaultInvertedColor {
            return false
        }
        if attribute.style.contains(.underline) != (attribute.underlineStyle != .none) {
            return false
        }
        switch attribute.underlineColor {
        case .none, .some(.ansi256), .some(.trueColor):
            return true
        case .some(.defaultColor), .some(.defaultInvertedColor):
            return false
        }
    }

    /// A cell an erase leaves behind: nothing in it, the default ink, any
    /// background SGR can name.
    private func isErased(_ cell: CharData) -> Bool {
        let attribute = cell.attribute
        return cell.code == 0 && cell.width == 1 && cell.payload.code == 0
            && attribute.fg == .defaultColor && attribute.style == .none
            && attribute.underlineStyle == .none && attribute.underlineColor == nil
            && attribute.bg != .defaultInvertedColor
    }

    /// - Parameter afterCluster: the cell before this one holds more than
    ///   one scalar, which the print path may try to extend.
    private func kind(of cell: CharData, at x: Int, in line: BufferLine, count: Int,
                      afterCluster: Bool) -> CellKind {
        let code = cell.code
        if code == 0 {
            if isErased(cell) {
                return cell.attribute.bg == .defaultColor ? .blank : .erased
            }
            return .raw
        }
        guard cell.attribute == pen || isSGRExpressible(cell.attribute) else {
            return .raw
        }
        let value: UInt32
        if code > 0 && code <= Int32(CharData.maxRune) {
            value = UInt32(code)
        } else {
            let scalars = terminal.getCharacter(for: cell).unicodeScalars
            guard scalars.count == 1, let only = scalars.first else {
                return .raw
            }
            value = only.value
        }
        let width = Int(cell.width)
        guard snapshotPrintsAsOneCell(value, width: width) else {
            return .raw
        }
        if value >= 0x80 && afterCluster {
            return .raw
        }
        if width == 1 {
            return .narrow
        }
        // The second half has to be the one the print path writes.
        guard x + 1 < count else { return .raw }
        let trailer = line[x + 1]
        guard trailer.code == 0, trailer.width == 0, trailer.attribute == Attribute.empty,
              trailer.payload.code == cell.payload.code else {
            return .raw
        }
        return .wide
    }

    /// True when the print path could extend this cell with the next
    /// character: it holds a cluster, or a lone joiner.
    private func holdsCluster(_ cell: CharData) -> Bool {
        let code = cell.code
        if code >= 0 && code <= Int32(CharData.maxRune) {
            return code == 0x200D
        }
        return terminal.getCharacter(for: cell).unicodeScalars.count != 1
    }

    private mutating func writeRow(_ line: BufferLine) {
        cursorX = 0
        let count = min(line.count, cols)
        var x = 0
        var afterCluster = false
        while x < count {
            let cell = line[x]
            switch kind(of: cell, at: x, in: line, count: count, afterCluster: afterCluster) {
            case .blank:
                afterCluster = false
                x += 1
            case .erased:
                let background = cell.attribute.bg
                var end = x + 1
                while end < count, isErased(line[end]), line[end].attribute.bg == background {
                    end += 1
                }
                setBackground(background)
                moveTo(x)
                csi(end - x, "X")
                afterCluster = false
                x = end
            case .narrow, .wide:
                setLink(linkOf(cell))
                setPen(cell.attribute)
                moveTo(x)
                putScalar(of: cell)
                let width = Int(cell.width)
                cursorX += width
                afterCluster = false
                x += width
            case .raw:
                let attribute = cell.attribute
                let payload = cell.payload.code
                setLink(linkOf(cell))
                moveTo(x)
                put("\u{1b}_swiftterm-snapshot;cells;")
                putAttribute(attribute)
                var end = x
                var cluster = afterCluster
                while end < count {
                    let next = line[end]
                    if end > x {
                        guard next.attribute == attribute, next.payload.code == payload,
                              kind(of: next, at: end, in: line, count: count, afterCluster: cluster) == .raw else {
                            break
                        }
                        out.append(0x2c) // ,
                    }
                    putRawCell(next)
                    cluster = holdsCluster(next)
                    end += 1
                }
                put("\u{1b}\\")
                afterCluster = cluster
                x = end
            }
        }
    }

    private mutating func moveTo(_ x: Int) {
        if cursorX != x {
            csi(x + 1, "G")
            cursorX = x
        }
    }

    private mutating func putScalar(of cell: CharData) {
        let code = cell.code
        if code < 0x80 {
            out.append(UInt8(code))
            return
        }
        let scalar: Unicode.Scalar
        if code <= Int32(CharData.maxRune), let direct = Unicode.Scalar(UInt32(code)) {
            scalar = direct
        } else {
            scalar = terminal.getCharacter(for: cell).unicodeScalars.first!
        }
        out.append(contentsOf: UTF8.encode(scalar)!)
    }

    private mutating func putRawCell(_ cell: CharData) {
        out.append(0x30 + UInt8(min(max(Int(cell.width), 0), 9)))
        let code = cell.code
        if code == 0 {
            return
        }
        if code > 0 && code <= Int32(CharData.maxRune) {
            hex(UInt32(code))
            return
        }
        var first = true
        for scalar in terminal.getCharacter(for: cell).unicodeScalars {
            if !first {
                out.append(0x2e) // .
            }
            first = false
            hex(scalar.value)
        }
    }

    private mutating func putColor(_ color: Attribute.Color) {
        switch color {
        case .defaultColor:
            out.append(0x64) // d
        case .defaultInvertedColor:
            out.append(0x69) // i
        case .ansi256(let code):
            out.append(0x70) // p
            put(Int(code))
        case .trueColor(let red, let green, let blue):
            out.append(0x74) // t
            hex(UInt32(red) << 16 | UInt32(green) << 8 | UInt32(blue))
        }
    }

    /// fg;bg;style;underline style;underline colour;
    private mutating func putAttribute(_ attribute: Attribute) {
        putColor(attribute.fg)
        out.append(0x3b)
        putColor(attribute.bg)
        out.append(0x3b)
        put(Int(attribute.style.rawValue))
        out.append(0x3b)
        put(Int(attribute.underlineStyle.rawValue))
        out.append(0x3b)
        if let color = attribute.underlineColor {
            putColor(color)
        } else {
            out.append(0x6e) // n
        }
        out.append(0x3b)
    }

    // MARK: Pen and link

    private mutating func linkOf(_ cell: CharData) -> String? {
        let code = cell.payload.code
        if code == 0 {
            return nil
        }
        if code != payloadCode {
            payloadCode = code
            payloadLink = cell.payload.target as? String
        }
        return payloadLink
    }

    private mutating func setLink(_ target: String?) {
        if target == link {
            return
        }
        put("\u{1b}]8;")
        if let target {
            putOscText(target)
        } else {
            out.append(0x3b)
        }
        put("\u{1b}\\")
        link = target
    }

    private mutating func putForeground(_ color: Attribute.Color) {
        switch color {
        case .ansi256(let code) where code < 8:
            put(30 + Int(code))
        case .ansi256(let code) where code < 16:
            put(90 + Int(code) - 8)
        case .ansi256(let code):
            put("38;5;")
            put(Int(code))
        case .trueColor(let red, let green, let blue):
            put("38;2;")
            put(Int(red)); out.append(0x3b)
            put(Int(green)); out.append(0x3b)
            put(Int(blue))
        case .defaultColor, .defaultInvertedColor:
            put(39)
        }
    }

    private mutating func putBackground(_ color: Attribute.Color) {
        switch color {
        case .ansi256(let code) where code < 8:
            put(40 + Int(code))
        case .ansi256(let code) where code < 16:
            put(100 + Int(code) - 8)
        case .ansi256(let code):
            put("48;5;")
            put(Int(code))
        case .trueColor(let red, let green, let blue):
            put("48;2;")
            put(Int(red)); out.append(0x3b)
            put(Int(green)); out.append(0x3b)
            put(Int(blue))
        case .defaultColor, .defaultInvertedColor:
            put(49)
        }
    }

    private mutating func setBackground(_ color: Attribute.Color) {
        if pen.bg == color {
            return
        }
        put("\u{1b}[")
        putBackground(color)
        out.append(0x6d)
        pen = Attribute(fg: pen.fg, bg: color, style: pen.style,
                        underlineStyle: pen.underlineStyle, underlineColor: pen.underlineColor)
    }

    /// SGR for `target`, as short as the change allows. The caller has
    /// checked that SGR can name it.
    private mutating func setPen(_ target: Attribute) {
        if target == pen {
            return
        }
        if target == CharData.defaultAttr {
            put("\u{1b}[m")
            pen = target
            return
        }
        put("\u{1b}[")
        if target.style == pen.style && target.underlineStyle == pen.underlineStyle
            && target.underlineColor == pen.underlineColor {
            var wrote = false
            if target.fg != pen.fg {
                putForeground(target.fg)
                wrote = true
            }
            if target.bg != pen.bg {
                if wrote { out.append(0x3b) }
                putBackground(target.bg)
            }
            out.append(0x6d)
            pen = target
            return
        }
        out.append(0x30)
        let style = target.style
        if style.contains(.bold) { put(";1") }
        if style.contains(.dim) { put(";2") }
        if style.contains(.italic) { put(";3") }
        switch target.underlineStyle {
        case .none: break
        case .double: put(";21")
        case .single, .curly, .dotted, .dashed: put(";4")
        }
        if style.contains(.blink) { put(";5") }
        if style.contains(.inverse) { put(";7") }
        if style.contains(.invisible) { put(";8") }
        if style.contains(.crossedOut) { put(";9") }
        if target.fg != .defaultColor {
            out.append(0x3b)
            putForeground(target.fg)
        }
        if target.bg != .defaultColor {
            out.append(0x3b)
            putBackground(target.bg)
        }
        switch target.underlineColor {
        case .some(.ansi256(let code)):
            put(";58;5;")
            put(Int(code))
        case .some(.trueColor(let red, let green, let blue)):
            put(";58;2;")
            put(Int(red)); out.append(0x3b)
            put(Int(green)); out.append(0x3b)
            put(Int(blue))
        default:
            break
        }
        out.append(0x6d)
        switch target.underlineStyle {
        case .curly, .dotted, .dashed:
            // The colon form only parses as a sequence of its own.
            put("\u{1b}[4:")
            put(Int(target.underlineStyle.rawValue))
            out.append(0x6d)
        case .none, .single, .double:
            break
        }
        pen = target
    }

    // MARK: Buffer state

    private func savedCursorIsDefault(_ buffer: Buffer) -> Bool {
        buffer.savedX == 0 && buffer.savedY == 0 && buffer.savedAttr == CharData.defaultAttr
            && buffer.savedCharset == nil && !buffer.savedOriginMode && !buffer.savedMarginMode
            && !buffer.savedWraparound && !buffer.savedReverseWraparound
    }

    private func tabStopsAreDefault(_ buffer: Buffer) -> Bool {
        let defaults = snapshotDefaultTabStops(cols: cols, width: terminal.tabStopWidth)
        let stops = buffer.tabStops
        for column in 0..<cols {
            if (column < stops.count && stops[column]) != defaults[column] {
                return false
            }
        }
        return true
    }

    private func bufferHasState(_ buffer: Buffer, alternate: Bool) -> Bool {
        let keyboard = terminal.snapshotKeyboardMode(alternate: alternate)
        return keyboard.flags != 0 || !keyboard.stack.isEmpty
            || !savedCursorIsDefault(buffer) || !tabStopsAreDefault(buffer)
            || buffer.x != 0 || buffer.y != 0
    }

    /// Written while `buffer` is the active one, after its rows, with origin
    /// and margin mode still off so that every position below is absolute.
    ///
    /// - Parameter cleared: the buffer is about to be emptied on the way
    ///   out, which resets its margins, region and cursor anyway.
    private mutating func writeBufferState(_ buffer: Buffer, alternate: Bool, cleared: Bool) {
        if !cleared {
            if buffer.marginLeft != 0 || buffer.marginRight != cols - 1 {
                // DECSLRM is only DECSLRM while margin mode is on.
                put("\u{1b}[?69h\u{1b}[")
                put(buffer.marginLeft + 1)
                out.append(0x3b)
                put(buffer.marginRight + 1)
                put("s\u{1b}[?69l")
            }
            if buffer.scrollTop != 0 || buffer.scrollBottom != rows - 1 {
                put("\u{1b}[")
                put(buffer.scrollTop + 1)
                out.append(0x3b)
                put(buffer.scrollBottom + 1)
                out.append(0x72) // r
            }
        }
        if !tabStopsAreDefault(buffer) {
            put("\u{1b}[3g")
            let stops = buffer.tabStops
            for column in 0..<min(cols, stops.count) where stops[column] {
                csi(column + 1, "G")
                put("\u{1b}H")
            }
        }
        // Empty the keyboard stack, then rebuild it by pushing through it:
        // the first entry is set, each later one pushes the one before it.
        let keyboard = terminal.snapshotKeyboardMode(alternate: alternate)
        let chain = keyboard.stack + [keyboard.flags]
        put("\u{1b}[<99u\u{1b}[=")
        put(chain[0])
        put(";1u")
        for flags in chain.dropFirst() {
            put("\u{1b}[>")
            put(flags)
            out.append(0x75) // u
        }
        if !savedCursorIsDefault(buffer) {
            if isSGRExpressible(buffer.savedAttr) {
                setPen(buffer.savedAttr)
            }
            put("\u{1b}_swiftterm-snapshot;saved;")
            put(buffer.savedX); out.append(0x3b)
            put(buffer.savedY); out.append(0x3b)
            put(buffer.savedOriginMode ? 1 : 0); out.append(0x3b)
            put(buffer.savedMarginMode ? 1 : 0); out.append(0x3b)
            put(buffer.savedWraparound ? 1 : 0); out.append(0x3b)
            put(buffer.savedReverseWraparound ? 1 : 0); out.append(0x3b)
            putCharsetKey(buffer.savedCharset)
            put("\u{1b}\\")
        }
        if !cleared {
            put("\u{1b}[")
            put(buffer.y + 1)
            out.append(0x3b)
            put(min(buffer.x, cols - 1) + 1)
            out.append(0x48) // H
            if buffer.x >= cols {
                verb("pendingwrap")
            }
        }
    }

    private mutating func putCharsetKey(_ table: [UInt8: String]?) {
        if let key = snapshotCharsetKey(table) {
            put(Int(key))
        } else {
            out.append(0x2d) // -
        }
    }

    private mutating func writeCharsets() {
        let charsets = terminal.snapshotCharsets
        if terminal.gLevel == 0 && charsets.current == nil && charsets.designated.allSatisfy({ $0 == nil }) {
            return
        }
        put("\u{1b}_swiftterm-snapshot;charsets;")
        put(Int(terminal.gLevel))
        for index in 0..<4 {
            out.append(0x3b)
            putCharsetKey(index < charsets.designated.count ? charsets.designated[index] : nil)
        }
        out.append(0x3b)
        putCharsetKey(charsets.current)
        put("\u{1b}\\")
    }

    // MARK: Modes

    /// After both buffers, because origin and margin mode change what a
    /// position means and a buffer switch shows the cursor. Each is written
    /// whichever way it stands, so the result does not lean on what the
    /// restoring terminal had.
    private mutating func writeModes() {
        put(terminal.insertMode ? "\u{1b}[4h" : "\u{1b}[4l")
        put(terminal.lineFeedMode ? "\u{1b}[20h" : "\u{1b}[20l")
        put(terminal.applicationCursor ? "\u{1b}[?1h" : "\u{1b}[?1l")
        put(terminal.applicationKeypad ? "\u{1b}[?66h" : "\u{1b}[?66l")
        put(terminal.smoothScroll ? "\u{1b}[?4h" : "\u{1b}[?4l")
        put(terminal.reverseColors ? "\u{1b}[?5h" : "\u{1b}[?5l")
        put(terminal.cursorBlink ? "\u{1b}[?12h" : "\u{1b}[?12l")
        put(terminal.allow80To132 ? "\u{1b}[?40h" : "\u{1b}[?40l")
        // Reverse wraparound can only be turned on while wraparound is on.
        put(terminal.reverseWraparound ? "\u{1b}[?7h\u{1b}[?45h" : "\u{1b}[?45l")
        put(terminal.wraparound ? "\u{1b}[?7h" : "\u{1b}[?7l")
        put(terminal.marginMode ? "\u{1b}[?69h" : "\u{1b}[?69l")
        put(terminal.originMode ? "\u{1b}[?6h" : "\u{1b}[?6l")
        put(terminal.bracketedPasteMode ? "\u{1b}[?2004h" : "\u{1b}[?2004l")
        put(terminal.alternateScrollMode ? "\u{1b}[?1007h" : "\u{1b}[?1007l")

        switch terminal.mouseMode {
        case .off: put("\u{1b}[?1003l")
        case .x10: put("\u{1b}[?9h")
        case .vt200: put("\u{1b}[?1000h")
        case .buttonEventTracking: put("\u{1b}[?1002h")
        case .anyEvent: put("\u{1b}[?1003h")
        }
        switch terminal.snapshotMouseProtocol {
        case .x10: put("\u{1b}[?1006l")
        case .utf8: put("\u{1b}[?1005h")
        case .sgr: put("\u{1b}[?1006h")
        case .urxvt: put("\u{1b}[?1015h")
        case .sgrPixel: put("\u{1b}[?1016h")
        }
        put(terminal.mouseShiftCapture ? "\u{1b}[>1s" : "\u{1b}[>0s")

        // ?1004h would report the focus at once.
        put("\u{1b}[?1004l")
        if terminal.sendFocus {
            verb("focus")
        }

        switch terminal.conformance {
        case .vt100: put("\u{1b}[61\"p")
        case .vt200: put("\u{1b}[62\"p")
        case .vt300: put("\u{1b}[63\"p")
        case .vt400: put("\u{1b}[64\"p")
        case .vt500: put("\u{1b}[65\"p")
        }
        put(terminal.cc.send8bit ? "\u{1b} G" : "\u{1b} F")

        put("\u{1b}[")
        put(snapshotCursorStyleCode(terminal.options.cursorStyle))
        put(" q")

        put(terminal.xtermTitleSetHex ? "\u{1b}[>0t" : "\u{1b}[>0T")
        put(terminal.xtermTitleQueryHex ? "\u{1b}[>1t" : "\u{1b}[>1T")
        put(terminal.xtermTitleSetUtf ? "\u{1b}[>2t" : "\u{1b}[>2T")
        put(terminal.xtermTitleQueryUtf ? "\u{1b}[>3t" : "\u{1b}[>3T")
    }

    private mutating func writeTitles() {
        for title in terminal.terminalTitleStack {
            put("\u{1b}]2;")
            putOscText(title)
            put("\u{1b}\\\u{1b}[22;2t")
        }
        for title in terminal.terminalIconStack {
            put("\u{1b}]1;")
            putOscText(title)
            put("\u{1b}\\\u{1b}[22;1t")
        }
        // A terminal nothing has titled stays untitled: an empty OSC 2
        // would tell the restoring view to clear the title it shows.
        if !terminal.terminalTitle.isEmpty || !terminal.terminalTitleStack.isEmpty {
            put("\u{1b}]2;")
            putOscText(terminal.terminalTitle)
            put("\u{1b}\\")
        }
        if !terminal.iconTitle.isEmpty || !terminal.terminalIconStack.isEmpty {
            put("\u{1b}]1;")
            putOscText(terminal.iconTitle)
            put("\u{1b}\\")
        }
        if let directory = terminal.hostCurrentDirectory {
            put("\u{1b}]7;")
            putOscText(directory)
            put("\u{1b}\\")
        }
        if let document = terminal.hostCurrentDocument {
            put("\u{1b}]6;")
            putOscText(document)
            put("\u{1b}\\")
        }
    }

    /// Only what a program set. The palette, ground and ink the embedder
    /// installed are the restoring terminal's own, and an OSC 11 here would
    /// repaint its ground with the source's.
    private mutating func writeColors() {
        // Ground and ink first: setting either rebuilds the palette.
        if terminal.programSetForegroundColor {
            put("\u{1b}]10;")
            out.append(contentsOf: terminal.foregroundColor.formatAsXcolor().utf8)
            put("\u{1b}\\")
        }
        if terminal.programSetBackgroundColor {
            put("\u{1b}]11;")
            out.append(contentsOf: terminal.backgroundColor.formatAsXcolor().utf8)
            put("\u{1b}\\")
        }
        if terminal.programSetCursorColor, let color = terminal.cursorColor {
            put("\u{1b}]12;")
            out.append(contentsOf: color.formatAsXcolor().utf8)
            put("\u{1b}\\")
        }
        let current = terminal.ansiColors
        let defaults = terminal.defaultAnsiColors
        for index in 0..<min(current.count, defaults.count) where current[index] != defaults[index] {
            put("\u{1b}]4;")
            put(index)
            out.append(0x3b)
            out.append(contentsOf: current[index].formatAsXcolor().utf8)
            put("\u{1b}\\")
        }
    }

    // MARK: Tail

    /// The half-parsed sequence, so the restoring parser stops where this
    /// one did and the next bytes of the stream finish it.
    private mutating func writeTail() {
        let parser = terminal.parser
        if parser.currentState == .ground {
            // Only a character's first bytes can be waiting here.
            out.append(contentsOf: terminal.snapshotPartialCharacter)
            return
        }
        if !parser.pendingOverflow {
            out.append(contentsOf: parser.pendingBytes)
            return
        }
        // Too long to carry. Open a sequence of the same kind with nothing
        // in it, so the rest of the payload is swallowed as it would have
        // been and its end does nothing.
        switch parser.currentState {
        case .oscString:
            put("\u{1b}]X")
        case .apcString:
            put("\u{1b}_X")
        case .sosPmApcString:
            put("\u{1b}^")
        case .dcsEntry, .dcsParam, .dcsIgnore, .dcsIntermediate, .dcsPassthrough:
            put("\u{1b}Pz")
        case .csiEntry, .csiParam, .csiIntermediate, .csiIgnore:
            put("\u{1b}[<<")
        case .escape, .escapeIntermediate:
            put("\u{1b}!!")
        case .ground:
            break
        }
    }
}

// MARK: - Restore

extension Terminal {
    /// The fork-private sequences a snapshot uses. `content` is the APC
    /// string after its first byte. Returns false for anything else that
    /// starts with an "s".
    func handleSnapshotSequence(_ content: ArraySlice<UInt8>) -> Bool {
        let prefix = snapshotPrefix.dropFirst()
        guard content.starts(with: prefix) else {
            return false
        }
        let fields = content.dropFirst(prefix.count).split(separator: 0x3b, omittingEmptySubsequences: false)
        guard let name = fields.first else {
            return true
        }
        let arguments = Array(fields.dropFirst())
        let row = buffer.yBase + buffer.y
        switch String(decoding: name, as: UTF8.self) {
        case "wrap":
            if row >= 0 && row < buffer.lines.count {
                buffer.lines[row].isWrapped = true
            }
        case "pendingwrap":
            buffer.x = cols
        case "focus":
            sendFocus = true
        case "bidi":
            if let bits = snapshotInt(arguments.first), row >= 0, row < buffer.lines.count {
                buffer.lines[row].bidiState = BidiPresentationState(snapshotBits: bits)
            }
        case "saved":
            restoreSavedCursor(arguments)
        case "charsets":
            restoreCharsets(arguments)
        case "cells":
            restoreCells(arguments)
        default:
            break
        }
        return true
    }

    private func snapshotInt(_ field: ArraySlice<UInt8>?) -> Int? {
        guard let field else { return nil }
        return EscapeSequenceParser.parseDecimal(field)
    }

    private func snapshotCharset(_ field: ArraySlice<UInt8>?) -> [UInt8: String]? {
        guard let value = snapshotInt(field), value >= 0, value <= 255 else {
            return nil
        }
        return CharSets.all[UInt8(value)]
    }

    private func restoreSavedCursor(_ arguments: [ArraySlice<UInt8>]) {
        guard arguments.count >= 7,
              let x = snapshotInt(arguments[0]), let y = snapshotInt(arguments[1]) else {
            return
        }
        buffer.savedX = min(x, cols)
        buffer.savedY = min(y, rows - 1)
        buffer.savedAttr = snapshotPen
        buffer.savedOriginMode = snapshotInt(arguments[2]) == 1
        buffer.savedMarginMode = snapshotInt(arguments[3]) == 1
        buffer.savedWraparound = snapshotInt(arguments[4]) == 1
        buffer.savedReverseWraparound = snapshotInt(arguments[5]) == 1
        buffer.savedCharset = snapshotCharset(arguments[6])
    }

    private func restoreCharsets(_ arguments: [ArraySlice<UInt8>]) {
        guard arguments.count >= 6, let level = snapshotInt(arguments[0]), level >= 0, level <= 3 else {
            return
        }
        snapshotSetCharsets(level: UInt8(level),
                            designated: (1...4).map { snapshotCharset(arguments[$0]) },
                            current: snapshotCharset(arguments[5]))
    }

    private func snapshotColor(_ field: ArraySlice<UInt8>) -> Attribute.Color? {
        guard let tag = field.first else { return nil }
        let rest = field.dropFirst()
        switch tag {
        case 0x64: // d
            return rest.isEmpty ? .defaultColor : nil
        case 0x69: // i
            return rest.isEmpty ? .defaultInvertedColor : nil
        case 0x70: // p
            guard let code = EscapeSequenceParser.parseDecimal(rest), code <= 255 else { return nil }
            return .ansi256(code: UInt8(code))
        case 0x74: // t
            guard let value = UInt32(String(decoding: rest, as: UTF8.self), radix: 16), value <= 0xFFFFFF else {
                return nil
            }
            return .trueColor(red: UInt8(value >> 16), green: UInt8((value >> 8) & 0xff), blue: UInt8(value & 0xff))
        default:
            return nil
        }
    }

    /// cells;fg;bg;style;underline style;underline colour;cell,cell,...
    /// Each cell is its width as one digit, then its scalars in hex joined
    /// with dots (none for an empty cell). Written from the cursor, on its
    /// row, without moving it; the active link is stamped on each.
    private func restoreCells(_ arguments: [ArraySlice<UInt8>]) {
        guard arguments.count >= 6,
              let fg = snapshotColor(arguments[0]), let bg = snapshotColor(arguments[1]),
              let style = snapshotInt(arguments[2]), style <= 255,
              let underline = snapshotInt(arguments[3]),
              let underlineStyle = UnderlineStyle(rawValue: UInt8(truncatingIfNeeded: min(underline, 255))) else {
            return
        }
        let underlineColor: Attribute.Color?
        if arguments[4].elementsEqual([0x6e]) {
            underlineColor = nil
        } else if let color = snapshotColor(arguments[4]) {
            underlineColor = color
        } else {
            return
        }
        let attribute = Attribute(fg: fg, bg: bg, style: CharacterStyle(rawValue: UInt8(style)),
                                  underlineStyle: underlineStyle, underlineColor: underlineColor)
        let row = buffer.yBase + buffer.y
        guard row >= 0, row < buffer.lines.count else { return }
        let line = buffer.lines[row]
        let payload = snapshotResolveActiveHyperlink()
        var x = buffer.x
        for field in arguments[5].split(separator: 0x2c, omittingEmptySubsequences: false) {
            guard x < cols, x < line.count else { break }
            guard let digit = field.first, digit >= 0x30, digit <= 0x32 else { return }
            let width = Int8(digit - 0x30)
            var text = String.UnicodeScalarView()
            for part in field.dropFirst().split(separator: 0x2e) {
                guard let value = UInt32(String(decoding: part, as: UTF8.self), radix: 16),
                      let scalar = Unicode.Scalar(value) else {
                    return
                }
                text.append(scalar)
            }
            var cell: CharData
            if let character = String(text).first, text.first?.value != 0 {
                cell = makeCharData(attribute: attribute, char: character, size: width)
            } else {
                cell = CharData(attribute: attribute, code: 0, size: width)
            }
            if let payload {
                cell.setPayload(atom: payload)
            }
            line[x] = cell
            x += 1
        }
        updateRange(buffer.y)
    }
}

// MARK: - Digest

private struct SnapshotHasher {
    unowned let terminal: Terminal
    private(set) var value: UInt64 = 0xcbf29ce484222325

    private var payloadCode: UInt16 = 0
    private var payloadHash: UInt64 = 0

    init(terminal: Terminal) {
        self.terminal = terminal
    }

    @inline(__always)
    private mutating func add(_ word: UInt64) {
        value = (value ^ word) &* 0x100000001b3
        value ^= value >> 29
    }

    @inline(__always)
    private mutating func add(_ word: Int) {
        add(UInt64(bitPattern: Int64(word)))
    }

    @inline(__always)
    private mutating func add(_ flag: Bool) {
        add(flag ? 1 : 0 as UInt64)
    }

    private mutating func add(_ text: String?) {
        guard let text else {
            add(0xfffe as UInt64)
            return
        }
        for byte in text.utf8 {
            add(UInt64(byte))
        }
        add(0xffff as UInt64)
    }

    private mutating func add(_ bytes: [UInt8]) {
        add(bytes.count)
        for byte in bytes {
            add(UInt64(byte))
        }
    }

    @inline(__always)
    private func pack(_ color: Attribute.Color) -> UInt64 {
        switch color {
        case .defaultColor: return 1 << 32
        case .defaultInvertedColor: return 2 << 32
        case .ansi256(let code): return 3 << 32 | UInt64(code)
        case .trueColor(let red, let green, let blue):
            return 4 << 32 | UInt64(red) << 16 | UInt64(green) << 8 | UInt64(blue)
        }
    }

    @inline(__always)
    private mutating func add(_ attribute: Attribute) {
        add(pack(attribute.fg))
        add(pack(attribute.bg))
        add(UInt64(attribute.style.rawValue) << 8 | UInt64(attribute.underlineStyle.rawValue))
        add(attribute.underlineColor.map { pack($0) } ?? 0)
    }

    private mutating func add(_ color: Color) {
        add(UInt64(color.red) << 32 | UInt64(color.green) << 16 | UInt64(color.blue))
    }

    private mutating func add(line: BufferLine, cols: Int) {
        add((line.isWrapped ? 1 : 0) | Int(snapshotRenderModeCode(line.renderMode)) << 1
            | line.bidiState.snapshotBits << 9)
        for x in 0..<min(line.count, cols) {
            let cell = line[x]
            let code = cell.code
            if code >= 0 && code <= Int32(CharData.maxRune) {
                add(UInt64(code) << 8 | UInt64(UInt8(bitPattern: cell.width)))
            } else {
                // A cluster is a per-terminal index: hash what it stands for.
                for scalar in terminal.getCharacter(for: cell).unicodeScalars {
                    add(UInt64(scalar.value) << 8 | 0xff)
                }
                add(UInt64(UInt8(bitPattern: cell.width)))
            }
            add(cell.attribute)
            let payload = cell.payload.code
            if payload != 0 {
                // So is a payload atom: hash the link it names.
                if payload != payloadCode {
                    payloadCode = payload
                    var inner = SnapshotHasher(terminal: terminal)
                    inner.add(cell.payload.target as? String)
                    payloadHash = inner.value
                }
                add(payloadHash)
            }
        }
    }

    private mutating func add(buffer: Buffer, alternate: Bool, includeScrollback: Bool) {
        let cols = terminal.cols
        let range = snapshotRowRange(of: buffer, rows: terminal.rows, includeScrollback: includeScrollback)
        let first = range.lowerBound
        let last = range.upperBound
        add(last - first)
        if first < last {
            let lines = buffer.lines
            for row in first..<last {
                add(line: lines[row], cols: cols)
            }
        }
        add(buffer.x)
        add(buffer.y)
        add(buffer.scrollTop)
        add(buffer.scrollBottom)
        add(buffer.marginLeft)
        add(buffer.marginRight)
        let stops = buffer.tabStops
        for column in 0..<cols {
            add(column < stops.count && stops[column])
        }
        add(buffer.savedX)
        add(buffer.savedY)
        add(buffer.savedAttr)
        add(Int(snapshotCharsetKey(buffer.savedCharset) ?? 0))
        add(buffer.savedOriginMode)
        add(buffer.savedMarginMode)
        add(buffer.savedWraparound)
        add(buffer.savedReverseWraparound)
        let keyboard = terminal.snapshotKeyboardMode(alternate: alternate)
        add(keyboard.flags)
        add(keyboard.stack.count)
        for flags in keyboard.stack {
            add(flags)
        }
    }

    mutating func hash(includeScrollback: Bool) {
        let rows = terminal.rows
        let normal = terminal.normalBuffer
        let alt = terminal.altBuffer
        add(terminal.cols)
        add(rows)

        add(buffer: normal, alternate: false, includeScrollback: includeScrollback)
        add(buffer: alt, alternate: true, includeScrollback: includeScrollback)
        add(terminal.isCurrentBufferAlternate)

        add(terminal.snapshotPen)
        add(terminal.snapshotActiveHyperlink)
        let charsets = terminal.snapshotCharsets
        add(Int(terminal.gLevel))
        add(Int(snapshotCharsetKey(charsets.current) ?? 0))
        for table in charsets.designated {
            add(Int(snapshotCharsetKey(table) ?? 0))
        }

        add(terminal.applicationCursor)
        add(terminal.applicationKeypad)
        add(terminal.bracketedPasteMode)
        add(terminal.sendFocus)
        switch terminal.mouseMode {
        case .off: add(0 as UInt64)
        case .x10: add(1 as UInt64)
        case .vt200: add(2 as UInt64)
        case .buttonEventTracking: add(3 as UInt64)
        case .anyEvent: add(4 as UInt64)
        }
        switch terminal.snapshotMouseProtocol {
        case .x10: add(0 as UInt64)
        case .utf8: add(1 as UInt64)
        case .sgr: add(2 as UInt64)
        case .urxvt: add(3 as UInt64)
        case .sgrPixel: add(4 as UInt64)
        }
        add(terminal.mouseShiftCapture)
        add(terminal.alternateScrollMode)
        add(terminal.cursorHidden)
        add(snapshotCursorStyleCode(terminal.options.cursorStyle))
        add(terminal.cursorBlink)
        add(terminal.originMode)
        add(terminal.marginMode)
        add(terminal.insertMode)
        add(terminal.wraparound)
        add(terminal.reverseWraparound)
        add(terminal.reverseColors)
        add(terminal.lineFeedMode)
        add(terminal.smoothScroll)
        add(terminal.allow80To132)
        add(terminal.synchronizedOutputActive)
        switch terminal.conformance {
        case .vt100: add(1 as UInt64)
        case .vt200: add(2 as UInt64)
        case .vt300: add(3 as UInt64)
        case .vt400: add(4 as UInt64)
        case .vt500: add(5 as UInt64)
        }
        add(terminal.cc.send8bit)
        add(terminal.currentBidiState.snapshotBits)
        add(terminal.bidiArrowKeySwap)
        for (mode, saved) in terminal.snapshotSavedBidiPrivateModes.sorted(by: { $0.key < $1.key }) {
            add(mode)
            add(saved)
        }
        add(terminal.xtermTitleSetHex)
        add(terminal.xtermTitleQueryHex)
        add(terminal.xtermTitleSetUtf)
        add(terminal.xtermTitleQueryUtf)

        add(terminal.terminalTitle)
        add(terminal.iconTitle)
        add(terminal.terminalTitleStack.count)
        for title in terminal.terminalTitleStack {
            add(title)
        }
        add(terminal.terminalIconStack.count)
        for title in terminal.terminalIconStack {
            add(title)
        }
        add(terminal.hostCurrentDirectory)
        add(terminal.hostCurrentDocument)

        let current = terminal.ansiColors
        let defaults = terminal.defaultAnsiColors
        for index in 0..<min(current.count, defaults.count) where current[index] != defaults[index] {
            add(index)
            add(current[index])
        }
        add(terminal.programSetForegroundColor)
        if terminal.programSetForegroundColor {
            add(terminal.foregroundColor)
        }
        add(terminal.programSetBackgroundColor)
        if terminal.programSetBackgroundColor {
            add(terminal.backgroundColor)
        }
        if terminal.programSetCursorColor, let color = terminal.cursorColor {
            add(color)
        }

        let parser = terminal.parser
        add(UInt64(parser.currentState.rawValue))
        add(parser.pendingOverflow)
        add(parser.pendingBytes)
        add(terminal.snapshotPartialCharacter)
    }
}
