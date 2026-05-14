import Foundation

struct ListDirectory: AgentTool {
    static let name = "list_directory"
    static let description = "List files and folders at a path. Returns names, types, and sizes. Hidden files excluded by default."
    static let riskLevel: RiskLevel = .readonly
    static let maxEntries = 500

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
        let path = NSString(string: rawPath).expandingTildeInPath
        let includeHidden = arguments["includeHidden"] as? Bool ?? false

        let fm = FileManager.default
        guard fm.fileExists(atPath: path) else {
            return .fail("Path does not exist: \(rawPath)")
        }

        var isDir: ObjCBool = false
        fm.fileExists(atPath: path, isDirectory: &isDir)
        guard isDir.boolValue else {
            return .fail("Path is not a directory: \(rawPath)")
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
            var entryIsDir: ObjCBool = false
            fm.fileExists(atPath: full, isDirectory: &entryIsDir)
            if entryIsDir.boolValue {
                lines.append("[DIR]  \(name)/")
            } else {
                let size = (try? fm.attributesOfItem(atPath: full)[.size] as? Int) ?? 0
                lines.append("[FILE] \(name)  (\(formatBytes(size)))")
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
