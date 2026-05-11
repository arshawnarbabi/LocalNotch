import SwiftUI
import MarkdownUI
import ImageIO
import ScreenCaptureKit

struct ChatView: View {
    @ObservedObject var state: ChatState
    @State private var inputText = ""
    @State private var isInputExpanded = false
    @State private var isHoveringInput = false
    @State private var showingHistory = false
    @State private var hoverExitTask: Task<Void, Never>?
    @State private var hoveringReset = false
    @State private var hoveringHistory = false
    @State private var hoveringCapture = false
    @State private var capturePressed = false
    @State private var pressProgress: CGFloat = 0
    @State private var ringDelayTask: Task<Void, Never>?
    @State private var streamingTask: Task<Void, Never>?   // tracked so reset can cancel it

    // Reset wipe
    @State private var snapshotForErase = ""
    @State private var isErasing = false
    @State private var eraseProgress: Double = 0


    @FocusState private var inputFocused: Bool
    @Namespace private var pillNS

    private let springAnim = Animation.spring(response: 0.42, dampingFraction: 0.72)

    // Single enum drives all content-area transitions cleanly
    private enum ChatPhase: Equatable {
        case idle, searching, processingImage, responding, erasing
    }
    private var chatPhase: ChatPhase {
        if isErasing                         { return .erasing   }
        if state.isSearching                 { return .searching  }
        if state.isProcessingImage && state.currentResponse.isEmpty { return .processingImage }
        if !state.currentResponse.isEmpty    { return .responding }
        if state.isLoading                   { return .responding }
        return .idle
    }

