import Foundation

struct OverwriteFile: AgentTool {
    static let name = "overwrite_file"
    static let description = "Replace the entire contents of an existing text file with new content. Creates the file if it does not exist. Always requires user approval — do not call this without a [NEEDS_APPROVAL] response from the user."
    static let riskLevel: RiskLevel = .destructive

    static let parameterSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "path": ["type": "string", "description": "Path of the file to write. Supports ~."],
            "content": ["type": "string", "description": "New UTF-8 text content to write to the file."]
        ] as [String: Any],
        "required": ["path", "content"]
    ]

    static func execute(arguments: [String: Any]) async throws -> ToolResult {
        guard let rawPath = arguments["path"] as? String,
              let content = arguments["content"] as? String else {
            return .fail("Missing required arguments: path, content")
        }
        let path = NSString(string: rawPath).expandingTildeInPath
        let fm = FileManager.default

        let parent = (path as NSString).deletingLastPathComponent
        if !fm.fileExists(atPath: parent) {
            do { try fm.createDirectory(atPath: parent, withIntermediateDirectories: true) }
            catch { return .fail("Cannot create parent directory: \(error.localizedDescription)") }
        }

        guard let data = content.data(using: .utf8) else {
            return .fail("Content could not be encoded as UTF-8")
        }

        do {
            try data.write(to: URL(fileURLWithPath: path), options: .atomic)
            return .ok("Written \(data.count) bytes to \(rawPath)")
        } catch {
            return .fail("Write failed: \(error.localizedDescription)")
        }
    }
}
