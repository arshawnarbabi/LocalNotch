import SwiftUI

// MARK: - Pearlescent Orb

struct PearlescentOrb: View {
    let size: CGFloat
    let animated: Bool

    private static let palette: [Color] = [
        Color(red: 1.00, green: 0.70, blue: 0.85), // #FFB3D9 pink
        Color(red: 0.76, green: 0.61, blue: 1.00), // #C19BFF violet
        Color(red: 0.56, green: 0.72, blue: 1.00), // #8FB8FF blue
        Color(red: 0.62, green: 0.91, blue: 1.00), // #9FE9FF cyan
        Color(red: 1.00, green: 0.70, blue: 0.85), // repeat for wrap
    ]

    var body: some View {
        TimelineView(.animation(minimumInterval: animated ? 1.0 / 30.0 : nil, paused: !animated)) { tl in
            let t = animated ? tl.date.timeIntervalSinceReferenceDate : 0
            orbLayers(t: t)
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }

    private func orbLayers(t: Double) -> some View {
        let angle = Angle.degrees(t * 25.0)
        // Slowly cycle through palette by shifting the start index
        let shift = Int(t * 0.3) % Self.palette.count
        let p = Self.palette
        let c0 = p[(shift + 0) % p.count]
        let c1 = p[(shift + 1) % p.count]
        let c2 = p[(shift + 2) % p.count]
        let c3 = p[(shift + 3) % p.count]
        let cycled: [Color] = [c0, c1, c2, c3, c0]

        let hx = 0.32 + sin(t * 0.7) * 0.05
        let hy = 0.28 + cos(t * 0.5) * 0.04

        return ZStack {
            Circle()
                .fill(RadialGradient(
                    colors: [c3, c1, c0],
                    center: .center, startRadius: 0, endRadius: size * 0.55
                ))
            Circle()
                .fill(AngularGradient(colors: cycled, center: .center, angle: angle))
                .opacity(0.55)
                .blendMode(.plusLighter)
            Circle()
                .fill(RadialGradient(
                    colors: [Color.white.opacity(0.55), Color.clear],
                    center: UnitPoint(x: hx, y: hy),
                    startRadius: 0, endRadius: size * 0.38
                ))
        }
    }
}

// MARK: - Agent Mode View

struct AgentModeView: View {
    @ObservedObject private var runner = AgentRunner.shared
    @ObservedObject private var settings = AppSettings.shared

    let onExit: () -> Void

    @State private var inputText = ""
    @State private var showingHistory = false
    @State private var isInputExpanded = false
    @FocusState private var inputFocused: Bool
    @State private var isHoveringOrb = false
    @State private var hoveringLeftBtn = false
    @State private var hoveringHistoryBtn = false
    @State private var scrollProxy: ScrollViewProxy? = nil

    private let springAnim = Animation.spring(response: 0.42, dampingFraction: 0.72)
    private let orbSmallSize: CGFloat = 30
    private let orbLargeSize: CGFloat = 76
    private let sphereSize: CGFloat = 30

    var body: some View {
        ZStack {
            if showingHistory {
                AgentHistoryView(runner: runner) { showingHistory = false }
                    .transition(.opacity.combined(with: .scale(scale: 0.97)))
            } else {
                VStack(spacing: 0) {
                    contentArea
                    inputArea
                }
                .transition(.opacity.combined(with: .scale(scale: 0.97)))
            }
        }
        .animation(.spring(response: 0.38, dampingFraction: 0.82), value: showingHistory)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: runner.state) { _, newState in
            handleStateChange(newState)
        }
    }

    // MARK: — Content area

    @ViewBuilder
    private var contentArea: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                // Bubble stack — shown whenever there are bubbles
                if !runner.bubbles.isEmpty || !runner.finalOutput.isEmpty {
                    bubbleStack
                }

