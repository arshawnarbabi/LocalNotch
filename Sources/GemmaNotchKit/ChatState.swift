import Foundation
import AppKit

struct ChatMessage: Identifiable {
    let id = UUID()
    let role: String
    var content: String
}

struct ChatTurn: Identifiable {
    let id = UUID()
    let prompt: String
    let response: String
}

private let systemPrompt = """
You are Gemma 4, an AI assistant made by Google. If asked who or what you are, say you are Gemma 4. \
You are not JARVIS — you only borrow JARVIS's manner of speaking from the Iron Man films as a \
stylistic inspiration. Do not roleplay as JARVIS, and do not claim to be JARVIS.

Tone: speak with calm precision and a touch of warmth. You are professional and articulate, with a \
quiet, observational dry wit that surfaces naturally — never performed, never forced. You are not \
robotic. Do not address the user as "Sir" or use stiff formal vocatives. Treat the user as a \
thoughtful peer: conversational where the moment calls for it, more formal where the topic warrants. \
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

@MainActor
class ChatState: ObservableObject {
    @Published var currentResponse: String = ""
    @Published var isLoading = false
    @Published var isSearching = false
    @Published var isProcessingImage = false
    @Published var showCompletionCheck = false
    @Published var chatHistory: [ChatTurn] = []
    @Published var capturedImage: NSImage? = nil
    @Published var isCapturing = false

    private var history: [ChatMessage] = []
    private var lastPrompt: String = ""

    func prepareForSend(_ text: String) -> [OllamaMessage] {
        lastPrompt = text
        history.append(ChatMessage(role: "user", content: text))
        currentResponse = ""
        isLoading = true
        showCompletionCheck = false
        let system = OllamaMessage(role: "system", content: systemPrompt)
        return [system] + history.map { OllamaMessage(role: $0.role, content: $0.content) }
    }

    func appendToken(_ token: String) {
        if isProcessingImage { isProcessingImage = false }
        currentResponse += token
    }

    func finishResponse() {
        chatHistory.append(ChatTurn(prompt: lastPrompt, response: currentResponse))
        history.append(ChatMessage(role: "assistant", content: currentResponse))
        isLoading = false
        showCompletionCheck = true
        Task {
            try? await Task.sleep(for: .seconds(30))
            showCompletionCheck = false
        }
    }

    func resetChat() {
        history = []
        chatHistory = []
        currentResponse = ""
        isLoading = false
        isSearching = false
        isProcessingImage = false
        showCompletionCheck = false
        lastPrompt = ""
        capturedImage = nil
        isCapturing = false
    }
}