    var body: some View {
        ZStack {
            if showingHistory {
                HistoryView(history: state.chatHistory) { showingHistory = false }
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
    }

    // MARK: - Content area

    @ViewBuilder
    private var contentArea: some View {
        ZStack {
            switch chatPhase {
            case .idle:
                WelcomeView()
                    .transition(.opacity)
            case .searching:
                Color.clear
                    .transition(.opacity)
            case .processingImage:
                ImageProcessingDots()
                    .transition(.opacity)
            case .responding, .erasing:
                responseScrollView
                    .transition(.opacity.combined(with: .scale(scale: 1.03, anchor: .top)))
            }
        }
        .animation(.easeInOut(duration: 0.32), value: chatPhase)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var responseScrollView: some View {
        ScrollView {
            responseContent
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
        }
        .scrollIndicators(.hidden)
        .mask {
            VStack(spacing: 0) {
                LinearGradient(colors: [.black.opacity(0.05), .black], startPoint: .top, endPoint: .bottom)
                    .frame(height: 22)
                Rectangle()
                LinearGradient(
                    colors: [.black, .black.opacity(state.isLoading ? 0.0 : 0.05)],
                    startPoint: .top, endPoint: .bottom
                )
                .frame(height: state.isLoading ? 68 : 22)
                .animation(.easeInOut(duration: 0.45), value: state.isLoading)
            }
        }
    }

    @ViewBuilder
    private var responseContent: some View {
        if isErasing {
            AssistantRow(content: snapshotForErase)
                .opacity(1.0 - eraseProgress)
        } else {
            AssistantRow(content: state.currentResponse)
        }
    }

    // MARK: - Input area

    private let sphereSize: CGFloat = 30
    private let captureButtonSize: CGFloat = 46   // matches expanded pill height (28 content + 9+9 padding)
    private let captureRingSize: CGFloat = 54     // 4pt radius beyond the button — small external gap for the progress ring
    private let pillCollapsedWidth: CGFloat = 148

    private var inputArea: some View {
        ZStack(alignment: .center) {
            if !isInputExpanded {
                HStack(spacing: 0) {
                    leftSphere
                    Spacer()
                    rightSphere
                }
                .padding(.horizontal, 10)
                .transition(.opacity.combined(with: .scale(scale: 0.7)).animation(springAnim))
            }

            HStack(alignment: .center, spacing: 8) {
                ZStack {
                    if !isInputExpanded {
                        pillLabel
                            .transition(.opacity.animation(.easeOut(duration: 0.18)))
                    } else {
                        pillTextField
                            .transition(.opacity.animation(.easeIn(duration: 0.18).delay(0.06)))
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, isInputExpanded ? 9 : 7)
                .frame(
                    minWidth: isInputExpanded ? 0 : pillCollapsedWidth,
                    maxWidth: isInputExpanded ? .infinity : pillCollapsedWidth
                )
                .modifier(GlassPillModifier())
                .background(
                    AlwaysActiveHoverDetector { hovering in
                        isHoveringInput = hovering
                        if hovering {
                            hoverExitTask?.cancel()
                            hoverExitTask = nil
                            withAnimation(springAnim) { isInputExpanded = true }
                        } else {
                            hoverExitTask?.cancel()
                            hoverExitTask = Task {
                                try? await Task.sleep(nanoseconds: 200_000_000)
                                guard !Task.isCancelled, !isHoveringInput, !hoveringCapture else { return }
                                await MainActor.run {
                                    if inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                        && !inputFocused && state.capturedImage == nil && !state.isCapturing {
                                        withAnimation(springAnim) { isInputExpanded = false }
                                    }
                                }
                            }
                        }
                    }
                )

                if isInputExpanded {
                    captureButton
                        .transition(.opacity.combined(with: .scale(scale: 0.7)).animation(springAnim))
                }
            }
            .padding(.horizontal, isInputExpanded ? 10 : sphereSize + 18)
            .animation(springAnim, value: isInputExpanded)
        }
        .animation(springAnim, value: isInputExpanded)
        .padding(.bottom, 10)
        .padding(.top, 4)
    }

    // Collapsed: [icon] "Ask anything" — matched geometry source for morph animation
    private var pillLabel: some View {
        HStack(spacing: 5) {
            Image(systemName: "text.bubble")
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.white.opacity(0.65))
            Text("Ask anything")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.white.opacity(0.65))
                .matchedGeometryEffect(id: "promptText", in: pillNS)
        }
    }

    // Expanded: "Ask anything" placeholder morphed from pill, then text field, then send button
    private var pillTextField: some View {
        HStack(spacing: 0) {
            ZStack(alignment: .leading) {
                if inputText.isEmpty {
                    Text("Ask anything")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.white.opacity(0.35))
                        .matchedGeometryEffect(id: "promptText", in: pillNS)
                }
                TextField("", text: $inputText)
                    .textFieldStyle(.plain)
                    .foregroundColor(.white)
                    .font(.system(size: 13))
                    .focused($inputFocused)
                    .onSubmit { sendMessage() }
                    .onChange(of: inputFocused) { focused in
                        if !focused && inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isHoveringInput {
                            hoverExitTask?.cancel()
                            hoverExitTask = Task {
                                try? await Task.sleep(nanoseconds: 200_000_000)
                                guard !Task.isCancelled, !isHoveringInput else { return }
                                await MainActor.run {
                                    withAnimation(springAnim) { isInputExpanded = false }
                                }
                            }
                        }
                    }
            }

            Spacer(minLength: 8)

            if state.isLoading {
                ProgressView()
                    .progressViewStyle(.circular)
                    .scaleEffect(0.6)
                    .tint(.white)
                    .frame(width: 28, height: 28)
            } else {
                Button(action: sendMessage) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(.black)
                        .frame(width: 28, height: 28)
                        .background(Circle().fill(.white))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .modifier(GlassCircleModifier())
                .disabled(inputText.isEmpty)
                .opacity(inputText.isEmpty ? 0.35 : 1)
            }
        }
    }

    private var leftSphere: some View {
        Image(systemName: "arrow.counterclockwise")
            .font(.system(size: 12, weight: .medium))
            .foregroundColor(.white.opacity(hoveringReset ? 1.0 : 0.75))
            .frame(width: sphereSize, height: sphereSize)
            .modifier(GlassSphereModifier())
            .scaleEffect(hoveringReset ? 1.14 : 1.0)
            .brightness(hoveringReset ? 0.12 : 0)
            .animation(.spring(response: 0.25, dampingFraction: 0.68), value: hoveringReset)
            .background(AlwaysActiveHoverDetector { hoveringReset = $0 })
            .overlay(AppKitTapHandler {
                guard !isErasing else { return }
                streamingTask?.cancel()
                streamingTask = nil
                snapshotForErase = state.currentResponse
                guard !snapshotForErase.isEmpty else {
                    state.resetChat()
                    return
                }
                isErasing = true
                withAnimation(.easeIn(duration: 0.1)) { eraseProgress = 1.0 }
                Task {
                    try? await Task.sleep(nanoseconds: 100_000_000)
                    state.resetChat()
                    eraseProgress = 0
                    isErasing = false
                }
            })
    }

    private var captureButton: some View {
        ZStack {
            // Inner button — scales with hover/press
            ZStack {
                if let img = state.capturedImage {
                    Image(nsImage: img)
                        .resizable()
                        .scaledToFill()
                        .frame(width: captureButtonSize, height: captureButtonSize)
                        .clipShape(Circle())
                        .transition(.opacity)
                } else {
                    Image(systemName: "camera.viewfinder")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(.white.opacity(hoveringCapture ? 1.0 : 0.75))
                        .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.08), value: state.capturedImage == nil)
            .frame(width: captureButtonSize, height: captureButtonSize)
            .modifier(GlassSphereModifier())
            .scaleEffect(capturePressed ? 0.88 : (hoveringCapture ? 1.08 : 1.0))
            .brightness(hoveringCapture ? 0.12 : 0)
            .animation(.spring(response: 0.22, dampingFraction: 0.65), value: hoveringCapture)
            .animation(.spring(response: 0.18, dampingFraction: 0.6), value: capturePressed)

            // External progress ring — sits just outside the button, does NOT scale.
            Circle()
                .trim(from: 0, to: pressProgress)
                .stroke(Color.white.opacity(0.95), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .frame(width: captureRingSize, height: captureRingSize)
                .opacity(state.capturedImage != nil ? 1 : 0)
                .allowsHitTesting(false)
        }
        .frame(width: captureRingSize, height: captureRingSize)
        .background(AlwaysActiveHoverDetector { hovering in
            hoveringCapture = hovering
            if hovering {
                hoverExitTask?.cancel()
                hoverExitTask = nil
            } else if !isHoveringInput {
                hoverExitTask?.cancel()
                hoverExitTask = Task {
                    try? await Task.sleep(nanoseconds: 200_000_000)
                    guard !Task.isCancelled, !isHoveringInput, !hoveringCapture else { return }
                    await MainActor.run {
                        if inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            && !inputFocused && state.capturedImage == nil && !state.isCapturing {
                            withAnimation(springAnim) { isInputExpanded = false }
                        }
                    }
                }
            }
        })
        .overlay(AppKitTapHandler(
            action: { captureScreen() },
            longPressAction: { state.capturedImage = nil },
            onPressChanged: { pressing in
                capturePressed = pressing
                ringDelayTask?.cancel()
                if pressing && state.capturedImage != nil {
                    // Wait 0.5s before the ring appears, so a normal short tap never
                    // shows it. After the delay, fill ring over 0.5s — total hold = 1.0s.
                    ringDelayTask = Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(500))
                        guard !Task.isCancelled else { return }
                        withAnimation(.linear(duration: 0.5)) { pressProgress = 1 }
                    }
                } else {
                    ringDelayTask = nil
                    withAnimation(.easeOut(duration: 0.12)) { pressProgress = 0 }
                }
            }
        ))
    }