                // Orb — animates position and size based on state
                let isIdle = runner.state == .idle
                let orbSize = isIdle ? orbLargeSize : orbSmallSize
                let centerX = geo.size.width / 2
                let centerY = (geo.size.height) / 2
                let idleX = centerX
                let idleY = runner.bubbles.isEmpty ? centerY : orbSmallSize / 2 + 10
                let activeX = orbSmallSize / 2 + 10
                let activeY = orbSmallSize / 2 + 10

                let orbX = isIdle ? idleX : activeX
                let orbY = isIdle ? idleY : activeY

                orbView(size: orbSize)
                    .position(x: orbX, y: orbY)
                    .animation(springAnim, value: isIdle)
                    .animation(springAnim, value: orbSize)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: runner.bubbles.count)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var bubbleStack: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    // Spacer for the orb when in small position
                    if runner.state != .idle {
                        Color.clear.frame(height: orbSmallSize + 16)
                    }

                    ForEach(runner.bubbles) { bubble in
                        AgentBubbleView(bubble: bubble, showReasoning: settings.agentShowReasoningTrace)
                            .id(bubble.id)
                    }

                    if !runner.finalOutput.isEmpty {
                        Text(runner.finalOutput)
                            .font(.system(size: 13))
                            .foregroundColor(.white)
                            .textSelection(.enabled)
                            .padding(.horizontal, 12)
                            .padding(.top, 4)
                    }

                    Color.clear.frame(height: 4).id("bottom")
                }
                .padding(.horizontal, 10)
                .padding(.top, 8)
            }
            .scrollIndicators(.hidden)
            .onAppear { scrollProxy = proxy }
            .onChange(of: runner.bubbles.count) { _, _ in
                withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .onChange(of: runner.finalOutput) { _, _ in
                withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
            }
        }
    }

    @ViewBuilder
    private func orbView(size: CGFloat) -> some View {
        let isFinished = runner.state == .finished || runner.state == .forceStopped
        let showXOverlay = runner.state == .running && isHoveringOrb

        ZStack {
            PearlescentOrb(size: size, animated: !isFinished)
                .opacity(showXOverlay ? 0.3 : 1.0)
                .animation(.easeInOut(duration: 0.15), value: showXOverlay)

            if showXOverlay {
                Image(systemName: "xmark")
                    .font(.system(size: size * 0.35, weight: .semibold))
                    .foregroundColor(.white)
                    .transition(.opacity)
            }
        }
        .frame(width: size, height: size)
        .background(
            AlwaysActiveHoverDetector { isHoveringOrb = $0 }
                .frame(width: size, height: size)
        )
        .overlay(
            AppKitTapHandler {
                if showXOverlay { runner.forceStop() }
            }
        )
        .animation(.easeInOut(duration: 0.15), value: showXOverlay)
    }

    // MARK: — Input area

    private var inputArea: some View {
        ZStack(alignment: .center) {
            // Collapsed: left/right spheres
            if !isInputExpanded {
                HStack(spacing: 0) {
                    leftControlButton
                    Spacer()
                    historyButton
                }
                .padding(.horizontal, 10)
                .transition(.opacity.combined(with: .scale(scale: 0.7)).animation(springAnim))
            }

            // Pill
            if showsPill {
                HStack(alignment: .center, spacing: 8) {
                    agentPill
                }
                .padding(.horizontal, isInputExpanded ? 10 : sphereSize + 18)
                .animation(springAnim, value: isInputExpanded)
            }
        }
        .animation(springAnim, value: isInputExpanded)
        .padding(.bottom, 10)
        .padding(.top, 4)
    }

    private var showsPill: Bool {
        switch runner.state {
        case .idle, .paused, .clarifying, .approving, .finished, .forceStopped: return true
        case .running: return false
        case .welcome: return true
        }
    }

    private var agentPill: some View {
        ZStack {
            if !isInputExpanded {
                HStack(spacing: 5) {
                    Image(systemName: "text.bubble")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.white.opacity(0.65))
                    Text(pillPlaceholderText)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.white.opacity(0.65))
                }
                .transition(.opacity.animation(.easeOut(duration: 0.18)))
            } else {
                HStack(spacing: 0) {
                    ZStack(alignment: .leading) {
                        if inputText.isEmpty {
                            Text(pillPlaceholderText)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(.white.opacity(0.35))
                        }
                        TextField("", text: $inputText)
                            .textFieldStyle(.plain)
                            .foregroundColor(.white)
                            .font(.system(size: 13))
                            .focused($inputFocused)
                            .onSubmit { sendOrRespond() }
                    }
                    Spacer(minLength: 8)
                    sendButton
                }
                .transition(.opacity.animation(.easeIn(duration: 0.18).delay(0.06)))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, isInputExpanded ? 9 : 7)
        .frame(
            minWidth: isInputExpanded ? 0 : 148,
            maxWidth: isInputExpanded ? .infinity : 148
        )
        .modifier(GlassPillModifier())
        .background(
            AlwaysActiveHoverDetector { hovering in
                if hovering {
                    withAnimation(springAnim) { isInputExpanded = true }
                } else if inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !inputFocused {
                    Task {
                        try? await Task.sleep(nanoseconds: 200_000_000)
                        guard inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !inputFocused else { return }
                        await MainActor.run { withAnimation(springAnim) { isInputExpanded = false } }
                    }
                }
            }
        )
    }

    private var pillPlaceholderText: String {
        switch runner.state {
        case .idle:       return "Describe a task…"
        case .paused:     return "Add context (optional)…"
        case .clarifying, .approving: return "Type a reply…"
        case .finished, .forceStopped: return "Start another task…"
        default:          return "Describe a task…"
        }
    }

    @ViewBuilder
    private var sendButton: some View {
        let isSendEnabled: Bool = {
            switch runner.state {
            case .idle, .paused, .clarifying, .approving, .finished, .forceStopped:
                return !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            default: return false
            }
        }()

        Button(action: sendOrRespond) {
            Image(systemName: "arrow.up")
                .font(.system(size: 12, weight: .bold))
                .foregroundColor(.black)
                .frame(width: 28, height: 28)
                .background(Circle().fill(.white))
                .clipShape(Circle())
        }
        .buttonStyle(.plain)
        .modifier(GlassCircleModifier())
        .disabled(!isSendEnabled)
        .opacity(isSendEnabled ? 1 : 0.35)
    }

    private var leftControlButton: some View {
        Group {
            switch runner.state {
            case .idle:
                sphereButton(icon: "xmark", label: "exit") { exitAgentMode() }
            case .running:
                sphereButton(icon: "pause.fill", label: "pause") { runner.pause() }
            case .paused:
                sphereButton(icon: "play.fill", label: "resume") { runner.resume() }
            case .finished, .forceStopped:
                sphereButton(icon: "xmark", label: "exit") { exitAgentMode() }
            case .clarifying, .approving:
                // Pulsing play button — signals "agent is waiting for you"
                PulsingPlayButton { /* tap does nothing; user must type and send */ }
            case .welcome:
                sphereButton(icon: "xmark", label: "exit") { exitAgentMode() }
            }
        }
    }

    private var historyButton: some View {
        Image(systemName: "clock.arrow.trianglehead.counterclockwise.rotate.90")
            .font(.system(size: 11, weight: .medium))
            .foregroundColor(.white.opacity(hoveringHistoryBtn ? 1.0 : 0.75))
            .frame(width: sphereSize, height: sphereSize)
            .modifier(GlassSphereModifier())
            .scaleEffect(hoveringHistoryBtn ? 1.14 : 1.0)
            .brightness(hoveringHistoryBtn ? 0.12 : 0)
            .animation(.spring(response: 0.25, dampingFraction: 0.68), value: hoveringHistoryBtn)
            .background(AlwaysActiveHoverDetector { hoveringHistoryBtn = $0 })
            .overlay(AppKitTapHandler { showingHistory = true })
    }

    private func sphereButton(icon: String, label: String, action: @escaping () -> Void) -> some View {
        Image(systemName: icon)
            .font(.system(size: 11, weight: .medium))
            .foregroundColor(.white.opacity(hoveringLeftBtn ? 1.0 : 0.75))
            .frame(width: sphereSize, height: sphereSize)
            .modifier(GlassSphereModifier())
            .scaleEffect(hoveringLeftBtn ? 1.14 : 1.0)
            .brightness(hoveringLeftBtn ? 0.12 : 0)
            .animation(.spring(response: 0.25, dampingFraction: 0.68), value: hoveringLeftBtn)
            .background(AlwaysActiveHoverDetector { hoveringLeftBtn = $0 })
            .overlay(AppKitTapHandler { action() })
    }

    // MARK: — Actions

    private func sendOrRespond() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        inputText = ""
        withAnimation(springAnim) { isInputExpanded = false }
        inputFocused = false

        switch runner.state {
        case .idle, .finished, .forceStopped:
            runner.startTask(prompt: text)
        case .paused:
            runner.resume(withContext: text)
        case .clarifying, .approving:
            runner.handleUserResponse(text)
        default:
            break
        }
    }

    private func exitAgentMode() {
        runner.exitAgentMode()
        onExit()
    }

    private func handleStateChange(_ state: AgentState) {
        switch state {
        case .idle, .paused, .clarifying, .approving, .finished, .forceStopped:
            withAnimation(springAnim) { isInputExpanded = true; inputFocused = false }
        case .running:
            withAnimation(springAnim) { isInputExpanded = false }
        case .welcome:
            withAnimation(springAnim) { isInputExpanded = true }
        }
    }
}

