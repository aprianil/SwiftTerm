//
//  TerminalViewSearch.swift
//  SwiftTerm
//
//  Search integration for TerminalView.
//

#if os(macOS) || os(iOS) || os(visionOS)
import Foundation

/// One match of a search, in buffer rows: row 0 is the oldest line the
/// buffer keeps, not the top of the screen, so a match stays put while the
/// view scrolls.
public struct SearchMatch: Equatable, Sendable {
    /// The buffer row the match starts on.
    public let row: Int
    /// The match's first cell on that row.
    public let col: Int
    /// The match's width in cells, a wide glyph counting two. It runs past
    /// the row's end when the match crosses a soft wrap onto the next row.
    public let cells: Int

    public init (row: Int, col: Int, cells: Int) {
        self.row = row
        self.col = col
        self.cells = cells
    }
}

extension TerminalView {
    /// Every literal, case-insensitive match of `term` that starts in the
    /// buffer rows `rows`, top to bottom, at most `limit` of them: the
    /// newest, the ones nearest the bottom, when there are more. Rows below
    /// `rows` are never read. Selects nothing and scrolls nothing.
    ///
    /// The rows read are kept, and read again only once their line has
    /// changed, so a search after a feed reads the rows the feed wrote and
    /// no others. `forgetSearchAll` lets them go.
    public func searchAll (_ term: String, rows: Range<Int>, limit: Int) -> [SearchMatch] {
        guard let search else {
            return []
        }
        return search.searchAll(term: term, rows: rows, limit: limit).map {
            SearchMatch(row: $0.row, col: $0.col, cells: $0.size)
        }
    }

    /// Reads the rows a `searchAll` over `rows` would, ahead of it: the
    /// first search reads every row, which over a long scrollback is worth
    /// doing before a keystroke waits on it.
    public func prepareSearchAll (rows: Range<Int>) {
        search?.prepareSearchAll(rows: rows)
    }

    /// Lets go of the rows `searchAll` kept.
    public func forgetSearchAll () {
        search?.forgetIndex()
    }

    /// Finds the next match for `term`, selects it, and optionally scrolls it into view.
    /// - Parameters:
    ///   - term: The search term.
    ///   - options: Search options (case sensitivity, regex, whole word).
    ///   - scrollToResult: Whether to scroll the result into view.
    /// - Returns: `true` if a match was found.
    @discardableResult
    public func findNext (_ term: String, options: SearchOptions = SearchOptions(), scrollToResult: Bool = true) -> Bool {
        guard let search = search, let selection = selection else {
            return false
        }

        search.updateLastSelection(currentSearchSelection(selection))
        if let result = search.findNext(term: term, options: options) {
            return applySearchResult(result, selection: selection, scrollToResult: scrollToResult)
        }

        selection.selectNone()
        return false
    }

    /// Finds the previous match for `term`, selects it, and optionally scrolls it into view.
    /// - Parameters:
    ///   - term: The search term.
    ///   - options: Search options (case sensitivity, regex, whole word).
    ///   - scrollToResult: Whether to scroll the result into view.
    /// - Returns: `true` if a match was found.
    @discardableResult
    public func findPrevious (_ term: String, options: SearchOptions = SearchOptions(), scrollToResult: Bool = true) -> Bool {
        guard let search = search, let selection = selection else {
            return false
        }

        search.updateLastSelection(currentSearchSelection(selection))
        if let result = search.findPrevious(term: term, options: options) {
            return applySearchResult(result, selection: selection, scrollToResult: scrollToResult)
        }

        selection.selectNone()
        return false
    }


    /// Position of the current match among all matches for `term`: a 1-based
    /// `index` (0 when there is no current match) and the `total` match count
    /// (capped at `limit`). Drives a "2/14" style counter in a search UI.
    public func searchMatchSummary (_ term: String, options: SearchOptions = SearchOptions(), limit: Int = 1000) -> (index: Int, total: Int) {
        guard let search = search else {
            return (0, 0)
        }
        let all = search.findAll(term: term, options: options, limit: limit)
        guard let last = search.lastResult,
              let i = all.firstIndex(where: { $0.row == last.row && $0.col == last.col }) else {
            return (0, all.count)
        }
        return (i + 1, all.count)
    }

    /// Clears the current search state and selection.
    public func clearSearch () {
        search?.reset()
        selection?.selectNone()
    }

    private func applySearchResult (_ result: SearchResult, selection: SelectionService, scrollToResult: Bool) -> Bool {
        let range = search?.selectionRange(for: result) ?? (start: Position(col: result.col, row: result.row),
                                                           end: Position(col: result.col, row: result.row))
        selection.setSelection(start: range.start, end: range.end)
        if scrollToResult {
            scrollToReveal(row: result.row)
        }
        return true
    }

    private func currentSearchSelection (_ selection: SelectionService) -> SearchSelection? {
        guard selection.active else {
            return nil
        }
        let start = selection.start
        let end = selection.end
        switch Position.compare(start, end) {
        case .before, .equal:
            return SearchSelection(start: start, end: end)
        case .after:
            return SearchSelection(start: end, end: start)
        }
    }

    private func scrollToReveal (row: Int) {
        let displayBuffer = terminal.displayBuffer
        let rows = displayBuffer.rows
        guard rows > 0 else {
            return
        }
        if terminal.isDisplayBufferAlternate {
            return
        }

        let upperVisible = displayBuffer.yDisp
        let lowerVisible = displayBuffer.yDisp + rows - 1
        if row >= upperVisible && row <= lowerVisible {
            return
        }

        let maxScrollback = max(0, displayBuffer.lines.count - rows)
        var target = row - rows / 2
        if target < 0 {
            target = 0
        }
        if target > maxScrollback {
            target = maxScrollback
        }
        scrollTo(row: target)
    }
}
#endif
