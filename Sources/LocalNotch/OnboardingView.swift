import SwiftUI
import AppKit

// MARK: - Onboarding View
// 5-step in-panel flow. Shown on first launch until onboardingComplete is set.
// Steps: 1 Ollama check → 2 Text model → 3 Vision model → 4 Brave key → 5 Done
// No skip/dismiss — user must complete all steps.
// Current step persists to UserDefaults so quitting mid-flow resumes in place.

struct OnboardingView: View {
    @ObservedObject private var settings = AppSettings.shared
    @State private var step: Int = AppSettings.shared.onboardingStep

    private let totalSteps = 5
    private let stepSpring = Animation.easeInOut(duration: 0.32)

    var body: some View {
        VStack(spacing: 0) {
            stepIndicator
                .padding(.top, 16)
                .padding(.bottom, 10)

            ZStack {
                stepContent
            }
            .animation(stepSpring, value: step)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Step Indicator

    private var stepIndicator: some View {
        HStack(spacing: 6) {
            ForEach(1...totalSteps, id: \.self) { i in
                Capsule()
                    .fill(Color.white.opacity(i == step ? 1.0 : 0.25))
                    .frame(width: i == step ? 20 : 10, height: 4)
                    .animation(stepSpring, value: step)
            }
        }
    }

    // MARK: Step Content

    @ViewBuilder
    private var stepContent: some View {
        switch step {
        case 1:
            OllamaCheckStep(onNext: advance)
                .transition(stepTransition)
                .id("step1")
        case 2:
            PickTextModelStep(onNext: advance)
                .transition(stepTransition)
                .id("step2")
        case 3:
            PickVisionModelStep(onNext: advance)
                .transition(stepTransition)
                .id("step3")
        case 4:
            BraveKeyStep(onNext: advance)
                .transition(stepTransition)
                .id("step4")
        case 5:
            DoneStep(onFinish: {
                AppSettings.shared.onboardingStep = 1
                AppSettings.shared.onboardingComplete = true
            })
            .transition(stepTransition)
            .id("step5")
        default:
            EmptyView()
        }
    }

    private var stepTransition: AnyTransition {
        .asymmetric(
            insertion: .opacity.combined(with: .offset(y: 20)),
            removal:   .opacity.combined(with: .offset(y: -20))
        )
    }

    private func advance() {
        let next = min(step + 1, totalSteps)
        AppSettings.shared.onboardingStep = next
        withAnimation(stepSpring) { step = next }
    }
}

// MARK: - Step 1: Ollama Check

private struct OllamaCheckStep: View {
    let onNext: () -> Void

    enum OllamaState { case checking, running, notRunning, notInstalled }

    @State private var ollamaState: OllamaState = .checking

    var body: some View {
        VStack(spacing: 20) {
            Spacer()

            VStack(spacing: 10) {
                statusIcon
                    .frame(height: 32)

                Text(statusTitle)
                    .font(.system(size: 18, weight: .medium))
                    .foregroundColor(.white)
                    .multilineTextAlignment(.center)

                Text(statusSubtitle)
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.5))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 24)

            actionButtons

            Spacer()
        }
        .task { await checkOllama() }
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch ollamaState {
        case .checking:
            PulsingDot()
        case .running:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 28))
                .foregroundColor(.green)
                .transition(.scale.combined(with: .opacity))
        case .notRunning, .notInstalled:
            Image(systemName: "exclamationmark.circle")
                .font(.system(size: 28))
                .foregroundColor(.white.opacity(0.6))
                .transition(.opacity)
        }
    }

    private var statusTitle: String {
        switch ollamaState {
        case .checking:     return "Looking for Ollama…"
        case .running:      return "Ollama detected"
        case .notRunning:   return "Ollama isn't running"
        case .notInstalled: return "Ollama not found"
        }
    }

    private var statusSubtitle: String {
        switch ollamaState {
        case .checking:     return ""
        case .running:      return "All good — continuing setup."
        case .notRunning:   return "Open the Ollama app, then check again."
        case .notInstalled: return "Install Ollama to get started."
        }
    }

    @ViewBuilder
    private var actionButtons: some View {
        switch ollamaState {
        case .checking:
            EmptyView()

        case .running:
            OnboardingButton(label: "Continue", icon: "arrow.right") { onNext() }
                .transition(.opacity)

        case .notRunning:
            HStack(spacing: 12) {
                OnboardingButton(label: "Open Ollama", icon: "arrow.up.right.square") {
                    NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications/Ollama.app"))
                }
                OnboardingButton(label: "Check again", icon: "arrow.clockwise") {
                    ollamaState = .checking
                    Task { await checkOllama() }
                }
            }

        case .notInstalled:
            HStack(spacing: 12) {
                OnboardingButton(label: "Get Ollama", icon: "arrow.up.right.square") {
                    NSWorkspace.shared.open(URL(string: "https://ollama.com")!)
                }
                OnboardingButton(label: "Check again", icon: "arrow.clockwise") {
                    ollamaState = .checking
                    Task { await checkOllama() }
                }
            }
        }
    }

    private func checkOllama() async {
        guard let url = URL(string: "http://localhost:11434/api/tags") else {
            ollamaState = .notInstalled; return
        }
        do {
            let (_, response) = try await OllamaAPI.statusSession.data(from: url)
            if (response as? HTTPURLResponse)?.statusCode == 200 {
                withAnimation(.spring(response: 0.38, dampingFraction: 0.75)) {
                    ollamaState = .running
                }
                try? await Task.sleep(for: .milliseconds(900))
                onNext()
            } else {
                ollamaState = .notRunning
            }
        } catch {
            let isInstalled = FileManager.default.fileExists(atPath: "/Applications/Ollama.app")
            ollamaState = isInstalled ? .notRunning : .notInstalled
        }
    }
}