// MARK: - Pulsing Play Button (State G/H)

struct PulsingPlayButton: View {
    let onTap: () -> Void
    @State private var pulse = false

    var body: some View {
        Image(systemName: "play.fill")
            .font(.system(size: 11, weight: .medium))
            .foregroundColor(.white.opacity(0.75))
            .frame(width: 30, height: 30)
            .modifier(GlassSphereModifier())
            .overlay(
                Circle()
                    .stroke(Color.white.opacity(pulse ? 0.0 : 0.5), lineWidth: 1.5)
                    .scaleEffect(pulse ? 1.5 : 1.0)
                    .animation(.easeOut(duration: 0.9).repeatForever(autoreverses: false), value: pulse)
            )
            .overlay(AppKitTapHandler { onTap() })
            .onAppear { pulse = true }
    }
}

// MARK: - Agent Bubble View

struct AgentBubbleView: View {
    let bubble: AgentBubble
    let showReasoning: Bool
    @State private var reasoningExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 8) {
                // Tinted indicator dot
                Circle()
                    .fill(dotColor)
                    .frame(width: 5, height: 5)
                    .padding(.top, 5)

                VStack(alignment: .leading, spacing: 4) {
                    Text(bubble.text.isEmpty && bubble.isStreaming ? "…" : bubble.text)
                        .font(.system(size: 12))
                        .foregroundColor(textColor)
                        .fixedSize(horizontal: false, vertical: true)

                    // Reasoning trace expander (when showReasoning + has reasoning)
                    if showReasoning, let reasoning = bubble.reasoning, !reasoning.isEmpty {
                        HStack(spacing: 4) {
                            Image(systemName: reasoningExpanded ? "chevron.up" : "chevron.down")
                                .font(.system(size: 8, weight: .medium))
                            Text("Reasoning")
                                .font(.system(size: 10))
                        }
                        .foregroundColor(.white.opacity(0.35))
                        .overlay(AppKitTapHandler { reasoningExpanded.toggle() })

                        if reasoningExpanded {
                            Text(reasoning)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(.white.opacity(0.4))
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(6)
                                .background(
                                    RoundedRectangle(cornerRadius: 6)
                                        .fill(Color.white.opacity(0.05))
                                )
                        }
                    }
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(bubbleBg)
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
    }

    private var dotColor: Color {
        switch bubble.type {
        case .error: return Color(red: 1.0, green: 0.4, blue: 0.4)
        case .toolResult: return Color(red: 0.4, green: 0.85, blue: 0.5)
        case .clarification, .approval: return Color(red: 1.0, green: 0.9, blue: 0.4)
        default: return Color.white.opacity(0.4)
        }
    }

    private var textColor: Color {
        switch bubble.type {
        case .error: return Color(red: 1.0, green: 0.6, blue: 0.6)
        default: return Color.white.opacity(0.75)
        }
    }

    private var bubbleBg: some View {
        Group {
            if #available(macOS 26, *) {
                RoundedRectangle(cornerRadius: 10).fill(Color.clear).glassEffect(.regular, in: .rect(cornerRadius: 10))
            } else {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.white.opacity(bubble.type == .error ? 0.08 : 0.06))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.white.opacity(0.1), lineWidth: 0.5))
            }
        }
    }
}

