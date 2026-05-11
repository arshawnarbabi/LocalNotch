import Foundation

final class BraveSearchService: Sendable {
    static let shared = BraveSearchService()

    func search(_ query: String) async -> String? {
        let apiKey = UserDefaults.standard.string(forKey: "braveSearchAPIKey") ?? ""
        guard !apiKey.isEmpty else { return nil }
        guard let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://api.search.brave.com/res/v1/web/search?q=\(encoded)&count=5")
        else { return nil }

        var request = URLRequest(url: url)
        request.setValue(apiKey, forHTTPHeaderField: "X-Subscription-Token")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            let parsed = try JSONDecoder().decode(BraveResponse.self, from: data)
            guard let results = parsed.web?.results, !results.isEmpty else { return nil }
            return results.prefix(5).enumerated().map { i, r in
                let desc = (r.description ?? "").strippingHTML()
                return "[\(i + 1)] \(r.title)\nURL: \(r.url)\n\(desc)"
            }.joined(separator: "\n\n")
        } catch {
            return nil
        }
    }
}

private extension String {
    func strippingHTML() -> String {
        var s = self.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        let entities: [String: String] = [
            "&amp;": "&", "&lt;": "<", "&gt;": ">",
            "&quot;": "\"", "&#x27;": "'", "&#39;": "'"
        ]
        for (entity, char) in entities { s = s.replacingOccurrences(of: entity, with: char) }
        return s
    }
}

private struct BraveResponse: Decodable {
    struct Web: Decodable {
        let results: [Result]?
    }
    struct Result: Decodable {
        let title: String
        let url: String
        let description: String?
    }
    let web: Web?
}