// MARK: - Step 2: Pick Text Model

private struct PickTextModelStep: View {
    let onNext: () -> Void

    @ObservedObject private var settings = AppSettings.shared
    @State private var availableModels: [String] = []
    @State private var loading = true
    @State private var isOpen = false

    private var canContinue: Bool { !settings.textModelName.isEmpty }

    var body: some View {
        VStack(spacing: 16) {
            Spacer()

            VStack(spacing: 6) {
                Text("Choose a text model")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundColor(.white)
                Text("Required — handles all chat and reasoning.")
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.5))
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 24)

            ModelDropdownRow(
                label: "Text model",
                selected: settings.textModelName,
                models: availableModels,
                isLoading: loading,
                isOpen: $isOpen,
                onSelect: {
                    settings.textModelName = $0
                    withAnimation(.easeInOut(duration: 0.12)) { isOpen = false }
                }
            )
            .padding(.horizontal, 24)

            OnboardingButton(
                label: "Continue",
                icon: "arrow.right",
                disabled: !canContinue
            ) { onNext() }

            Spacer()
        }
        .task { await loadModels() }
    }

    private func loadModels() async {
        guard let url = URL(string: "http://localhost:11434/api/tags") else { loading = false; return }
        do {
            let (data, _) = try await OllamaAPI.statusSession.data(from: url)
            let decoded = try JSONDecoder().decode(OllamaTagsResponse.self, from: data)
            let textOnly = decoded.models.filter { !$0.isVisionCapable }.map(\.name).sorted()
            // Fall back to all models if nothing qualifies as text-only
            availableModels = textOnly.isEmpty ? decoded.models.map(\.name).sorted() : textOnly
        } catch {}
        loading = false
    }
}

// MARK: - Step 3: Pick Vision Model

private struct PickVisionModelStep: View {
    let onNext: () -> Void

    @ObservedObject private var settings = AppSettings.shared
    @State private var availableModels: [String] = []
    @State private var loading = true
    @State private var isOpen = false

    var body: some View {
        VStack(spacing: 16) {
            Spacer()

            VStack(spacing: 6) {
                Text("Vision model")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundColor(.white)
                Text("Optional — enables screenshot analysis.\nYou can add one later in Settings.")
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.5))
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 24)

            ModelDropdownRow(
                label: "Vision model (optional)",
                selected: settings.visionModelName,
                models: availableModels,
                isLoading: loading,
                isOpen: $isOpen,
                onSelect: {
                    settings.visionModelName = $0
                    withAnimation(.easeInOut(duration: 0.12)) { isOpen = false }
                }
            )
            .padding(.horizontal, 24)

