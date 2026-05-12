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

    private var history: [ChatMessage] = []
    private var lastPrompt: String = ""

    func prepareForSend(_ text: String) -> [OllamaMessage] {
        lastPrompt = text
        history.append(ChatMessage(role: "user", content: text))
        currentResponse = ""
        isLoading = true
        showCompletionCheck = false
        let system = OllamaMessage(role: "system", content: AppSettings.shared.systemPrompt)
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
    }
}
