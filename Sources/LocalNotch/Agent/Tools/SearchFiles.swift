import Foundation

struct SearchFiles: AgentTool {
    static let name = "search_files"
    static let description = "Find files and folders by name pattern within a directory tree. Supports glob wildcards (* and ?). Returns full paths."
    static let riskLevel: RiskLevel = .readonly
    static let maxMatches = 200

    static let parameterSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "query": ["type": "string", "description": "Name pattern to search for. Supports * and ? wildcards. Case-insensitive."],
            "path": ["type": "string", "description": "Root directory to search in. Supports ~. Defaults to home directory if omitted."],
            "includeHidden": ["type": "boolean", "description": "Include hidden files/folders (starting with '.'). Default false."]
        ] as [String: Any],
        "required": ["query"]
    ]

    static func execute(arguments: [String: Any]) async throws -> ToolResult {
        guard let query = arguments["query"] as? String, !query.isEmpty else {
            return .fail("Missing required argument: query")
        }
        let rawPath = arguments["path"] as? String ?? "~"
        let root = NSString(string: rawPath).expandingTildeInPath
        let includeHidden = arguments["includeHidden"] as? Bool ?? false

        let fm = FileManager.default
        guard fm.fileExists(atPath: root) else { return .fail("Search path does not exist: \(rawPath)") }

        var matches: [String] = []
        var totalMatches = 0

        guard let enumerator = fm.enumerator(atPath: root) else {
            return .fail("Cannot enumerate directory: \(rawPath)")
        }
        // Use nextObject() instead of for-in — NSEnumerator.makeIterator() is @available(*, noasync).
        while let obj = enumerator.nextObject(), let relativePath = obj as? String {
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

        let truncated = totalMatches > maxMatches
        if matches.isEmpty { return .ok("No files matching '\(query)' found in \(rawPath).") }
        return .ok(matches.joined(separator: "\n"),
                   truncated: truncated,
                   totalEntries: truncated ? totalMatches : nil)
    }
}
