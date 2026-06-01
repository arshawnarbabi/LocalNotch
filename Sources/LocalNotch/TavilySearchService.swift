import Foundation

final class TavilySearchService: Sendable {
    static let shared = TavilySearchService()

    func search(_ query: String) async -> String? {
        let apiKey = (UserDefaults.standard.string(forKey: "tavilyAPIKey") ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !apiKey.isEmpty else { return nil }
        guard let url = URL(string: "https://api.tavily.com/search") else { return nil }

        let body: [String: Any] = [
            "api_key": apiKey,
            "query": query,
            "max_results": 5,
            "search_depth": "basic"
        ]

        guard let jsonData = try? JSONSerialization.data(withJSONObject: body) else { return nil }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = jsonData

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            let parsed = try JSONDecoder().decode(TavilyResponse.self, from: data)
            guard !parsed.results.isEmpty else { return nil }
            return parsed.results.prefix(5).enumerated().map { i, r in
                let snippet = r.content
                return "[\(i + 1)] \(r.title)\nURL: \(r.url)\n\(snippet)"
            }.joined(separator: "\n\n")
        } catch {
            return nil
        }
    }
}

private struct TavilyResponse: Decodable {
    struct Result: Decodable {
        let title: String
        let url: String
        let content: String
    }
    let results: [Result]
}
