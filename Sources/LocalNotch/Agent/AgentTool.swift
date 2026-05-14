import Foundation

enum RiskLevel { case readonly, write, destructive }

struct ToolResult {
    let success: Bool
    let output: String?
    let error: String?
    var truncated: Bool = false
    var totalEntries: Int? = nil
    var totalBytes: Int? = nil

    static func ok(_ output: String, truncated: Bool = false, totalEntries: Int? = nil, totalBytes: Int? = nil) -> ToolResult {
        ToolResult(success: true, output: output, error: nil, truncated: truncated, totalEntries: totalEntries, totalBytes: totalBytes)
    }
    static func fail(_ error: String) -> ToolResult {
        ToolResult(success: false, output: nil, error: error)
    }

    var asString: String {
        if success {
            var s = output ?? "(no output)"
            if truncated {
                if let total = totalEntries { s += "\n[truncated — \(total) total entries]" }
                else if let bytes = totalBytes { s += "\n[truncated — \(bytes) total bytes]" }
                else { s += "\n[truncated]" }
            }
            return s
        } else {
            return "ERROR: \(error ?? "unknown error")"
        }
    }
}

protocol AgentTool {
    static var name: String { get }
    static var description: String { get }
    static var parameterSchema: [String: Any] { get }
    static var riskLevel: RiskLevel { get }
    static func execute(arguments: [String: Any]) async throws -> ToolResult
}

extension AgentTool {
    static var toolDefinition: [String: Any] {
        [
            "type": "function",
            "function": [
                "name": name,
                "description": description,
                "parameters": parameterSchema
            ] as [String: Any]
        ]
    }
}
