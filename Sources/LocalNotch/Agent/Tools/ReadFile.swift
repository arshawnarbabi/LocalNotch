import Foundation

struct ReadFile: AgentTool {
    static let name = "read_file"
    static let description = "Read the text contents of a file. Binary files are not supported. Truncated at 1 MB."
    static let riskLevel: RiskLevel = .readonly
    static let maxBytes = 1_048_576 // 1 MB

    static let parameterSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "path": ["type": "string", "description": "File path to read. Supports ~."]
        ] as [String: Any],
        "required": ["path"]
    ]

    static func execute(arguments: [String: Any]) async throws -> ToolResult {
        guard let rawPath = arguments["path"] as? String else {
            return .fail("Missing required argument: path")
        }
        let path = NSString(string: rawPath).expandingTildeInPath
        let fm = FileManager.default
        guard fm.fileExists(atPath: path) else { return .fail("File not found: \(rawPath)") }

        var isDir: ObjCBool = false
        fm.fileExists(atPath: path, isDirectory: &isDir)
        if isDir.boolValue { return .fail("Path is a directory, not a file: \(rawPath)") }

        guard let data = fm.contents(atPath: path) else {
            return .fail("Cannot read file: \(rawPath)")
        }
        let totalBytes = data.count
        let truncated = totalBytes > maxBytes
        let slice = truncated ? data.prefix(maxBytes) : data

        guard let text = String(data: slice, encoding: .utf8) ?? String(data: slice, encoding: .isoLatin1) else {
            return .fail("File does not appear to be text (binary file?): \(rawPath)")
        }

        return .ok(text, truncated: truncated, totalBytes: truncated ? totalBytes : nil)
    }
}
