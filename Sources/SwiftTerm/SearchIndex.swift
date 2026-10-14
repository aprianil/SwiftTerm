//
//  SearchIndex.swift
//  SwiftTerm
//
//  The buffer's text, lowercased, kept in step with the buffer row by row,
//  for `searchAll`.
//

import Foundation

/// The buffer's text as one run of lowercased UTF-8 bytes, kept in step
/// with the buffer a row at a time, for repeated literal searches.
///
/// Reading rows into strings is most of what a search over a long buffer
/// costs, and a feed used to throw every string away (`SearchService`
/// invalidates its line cache on each one). Here a row is read again only
/// when its line changed: the same `BufferLine` object at the same index
/// with the same `generation` is the same text, the test the row render
/// cache already uses. A program can only write to the screen, so after a
/// push the rows to read again are the last screenful, and the rest of the
/// scrollback is searched as it was.
///
///     text   \nthe first row\nthe second row runs on to the next ro
///            w, a soft wrap\nthe fourth row
///            ↑ a row that does not continue the one above starts with
///              "\n", so no match runs from one line into the next
///
/// Nothing is trimmed: a row is all of its cells, a blank one a space, so
/// a byte is a cell until a row holds something other than one-cell ASCII,
/// and then the row keeps a map from its bytes to its cells.
final class SearchIndex {
    private let terminal: Terminal
    private weak var buffer: Buffer?
    private var cols = 0
    private var linesTop = 0

    private var text: [UInt8] = []
    /// One entry per indexed row, buffer row 0 first.
    private var lines: [BufferLine] = []
    private var generations: [UInt64] = []
    /// A row's first byte, after its "\n", and one past its last.
    private var starts: [Int] = []
    private var ends: [Int] = []
    /// The cell each of a row's bytes is in; nil when byte i is cell i.
    private var cellMaps: [[Int16]?] = []

    init (terminal: Terminal) {
        self.terminal = terminal
    }

    /// Lets go of everything read.
    func reset () {
        buffer = nil
        text = []
        lines = []
        generations = []
        starts = []
        ends = []
        cellMaps = []
    }

    /// Read the rows `0 ..< upper` now, so the first search does not.
    func prepare (upTo upper: Int) {
        sync(upTo: upper)
    }

    /// The last `limit` matches of `term` that start in buffer rows `rows`,
    /// lowercased both sides, top to bottom.
    func search (term: String, rows: Range<Int>, limit: Int) -> [SearchResult] {
        let needle = Array(term.lowercased().utf8)
        guard !needle.isEmpty, !needle.contains(10), limit > 0 else {
            return []
        }
        sync(upTo: rows.upperBound)
        let lower = max(0, rows.lowerBound)
        let upper = min(rows.upperBound, lines.count)
        guard lower < upper else {
            return []
        }
        let regionStart = starts[lower]
        let regionEnd = ends[upper - 1]

        // Back from the end a block at a time, so the newest are found
        // first and a term that is everywhere stops a block in.
        var blocks: [ArraySlice<Int>] = []
        var kept = 0
        text.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            needle.withUnsafeBytes { pattern in
                let blockSize = 32 * 1024
                var blockEnd = regionEnd
                while blockEnd > regionStart && kept < limit {
                    let blockStart = max(regionStart, blockEnd - blockSize)
                    // A match starts in the block and may run on past it.
                    let searchEnd = min(regionEnd, blockEnd + needle.count - 1)
                    var hits: [Int] = []
                    var from = blockStart
                    while from < blockEnd,
                          let found = memmem(base + from, searchEnd - from, pattern.baseAddress!, needle.count) {
                        let offset = base.distance(to: UnsafeRawPointer(found))
                        if offset >= blockEnd {
                            break
                        }
                        hits.append(offset)
                        from = offset + needle.count
                    }
                    let taken = hits.suffix(limit - kept)
                    if !taken.isEmpty {
                        blocks.append(taken)
                        kept += taken.count
                    }
                    blockEnd = blockStart
                }
            }
        }

