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

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        setupMainMenu()
        setupNotch()
        setupStatusItem()
        if !AppSettings.shared.onboardingComplete {
            Task {
                try? await Task.sleep(for: .milliseconds(600))
                isCurrentlyExpanded = true
                await notch?.expand()
            }
        }
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
        menu.addItem(NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ","))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit LocalNotch", action: #selector(quitApp), keyEquivalent: "q"))
        statusItem?.menu = menu
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

// Cycles a dot from small to large while the model is responding.
// Uses Circle() in a fixed frame so vertical position never shifts.
struct ReactiveTypingDots: View {
    @ObservedObject var state: ChatState
    private let sizes: [CGFloat] = [3, 5, 8, 5]
    private let interval = 0.15

    var body: some View {
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
}