    private var rightSphere: some View {
        Image(systemName: "clock.arrow.trianglehead.counterclockwise.rotate.90")
            .font(.system(size: 11, weight: .medium))
            .foregroundColor(.white.opacity(hoveringHistory ? 1.0 : 0.75))
            .frame(width: sphereSize, height: sphereSize)
            .modifier(GlassSphereModifier())
            .scaleEffect(hoveringHistory ? 1.14 : 1.0)
            .brightness(hoveringHistory ? 0.12 : 0)
            .animation(.spring(response: 0.25, dampingFraction: 0.68), value: hoveringHistory)
            .background(AlwaysActiveHoverDetector { hoveringHistory = $0 })
            .overlay(AppKitTapHandler { showingHistory = true })
    }

    private func sendMessage() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !state.isLoading, !state.isSearching, !isErasing else { return }

        // Snapshot and convert image on main thread — NSImage is not thread-safe
        let imageBase64 = state.capturedImage.flatMap { imageToBase64($0) }

        inputText = ""
        state.capturedImage = nil
        withAnimation(springAnim) { isInputExpanded = false }
        inputFocused = false
        let model = imageBase64 != nil ? OllamaAPI.visionModel : OllamaAPI.textModel
        streamingTask?.cancel()
        streamingTask = Task {
            guard !model.isEmpty else {
                await MainActor.run {
                    state.currentResponse = "No model configured. Open Settings (⌘,) to choose one."
                }
                return
            }

            var messages: [OllamaMessage]
            let displayText = text

            // Show typing dots in the compact view while we run the classifier.
            await MainActor.run { state.isLoading = true }

            let query = await decideSearchQuery(from: text)
            guard !Task.isCancelled else {
                await MainActor.run { state.isLoading = false }
                return
            }

            if let query = query {
                await MainActor.run { state.isSearching = true }
                let searchContext = await BraveSearchService.shared.search(query)
                await MainActor.run { state.isSearching = false }
                guard !Task.isCancelled else {
                    await MainActor.run { state.isLoading = false }
                    return
                }
                messages = await MainActor.run { state.prepareForSend(displayText) }
                if let lastIdx = messages.lastIndex(where: { $0.role == "user" }) {
                    let resultBlock = searchContext ?? "The web search returned no results for this query."
                    messages[lastIdx] = OllamaMessage(
                        role: "user",
                        content: displayText + "\n\n[Web search results for '\(query)':\n\(resultBlock)]",
                        images: imageBase64.map { [$0] }
                    )
                }
            } else {
                messages = await MainActor.run { state.prepareForSend(displayText) }
                if let imgData = imageBase64,
                   let lastIdx = messages.lastIndex(where: { $0.role == "user" }) {
                    messages[lastIdx] = OllamaMessage(
                        role: messages[lastIdx].role,
                        content: messages[lastIdx].content,
                        images: [imgData]
                    )
                }
            }

            guard !Task.isCancelled else { return }

            // If an image is being sent, show the processing-dots indicator until
            // the first token arrives (the vision model takes notably longer).
            if imageBase64 != nil {
                await MainActor.run { state.isProcessingImage = true }
            }

            do {
                for try await token in OllamaAPI.shared.chat(messages: messages, model: model) {
                    if Task.isCancelled { break }
                    await MainActor.run { state.appendToken(token) }
                }
            } catch {
                if !Task.isCancelled {
                    await MainActor.run {
                        state.isProcessingImage = false
                        state.appendToken("[Error: \(error.localizedDescription)]")
                    }
                }
            }
            if !Task.isCancelled {
                await MainActor.run {
                    state.isProcessingImage = false
                    state.finishResponse()
                }
            }
        }
    }

    // MARK: - Search decision (hybrid: explicit → keywords → LLM classifier)

    /// Layer 1: explicit user triggers like "search up X" or "look this up".
    private func extractExplicitSearchQuery(from text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let lower = trimmed.lowercased()

        let explicitTriggers = [
            "search the web for ", "search the web ", "search up ",
            "search for ", "look up "
        ]
        for trigger in explicitTriggers {
            if let range = lower.range(of: trigger) {
                let query = String(trimmed[range.upperBound...]).trimmingCharacters(in: .whitespaces)
                if !query.isEmpty { return query }
            }
        }

        let contextual = [
            "search this up", "search that up", "search this", "search that",
            "look this up", "look that up"
        ]
        if contextual.contains(where: { lower.contains($0) }) {
            return state.chatHistory.last?.prompt
        }

        return nil
    }

    /// Layer 2: high-confidence keyword/pattern detection for obvious "current info" topics.
    /// Catches the bulk of cases instantly with no LLM round-trip.
    private func detectCurrentInfoQuery(from text: String) -> String? {
        let lower = text.lowercased()

        let currentKeywords = [
            // Weather
            "weather", "forecast", "raining", "snowing", "how hot", "how cold",
            "temperature outside", "humidity", "wind speed",
            // News / events
            "news", "headline", "headlines", "latest on", "latest from",
            "most recent", "newest", "breaking",
            // Time-sensitive markers
            "currently", "right now", "happening now", "happening today",
            "today's", "tonight", "this morning", "this afternoon", "this evening",
            "yesterday", "tomorrow",
            "this week", "this month", "this year",
            // Sports
            "score of", "score for", "who won", "who's winning", "game tonight",
            "match tonight", "playing tonight",
            // Markets / prices
            "stock price", "stock market", "share price", "exchange rate",
            "price of bitcoin", "crypto price", "current price",
            // Trends / releases
            "trending", "viral", "what's new with",
            "release date", "when does", "when is the next",
        ]

        if currentKeywords.contains(where: { lower.contains($0) }) {
            return text
        }

        // Years past plausible model knowledge cutoff → likely needs current info.
        if text.range(of: #"\b202[5-9]\b|\b20[3-9]\d\b"#, options: .regularExpression) != nil {
            return text
        }

        return nil
    }

    /// Layer 3: lightweight LLM classifier for ambiguous queries.
    /// Uses the fast text model with a tightly-scoped prompt.
    /// Returns the suggested search query, or nil if no search is needed / call fails.
    private func classifySearchNeed(from text: String) async -> String? {
        let today = Date().formatted(.dateTime.year().month().day())
        let prompt = """
        Decide if this question needs current real-time information from the web.

        Today is \(today).

        SEARCH when the question is about:
        - current events, today's news
        - current weather or forecast
        - sports scores, schedules
        - current prices (stocks, crypto, products)
        - recent releases or announcements
        - anything "now", "currently", "today"
        - things that change frequently

        NO SEARCH when about:
        - definitions, vocabulary
        - math, programming, algorithms
        - established history
        - science fundamentals
        - how-to instructions
        - creative writing
        - general conversation

        When uncertain, prefer SEARCH.

        Respond in EXACTLY one of these formats:
        SEARCH: <concise search query>
        NO

        Add no other text.

        Question: \(text)
        """

        let messages = [OllamaMessage(role: "user", content: prompt)]

        do {
            var response = ""
            for try await token in OllamaAPI.shared.chat(messages: messages, model: OllamaAPI.textModel) {
                response += token
                // Stop reading once we have a definitive first line
                if response.contains("\n") || response.count > 250 { break }
            }

            let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)

            // Look for "SEARCH ... :" — case-insensitive, tolerant of whitespace.
            if let searchRange = trimmed.range(of: "SEARCH", options: .caseInsensitive),
               let colonRange = trimmed.range(of: ":", range: searchRange.upperBound..<trimmed.endIndex) {
                let afterColon = trimmed[colonRange.upperBound...]
                let lineEnd = afterColon.firstIndex(of: "\n") ?? afterColon.endIndex
                let query = String(afterColon[..<lineEnd]).trimmingCharacters(in: .whitespaces)
                return query.isEmpty ? text : query
            }
            return nil
        } catch {
            return nil
        }
    }

    /// Combined decision: returns a search query if any layer decides to search.
    private func decideSearchQuery(from text: String) async -> String? {
        let hasKey = !AppSettings.shared.braveSearchAPIKey.trimmingCharacters(in: .whitespaces).isEmpty
        guard hasKey else { return nil }
        if let q = extractExplicitSearchQuery(from: text) { return q }
        if let q = detectCurrentInfoQuery(from: text) { return q }
        return await classifySearchNeed(from: text)
    }

    private func captureScreen() {
        state.isCapturing = true
        Task {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard let display = content.displays.first else {
                    await MainActor.run { state.isCapturing = false }
                    return
                }

                let panelNums: Set<CGWindowID> = await MainActor.run {
                    Set(NSApp.windows
                        .filter { $0.level.rawValue >= NSWindow.Level.screenSaver.rawValue }
                        .map { CGWindowID($0.windowNumber) })
                }
                let excluded = content.windows.filter { panelNums.contains($0.windowID) }

                let filter = SCContentFilter(display: display, excludingWindows: excluded)
                let config = SCStreamConfiguration()
                config.width = display.width
                config.height = display.height

                let cgImage = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                await MainActor.run {
                    state.isCapturing = false
                    state.capturedImage = NSImage(cgImage: cgImage, size: NSZeroSize)
                    flashScreen()
                }
            } catch {
                await MainActor.run { state.isCapturing = false }
            }
        }
    }

    @MainActor
    private func flashScreen() {
        guard let screen = NSScreen.main else { return }
        let w = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false   // ARC manages lifetime; without this, close() double-releases
        w.backgroundColor = .white
        w.alphaValue = 0
        w.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
        w.isOpaque = true
        w.ignoresMouseEvents = true
        w.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.04
            w.animator().alphaValue = 0.85
        }, completionHandler: {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.18
                w.animator().alphaValue = 0
            }, completionHandler: { w.close() })
        })
    }

    private func imageToBase64(_ image: NSImage, maxDimension: Int = 1280) -> String? {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let w = cgImage.width, h = cgImage.height
        let scale = min(Double(maxDimension) / Double(max(w, h)), 1.0)
        let newW = max(1, Int(Double(w) * scale))
        let newH = max(1, Int(Double(h) * scale))
        let ctx = CGContext(data: nil, width: newW, height: newH,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        ctx?.interpolationQuality = .high
        ctx?.draw(cgImage, in: CGRect(x: 0, y: 0, width: newW, height: newH))
        guard let resized = ctx?.makeImage() else { return nil }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, resized, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return (data as Data).base64EncodedString()
    }
}

