import Foundation

struct WeatherData: Equatable {
    let tempF: Int
    let feelsLikeF: Int
    let condition: String
    let humidity: Int
}

@MainActor
class WeatherService: ObservableObject {
    @Published var data: WeatherData?

    private struct WttrResponse: Decodable {
        struct Condition: Decodable {
            let temp_F: String
            let FeelsLikeF: String
            let humidity: String
            let weatherDesc: [Desc]
            struct Desc: Decodable { let value: String }
        }
        let current_condition: [Condition]
    }

    init() {
        Task { await fetch() }
        Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(600))
                await fetch()
            }
        }
    }

    func fetch() async {
        guard let url = URL(string: "https://wttr.in/?format=j1") else { return }
        var request = URLRequest(url: url)
        request.setValue("LocalNotch/1.0", forHTTPHeaderField: "User-Agent")
        do {
            let (raw, _) = try await URLSession.shared.data(for: request)
            let parsed = try JSONDecoder().decode(WttrResponse.self, from: raw)
            if let c = parsed.current_condition.first {
                data = WeatherData(
                    tempF: Int(c.temp_F) ?? 0,
                    feelsLikeF: Int(c.FeelsLikeF) ?? 0,
                    condition: c.weatherDesc.first?.value ?? "",
                    humidity: Int(c.humidity) ?? 0
                )
            }
        } catch {
            // silent — weather is decorative
        }
    }
}
