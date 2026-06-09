import Foundation

struct ListDirectory: AgentTool {
    static let name = "list_directory"
    static let description = "List files and folders at a path. Returns each entry's name, type, size, and last-modified date — enough to rank by recency or size in ONE call (no need to get_file_info each file). Hidden files excluded by default."
    static let riskLevel: RiskLevel = .readonly
    static let maxEntries = 500

    // Deterministic short timestamp for listings (POSIX locale so it doesn't vary by user settings).
    static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f
    }()

    static let parameterSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "path": ["type": "string", "description": "Directory path to list. Supports ~ for home directory."],
            "includeHidden": ["type": "boolean", "description": "Include files starting with '.'. Default false."]
        ] as [String: Any],
        "required": ["path"]
    ]

    static func execute(arguments: [String: Any]) async throws -> ToolResult {
        guard let rawPath = arguments["path"] as? String else {
            return .fail("Missing required argument: path")
        }
        let path = (NSString(string: rawPath).expandingTildeInPath as NSString).standardizingPath
        let includeHidden = arguments["includeHidden"] as? Bool ?? false

        let fm = FileManager.default
        guard fm.fileExists(atPath: path) else {
            return .fail("Path does not exist: \(rawPath). List its parent folder or use search_files to find the right path.")
        }

        var isDir: ObjCBool = false
        fm.fileExists(atPath: path, isDirectory: &isDir)
        guard isDir.boolValue else {
            return .fail("Path is not a directory: \(rawPath). It's a file — use read_file or get_file_info instead.")
        }

        let contents: [String]
        do {
            contents = try fm.contentsOfDirectory(atPath: path)
        } catch {
            return .fail("Cannot read directory: \(error.localizedDescription)")
        }

        let filtered = includeHidden ? contents : contents.filter { !$0.hasPrefix(".") }
        let sorted = filtered.sorted()
        let truncated = sorted.count > maxEntries
        let slice = truncated ? Array(sorted.prefix(maxEntries)) : sorted

        var lines: [String] = []
        for name in slice {
            let full = (path as NSString).appendingPathComponent(name)
            let attrs = try? fm.attributesOfItem(atPath: full)
            let mtime = (attrs?[.modificationDate] as? Date).map { dateFormatter.string(from: $0) } ?? "—"
            var entryIsDir: ObjCBool = false
            fm.fileExists(atPath: full, isDirectory: &entryIsDir)
            if entryIsDir.boolValue {
                lines.append("[DIR]  \(name)/  (modified \(mtime))")
            } else {
                let size = (attrs?[.size] as? Int) ?? 0
                lines.append("[FILE] \(name)  (\(formatBytes(size)), modified \(mtime))")
            }
        }

        return .ok(lines.joined(separator: "\n"),
                   truncated: truncated,
                   totalEntries: truncated ? filtered.count : nil)
    }

    private static func formatBytes(_ bytes: Int) -> String {
        if bytes < 1024 { return "\(bytes) B" }
        if bytes < 1_048_576 { return String(format: "%.1f KB", Double(bytes) / 1024) }
        return String(format: "%.1f MB", Double(bytes) / 1_048_576)
    }
}