            HStack(spacing: 12) {
                OnboardingButton(label: "Skip", icon: "arrow.right") { onNext() }
                if !settings.visionModelName.isEmpty {
                    OnboardingButton(label: "Continue", icon: "checkmark") { onNext() }
                        .transition(.opacity.combined(with: .scale(scale: 0.95)))
                }
            }
            .animation(.spring(response: 0.28, dampingFraction: 0.72), value: settings.visionModelName.isEmpty)

            Spacer()
        }
        .task { await loadModels() }
    }

    private func loadModels() async {
        guard let url = URL(string: "http://localhost:11434/api/tags") else { loading = false; return }
        do {
            let (data, _) = try await OllamaAPI.statusSession.data(from: url)
            let decoded = try JSONDecoder().decode(OllamaTagsResponse.self, from: data)
            // Only show vision-capable models; empty list is valid (user has none installed)
            availableModels = decoded.models.filter { $0.isVisionCapable }.map(\.name).sorted()
        } catch {}
        loading = false
    }
}

// MARK: - Step 4: Brave Key

private struct BraveKeyStep: View {
    let onNext: () -> Void

    @ObservedObject private var settings = AppSettings.shared
    @State private var keyVisible = false

    var body: some View {
        VStack(spacing: 16) {
            Spacer()

            VStack(spacing: 6) {
                Text("Web search")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundColor(.white)
                Text("Optional — you can add this later in Settings.")
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.5))
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 24)

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
            .padding(.horizontal, 24)

            HStack(spacing: 12) {
                OnboardingButton(label: "Skip", icon: "arrow.right") { onNext() }
                if !settings.braveSearchAPIKey.trimmingCharacters(in: .whitespaces).isEmpty {
                    OnboardingButton(label: "Save & continue", icon: "checkmark") { onNext() }
                        .transition(.opacity.combined(with: .scale(scale: 0.95)))
                }
            }
            .animation(.spring(response: 0.28, dampingFraction: 0.72), value: settings.braveSearchAPIKey.isEmpty)

            Spacer()
        }
    }
}

// MARK: - Step 5: Done

private struct DoneStep: View {
    let onFinish: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Spacer()

            Text("You're all set.")
                .font(.system(size: 22, weight: .medium))
                .foregroundColor(.white)

            Text("Hover over the notch anytime to open.")
                .font(.system(size: 12))
                .foregroundColor(.white.opacity(0.45))
                .frame(height: 16)

            OnboardingButton(label: "Let's go", icon: "sparkles") { onFinish() }

            Spacer()
        }
    }
}

// MARK: - Onboarding Button

struct OnboardingButton: View {
    let label: String
    let icon: String
    var disabled: Bool = false
    let action: () -> Void

    @State private var hovering = false
    @State private var pressing = false

    var body: some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.system(size: 12, weight: .medium))
            Image(systemName: icon)
                .font(.system(size: 11, weight: .medium))
        }
        .foregroundColor(disabled ? .white.opacity(0.3) : .white)
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .modifier(GlassPillModifier())
        .scaleEffect(pressing ? 0.95 : (hovering ? 1.04 : 1.0))
        .brightness(hovering && !disabled ? 0.1 : 0)
        .opacity(disabled ? 0.5 : 1)
        .animation(.spring(response: 0.22, dampingFraction: 0.65), value: hovering)
        .animation(.spring(response: 0.18, dampingFraction: 0.6), value: pressing)
        .background(AlwaysActiveHoverDetector { if !disabled { hovering = $0 } })
        .overlay(AppKitTapHandler(
            action: { if !disabled { action() } },
            onPressChanged: { if !disabled { pressing = $0 } }
        ))
    }
}

// MARK: - Pulsing Dot (Ollama check indicator)

private struct PulsingDot: View {
    private let sizes: [CGFloat] = [4, 6, 9, 6]
    private let interval = 0.15

    var body: some View {
        TimelineView(.periodic(from: .now, by: interval)) { context in
            let idx = Int(context.date.timeIntervalSince1970 / interval) % sizes.count
            Circle()
                .fill(Color.white)
                .frame(width: sizes[idx], height: sizes[idx])
                .frame(width: 16, height: 16)
        }
    }
}
