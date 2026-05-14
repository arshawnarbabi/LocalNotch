import Foundation

struct GetFileInfo: AgentTool {
    static let name = "get_file_info"
    static let description = "Get metadata for a file or folder: size, type, modification date, creation date, permissions."
    static let riskLevel: RiskLevel = .readonly

    static let parameterSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "path": ["type": "string", "description": "Path to the file or directory. Supports ~."]
        ] as [String: Any],
        "required": ["path"]
    ]

    static func execute(arguments: [String: Any]) async throws -> ToolResult {
        guard let rawPath = arguments["path"] as? String else {
            return .fail("Missing required argument: path")
        }
        let path = NSString(string: rawPath).expandingTildeInPath
        let fm = FileManager.default
        guard fm.fileExists(atPath: path) else { return .fail("Path does not exist: \(rawPath)") }

        let attrs: [FileAttributeKey: Any]
        do {
            attrs = try fm.attributesOfItem(atPath: path)
        } catch {
            return .fail("Cannot read attributes: \(error.localizedDescription)")
        }

        let df = DateFormatter()
        df.dateStyle = .medium; df.timeStyle = .short

        var lines: [String] = []
        lines.append("path: \(rawPath)")
        lines.append("type: \((attrs[.type] as? FileAttributeType)?.rawValue ?? "unknown")")
        if let size = attrs[.size] as? Int { lines.append("size: \(size) bytes") }
        if let mod = attrs[.modificationDate] as? Date { lines.append("modified: \(df.string(from: mod))") }
        if let cre = attrs[.creationDate] as? Date { lines.append("created: \(df.string(from: cre))") }
        if let perms = attrs[.posixPermissions] as? Int {
            lines.append("permissions: \(String(perms, radix: 8))")
        }

        return .ok(lines.joined(separator: "\n"))
    }
}