// MARK: - Welcome View

struct WelcomeView: View {
    @StateObject private var weather = WeatherService()
    @ObservedObject private var settings = AppSettings.shared
    @State private var nameWidth: CGFloat = 0

    private var greeting: String {
        let name = settings.displayName.trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? "Hello." : "Hello, \(name)."
    }

    var body: some View {
        ZStack {
            VStack(alignment: .leading, spacing: 22) {
                Text(greeting)
                    .font(.system(size: 28, weight: .medium))
                    .foregroundColor(.white)
                    .background(
                        GeometryReader { geo in
                            Color.clear.onAppear { nameWidth = geo.size.width }
                        }
                    )

                if let w = weather.data {
                    TimelineView(.everyMinute) { ctx in
                        HStack(alignment: .top, spacing: 0) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("\(w.tempF)°F  ·  \(w.condition)")
                                Text("Feels \(w.feelsLikeF)°  ·  \(w.humidity)% humidity")
                                    .opacity(0.6)
                            }
                            Spacer(minLength: 8)
                            VStack(alignment: .trailing, spacing: 3) {
                                Text(ctx.date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()))
                                Text(ctx.date.formatted(.dateTime.hour().minute()))
                                    .opacity(0.6)
                            }
                        }
                        .frame(width: nameWidth > 0 ? nameWidth : nil)
                    }
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.5))
                    .transition(.opacity)
                }
            }
            .animation(.easeIn(duration: 0.5), value: weather.data != nil)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Image Processing Dots
