import AppKit
import SwiftUI
import Combine
import DynamicNotchKit

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    private var chatState = ChatState()
    private var notch: DynamicNotch<AnyView, AnyView, AnyView>?
    private var hoverCancellable: AnyCancellable?
    private var collapseTask: Task<Void, Never>?
    private var mouseMoveMonitor: Any?   // global mouse monitor — real-position collapse fallback
    private var isCurrentlyExpanded = false
    private var statusItem: NSStatusItem?
    private var settingsWindow: NSWindow?
    private var updateMenuItem: NSMenuItem?
    private var agentGlowWindow: AgentGlowWindow?
    private var panelGlowWindow: PanelGlowWindow?
    private var rippleWindow: ScreenRippleWindow?
    private var agentStateCancellable: AnyCancellable?
    private var previousAgentState: AgentState = .welcome   // matches AgentRunner's initial state
    private var glowHideTask: Task<Void, Never>?
    private var agentModeActive = false   // true while the agent mode panel is open
    private var agentGlowShown = false    // whether the persistent agent edge-glow is currently up
    private var agentModeEnteredAt: Date? = nil  // used for 600ms entry grace period
    private var agentLifecycleTask: Task<Void, Never>? = nil  // debounced model preload/unload

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        setupMainMenu()
        setupNotch()
        setupStatusItem()
        setupAgentObserver()
        if !AppSettings.shared.onboardingComplete {
            Task {
                try? await Task.sleep(for: .milliseconds(600))
                isCurrentlyExpanded = true
                await notch?.expand()
            }
        }

    }

    // autoHide=false keeps the glow alive until the notch collapses (used for .enter variant).
    // Never auto-hides while agent mode is active — the enter glow owns lifetime then.
    // Debounced model lifecycle for agent mode: preload on enter, unload on exit, with a ~450ms
    // buffer so rapid enter/exit toggling settles to the FINAL state (no load/unload churn, no
    // spamming Ollama). warmUp/unload are idempotent, and Ollama keeps a single resident model
    // (it never spawns multiple), so even if a stray call slips through nothing breaks.
    private func setAgentModeActive(_ active: Bool) {
        agentLifecycleTask?.cancel()
        let model = AppSettings.shared.agentModel
        guard !model.isEmpty else { return }
        agentLifecycleTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled else { return }
            print("[Agent] model lifecycle: \(active ? "preload" : "unload") \(model)")
            if active { OllamaAPI.shared.warmUp(model: model) }
            else      { OllamaAPI.shared.unload(model: model) }
        }
    }

    private func showGlow(variant: AgentGlowVariant, autoHide: Bool = true) {
        // Edge glow ONLY while the panel is open — never flash it for a task whose panel is
        // closed (e.g. the finish glow after the user collapsed the notch).
        guard isCurrentlyExpanded else {
            print("[Glow] skipped variant=\(variant) — panel closed")
            return
        }
        print("[Glow] showGlow variant=\(variant) autoHide=\(autoHide) agentModeActive=\(agentModeActive) windowExists=\(agentGlowWindow != nil)")
        glowHideTask?.cancel()
        agentGlowWindow?.show(variant: variant)
        agentGlowShown = true
        guard autoHide && !agentModeActive else { return }
        glowHideTask = Task {
            try? await Task.sleep(nanoseconds: 2_200_000_000)   // 2.2s hold at peak
            guard !Task.isCancelled else { return }
            agentGlowWindow?.cancelAndHide(duration: 0.15)
            self.agentGlowShown = false
        }
    }

    /// Level-triggered authority for the persistent agent edge-glow: it must be visible EXACTLY when
    /// we're in agent mode AND the panel is open — nothing else. Call this after ANY change to
    /// `agentModeActive` or `isCurrentlyExpanded` (enter, exit, expand, collapse, re-expand recovery).
    ///
    /// Why this exists: the glow used to be driven by scattered edge-triggers (show on enter/run, hide
    /// on collapse). Every collapse hid it, but the several re-expand paths didn't all re-show it, so
    /// after one collapse+re-expand the glow stayed off for the rest of the session while the task kept
    /// running — the recurring "pulse is there but the edge glow is gone" bug. Level-triggering removes
    /// that whole class of failure: a path that forgets to call this is self-corrected by the next call,
    /// and there is exactly one place that decides visibility. Do NOT add bespoke show/hide calls for
    /// the agent glow elsewhere — change the state and call syncAgentGlow().
    private func syncAgentGlow() {
        let shouldShow = agentModeActive && isCurrentlyExpanded
        if shouldShow {
            guard !agentGlowShown else { return }
            showGlow(variant: .enter, autoHide: false)   // sets agentGlowShown = true
        } else {
            guard agentGlowShown else { return }
            agentGlowShown = false
            glowHideTask?.cancel(); glowHideTask = nil
            agentGlowWindow?.cancelAndHide(duration: 0.3)
        }
    }

    private func setupAgentObserver() {
        agentGlowWindow = AgentGlowWindow()
        panelGlowWindow = PanelGlowWindow()
        rippleWindow = ScreenRippleWindow()

        // Prewarm glow windows after the app has settled (2 s) and only when the
        // panel is compact. The AgentGlowWindow sits at .screenSaver+1 (above
        // DynamicNotchKit), so we must never prewarm it while the panel is open or
        // hover-tracking could glitch. PanelGlowWindow (.screenSaver-1) is safe to
        // prewarm independently; we stagger them to avoid simultaneous z-order changes.
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(2000))
            guard !self.isCurrentlyExpanded else { return }
            self.panelGlowWindow?.prewarm()
            try? await Task.sleep(for: .milliseconds(150))
            guard !self.isCurrentlyExpanded else { return }
            self.agentGlowWindow?.prewarm()
        }

        NotificationCenter.default.addObserver(forName: .agentModeEntered, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.agentModeActive = true
                self.setAgentModeActive(true)   // debounced preload — model loads as soon as agent mode is selected
                self.agentModeEnteredAt = Date()
                self.collapseTask?.cancel()
                self.collapseTask = nil
                if !self.isCurrentlyExpanded {
                    self.isCurrentlyExpanded = true
                    await self.notch?.expand()
                }
            }
            Task { @MainActor in self.rippleWindow?.play() }
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(380))
                print("[Glow] agentModeEntered → firing enter glow")
                self.panelGlowWindow?.show(variant: .enter)
                try? await Task.sleep(for: .milliseconds(120))
                self.syncAgentGlow()   // shows iff agent-mode + panel open (it is, after the ripple)
            }
        }

        // X button exit — clear agent mode lock, hide the persistent enter glow
        NotificationCenter.default.addObserver(forName: .agentModeExited, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.agentModeActive = false
                self.setAgentModeActive(false)   // debounced unload — model stops when leaving agent mode
                self.syncAgentGlow()             // agent mode off → hides the persistent agent glow
                self.panelGlowWindow?.cancelAndHide(duration: 0.4)
            }
        }

        agentStateCancellable = AgentRunner.shared.$state
            .receive(on: RunLoop.main)
            .sink { [weak self] newState in
                guard let self else { return }
                defer { self.previousAgentState = newState }
                print("[Glow] state transition \(self.previousAgentState) -> \(newState)")
                // Fire the start glow on any entry into .running from a non-active prior state
                // (.welcome / .idle / .finished / .forceStopped). The runner boots and resets in
                // .welcome (never .idle before a task), so the old `== .idle` gate never matched
                // and the per-task start glow silently stopped firing. !isActive also correctly
                // EXCLUDES resume from .paused/.clarifying/.approving, so a mid-task resume
                // doesn't re-flash the start glow.
                if !self.previousAgentState.isActive && newState == .running {
                    self.showGlow(variant: .start)
                }
                if self.previousAgentState == .running && newState == .finished {
                    self.showGlow(variant: .finish)
                }
                self.updateMenuBarIcon(state: newState)
            }
    }

    private func updateMenuBarIcon(state: AgentState) {
        guard let button = statusItem?.button else { return }
        switch state {
        case .running:
            button.image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: "LocalNotch — Agent Running")
        case .clarifying, .approving:
            button.image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: "LocalNotch — Agent Waiting")
        case .idle, .finished, .forceStopped, .welcome:
            button.image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: "LocalNotch")
        default:
            button.image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: "LocalNotch")
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let agentState = AgentRunner.shared.state
        guard agentState.isActive else { return .terminateNow }

        let alert = NSAlert()
        alert.messageText = "Agent is running."
        alert.informativeText = "Quitting now will stop the current task. Any file operations that have already completed will not be undone. Files moved to Trash will remain in Trash."
        alert.addButton(withTitle: "Quit Anyway")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            AgentRunner.shared.forceStop()
            return .terminateNow
        }
        return .terminateCancel
    }

    private func setupNotch() {
        let state = chatState
        let notch = DynamicNotch(
            hoverBehavior: [.keepVisible, .increaseShadow],
            style: .notch(topCornerRadius: 15, bottomCornerRadius: 38)
        ) {
            AnyView(NotchContentView(state: state))
        } compactLeading: {
            AnyView(EmptyView())
        } compactTrailing: {
            AnyView(ReactiveTypingDots(state: state))
        }

        notch.transitionConfiguration = DynamicNotchTransitionConfiguration(
            openingAnimation: .bouncy(duration: 0.3),
            closingAnimation: .smooth(duration: 0.22),
            conversionAnimation: .snappy(duration: 0.25),
            skipIntermediateHides: true
        )

        self.notch = notch
        Task { await notch.compact() }

        // Debounced hover driver: expand immediately, collapse after 350ms.
        //
        // 350ms (up from 200ms) absorbs brief isHovering=false flickers that DynamicNotchKit
        // emits during its own layout/animation passes, preventing false auto-collapses.
        //
        // Race condition fix: isCurrentlyExpanded is only set to false RIGHT BEFORE compact()
        // and the task checks isHovering one final time. After compact() returns, if hover
        // came back during the animation, we immediately re-expand so the panel is never stuck.
        hoverCancellable = notch.$isHovering
            .receive(on: RunLoop.main)
            .removeDuplicates()
            .sink { [weak self, weak notch] hovering in
                guard let self, let notch else { return }

                if hovering {
                    self.collapseTask?.cancel()
                    self.collapseTask = nil
                    guard !self.isCurrentlyExpanded else { return }
                    self.isCurrentlyExpanded = true
                    Task { await notch.expand() }
                    self.syncAgentGlow()   // re-expanded → restore the agent glow if in agent mode
                    // Re-show the panel glow too if re-expanding while agent mode is still active
                    if self.agentModeActive {
                        Task { @MainActor in
                            try? await Task.sleep(for: .milliseconds(200))
                            guard notch.isHovering else { return }
                            self.panelGlowWindow?.show(variant: .enter)
                        }
                    }
                } else {
                    self.collapseTask?.cancel()
                    self.collapseTask = Task {
                        try? await Task.sleep(for: .milliseconds(350))
                        guard !Task.isCancelled, !self.mouseIsOverPanel() else { return }

                        // Agent-entry grace period: sleep out the remainder so the panel
                        // never closes immediately after entering agent mode.
                        if let enteredAt = self.agentModeEnteredAt {
                            let elapsed = Date().timeIntervalSince(enteredAt)
                            if elapsed < 0.6 {
                                let remaining = 0.6 - elapsed
                                try? await Task.sleep(for: .seconds(remaining))
                                guard !Task.isCancelled, !self.mouseIsOverPanel() else { return }
                            }
                        }

                        // Final hover check right before committing — catches any
                        // hover events that arrived while we were sleeping.
                        guard !Task.isCancelled, !self.mouseIsOverPanel() else { return }

                        self.isCurrentlyExpanded = false
                        self.syncAgentGlow()   // panel closed → hides the agent glow
                        self.panelGlowWindow?.collapseToNotch(duration: 0.25)
                        await notch.compact()

                        // Recovery: if hover returned during the compact animation (a race
                        // where compact() and expand() run concurrently and compact wins),
                        // re-expand so the panel is never stuck in compact with isCurrentlyExpanded=true.
                        guard !Task.isCancelled else { return }
                        if self.mouseIsOverPanel() && !self.isCurrentlyExpanded {
                            self.isCurrentlyExpanded = true
                            Task { @MainActor in await notch.expand() }
                            self.syncAgentGlow()   // re-expanded → restore the agent glow
                        }
                    }
                }
            }

        // Real-mouse-position collapse fallback. DynamicNotchKit's isHovering can get stuck `true`
        // (worse with the overlay glow windows / fast in-out movement), so hovering=false sometimes
        // never fires and the panel stays open. This global monitor watches the actual pointer and
        // collapses when it has genuinely left the panel region — independent of isHovering.
        mouseMoveMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved]) { [weak self, weak notch] _ in
            Task { @MainActor in
                guard let self, let notch, self.isCurrentlyExpanded else { return }
                if self.mouseIsOverPanel() {
                    self.collapseTask?.cancel(); self.collapseTask = nil
                } else if self.collapseTask == nil {
                    self.collapseTask = Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(350))
                        guard !Task.isCancelled, !self.mouseIsOverPanel() else { return }
                        self.isCurrentlyExpanded = false
                        self.syncAgentGlow()   // panel closed → hides the agent glow
                        self.panelGlowWindow?.collapseToNotch(duration: 0.25)
                        await notch.compact()
                    }
                }
            }
        }
    }

    // Real-mouse-position hover test — authoritative substitute for DynamicNotchKit's flaky
    // isHovering. True if the pointer is within the (generously-sized) notch panel region at the
    // top-center of the notched display.
    private func mouseIsOverPanel() -> Bool {
        let screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 })
            ?? NSScreen.main ?? NSScreen.screens.first
        guard let f = screen?.frame else { return true }
        let m = NSEvent.mouseLocation
        let panelH = 40 + AppSettings.shared.notchContentHeight + 15   // notch + content + DNK inset
        let margin: CGFloat = 60
        let halfW = PanelGlowWindow.panelVisualWidth / 2 + margin
        let overX = m.x >= f.midX - halfW && m.x <= f.midX + halfW
        let overY = m.y >= f.maxY - panelH - margin && m.y <= f.maxY + 4
        return overX && overY
    }

    private func setupMainMenu() {
        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(NSMenuItem(title: "Quit LocalNotch", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(NSMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "z"))
        editMenu.addItem(NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "Z"))
        editMenu.addItem(.separator())
        editMenu.addItem(NSMenuItem(title: "Cut",        action: #selector(NSText.cut(_:)),       keyEquivalent: "x"))
        editMenu.addItem(NSMenuItem(title: "Copy",       action: #selector(NSText.copy(_:)),      keyEquivalent: "c"))
        editMenu.addItem(NSMenuItem(title: "Paste",      action: #selector(NSText.paste(_:)),     keyEquivalent: "v"))
        editMenu.addItem(NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)

        NSApp.mainMenu = mainMenu
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem?.button {
            button.image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: "LocalNotch")
        }

        let menu = NSMenu()

        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
        let versionItem = NSMenuItem(title: "LocalNotch v\(version)", action: nil, keyEquivalent: "")
        versionItem.isEnabled = false
        menu.addItem(versionItem)

        menu.addItem(.separator())

        let updateItem = NSMenuItem(title: "Check for Updates…", action: #selector(checkForUpdates), keyEquivalent: "")
        updateMenuItem = updateItem
        menu.addItem(updateItem)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ","))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit LocalNotch", action: #selector(quitApp), keyEquivalent: "q"))
        statusItem?.menu = menu

        // Silent background check 5s after launch — updates the menu item label if a new version exists.
        Task {
            try? await Task.sleep(for: .seconds(5))
            await performUpdateCheck(userInitiated: false)
        }
    }

    @objc private func checkForUpdates() {
        updateMenuItem?.title = "Checking…"
        updateMenuItem?.isEnabled = false
        Task { await performUpdateCheck(userInitiated: true) }
    }

    private func performUpdateCheck(userInitiated: Bool) async {
        let currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
        // /releases?per_page=1 includes pre-releases; /releases/latest skips them
        guard let url = URL(string: "https://api.github.com/repos/s24b/LocalNotch/releases?per_page=1") else { return }

        var request = URLRequest(url: url)
        request.setValue("LocalNotch/\(currentVersion)", forHTTPHeaderField: "User-Agent")

        defer {
            updateMenuItem?.title = "Check for Updates…"
            updateMenuItem?.isEnabled = true
        }

        // Network failure
        guard let (data, _) = try? await URLSession.shared.data(for: request) else {
            if userInitiated {
                showUpdateAlert(title: "Unable to Check for Updates",
                                message: "Could not reach GitHub. Check your internet connection and try again.")
            }
            return
        }

        // Parse — must be an array of release objects
        guard let releases = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            if userInitiated {
                showUpdateAlert(title: "Unable to Check for Updates",
                                message: "Unexpected response from GitHub. Try again later.")
            }
            return
        }

        // No releases published yet — treat as up to date
        guard let latest = releases.first,
              let tagName = latest["tag_name"] as? String,
              let htmlURLString = latest["html_url"] as? String,
              let releaseURL = URL(string: htmlURLString) else {
            if userInitiated {
                showUpdateAlert(title: "You're Up to Date",
                                message: "LocalNotch v\(currentVersion) is the latest version.")
            }
            return
        }

        let latestVersion = tagName.hasPrefix("v") ? String(tagName.dropFirst()) : tagName

        if latestVersion == currentVersion {
            if userInitiated {
                showUpdateAlert(title: "You're Up to Date",
                                message: "LocalNotch v\(currentVersion) is the latest version.")
            }
        } else {
            updateMenuItem?.title = "Update Available — v\(latestVersion)"
            if userInitiated {
                NSApp.activate(ignoringOtherApps: true)
                let alert = NSAlert()
                alert.messageText = "Update Available"
                alert.informativeText = "LocalNotch v\(latestVersion) is available. You have v\(currentVersion)."
                alert.addButton(withTitle: "View on GitHub")
                alert.addButton(withTitle: "Later")
                if alert.runModal() == .alertFirstButtonReturn {
                    NSWorkspace.shared.open(releaseURL)
                }
            }
        }
    }

    private func showUpdateAlert(title: String, message: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    @objc private func openSettings() {
        if settingsWindow == nil {
            let controller = NSHostingController(rootView:
                SettingsView()
                    .frame(width: 360, height: 480)
                    .background(Color.black)
            )
            let window = NSWindow(contentViewController: controller)
            window.title = "LocalNotch — Settings"
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.backgroundColor = .black
            window.appearance = NSAppearance(named: .darkAqua)
            window.isReleasedWhenClosed = false
            window.setContentSize(NSSize(width: 360, height: 480))
            window.center()
            settingsWindow = window
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }
}

// Reactive wrapper so the panel height can animate when dropdowns open in onboarding.
private struct NotchContentView: View {
    let state: ChatState
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        ChatView(state: state)
            .frame(width: 420, height: settings.notchContentHeight)
            .background(Color.black)
    }
}

// Compact notch trailing indicator — shows chat loading dots OR agent state indicator.
struct ReactiveTypingDots: View {
    @ObservedObject var state: ChatState
    @ObservedObject private var agentRunner = AgentRunner.shared
    private let sizes: [CGFloat] = [3, 5, 8, 5]
    private let interval = 0.15

    var body: some View {
        ZStack {
            // Agent state takes priority over chat loading.
            switch agentRunner.state {
            case .running, .paused:
                // White pulsing dot — agent is working
                agentWorkingDot(color: .white)
            case .clarifying, .approving:
                // Yellow pulsing dot — agent needs user attention
                agentWorkingDot(color: Color(red: 1.0, green: 0.9, blue: 0.3))
            case .finished, .forceStopped:
                if agentRunner.showAgentCompletionCheck {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.green)
                        .frame(width: 16, height: 16)
                        .transition(.scale(scale: 0.5).combined(with: .opacity))
                }
            default:
                // Normal chat indicators
                chatIndicator
            }
        }
        .animation(.easeInOut(duration: 0.25), value: agentRunner.state)
    }

    @ViewBuilder
    private var chatIndicator: some View {
        if state.isLoading {
            TimelineView(.periodic(from: .now, by: interval)) { context in
                let idx = Int(context.date.timeIntervalSince1970 / interval) % sizes.count
                Circle()
                    .fill(Color.white)
                    .frame(width: sizes[idx], height: sizes[idx])
                    .frame(width: 16, height: 16)
            }
            .transition(.opacity)
        } else if state.showCompletionCheck {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.green)
                .frame(width: 16, height: 16)
                .transition(.scale(scale: 0.5).combined(with: .opacity))
        }
    }

    private func agentWorkingDot(color: Color) -> some View {
        TimelineView(.periodic(from: .now, by: interval)) { context in
            let idx = Int(context.date.timeIntervalSince1970 / interval) % sizes.count
            Circle()
                .fill(color)
                .frame(width: sizes[idx], height: sizes[idx])
                .frame(width: 16, height: 16)
        }
        .transition(.opacity)
    }
}
