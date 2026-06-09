import Foundation

struct MoveFile: AgentTool {
    static let name = "move_file"
    static let description = "Move or rename a file or folder. The destination parent directory must exist."
    static let riskLevel: RiskLevel = .write

    static let parameterSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "from": ["type": "string", "description": "Current path of the file or folder. Supports ~."],
            "to": ["type": "string", "description": "Destination path (full path including filename). Supports ~."]
        ] as [String: Any],
        "required": ["from", "to"]
    ]

    static func execute(arguments: [String: Any]) async throws -> ToolResult {
        guard let rawFrom = arguments["from"] as? String,
              let rawTo = arguments["to"] as? String else {
            return .fail("Missing required arguments: from, to")
        }
        let from = (NSString(string: rawFrom).expandingTildeInPath as NSString).standardizingPath
        let to = (NSString(string: rawTo).expandingTildeInPath as NSString).standardizingPath
        let fm = FileManager.default

        guard fm.fileExists(atPath: from) else {
            return .fail("Source does not exist: \(rawFrom). List its parent folder or use search_files to find the correct path.")
        }

        let toParent = (to as NSString).deletingLastPathComponent
        guard fm.fileExists(atPath: toParent) else {
            return .fail("Destination directory does not exist: \(toParent). Call create_folder on it first, then retry the move.")
        }

        if fm.fileExists(atPath: to) {
            return .fail("Destination already exists: \(rawTo). Use overwrite_file to replace content, or choose a different path.")
        }

        do {
            try fm.moveItem(atPath: from, toPath: to)
            return .ok("Moved \(rawFrom) → \(rawTo)")
        } catch {
            return .fail("Move failed: \(error.localizedDescription)")
        }
    }
}
