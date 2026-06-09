import Foundation
import AppKit

struct DeleteFile: AgentTool {
    static let name = "delete_file"
    static let description = "Move a file or folder to the Trash. NEVER permanently deletes. The operation always requires user approval — do not call this without a [NEEDS_APPROVAL] response from the user."
    static let riskLevel: RiskLevel = .destructive

    static let parameterSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "path": ["type": "string", "description": "Path of the file or folder to trash. Supports ~."]
        ] as [String: Any],
        "required": ["path"]
    ]

    static func execute(arguments: [String: Any]) async throws -> ToolResult {
        guard let rawPath = arguments["path"] as? String else {
            return .fail("Missing required argument: path")
        }
        let path = (NSString(string: rawPath).expandingTildeInPath as NSString).standardizingPath
        let fm = FileManager.default

        guard fm.fileExists(atPath: path) else { return .fail("Path does not exist: \(rawPath)") }

        var resultingURL: NSURL? = nil
        do {
            try fm.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: &resultingURL)
            let trashPath = resultingURL?.path ?? "Trash"
            return .ok("Moved to Trash: \(rawPath) → \(trashPath)")
        } catch {
            return .fail("Failed to trash: \(error.localizedDescription)")
        }
    }
}
