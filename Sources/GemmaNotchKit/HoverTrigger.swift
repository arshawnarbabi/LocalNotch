import AppKit

// Invisible NSPanel sitting at the notch. Its NSTrackingArea fires enter/exit without
// requiring Input Monitoring permission. On exit we poll mouse position so the collapse
// fires even if the cursor leaves faster than AppKit delivers the event.
@MainActor
class HoverTrigger: NSObject {
    private var triggerPanel: NSPanel?
    private var collapseTimer: Timer?
    private var outsideCount = 0
    private var isExpanded = false

    private let onEnter: () -> Void
    private let onExit: () -> Void

    init(onEnter: @escaping () -> Void, onExit: @escaping () -> Void) {
        self.onEnter = onEnter
        self.onExit = onExit
        super.init()
        setup()
    }

    private func setup() {
        guard let screen = NSScreen.screens.first else { return }
        let notchRect = notchFrame(screen: screen)

        let panel = NSPanel(
            contentRect: notchRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 8)
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        panel.ignoresMouseEvents = false

        let view = TriggerView(frame: NSRect(origin: .zero, size: notchRect.size))
        view.onEntered = { [weak self] in self?.handleEnter() }
        view.onExited = { [weak self] in self?.startCollapsePolling() }
        panel.contentView = view
        panel.orderFrontRegardless()
        triggerPanel = panel
    }

    private func handleEnter() {
        collapseTimer?.invalidate()
        collapseTimer = nil
        outsideCount = 0
        guard !isExpanded else { return }
        isExpanded = true
        onEnter()
    }

    private func startCollapsePolling() {
        guard isExpanded else { return }
        outsideCount = 0
        collapseTimer?.invalidate()
        collapseTimer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.pollCollapse()
            }
        }
    }

    private func pollCollapse() {
        guard isExpanded, let screen = NSScreen.screens.first else { return }
        let mouse = NSEvent.mouseLocation
        // Keep zone: full width of notch area + the expanded panel below it
        let notchRect = notchFrame(screen: screen)
        let keepZone = NSRect(
            x: screen.frame.midX - 200,
            y: notchRect.minY - 300,
            width: 400,
            height: notchRect.height + 300 + 20
        )
        if keepZone.contains(mouse) {
            outsideCount = 0
        } else {
            outsideCount += 1
            if outsideCount >= 3 {
                collapseTimer?.invalidate()
                collapseTimer = nil
                isExpanded = false
                onExit()
            }
        }
    }

    private func notchFrame(screen: NSScreen) -> NSRect {
        // Try real notch geometry first
        if screen.safeAreaInsets.top > 0,
           let aux = screen.auxiliaryTopLeftArea ?? screen.auxiliaryTopRightArea {
            let notchW = screen.frame.width - aux.width * 2
            let notchH = screen.safeAreaInsets.top
            return NSRect(
                x: screen.frame.midX - notchW / 2,
                y: screen.frame.maxY - notchH,
                width: notchW,
                height: notchH
            )
        }
        // Fallback: treat menubar as trigger zone
        let menuH = screen.frame.height - screen.visibleFrame.maxY
        return NSRect(
            x: screen.frame.midX - 80,
            y: screen.frame.maxY - menuH,
            width: 160,
            height: menuH
        )
    }
}

private class TriggerView: NSView {
    var onEntered: (() -> Void)?
    var onExited: (() -> Void)?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        ))
    }

    override func mouseEntered(with event: NSEvent) { onEntered?() }
    override func mouseExited(with event: NSEvent) { onExited?() }
}
