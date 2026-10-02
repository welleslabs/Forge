import Foundation

// MARK: - Console Line

enum LineType {
    case stdout, stderr, stdin, system, success, warning, groupHeader
}

struct ConsoleLine: Identifiable, Sendable {
    let id = UUID()
    var text: String
    let type: LineType
    /// A line that belongs under the current attack — rendered with an indented left
    /// spine so it's visually bracketed to its group header (works without color).
    var inGroup = false
}

// MARK: - Console Block
//
// A console block: either a standalone line (header == nil) or an attack — a
// `.groupHeader` line plus the `inGroup` lines that follow it. Grouping is computed
// once per console revision and cached, so the view never re-folds the whole list per
// render.
struct ConsoleBlock: Identifiable {
    let id: UUID
    let header: ConsoleLine?
    let lines: [ConsoleLine]
}

// MARK: - Console Store
//
// Owns the console's line buffer and everything that turns raw subprocess output into
// renderable lines: ANSI stripping, system-noise filtering, carriage-return handling,
// and the grouping of lines into attack cards. Split out of DemoRunner so the runner can
// stay a thin coordinator. Lines are stored non-published (no per-append array diff);
// `lineRevision` is the published trigger that drives view refresh and memoizes grouping.
@MainActor
final class ConsoleStore: ObservableObject {
    private(set) var lines: [ConsoleLine] = []
    @Published private(set) var lineRevision = 0

    private var stdoutBuffer = ""
    private var stderrBuffer = ""

    // MARK: Mutations

    func append(_ text: String, type: LineType, inGroup: Bool = false) {
        lines.append(ConsoleLine(text: text, type: type, inGroup: inGroup))
        lineRevision &+= 1
    }

    func overwriteLast(_ text: String, type: LineType) {
        if lines.isEmpty {
            append(text, type: type)
        } else {
            lines[lines.count - 1] = ConsoleLine(text: text, type: type)
            lineRevision &+= 1
        }
    }

    func clear() {
        lines.removeAll()
        stdoutBuffer = ""
        stderrBuffer = ""
        lineRevision &+= 1
    }

    // MARK: Grouping (memoized against lineRevision)

    private var cachedBlocks: [ConsoleBlock] = []
    private var cachedBlocksRevision = -1
    var consoleBlocks: [ConsoleBlock] {
        if cachedBlocksRevision != lineRevision {
            cachedBlocks = Self.groupBlocks(lines)
            cachedBlocksRevision = lineRevision
        }
        return cachedBlocks
    }

    /// Fold the flat line list into blocks so each attack renders as one card.
    static func groupBlocks(_ all: [ConsoleLine]) -> [ConsoleBlock] {
        var blocks: [ConsoleBlock] = []
        var i = 0
        while i < all.count {
            let line = all[i]
            if line.type == .groupHeader {
                var sub: [ConsoleLine] = []
                var j = i + 1
                while j < all.count, all[j].inGroup { sub.append(all[j]); j += 1 }
                blocks.append(ConsoleBlock(id: line.id, header: line, lines: sub))
                i = j
            } else {
                blocks.append(ConsoleBlock(id: line.id, header: nil, lines: [line]))
                i += 1
            }
        }
        return blocks
    }

    // MARK: Raw output processing

    /// Turn a chunk of raw subprocess output into console lines: strip ANSI, buffer until
    /// a newline, collapse carriage-return overwrites (progress bars), and drop system noise.
    func processOutput(_ text: String, isError: Bool) {
        let stripped = stripANSI(text)
        var buf = (isError ? stderrBuffer : stdoutBuffer) + stripped

        while true {
            if let nlIdx = buf.firstIndex(of: "\n") {
                let segment = String(buf[buf.startIndex..<nlIdx])
                buf = String(buf[buf.index(after: nlIdx)...])
                // PTY uses \r\n endings; take the last non-empty part after splitting on \r
                // (also handles progress-bar-style \r overwrite within a line)
                let finalText = segment.components(separatedBy: "\r")
                    .filter { !$0.isEmpty }.last ?? ""
                if !finalText.isEmpty && !Self.isSystemNoise(finalText) {
                    let type: LineType = isError ? .stderr : .stdout
                    // Collapse a run of live progress frames (e.g. `ollama pull`'s
                    // download bar) onto a single self-updating line instead of letting
                    // hundreds of near-identical frames flood the console.
                    if Self.isProgressLine(finalText), let last = lines.last, Self.isProgressLine(last.text) {
                        overwriteLast(finalText, type: type)
                    } else {
                        append(finalText, type: type)
                    }
                }
            } else if buf.contains("\r") {
                let parts = buf.components(separatedBy: "\r")
                buf = parts.last ?? ""
                if let candidate = parts.dropLast().last,
                   !candidate.isEmpty && !Self.isSystemNoise(candidate) {
                    overwriteLast(candidate, type: isError ? .stderr : .stdout)
                }
                if !buf.isEmpty && !buf.contains("\r") { break }
            } else {
                break
            }
        }
        if isError { stderrBuffer = buf } else { stdoutBuffer = buf }
    }

    // MARK: System-noise filtering

    /// macOS system-framework debug noise that subprocess tools emit on launch.
    private static let noisePrefixes = [
        "<_Tt",                                     // mangled Swift class names from AppKit internals
        "Unable to re-register with Process",
        "Unable to get synchronous",
        "Will NOT re-try to establish",
        "Cannot index window tabs",
        "ViewBridge to RemoteViewService",
        "Unable to obtain a task name port",
    ]

    private static func isSystemNoise(_ line: String) -> Bool {
        noisePrefixes.contains { line.hasPrefix($0) }
    }

    /// A transient progress frame (a percentage + a size/rate or bar) — chiefly
    /// `ollama pull`'s download output. Consecutive frames overwrite each other so the
    /// download shows as one self-updating line rather than hundreds of stacked lines.
    private static func isProgressLine(_ s: String) -> Bool {
        guard s.range(of: #"\b\d{1,3}%"#, options: .regularExpression) != nil else { return false }
        return s.contains("/s") || s.contains("MB") || s.contains("GB") || s.contains("KB") || s.contains("|")
    }

    // MARK: ANSI stripping

    /// Compiled once and reused — stripANSI runs on every chunk of subprocess output, so
    /// recompiling the regex per call was pure overhead on a hot path.
    ///   CSI sequences: ESC [ [?!>]? params letter  (covers \e[?1049h, \e[38;5;Xm, etc.)
    ///   OSC sequences: ESC ] ... BEL-or-ST          (covers title-set and hyperlinks)
    ///   DCS/PM/APC:    ESC [P_^X] ... ST
    ///   Lone ESC:      ESC followed by a single non-introducer character
    private static let ansiRegex = try! NSRegularExpression(
        pattern: "\u{1B}\\[[?!>]?[0-9;]*[A-Za-z]"
               + "|\u{1B}\\][^\u{07}\u{1B}]*(?:\u{07}|\u{1B}\\\\)"
               + "|\u{1B}[PX\\^_][^\u{1B}]*\u{1B}\\\\"
               + "|\u{1B}[^\\[]")

    private func stripANSI(_ text: String) -> String {
        let range = NSRange(text.startIndex..., in: text)
        return Self.ansiRegex.stringByReplacingMatches(in: text, range: range, withTemplate: "")
    }
}
