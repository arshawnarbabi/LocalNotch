import Foundation
import PDFKit

struct ReadFile: AgentTool {
    static let name = "read_file"
    static let description = "Read the text contents of a file. Text and PDF files are supported (PDF text is extracted automatically); other binary files are rejected. Returns up to ~16 KB per call — for larger files page through with offset/limit (line numbers)."
    static let riskLevel: RiskLevel = .readonly
    static let maxBytes = 1_048_576 // 1 MB — how much of the file we read off disk (for line counting / paging)
    // Cap on text RETURNED to the model in one call. A single tool result must stay small relative
    // to the model's working context window (~16 K tokens). ~16 KB ≈ ~5.3 K tokens, so even two such
    // results plus the system prompt and tool schemas fit comfortably; larger files page via offset/limit.
    static let maxReturnBytes = 16_000

    static let parameterSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "path": ["type": "string", "description": "File path to read. Supports ~."],
            "offset": ["type": "integer", "description": "1-based line number to start from. Optional; default 1."],
            "limit": ["type": "integer", "description": "Max number of lines to return. Optional; default all (within the size cap)."]
        ] as [String: Any],
        "required": ["path"]
    ]

    static func execute(arguments: [String: Any]) async throws -> ToolResult {
        guard let rawPath = arguments["path"] as? String else {
            return .fail("Missing required argument: path")
        }
        let path = (NSString(string: rawPath).expandingTildeInPath as NSString).standardizingPath
        let fm = FileManager.default
        guard fm.fileExists(atPath: path) else {
            return .fail("File not found: \(rawPath). Call list_directory on its parent folder to see what's actually there.")
        }

        var isDir: ObjCBool = false
        fm.fileExists(atPath: path, isDirectory: &isDir)
        if isDir.boolValue {
            return .fail("Path is a directory, not a file: \(rawPath). Use list_directory to see its contents.")
        }

        // PDFs: extract real text via PDFKit rather than reading raw bytes (which are binary).
        if path.lowercased().hasSuffix(".pdf") {
            return readPDF(path: path, rawPath: rawPath, arguments: arguments)
        }

        guard let data = fm.contents(atPath: path) else {
            return .fail("Cannot read file: \(rawPath)")
        }
        let byteTruncated = data.count > maxBytes
        let slice = byteTruncated ? data.prefix(maxBytes) : data

        // Reject genuine binary files. A NUL byte essentially never appears in text but is ubiquitous
        // in binaries; latin1 would otherwise happily decode binary into garbage and flood the context
        // (the bug that blew the context window on a PDF). Scan the WHOLE (≤1 MB) slice, not just a
        // prefix — a binary can be NUL-free for its first few KB.
        if slice.contains(0) {
            return .fail("File appears to be binary, not text: \(rawPath). read_file only supports text and PDF files.")
        }

        guard let text = String(data: slice, encoding: .utf8) ?? String(data: slice, encoding: .isoLatin1) else {
            return .fail("File does not appear to be text (binary file?): \(rawPath)")
        }
        if text.isEmpty { return .ok("(file is empty)") }

        return paginate(text: text, byteTruncated: byteTruncated, totalBytes: data.count, cap: maxReturnBytes, arguments: arguments)
    }

    // Extract text from a PDF and page through it like any other text file.
    private static func readPDF(path: String, rawPath: String, arguments: [String: Any]) -> ToolResult {
        guard let doc = PDFDocument(url: URL(fileURLWithPath: path)) else {
            return .fail("Could not open PDF (it may be corrupt or password-protected): \(rawPath)")
        }
        guard let text = doc.string, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .fail("No extractable text in PDF \(rawPath) — it may be a scanned/image-only document.")
        }
        let header = "[PDF: \(doc.pageCount) page\(doc.pageCount == 1 ? "" : "s"), text extracted]\n"
        // Reserve the header's length so header + body still fits within the per-call cap.
        let cap = max(1_000, maxReturnBytes - header.count)
        let result = paginate(text: text, byteTruncated: false, totalBytes: 0, cap: cap, arguments: arguments)
        if result.success, let body = result.output {
            return .ok(header + body, truncated: result.truncated, totalBytes: result.totalBytes)
        }
        return result
    }

    // Shared paging + size-cap logic for both text files and extracted PDF text. `cap` is the maximum
    // number of characters to return in this call. Guarantees the body never exceeds `cap`, even when
    // a single line is longer than the whole budget (minified JS/JSON, single-paragraph PDFs).
    private static func paginate(text: String, byteTruncated: Bool, totalBytes: Int, cap: Int, arguments: [String: Any]) -> ToolResult {
        let offset = arguments["offset"] as? Int
        let limit = (arguments["limit"] as? Int).flatMap { $0 > 0 ? $0 : nil }   // limit<=0 → treat as no limit (avoids empty-page loop)

        var lines = text.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }   // drop the empty element from a trailing newline
        let total = lines.count
        if total == 0 { return .ok("(file is empty)") }
        let start = max(0, (offset ?? 1) - 1)
        if start >= total {
            return .fail("offset \(offset ?? 1) is past end of file (\(total) lines).")
        }
        let requestedEnd = limit.map { min(total, start + $0) } ?? total

        // Accumulate whole lines until the next one would exceed the budget.
        var charsUsed = 0
        var end = start
        while end < requestedEnd {
            let lineCost = lines[end].count + 1   // +1 for the newline
            if charsUsed + lineCost > cap { break }
            charsUsed += lineCost
            end += 1
        }

        var out: String
        var lineCharTruncated = false
        if end == start {
            // Not even one whole line fit — return a character-truncated prefix of this one line so a
            // single huge line can never overflow the context. offset/limit page by LINE and cannot
            // page within a line, so this is flagged separately (no next-line offset to suggest).
            out = String(lines[start].prefix(cap))
            lineCharTruncated = true
            end = start + 1
        } else {
            out = lines[start..<end].joined(separator: "\n")
        }

        if lineCharTruncated {
            out += "\n[line \(start + 1) is very long — showing only its first \(cap) characters; offset/limit page by line and cannot page within a line]"
            // The long line's tail can't be paged within the line, but later lines still can —
            // give the resume offset so the model isn't stranded when more content follows.
            if end < total {
                out += "\n[\(total - end) more line\(total - end == 1 ? "" : "s") follow — continue with offset=\(end + 1)]"
            }
        } else if end < total {
            out += "\n[lines \(start + 1)–\(end) of \(total); read more with offset=\(end + 1)]"
        }
        if byteTruncated {
            out += "\n[file exceeds \(maxBytes / 1024) KB; only the first part was read — more content lies beyond the byte cap]"
        }
        let truncated = byteTruncated || lineCharTruncated || end < total
        // Only surface a byte total when we actually have a meaningful one (text files pass their
        // real data.count; PDFs pass 0 as "unknown"). Passing nil makes asString print a plain
        // "[truncated]" instead of a misleading "[truncated — 0 total bytes]".
        return .ok(out, truncated: truncated, totalBytes: (truncated && totalBytes > 0) ? totalBytes : nil)
    }
}