        var results: [SearchResult] = []
        results.reserveCapacity(kept)
        var row = lower
        for offset in blocks.reversed().joined() {
            while row + 1 < upper && starts[row + 1] <= offset {
                row += 1
            }
            let startCell = cell(row: row, byte: offset)
            let last = offset + needle.count - 1
            var endRow = row
            while endRow + 1 < lines.count && ends[endRow] <= last {
                endRow += 1
            }
            let endCell = last + 1 < ends[endRow] ? cell(row: endRow, byte: last + 1) : cols
            results.append(SearchResult(term: term, col: startCell, row: row,
                                        size: (endRow - row) * cols + endCell - startCell))
        }
        return results
    }

    private func cell (row: Int, byte: Int) -> Int {
        let index = byte - starts[row]
        guard let map = cellMaps[row] else {
            return index
        }
        return Int(map[index])
    }

    /// Bring the indexed rows `0 ..< upper` in step with the buffer: drop
    /// what was trimmed off the top, keep every row whose line is unchanged
    /// down to the first that changed, and read the rest again.
    private func sync (upTo upper: Int) {
        let buffer = terminal.displayBuffer
        if buffer !== self.buffer || terminal.cols != cols || buffer.linesTop < linesTop {
            reset()
            self.buffer = buffer
            cols = terminal.cols
            linesTop = buffer.linesTop
        }
        let trimmed = min(buffer.linesTop - linesTop, lines.count)
        linesTop = buffer.linesTop
        if trimmed > 0 {
            lines.removeFirst(trimmed)
            generations.removeFirst(trimmed)
            starts.removeFirst(trimmed)
            ends.removeFirst(trimmed)
            cellMaps.removeFirst(trimmed)
        }

        let bufferLines = buffer.lines
        let wanted = min(upper, bufferLines.count)
        var valid = 0
        let checkable = min(lines.count, wanted)
        while valid < checkable {
            let line = bufferLines[valid]
            if line !== lines[valid] || line.generation != generations[valid] {
                break
            }
            valid += 1
        }
        if valid < lines.count {
            let cut = lines.count - valid
            lines.removeLast(cut)
            generations.removeLast(cut)
            starts.removeLast(cut)
            ends.removeLast(cut)
            cellMaps.removeLast(cut)
        }
        // Keep the bytes of the rows kept, and let the dead front go once
        // it is most of the run.
        text.removeLast(text.count - (ends.last ?? 0))
        if let first = starts.first, first > 64 * 1024, first > text.count / 2 {
            let dead = first
            text.removeFirst(dead)
            for index in starts.indices {
                starts[index] -= dead
                ends[index] -= dead
            }
        }
        if lines.isEmpty {
            text.removeAll(keepingCapacity: true)
        }
        for row in valid..<max(valid, wanted) {
            append(bufferLines[row], continues: row > 0 && bufferLines[row].isWrapped)
        }
    }

    private func append (_ line: BufferLine, continues: Bool) {
        if !continues {
            text.append(10)
        }
        let start = text.count
        var map: [Int16]? = nil
        let count = min(line.count, cols)
        for column in 0..<count {
            let cell = line[column]
            if cell.width == 0 {
                // The second half of a wide glyph.
                continue
            }
            let code = cell.code
            if code >= 0 && code < 128 {
                if map == nil && text.count - start != column {
                    map = (start..<text.count).map { Int16($0 - start) }
                }
                var byte = code == 0 ? 32 : UInt8(code)
                if byte >= 65 && byte <= 90 {
                    byte += 32
                }
                text.append(byte)
                map?.append(Int16(column))
            } else {
                if map == nil {
                    map = (start..<text.count).map { Int16($0 - start) }
                }
                for byte in String(terminal.getCharacter(for: cell)).lowercased().utf8 {
                    text.append(byte)
                    map!.append(Int16(column))
                }
            }
        }
        lines.append(line)
        generations.append(line.generation)
        starts.append(start)
        ends.append(text.count)
        cellMaps.append(map)
    }
}
