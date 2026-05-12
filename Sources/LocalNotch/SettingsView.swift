import SwiftUI
import AppKit

// MARK: - Root Settings View

struct SettingsView: View {
    @ObservedObject private var settings = AppSettings.shared
    @State private var activeSection: SettingsSection? = nil

    enum SettingsSection: CaseIterable {
        case models, webSearch, personality, about

        var title: String {
            switch self {
            case .models:     "Models"
            case .webSearch:  "Web Search"
            case .personality: "Personality"
            case .about:      "About"
            }
        }
        var icon: String {
            switch self {
            case .models:     "cpu"
            case .webSearch:  "magnifyingglass"
            case .personality: "person.circle"
            case .about:      "info.circle"
            }
        }
    }

    private let navSpring = Animation.spring(response: 0.38, dampingFraction: 0.80)

    var body: some View {
        VStack(spacing: 0) {
            header
            ZStack {
                if activeSection == nil {
                    sectionList
                        .transition(.asymmetric(
                            insertion: .move(edge: .leading).combined(with: .opacity),
                            removal: .move(edge: .leading).combined(with: .opacity)
                        ))
                } else {
                    sectionContent
                        .transition(.asymmetric(
                            insertion: .move(edge: .trailing).combined(with: .opacity),
                            removal: .move(edge: .trailing).combined(with: .opacity)
                        ))
                }
            }
            .animation(navSpring, value: activeSection)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var header: some View {
        HStack(spacing: 8) {
            if activeSection != nil {
                Image(systemName: "chevron.left")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white.opacity(0.75))
                    .frame(width: 26, height: 26)
                    .modifier(GlassSphereModifier())
                    .overlay(AppKitTapHandler { withAnimation(navSpring) { activeSection = nil } })
            }

            Text(activeSection?.title ?? "Settings")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.white)
                .animation(nil, value: activeSection)

            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.top, 14)
        .padding(.bottom, 10)
    }

    private var sectionList: some View {
        ScrollView {
            VStack(spacing: 8) {
                ForEach(SettingsSection.allCases, id: \.self) { section in
                    SettingsRowButton(title: section.title, icon: section.icon) {
                        withAnimation(navSpring) { activeSection = section }
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 14)
        }
        .scrollIndicators(.hidden)
    }

    @ViewBuilder
    private var sectionContent: some View {
        switch activeSection {
        case .models:      ModelsSettingsView()
        case .webSearch:   WebSearchSettingsView()
        case .personality: PersonalitySettingsView()
        case .about:       AboutSettingsView()
        case nil:          EmptyView()
        }
    }
}

// MARK: - Reusable Row Button

struct SettingsRowButton: View {
    let title: String
    let icon: String
    let action: () -> Void
    @State private var hovering = false
    @State private var pressing = false

    var body: some View {
        HStack {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.white.opacity(0.65))
                .frame(width: 20)
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.white)
            Spacer()
            Image(systemName: "chevron.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.white.opacity(0.35))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .modifier(GlassPillModifier())
        .scaleEffect(pressing ? 0.97 : (hovering ? 1.02 : 1.0))
        .brightness(hovering ? 0.08 : 0)
        .animation(.spring(response: 0.22, dampingFraction: 0.65), value: hovering)
        .animation(.spring(response: 0.18, dampingFraction: 0.6), value: pressing)
        .background(AlwaysActiveHoverDetector { hovering = $0 })
        .overlay(AppKitTapHandler(action: action, onPressChanged: { pressing = $0 }))
    }
}

// MARK: - Models Section

struct ModelsSettingsView: View {
    @ObservedObject private var settings = AppSettings.shared
    @State private var availableModels: [String] = []
    @State private var ollamaStatus: OllamaStatus = .loading
    @State private var textOpen = false
    @State private var visionOpen = false

    enum OllamaStatus { case loading, ok, unreachable }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if ollamaStatus == .unreachable {
                    unreachableView
                } else {
                    ModelDropdownRow(
                        label: "Text model",
                        selected: settings.textModelName,
                        models: availableModels,
                        isLoading: ollamaStatus == .loading,
                        isOpen: $textOpen,
                        onSelect: {
                            settings.textModelName = $0
                            withAnimation(.easeInOut(duration: 0.12)) { textOpen = false }
                        }
                    )
                    .zIndex(textOpen ? 1 : 0)

                    ModelDropdownRow(
                        label: "Vision model",
                        selected: settings.visionModelName,
                        models: availableModels,
                        isLoading: ollamaStatus == .loading,
                        isOpen: $visionOpen,
                        onSelect: {
                            settings.visionModelName = $0
                            withAnimation(.easeInOut(duration: 0.12)) { visionOpen = false }
                        }
                    )
                    .zIndex(visionOpen ? 1 : 0)
                }

                HStack(spacing: 10) {
                    refreshButton

                    Group {
                        switch ollamaStatus {
                        case .loading:    Text("Connecting to Ollama…")
                        case .unreachable: Text("Ollama not reachable")
                        case .ok:
                            Text("\(availableModels.count) model\(availableModels.count == 1 ? "" : "s") found")
                        }
                    }
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.45))
                }
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 14)
        }
        .scrollIndicators(.hidden)
        .task { await loadModels() }
    }

    private var unreachableView: some View {
        VStack(spacing: 8) {
            Text("Ollama not detected")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.white)
            Text("Make sure Ollama is running on localhost:11434")
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.5))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
    }

    private var refreshButton: some View {
        HStack(spacing: 5) {
            Image(systemName: "arrow.clockwise")
                .font(.system(size: 11, weight: .medium))
            Text("Refresh")
                .font(.system(size: 11, weight: .medium))
        }
        .foregroundColor(.white.opacity(0.75))
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .modifier(GlassPillModifier())
        .overlay(AppKitTapHandler {
            ollamaStatus = .loading
            Task { await loadModels() }
        })
    }

    private func loadModels() async {
        guard let url = URL(string: "http://localhost:11434/api/tags") else {
            ollamaStatus = .unreachable; return
        }
        do {
            let (data, response) = try await OllamaAPI.statusSession.data(from: url)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                ollamaStatus = .unreachable; return
            }
            let decoded = try JSONDecoder().decode(OllamaTagsResponse.self, from: data)
            availableModels = decoded.models.map(\.name).sorted()
            ollamaStatus = .ok
        } catch {
            ollamaStatus = .unreachable
        }
    }
}

