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
    @Published var lastSearchQuery: String? = nil

    private var history: [ChatMessage] = []
    private var lastPrompt: String = ""

    func prepareForSend(_ text: String) -> [OllamaMessage] {
        lastPrompt = text
        history.append(ChatMessage(role: "user", content: text))
        currentResponse = ""
        isLoading = true
        showCompletionCheck = false
        // Note: lastSearchQuery is managed by ChatView around the search call so the
        // badge can show during the .searching phase. Don't clear it here.
        // Non-overridable preamble — web search is a system capability, not personality.
        // Placed at the very start of the system message where models attend to it most.
        let preamble = """
        CAPABILITY: This assistant has real-time web search via Brave Search API. \
        When <web_search> blocks appear in the conversation, those are REAL results \
        retrieved from the internet moments ago — not simulated, not from training data. \
        If the user asks "did you search the web?" and a <web_search> block exists in \
        this conversation, the answer is YES. Never deny having web search capability.
        """
        let system = OllamaMessage(role: "system", content: preamble + "\n\n" + AppSettings.shared.systemPrompt)
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

    func updateLastUserContent(_ content: String) {
        guard let idx = history.lastIndex(where: { $0.role == "user" }) else { return }
        history[idx] = ChatMessage(role: "user", content: content)
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
        lastSearchQuery = nil
    }
}
