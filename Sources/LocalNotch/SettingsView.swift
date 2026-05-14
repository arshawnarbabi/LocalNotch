import SwiftUI
import AppKit

// MARK: - Root Settings View

struct SettingsView: View {
    @ObservedObject private var settings = AppSettings.shared
    @State private var activeSection: SettingsSection? = nil

    enum SettingsSection: CaseIterable {
        case models, webSearch, personality, agent, about

        var title: String {
            switch self {
            case .models:     "Models"
            case .webSearch:  "Web Search"
            case .personality: "Personality"
            case .agent:      "Agent"
            case .about:      "About"
            }
        }
        var icon: String {
            switch self {
            case .models:     "cpu"
            case .webSearch:  "magnifyingglass"
            case .personality: "person.circle"
            case .agent:      "sparkles"
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
        case .agent:       AgentSettingsView()
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
    @State private var textModels: [String] = []
    @State private var visionModels: [String] = []
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
                        models: textModels,
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
                        models: visionModels,
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
                        case .loading:     Text("Connecting to Ollama…")
                        case .unreachable: Text("Ollama not reachable")
                        case .ok:          Text("\(textModels.count) text · \(visionModels.count) vision")
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
        .onChange(of: textOpen) { _, open in
            if open { withAnimation(.easeInOut(duration: 0.12)) { visionOpen = false } }
        }
        .onChange(of: visionOpen) { _, open in
            if open { withAnimation(.easeInOut(duration: 0.12)) { textOpen = false } }
        }
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
            let all = decoded.models
            let tv = all.filter { !$0.isVisionCapable }.map(\.name).sorted()
            textModels = tv.isEmpty ? all.map(\.name).sorted() : tv
            visionModels = all.filter { $0.isVisionCapable }.map(\.name).sorted()
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
    var recommended: String? = nil

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
                                ModelOptionRow(
                                    name: model,
                                    isSelected: model == selected,
                                    isRecommended: recommended == model
                                ) {
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
    var isRecommended: Bool = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack {
            Text(name)
                .font(.system(size: 12))
                .foregroundColor(.white)
                .lineLimit(1)
                .truncationMode(.middle)
            if isRecommended {
                Text("Recommended")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(.white.opacity(0.55))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.white.opacity(0.10)))
            }
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
                        AppSettings.shared.onboardingStep = 1
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

// MARK: - Agent Section

struct AgentSettingsView: View {
    @ObservedObject private var settings = AppSettings.shared
    @State private var allModels: [OllamaTagsResponse.Model] = []
    @State private var ollamaStatus: AgentOllamaStatus = .loading
    @State private var ollamaVersion: SemVer? = nil
    @State private var showAllModels = false
    @State private var agentDropdownOpen = false
    @State private var smokeTestStatus: SmokeTestStatus = .idle
    @State private var customPathDraft = ""

    static let minVersion = SemVer(major: 0, minor: 4, patch: 0)

    enum AgentOllamaStatus { case loading, ok, unreachable }
    enum SmokeTestStatus { case idle, running, passed, failed }

    var agentEnabled: Bool {
        guard let v = ollamaVersion else { return false }
        return v >= Self.minVersion
            && !settings.agentModel.isEmpty
            && smokeTestStatus == .passed
    }

    var filteredModels: [String] {
        guard ollamaStatus == .ok else { return [] }
        if showAllModels { return allModels.map(\.name).sorted() }
        return allModels.filter { isThinkingCapable($0) }.map(\.name).sorted()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                versionBanner
                modelPicker
                smokeTestRow
                reasoningToggle
                allowedPathsSection
                ramHelpText
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 14)
        }
        .scrollIndicators(.hidden)
        .task { await loadState() }
    }

    // MARK: Sub-views

    @ViewBuilder
    private var versionBanner: some View {
        if ollamaStatus == .unreachable {
            bannerView(color: Color.red.opacity(0.18), text: "Ollama not reachable. Start Ollama to use Agent Mode.")
        } else if let v = ollamaVersion, v < Self.minVersion {
            bannerView(color: Color.orange.opacity(0.20), text: "Ollama \(v.major).\(v.minor).\(v.patch) detected. Agent Mode requires Ollama 0.4.0+. Update at ollama.com.")
        } else if agentEnabled {
            bannerView(color: Color.green.opacity(0.14), text: "Agent mode enabled with \(settings.agentModel).")
        } else if !settings.agentModel.isEmpty && smokeTestStatus != .passed {
            bannerView(color: Color.white.opacity(0.07), text: "No agent model selected — agent mode disabled.")
        } else {
            bannerView(color: Color.white.opacity(0.07), text: "Select a reasoning model to enable agent mode.")
        }
    }

    private var modelPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Agent model")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white.opacity(0.5))
                Spacer()
                HStack(spacing: 4) {
                    Text("Show all")
                        .font(.system(size: 10))
                        .foregroundColor(.white.opacity(0.4))
                    Toggle("", isOn: $showAllModels)
                        .toggleStyle(.switch)
                        .scaleEffect(0.65)
                        .frame(width: 36)
                        .tint(Color.white.opacity(0.3))
                }
            }