// Three pulsing dots shown ONLY while the vision model is processing an image.
// Vanishes the moment the first response token arrives.

struct ImageProcessingDots: View {
    @State private var animating = false

    private let dotSize: CGFloat = 20
    private let spacing: CGFloat = 18
    private let bounceHeight: CGFloat = 22
    private let bounceDuration: Double = 0.42
    private let stagger: Double = 0.14

    var body: some View {
        HStack(spacing: spacing) {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .fill(Color.white)
                    .frame(width: dotSize, height: dotSize)
                    .offset(y: animating ? -bounceHeight : 0)
                    .animation(
                        Animation.easeInOut(duration: bounceDuration)
                            .repeatForever()
                            .delay(Double(i) * stagger),
                        value: animating
                    )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { animating = true }
    }
}

// MARK: - Assistant Row

struct AssistantRow: View {
    let content: String

    var body: some View {
        Markdown(content.isEmpty ? "\u{200B}" : content)
            .markdownTheme(.localNotch)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4)
            .padding(.top, 2)
    }
}

// MARK: - History View

struct HistoryView: View {
    let history: [ChatTurn]
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("History")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white)
                Spacer()
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.white.opacity(0.65))
                    .frame(width: 26, height: 26)
                    .modifier(GlassSphereModifier())
                    .overlay(AppKitTapHandler { onClose() })
            }
            .padding(.horizontal, 14)
            .padding(.top, 14)
            .padding(.bottom, 8)

            if history.isEmpty {
                Spacer()
                Text("No previous chats yet")
                    .font(.system(size: 13))
                    .foregroundColor(.white.opacity(0.35))
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(history.reversed()) { turn in
                            HistoryTurnView(turn: turn)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 12)
                }
                .scrollIndicators(.hidden)
                .mask {
                    VStack(spacing: 0) {
                        Rectangle()
                        LinearGradient(colors: [.black, .black.opacity(0.05)], startPoint: .top, endPoint: .bottom)
                            .frame(height: 18)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct HistoryTurnView: View {
    let turn: ChatTurn
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(turn.prompt)
                .lineLimit(1)
                .truncationMode(.tail)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.white.opacity(0.7))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Capsule().fill(Color.white.opacity(0.1)))
                .frame(maxWidth: .infinity, alignment: .trailing)

            Text(turn.response)
                .lineLimit(expanded ? nil : 3)
                .font(.system(size: 13))
                .foregroundColor(.white.opacity(0.85))
                .frame(maxWidth: .infinity, alignment: .leading)
                .onTapGesture {
                    withAnimation(.easeInOut(duration: 0.2)) { expanded.toggle() }
                }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.05)))
    }
}

