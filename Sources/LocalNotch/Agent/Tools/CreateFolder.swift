import Foundation

struct CreateFolder: AgentTool {
    static let name = "create_folder"
    static let description = "Create a new directory at the given path. Creates intermediate directories as needed."
    static let riskLevel: RiskLevel = .write

    static let parameterSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "path": ["type": "string", "description": "Full path of the directory to create. Supports ~."]
        ] as [String: Any],
        "required": ["path"]
    ]

    static func execute(arguments: [String: Any]) async throws -> ToolResult {
        guard let rawPath = arguments["path"] as? String else {
            return .fail("Missing required argument: path")
        }
        let path = NSString(string: rawPath).expandingTildeInPath
        let fm = FileManager.default

        if fm.fileExists(atPath: path) {
            return .ok("Directory already exists: \(rawPath)")
        }

        do {
            try fm.createDirectory(atPath: path, withIntermediateDirectories: true, attributes: nil)
            return .ok("Created directory: \(rawPath)")
        } catch {
            return .fail("Failed to create directory: \(error.localizedDescription)")
        }
    }
}
