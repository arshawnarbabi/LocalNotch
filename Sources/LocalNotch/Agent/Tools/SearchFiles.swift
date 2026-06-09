import Foundation

struct SearchFiles: AgentTool {
    static let name = "search_files"
    static let description = "Find files and folders by name pattern within a directory tree. Supports glob wildcards (* and ?). Returns full paths, or just a count with mode=\"count\" (use that first on large trees). Pass sort=\"modified\"/\"size\" (+ optional limit) to get the newest or largest matches WITH their size and date in one call — don't get_file_info each result to rank them."
    static let riskLevel: RiskLevel = .readonly
    static let maxMatches = 200

    static let parameterSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "query": ["type": "string", "description": "Name pattern to search for. Supports * and ? wildcards. Case-insensitive."],
            "path": ["type": "string", "description": "Root directory to search in. Supports ~. Defaults to home directory if omitted."],
            "includeHidden": ["type": "boolean", "description": "Include hidden files/folders (starting with '.'). Default false."],
            "mode": ["type": "string", "description": "\"paths\" (default) returns matching full paths; \"count\" returns only the number of matches — cheap, use it first on a big tree."],
            "sort": ["type": "string", "description": "Sort results and annotate each with size + last-modified date: \"modified\" (newest first), \"size\" (largest first), or \"name\". Use this to find e.g. the most recent matches in ONE call."],
            "limit": ["type": "integer", "description": "With sort, return only the top N results. Optional."]
        ] as [String: Any],
        "required": ["query"]
    ]

    private static func formatBytes(_ bytes: Int) -> String {
        if bytes < 1024 { return "\(bytes) B" }
        if bytes < 1_048_576 { return String(format: "%.1f KB", Double(bytes) / 1024) }
        return String(format: "%.1f MB", Double(bytes) / 1_048_576)
    }

    static func execute(arguments: [String: Any]) async throws -> ToolResult {
        guard let query = arguments["query"] as? String, !query.isEmpty else {
            return .fail("Missing required argument: query")
        }
        let rawPath = arguments["path"] as? String ?? "~"
        let root = (NSString(string: rawPath).expandingTildeInPath as NSString).standardizingPath
        let includeHidden = arguments["includeHidden"] as? Bool ?? false

        let fm = FileManager.default
        guard fm.fileExists(atPath: root) else { return .fail("Search path does not exist: \(rawPath)") }

        var matches: [String] = []
        var totalMatches = 0
        var iterCount = 0
        var cancelled = false

        guard let enumerator = fm.enumerator(atPath: root) else {
            return .fail("Cannot enumerate directory: \(rawPath)")
        }
        // Use nextObject() instead of for-in — NSEnumerator.makeIterator() is @available(*, noasync).
        while let obj = enumerator.nextObject(), let relativePath = obj as? String {
            iterCount += 1
            if iterCount % 50 == 0 && Task.isCancelled { cancelled = true; break }
            let components = relativePath.split(separator: "/")
            let name = String(components.last ?? Substring(relativePath))
            if !includeHidden && components.contains(where: { $0.hasPrefix(".") }) {
                enumerator.skipDescendants()
                continue
            }
            if fnmatch(query, name, FNM_CASEFOLD) == 0 {
                totalMatches += 1
                if matches.count < maxMatches {
                    matches.append((root as NSString).appendingPathComponent(relativePath))
                }
            }
        }

        // count mode: just the number — avoids flooding the small local context on big trees.
        if (arguments["mode"] as? String)?.lowercased() == "count" {
            let note = cancelled ? " (search interrupted — at least this many)" : ""
            return .ok("\(totalMatches) match\(totalMatches == 1 ? "" : "es") for '\(query)' in \(rawPath)\(note).")
        }

        let truncated = totalMatches > maxMatches
        if matches.isEmpty {
            return .ok("No files matching '\(query)' found in \(rawPath). Try a broader pattern (e.g. *\(query)*) or verify the path with list_directory.")
        }

        // Sorted mode: annotate each match with size + modified date and rank them, so callers can
        // get e.g. "the 4 newest PDFs" in ONE call instead of get_file_info-ing every result.
        if let sortKey = (arguments["sort"] as? String)?.lowercased(),
           ["modified", "size", "name"].contains(sortKey) {
            struct Entry { let path: String; let size: Int; let mtime: Date? }
            var entries = matches.map { p -> Entry in
                let a = try? fm.attributesOfItem(atPath: p)
                return Entry(path: p, size: (a?[.size] as? Int) ?? 0, mtime: a?[.modificationDate] as? Date)
            }
            switch sortKey {
            case "modified": entries.sort { ($0.mtime ?? .distantPast) > ($1.mtime ?? .distantPast) }
            case "size":     entries.sort { $0.size > $1.size }
            default:         entries.sort { $0.path.localizedCaseInsensitiveCompare($1.path) == .orderedAscending }
            }
            if let limit = (arguments["limit"] as? Int), limit > 0 { entries = Array(entries.prefix(limit)) }
            let df = ListDirectory.dateFormatter
            let lines = entries.map { e in
                "\(e.path)  (\(SearchFiles.formatBytes(e.size)), modified \(e.mtime.map { df.string(from: $0) } ?? "—"))"
            }
            return .ok(lines.joined(separator: "\n"),
                       truncated: truncated,
                       totalEntries: truncated ? totalMatches : nil)
        }

        return .ok(matches.joined(separator: "\n"),
                   truncated: truncated,
                   totalEntries: truncated ? totalMatches : nil)
    }
}
