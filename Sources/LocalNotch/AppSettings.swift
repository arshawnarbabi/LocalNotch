import Foundation
import AppKit

enum SearchProvider: String, CaseIterable {
    case brave = "brave"
    case tavily = "tavily"
    case auto = "auto"

    var label: String {
        switch self {
        case .brave:  return "Brave"
        case .tavily: return "Tavily"
        case .auto:   return "Auto"
        }
    }
}

@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    static let defaultSystemPrompt = """
You are a local AI assistant running on this machine via Ollama. If asked who or what you are, \
say you are a local AI assistant — do not claim to be any specific model or product.

Tone: speak with calm precision and a touch of warmth. You are professional and articulate, with a \
quiet, observational dry wit that surfaces naturally — never performed, never forced. You are not \
robotic. Do not address the user formally or use stiff vocatives. Treat the user as a thoughtful \
peer: conversational where the moment calls for it, more formal where the topic warrants. \
A little human texture — a passing aside, a small acknowledgment — is welcome when it fits, but never \
filler.

Be direct and efficient. Answer what is asked, provide the context that genuinely matters, and stop \
there. For simple questions, be concise. For complex or technical subjects, go as deep as the topic \
warrants — thoroughness when it serves, brevity when it doesn't. Do not flatter, do not hedge \
unnecessarily, do not pad. When you do not know something, say so plainly without apology.

Never fabricate information.

Never use emojis.

This assistant has live web search integrated. When a <web_search> block appears \
in a message, those results are real data retrieved from the internet in real time — not simulated, \
not from your training data. Treat them as authoritative current information and use them to \
answer accurately.

Web search rules: never quote or echo the <web_search> tags themselves. Never say you are about to \
search or will look something up — the search has already run before you see the message. If asked \
whether you searched the web or have access to current information, say yes and answer normally — \
never deny web search capability or claim results were simulated. If the block says no results were \
found, state that plainly and answer with what you know. Trust the query — do not ask for clarification.
"""

    @Published var textModelName: String {
        didSet { UserDefaults.standard.set(textModelName, forKey: "textModelName") }
    }
    @Published var visionModelName: String {
        didSet { UserDefaults.standard.set(visionModelName, forKey: "visionModelName") }
    }
    @Published var braveSearchAPIKey: String {
        didSet { UserDefaults.standard.set(braveSearchAPIKey, forKey: "braveSearchAPIKey") }
    }
    @Published var tavilyAPIKey: String {
        didSet { UserDefaults.standard.set(tavilyAPIKey, forKey: "tavilyAPIKey") }
    }
    @Published var searchProvider: SearchProvider {
        didSet { UserDefaults.standard.set(searchProvider.rawValue, forKey: "searchProvider") }
    }
    @Published var displayName: String {
        didSet { UserDefaults.standard.set(displayName, forKey: "displayName") }
    }
    @Published var systemPrompt: String {
        didSet { UserDefaults.standard.set(systemPrompt, forKey: "systemPrompt") }
    }
    @Published var onboardingComplete: Bool {
        didSet { UserDefaults.standard.set(onboardingComplete, forKey: "onboardingComplete") }
    }
    @Published var onboardingStep: Int {
        didSet { UserDefaults.standard.set(onboardingStep, forKey: "onboardingStep") }
    }
    @Published var notchContentHeight: CGFloat = 300

    private init() {
        textModelName    = UserDefaults.standard.string(forKey: "textModelName") ?? ""
        visionModelName  = UserDefaults.standard.string(forKey: "visionModelName") ?? ""
        braveSearchAPIKey = UserDefaults.standard.string(forKey: "braveSearchAPIKey") ?? ""
        tavilyAPIKey     = UserDefaults.standard.string(forKey: "tavilyAPIKey") ?? ""
        let providerRaw  = UserDefaults.standard.string(forKey: "searchProvider") ?? "brave"
        searchProvider   = SearchProvider(rawValue: providerRaw) ?? .brave
        displayName      = UserDefaults.standard.string(forKey: "displayName") ?? ""
        systemPrompt     = UserDefaults.standard.string(forKey: "systemPrompt") ?? AppSettings.defaultSystemPrompt
        onboardingComplete = UserDefaults.standard.bool(forKey: "onboardingComplete")
        let saved = UserDefaults.standard.integer(forKey: "onboardingStep")
        onboardingStep = saved > 0 ? saved : 1
    }
}
