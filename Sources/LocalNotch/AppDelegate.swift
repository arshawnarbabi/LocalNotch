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
    private var isCurrentlyExpanded = false
    private var statusItem: NSStatusItem?
    private var settingsWindow: NSWindow?
    private var updateMenuItem: NSMenuItem?
    private var agentGlowWindow: AgentGlowWindow?
    private var agentStateCancellable: AnyCancellable?
    private var previousAgentState: AgentState = .idle

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

    private func setupAgentObserver() {
        agentGlowWindow = AgentGlowWindow()
        agentStateCancellable = AgentRunner.shared.$state
            .receive(on: RunLoop.main)
            .sink { [weak self] newState in
                guard let self else { return }
                defer { self.previousAgentState = newState }
                // B → C: task start glow
                if self.previousAgentState == .idle && newState == .running {
                    self.agentGlowWindow?.show(variant: .start)
                }
                // C → E: task finish glow
                if self.previousAgentState == .running && newState == .finished {
                    self.agentGlowWindow?.show(variant: .finish)
                }
                // Update menu bar icon based on agent state
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

        // Debounced hover driver: expand immediately, collapse with 200ms grace period.
        // Without the debounce, the layout recalculation during expand can briefly fire
        // isHovering=false, causing expand() and compact() to race — leaving the notch stuck.
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
                } else {
                    self.collapseTask?.cancel()
                    self.collapseTask = Task {
                        try? await Task.sleep(for: .milliseconds(200))
                        guard !Task.isCancelled, !notch.isHovering else { return }
                        self.isCurrentlyExpanded = false
                        await notch.compact()
                    }
                }
            }
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
            case .idle, .finished, .forceStopped:
                // Static mini-orb — in agent mode but no active work
                PearlescentOrb(size: 10, animated: false)
                    .frame(width: 16, height: 16)
                    .transition(.opacity)
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