// MARK: - Dark Markdown Theme

extension Theme {
    static var localNotch: Theme {
        Theme()
            .text { ForegroundColor(.white); FontSize(15) }
            .strong { FontWeight(.bold) }
            .emphasis { FontStyle(.italic) }
            .strikethrough { StrikethroughStyle(Text.LineStyle(pattern: .solid)) }
            .code {
                FontFamilyVariant(.monospaced)
                FontSize(.em(0.88))
                BackgroundColor(.white.opacity(0.12))
                ForegroundColor(.white)
            }
            .link { ForegroundColor(Color(red: 0.4, green: 0.7, blue: 1.0)) }
            .heading1 { config in
                config.label
                    .markdownTextStyle { FontWeight(.bold); FontSize(.em(1.3)); ForegroundColor(.white) }
                    .markdownMargin(top: 16, bottom: 8)
            }
            .heading2 { config in
                config.label
                    .markdownTextStyle { FontWeight(.semibold); FontSize(.em(1.15)); ForegroundColor(.white) }
                    .markdownMargin(top: 12, bottom: 6)
            }
            .heading3 { config in
                config.label
                    .markdownTextStyle { FontWeight(.semibold); FontSize(.em(1.05)); ForegroundColor(.white) }
                    .markdownMargin(top: 10, bottom: 4)
            }
            .paragraph { config in
                config.label
                    .fixedSize(horizontal: false, vertical: true)
                    .relativeLineSpacing(.em(0.32))
                    .markdownMargin(top: 0, bottom: 14)
            }
            .codeBlock { config in
                ScrollView(.horizontal) {
                    config.label
                        .relativeLineSpacing(.em(0.2))
                        .markdownTextStyle {
                            FontFamilyVariant(.monospaced); FontSize(.em(0.85)); ForegroundColor(.white)
                        }
                        .padding(10)
                }
                .background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(0.07)))
                .markdownMargin(top: 4, bottom: 8)
            }
            .blockquote { config in
                HStack(spacing: 0) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.white.opacity(0.35))
                        .relativeFrame(width: .em(0.2))
                    config.label
                        .markdownTextStyle { ForegroundColor(.white.opacity(0.65)) }
                        .relativePadding(.horizontal, length: .em(0.75))
                }
                .fixedSize(horizontal: false, vertical: true)
                .markdownMargin(top: 4, bottom: 8)
            }
            .table { config in
                config.label
                    .fixedSize(horizontal: false, vertical: true)
                    .markdownTableBorderStyle(.init(color: .white.opacity(0.2)))
                    .markdownTableBackgroundStyle(.alternatingRows(Color.white.opacity(0.06), Color.clear))
                    .markdownMargin(top: 4, bottom: 8)
            }
            .tableCell { config in
                config.label
                    .markdownTextStyle {
                        if config.row == 0 { FontWeight(.semibold) }
                        ForegroundColor(.white); BackgroundColor(nil)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, 5)
                    .padding(.horizontal, 10)
                    .relativeLineSpacing(.em(0.2))
            }
            .thematicBreak {
                Divider()
                    .overlay(Color.white.opacity(0.2))
                    .markdownMargin(top: 10, bottom: 10)
            }
    }
}

