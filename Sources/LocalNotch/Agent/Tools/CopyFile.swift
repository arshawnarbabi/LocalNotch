import Foundation

struct CopyFile: AgentTool {
    static let name = "copy_file"
    static let description = "Copy a file or folder to a new location. The destination must not already exist."
    static let riskLevel: RiskLevel = .write

    static let parameterSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "from": ["type": "string", "description": "Source path. Supports ~."],
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

        guard fm.fileExists(atPath: from) else { return .fail("Source does not exist: \(rawFrom)") }

        if fm.fileExists(atPath: to) {
            return .fail("Destination already exists: \(rawTo). Remove it first or choose a different path.")
        }

        let toParent = (to as NSString).deletingLastPathComponent
        if !fm.fileExists(atPath: toParent) {
            do { try fm.createDirectory(atPath: toParent, withIntermediateDirectories: true) }
            catch { return .fail("Cannot create destination directory: \(error.localizedDescription)") }
        }

        do {
            try fm.copyItem(atPath: from, toPath: to)
            return .ok("Copied \(rawFrom) → \(rawTo)")
        } catch {
            return .fail("Copy failed: \(error.localizedDescription)")
        }
    }
}
