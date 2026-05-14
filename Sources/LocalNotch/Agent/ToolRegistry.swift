import Foundation

enum ToolRegistry {
    static let allTools: [any AgentTool.Type] = [
        ListDirectory.self,
        ReadFile.self,
        GetFileInfo.self,
        SearchFiles.self,
        MoveFile.self,
        CreateFolder.self,
        CopyFile.self,
        DeleteFile.self,
        OverwriteFile.self
    ]

    // JSON-serializable tool definitions for Ollama's tool-calling API.
    static var toolDefinitions: [[String: Any]] {
        allTools.map { $0.toolDefinition }
    }

    static func riskLevel(for toolName: String) -> RiskLevel? {
        allTools.first { $0.name == toolName }?.riskLevel
    }

    static func execute(toolName: String, arguments: [String: Any]) async throws -> ToolResult {
        guard let tool = allTools.first(where: { $0.name == toolName }) else {
            return .fail("Unknown tool: \(toolName)")
        }
        return try await tool.execute(arguments: arguments)
    }
}