            ModelDropdownRow(
                label: "",
                selected: settings.agentModel,
                models: filteredModels,
                isLoading: ollamaStatus == .loading,
                isOpen: $agentDropdownOpen,
                onSelect: { model in
                    settings.agentModel = model
                    settings.agentModelToolCallVerified.removeValue(forKey: model)
                    smokeTestStatus = .idle
                    withAnimation(.easeInOut(duration: 0.12)) { agentDropdownOpen = false }
                    Task { await runSmokeTest(for: model) }
                }
            )
            .zIndex(agentDropdownOpen ? 1 : 0)
        }
    }

    @ViewBuilder
    private var smokeTestRow: some View {
        if !settings.agentModel.isEmpty {
            HStack(spacing: 8) {
                Group {
                    switch smokeTestStatus {
                    case .idle:
                        Text("Not tested")
                            .foregroundColor(.white.opacity(0.35))
                    case .running:
                        HStack(spacing: 5) {
                            ProgressView().tint(.white).scaleEffect(0.6)
                            Text("Verifying tool calling…").foregroundColor(.white.opacity(0.5))
                        }
                    case .passed:
                        HStack(spacing: 5) {
                            Image(systemName: "checkmark.circle.fill").foregroundColor(Color(red: 0.3, green: 0.85, blue: 0.5))
                            Text("Tool calling verified").foregroundColor(.white.opacity(0.7))
                        }
                    case .failed:
                        HStack(spacing: 5) {
                            Image(systemName: "xmark.circle.fill").foregroundColor(Color(red: 1.0, green: 0.4, blue: 0.4))
                            Text("Model does not support tool calling").foregroundColor(.white.opacity(0.7))
                        }
                    }
                }
                .font(.system(size: 11))
                Spacer()
                if smokeTestStatus != .running {
                    Text("Re-test")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.white.opacity(0.4))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .modifier(GlassPillModifier())
                        .overlay(AppKitTapHandler {
                            Task { await runSmokeTest(for: settings.agentModel) }
                        })
                }
            }
        }
    }

    private var reasoningToggle: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Show full reasoning trace")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.white)
                Text("Expose chain-of-thought in agent bubbles")
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.4))
            }
            Spacer()
            Toggle("", isOn: $settings.agentShowReasoningTrace)
                .toggleStyle(.switch)
                .scaleEffect(0.75)
                .tint(Color(red: 0.4, green: 0.7, blue: 1.0))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .modifier(GlassPillModifier())
    }

    private var allowedPathsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Allowed paths for writes")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.white.opacity(0.5))
            Text("Writes inside these paths are autonomous. Writes elsewhere require approval.")
                .font(.system(size: 10))
                .foregroundColor(.white.opacity(0.35))
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 4) {
                ForEach(settings.agentAllowedPaths, id: \.self) { path in
                    HStack {
                        Text(path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.white.opacity(0.75))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundColor(.white.opacity(0.35))
                            .frame(width: 18, height: 18)
                            .overlay(AppKitTapHandler {
                                settings.agentAllowedPaths.removeAll { $0 == path }
                            })
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.white.opacity(0.06))
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.09), lineWidth: 0.5))
                    )
                }
            }

            HStack(spacing: 6) {
                TextField("Add path (e.g. ~/Projects)", text: $customPathDraft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.white)
                    .tint(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .modifier(GlassPillModifier())

                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.white.opacity(0.6))
                    .frame(width: 30, height: 30)
                    .modifier(GlassPillModifier())
                    .overlay(AppKitTapHandler { addCustomPath() })
            }
        }
    }

    private var ramHelpText: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Recommended models")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.white.opacity(0.5))
            ForEach([
                ("8 GB Mac", "deepseek-r1:7b"),
                ("16 GB Mac (recommended)", "deepseek-r1:14b"),
                ("32 GB Mac", "qwq:32b")
            ], id: \.0) { label, model in
                HStack(spacing: 6) {
                    Text(label + ":")
                        .font(.system(size: 10))
                        .foregroundColor(.white.opacity(0.35))
                    Text(model)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.white.opacity(0.55))
                    Spacer()
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 9))
                        .foregroundColor(.white.opacity(0.3))
                        .overlay(AppKitTapHandler {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString("ollama pull \(model)", forType: .string)
                        })
                }
            }
        }
    }

    // MARK: Helpers

    private func bannerView(color: Color, text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundColor(.white.opacity(0.7))
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(RoundedRectangle(cornerRadius: 10).fill(color))
    }

    private func isThinkingCapable(_ model: OllamaTagsResponse.Model) -> Bool {
        OllamaAPI.shared.isThinkingCapable(model: model)
    }

    private func addCustomPath() {
        let raw = customPathDraft.trimmingCharacters(in: .whitespaces)
        guard !raw.isEmpty else { return }
        let expanded = NSString(string: raw).expandingTildeInPath
        guard !settings.agentAllowedPaths.contains(expanded) else { customPathDraft = ""; return }
        settings.agentAllowedPaths.append(expanded)
        customPathDraft = ""
    }

    private func loadState() async {
        async let versionTask: SemVer? = try? await OllamaAPI.shared.ollamaVersion()
        async let tagsTask: OllamaTagsResponse? = {
            guard let url = URL(string: "http://localhost:11434/api/tags"),
                  let (data, _) = try? await OllamaAPI.statusSession.data(from: url) else { return nil }
            return try? JSONDecoder().decode(OllamaTagsResponse.self, from: data)
        }()

        let v = await versionTask
        let tags = await tagsTask

        await MainActor.run {
            ollamaVersion = v
            ollamaStatus = (tags != nil) ? .ok : .unreachable
            allModels = tags?.models ?? []
        }

        if !settings.agentModel.isEmpty {
            let cached = settings.agentModelToolCallVerified[settings.agentModel]
            if let cached {
                await MainActor.run { smokeTestStatus = cached ? .passed : .failed }
            } else {
                await runSmokeTest(for: settings.agentModel)
            }
        }
    }

    private func runSmokeTest(for model: String) async {
        await MainActor.run { smokeTestStatus = .running }
        let result = await OllamaAPI.shared.verifyToolCalling(model: model)
        await MainActor.run {
            settings.agentModelToolCallVerified[model] = result
            smokeTestStatus = result ? .passed : .failed
            if !result && settings.agentModel == model {
                // Don't auto-clear selection — user may want to try a different model, not lose their choice
            }
        }
    }
}