// MARK: - AppKit Tap Handler

private struct AppKitTapHandler: NSViewRepresentable {
    let action: () -> Void
    var longPressAction: (() -> Void)? = nil
    var onPressChanged: ((Bool) -> Void)? = nil

    func makeNSView(context: Context) -> TapView {
        TapView(action: action, longPressAction: longPressAction, onPressChanged: onPressChanged)
    }
    func updateNSView(_ view: TapView, context: Context) {
        view.action = action
        view.longPressAction = longPressAction
        view.onPressChanged = onPressChanged
    }

    class TapView: NSView {
        var action: () -> Void
        var longPressAction: (() -> Void)?
        var onPressChanged: ((Bool) -> Void)?
        private var pressTimer: Timer?
        private var didFireLong = false

        init(action: @escaping () -> Void, longPressAction: (() -> Void)?, onPressChanged: ((Bool) -> Void)?) {
            self.action = action
            self.longPressAction = longPressAction
            self.onPressChanged = onPressChanged
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { fatalError() }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override var needsPanelToBecomeKey: Bool { false }

        override func mouseDown(with event: NSEvent) {
            onPressChanged?(true)
            if longPressAction == nil {
                action()
            } else {
                didFireLong = false
                pressTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: false) { [weak self] _ in
                    guard let self else { return }
                    self.didFireLong = true
                    self.pressTimer = nil
                    // Spring the button back to idle FIRST, then run the action,
                    // so the visual snap-back coincides with the image fading out.
                    self.onPressChanged?(false)
                    self.longPressAction?()
                }
            }
        }