// MARK: - Model Dropdown

struct ModelDropdownRow: View {
    let label: String
    let selected: String
    let models: [String]
    let isLoading: Bool
    @Binding var isOpen: Bool
    let onSelect: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.white.opacity(0.5))

            HStack {
                Text(selected.isEmpty ? "None selected" : selected)
                    .font(.system(size: 12))
                    .foregroundColor(selected.isEmpty ? .white.opacity(0.35) : .white)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Image(systemName: isOpen ? "chevron.up" : "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.white.opacity(0.5))
                    .animation(.easeInOut(duration: 0.15), value: isOpen)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .modifier(GlassPillModifier())
            .overlay(AppKitTapHandler {
                withAnimation(.easeInOut(duration: 0.15)) { isOpen.toggle() }
            })

            if isOpen {
                Group {
                    if isLoading {
                        HStack { Spacer(); ProgressView().tint(.white).scaleEffect(0.7); Spacer() }
                            .padding(.vertical, 8)
                    } else if models.isEmpty {
                        Text("No models found — run ollama pull <model>")
                            .font(.system(size: 11))
                            .foregroundColor(.white.opacity(0.45))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                    } else {
                        VStack(spacing: 3) {
                            ForEach(models, id: \.self) { model in
                                ModelOptionRow(name: model, isSelected: model == selected) {
                                    onSelect(model)
                                }
                            }
                        }
                        .padding(6)
                    }
                }
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.white.opacity(0.06))
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.1), lineWidth: 0.5))
                )
                .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .top)))
            }
        }
    }
}

struct ModelOptionRow: View {
    let name: String
    let isSelected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack {
            Text(name)
                .font(.system(size: 12))
                .foregroundColor(.white)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            if isSelected {
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.white)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isSelected ? Color.white.opacity(0.15) : (hovering ? Color.white.opacity(0.08) : Color.clear))
                .animation(.easeInOut(duration: 0.1), value: hovering)
        )
        .background(AlwaysActiveHoverDetector { hovering = $0 })
        .overlay(AppKitTapHandler { action() })
    }
}

// MARK: - Web Search Section

struct WebSearchSettingsView: View {
    @ObservedObject private var settings = AppSettings.shared
    @State private var keyVisible = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Brave Search API key")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.white.opacity(0.5))

