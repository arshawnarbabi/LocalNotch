import Foundation
import AppKit

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

When web search results are included in a message (marked with [Web search results:...]), use them \
silently to inform your answer. Never output, echo, or reference the raw tag itself. Never say you are \
running a search or that you will look something up — the results have already been retrieved and \
handed to you. Simply answer using what you know. If the results say no results were found, state \
that plainly and move on. Never ask for clarification on a search query — trust that it was specific \
enough and answer with whatever information is available.
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
    @Published var displayName: String {
        didSet { UserDefaults.standard.set(displayName, forKey: "displayName") }
    }
    @Published var systemPrompt: String {
        didSet { UserDefaults.standard.set(systemPrompt, forKey: "systemPrompt") }
    }
    @Published var onboardingComplete: Bool {
        didSet { UserDefaults.standard.set(onboardingComplete, forKey: "onboardingComplete") }
    }
    @Published var showingSettings: Bool = false

    private init() {
        textModelName    = UserDefaults.standard.string(forKey: "textModelName") ?? ""
        visionModelName  = UserDefaults.standard.string(forKey: "visionModelName") ?? ""
        braveSearchAPIKey = UserDefaults.standard.string(forKey: "braveSearchAPIKey") ?? ""
        displayName      = UserDefaults.standard.string(forKey: "displayName") ?? ""
        systemPrompt     = UserDefaults.standard.string(forKey: "systemPrompt") ?? AppSettings.defaultSystemPrompt
        onboardingComplete = UserDefaults.standard.bool(forKey: "onboardingComplete")
    }
}
