import Foundation

/// Single source of truth for which local models we recommend for Agent Mode.
///
/// Every model listed here MUST:
///   1. Support Ollama tool-calling — the agent smoke test (`verifyToolCalling`)
///      requires the model to emit `tool_calls`, so non-tool models (e.g.
///      deepseek-r1, llava, llama3.2-vision) can never enable Agent Mode.
///   2. Avoid the `nvfp4` / `mxfp8` quants, which are broken on Apple Silicon
///      as of mid-2026 (corrupted weights / runner crashes). The bare tags below
///      resolve to q4_K_M (GGUF), which is safe.
///
/// Sizes are the Q4_K_M on-disk footprint; loaded RAM (with the agent's context
/// window) runs higher, which is why each tier targets a comfortable RAM floor.
enum AgentModelRecommendations {
    struct Tier {
        let ramLabel: String   // e.g. "32 GB Mac"
        let minRAMGB: Int      // RAM floor this tier targets
        let model: String      // ollama tag (bare → q4_K_M), tool-capable
        let sizeNote: String   // on-disk size, e.g. "~9 GB"
    }

    /// Ordered low → high. Agent Mode needs 16 GB+; below that we recommend skipping.
    static let tiers: [Tier] = [
        Tier(ramLabel: "16 GB Mac",  minRAMGB: 16, model: "qwen3:8b",       sizeNote: "~5 GB"),
        Tier(ramLabel: "32 GB Mac",  minRAMGB: 32, model: "qwen3:14b",      sizeNote: "~9 GB"),
        Tier(ramLabel: "48 GB+ Mac", minRAMGB: 48, model: "qwen3:30b-a3b",  sizeNote: "~18 GB"),
    ]

    /// Physical RAM in whole GB.
    static var systemRAMGB: Int {
        Int(ProcessInfo.processInfo.physicalMemory / 1_073_741_824)
    }

    /// Highest tier whose RAM floor the machine meets. `nil` below 16 GB.
    static func tier(forRAMGB ram: Int) -> Tier? {
        tiers.last(where: { ram >= $0.minRAMGB })
    }

    /// Model to suggest installing for the given RAM (`nil` below 16 GB).
    static func suggestedModel(forRAMGB ram: Int) -> String? {
        tier(forRAMGB: ram)?.model
    }

    /// Best ALREADY-INSTALLED recommended model for the given RAM: searches the
    /// affordable tiers best-first, matching installed tags by prefix
    /// (so "qwen3:14b" matches an installed "qwen3:14b-q4_K_M"). Falls back to the
    /// first installed model if none match. `nil` below 16 GB.
    static func bestInstalled(forRAMGB ram: Int, among installed: [String]) -> String? {
        guard ram >= 16 else { return nil }
        for tier in tiers.filter({ ram >= $0.minRAMGB }).reversed() {
            if let match = installed.first(where: { $0.lowercased().contains(tier.model.lowercased()) }) {
                return match
            }
        }
        return installed.first
    }
}