                    HStack {
                        Group {
                            if keyVisible {
                                TextField("Paste key here", text: $settings.braveSearchAPIKey)
                            } else {
                                SecureField("Paste key here", text: $settings.braveSearchAPIKey)
                            }
                        }
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                        .foregroundColor(.white)
                        .tint(.white)

                        Button { keyVisible.toggle() } label: {
                            Image(systemName: keyVisible ? "eye.slash" : "eye")
                                .font(.system(size: 12))
                                .foregroundColor(.white.opacity(0.5))
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .modifier(GlassPillModifier())
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Free tier: 1,000 queries/month. Requires a credit card on file with Brave.")
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.45))
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: 4) {
                        Text("Get an API key")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(Color(red: 0.4, green: 0.7, blue: 1.0))
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundColor(Color(red: 0.4, green: 0.7, blue: 1.0))
                    }
                    .overlay(AppKitTapHandler {
                        NSWorkspace.shared.open(URL(string: "https://api.search.brave.com/register")!)
                    })
                }

                Text(settings.braveSearchAPIKey.trimmingCharacters(in: .whitespaces).isEmpty
                     ? "No key set — web search disabled."
                     : "Web search enabled.")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.35))
                    .animation(.easeInOut(duration: 0.2), value: settings.braveSearchAPIKey.isEmpty)
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 14)
        }
        .scrollIndicators(.hidden)
    }
}

// MARK: - Personality Section

struct PersonalitySettingsView: View {
    @ObservedObject private var settings = AppSettings.shared
    @State private var resetPending = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Display name")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.white.opacity(0.5))

                    TextField("Your name", text: $settings.displayName)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                        .foregroundColor(.white)
                        .tint(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                        .modifier(GlassPillModifier())
                }

                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("System prompt")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.white.opacity(0.5))
                        Spacer()
                        Text(resetPending ? "Tap again to confirm" : "Reset to default")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(resetPending ? .white.opacity(0.65) : .white.opacity(0.4))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .modifier(GlassPillModifier())
                            .animation(.easeInOut(duration: 0.15), value: resetPending)
                            .overlay(AppKitTapHandler {
                                if resetPending {
                                    settings.systemPrompt = AppSettings.defaultSystemPrompt
                                    resetPending = false
                                } else {
                                    resetPending = true
                                    Task {
                                        try? await Task.sleep(for: .seconds(3))
                                        resetPending = false
                                    }
                                }
                            })
                    }

                    TextEditor(text: $settings.systemPrompt)
                        .scrollContentBackground(.hidden)
                        .font(.system(size: 11))
                        .foregroundColor(.white)
                        .tint(.white)
                        .frame(minHeight: 140)
                        .padding(10)
                        .background(
                            RoundedRectangle(cornerRadius: 12)
                                .fill(Color.white.opacity(0.07))
                                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.12), lineWidth: 0.5))
                        )
                }
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 14)
        }
        .scrollIndicators(.hidden)
    }
}

// MARK: - About Section

struct AboutSettingsView: View {
    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                VStack(spacing: 4) {
                    Text("LocalNotch")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundColor(.white)
                    Text("v0.1.0-beta")
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.45))
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 8)

                VStack(spacing: 8) {
                    AboutLinkButton(title: "GitHub", icon: "arrow.up.right.square") {
                        NSWorkspace.shared.open(URL(string: "https://github.com/s24b/LocalNotch")!)
                    }
                    AboutLinkButton(title: "MIT License", icon: "doc.text") {
                        NSWorkspace.shared.open(URL(string: "https://github.com/s24b/LocalNotch/blob/main/LICENSE")!)
                    }
                    AboutLinkButton(title: "Show onboarding again", icon: "arrow.counterclockwise") {
                        AppSettings.shared.onboardingComplete = false
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 14)
        }
        .scrollIndicators(.hidden)
    }
}

struct AboutLinkButton: View {
    let title: String
    let icon: String
    let action: () -> Void
    @State private var hovering = false
    @State private var pressing = false

    var body: some View {
        HStack {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.white.opacity(0.65))
                .frame(width: 20)
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.white)
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .modifier(GlassPillModifier())
        .scaleEffect(pressing ? 0.97 : (hovering ? 1.02 : 1.0))
        .brightness(hovering ? 0.08 : 0)
        .animation(.spring(response: 0.22, dampingFraction: 0.65), value: hovering)
        .animation(.spring(response: 0.18, dampingFraction: 0.6), value: pressing)
        .background(AlwaysActiveHoverDetector { hovering = $0 })
        .overlay(AppKitTapHandler(action: action, onPressChanged: { pressing = $0 }))
    }
}