// MARK: - Agent History View

struct AgentHistoryView: View {
    @ObservedObject var runner: AgentRunner
    let onClose: () -> Void
    @State private var activeTab = 0  // 0 = Chat, 1 = Action Log

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: 8) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white.opacity(0.75))
                    .frame(width: 26, height: 26)
                    .modifier(GlassSphereModifier())
                    .overlay(AppKitTapHandler { onClose() })

                Text("Agent History")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white)

                Spacer()

                // Tab switcher
                HStack(spacing: 2) {
                    ForEach(["Chat", "Actions"], id: \.self) { tab in
                        let idx = tab == "Chat" ? 0 : 1
                        Text(tab)
                            .font(.system(size: 11, weight: activeTab == idx ? .semibold : .regular))
                            .foregroundColor(.white.opacity(activeTab == idx ? 1.0 : 0.5))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(
                                Capsule().fill(Color.white.opacity(activeTab == idx ? 0.15 : 0))
                            )
                            .overlay(AppKitTapHandler { activeTab = idx })
                    }
                }
                .modifier(GlassPillModifier())
            }
            .padding(.horizontal, 14)
            .padding(.top, 14)
            .padding(.bottom, 10)

            if activeTab == 0 {
                chatTab
            } else {
                actionLogTab
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var chatTab: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 6) {
                ForEach(runner.bubbles) { bubble in
                    AgentBubbleView(bubble: bubble, showReasoning: AppSettings.shared.agentShowReasoningTrace)
                }
                if !runner.finalOutput.isEmpty {
                    Text(runner.finalOutput)
                        .font(.system(size: 13))
                        .foregroundColor(.white)
                        .padding(.horizontal, 12)
                        .padding(.top, 4)
                }
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 14)
        }
        .scrollIndicators(.hidden)
    }

    private var actionLogTab: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 4) {
                if runner.actionLog.isEmpty {
                    Text("No tool calls yet in this session.")
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.35))
                        .padding(.horizontal, 14)
                        .padding(.top, 16)
                } else {
                    ForEach(runner.actionLog) { entry in
                        actionLogRow(entry)
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 14)
        }
        .scrollIndicators(.hidden)
    }

    private func actionLogRow(_ entry: ActionLogEntry) -> some View {
        let df = DateFormatter(); df.dateFormat = "HH:mm:ss"
        return HStack(spacing: 6) {
            Text("[\(df.string(from: entry.timestamp))]")
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(.white.opacity(0.35))

            Text("\(entry.toolName)(\(entry.argsDescription))")
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(.white.opacity(0.65))
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 4)

            Image(systemName: entry.succeeded ? "checkmark" : "xmark")
                .font(.system(size: 9, weight: .semibold))
                .foregroundColor(entry.succeeded
                    ? Color(red: 0.3, green: 0.85, blue: 0.5)
                    : Color(red: 1.0, green: 0.4, blue: 0.4))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.white.opacity(0.04))
        )
    }
}
