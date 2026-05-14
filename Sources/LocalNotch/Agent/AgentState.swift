import Foundation

enum AgentState: Equatable {
    case welcome       // A — first time entering agent mode, orb centered, welcome copy
    case idle          // B — waiting for user task prompt
    case running       // C — harness loop executing
    case paused        // D — user-initiated pause
    case finished      // E — task completed normally
    case forceStopped  // F — user force-stopped via orb-X
    case clarifying    // G — agent emitted [NEEDS_CLARIFICATION], waiting on user answer
    case approving     // H — agent emitted [NEEDS_APPROVAL] or hard rail triggered, waiting on user
}

extension AgentState {
    var isActive: Bool {
        switch self {
        case .running, .paused, .clarifying, .approving: true
        default: false
        }
    }

    var needsUserAttention: Bool {
        self == .clarifying || self == .approving
    }
}