        override func mouseUp(with event: NSEvent) {
            guard longPressAction != nil else { return }
            pressTimer?.invalidate()
            pressTimer = nil
            // If the long-press already fired, it already called onPressChanged(false).
            // Only call it here for a normal short tap.
            if !didFireLong {
                onPressChanged?(false)
                action()
            }
        }
    }
}

// MARK: - Always-Active Hover Detector

private struct AlwaysActiveHoverDetector: NSViewRepresentable {
    let onHover: (Bool) -> Void

    func makeNSView(context: Context) -> HoverView { HoverView(onHover: onHover) }
    func updateNSView(_ view: HoverView, context: Context) { view.onHover = onHover }

    class HoverView: NSView {
        var onHover: (Bool) -> Void
        init(onHover: @escaping (Bool) -> Void) { self.onHover = onHover; super.init(frame: .zero) }
        required init?(coder: NSCoder) { fatalError() }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            for area in trackingAreas { removeTrackingArea(area) }
            addTrackingArea(NSTrackingArea(
                rect: bounds,
                options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                owner: self, userInfo: nil
            ))
        }
        override func mouseEntered(with event: NSEvent) { DispatchQueue.main.async { self.onHover(true) } }
        override func mouseExited(with event: NSEvent)  { DispatchQueue.main.async { self.onHover(false) } }
    }
}

// MARK: - Glass Modifiers

private struct GlassPillModifier: ViewModifier {
    @ViewBuilder func body(content: Content) -> some View {
        if #available(macOS 26, *) { content.glassEffect(.regular, in: .capsule) }
        else {
            content
                .background(Capsule().fill(Color.white.opacity(0.1)))
                .overlay(Capsule().stroke(Color.white.opacity(0.15), lineWidth: 0.5))
        }
    }
}

private struct GlassSphereModifier: ViewModifier {
    @ViewBuilder func body(content: Content) -> some View {
        if #available(macOS 26, *) { content.glassEffect(.regular, in: .circle) }
        else {
            content
                .background(Circle().fill(Color.white.opacity(0.1)))
                .overlay(Circle().stroke(Color.white.opacity(0.15), lineWidth: 0.5))
        }
    }
}

private struct GlassCircleModifier: ViewModifier {
    @ViewBuilder func body(content: Content) -> some View {
        if #available(macOS 26, *) { content.glassEffect(.regular, in: .circle) }
        else { content }
    }
}
