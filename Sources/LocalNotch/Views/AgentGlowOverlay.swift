import AppKit
import SwiftUI

// MARK: - Agent Glow Window

final class AgentGlowWindow: NSWindow {
    private var hostingView: NSHostingView<AgentGlowView>?

    init() {
        super.init(
            contentRect: NSScreen.main?.frame ?? .zero,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        level = .screenSaver
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        ignoresMouseEvents = true
        collectionBehavior = [.canJoinAllSpaces, .stationary]
        isReleasedWhenClosed = false
    }

    func show(variant: AgentGlowView.Variant) {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }

        let frame = NSScreen.main?.frame ?? .zero
        setFrame(frame, display: false)
        contentView = NSHostingView(rootView: AgentGlowView(variant: variant))

        alphaValue = 0
        orderFront(nil)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.35
            animator().alphaValue = 1.0
        } completionHandler: {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.45
                    self.animator().alphaValue = 0
                } completionHandler: {
                    self.orderOut(nil)
                }
            }
        }
    }
}

// MARK: - Agent Glow View

struct AgentGlowView: View {
    enum Variant { case start, finish, abort }

    let variant: Variant

    private var colors: [Color] {
        switch variant {
        case .start, .finish:
            return [
                Color(red: 1.00, green: 0.70, blue: 0.85).opacity(0.85),
                Color(red: 0.76, green: 0.61, blue: 1.00).opacity(0.85),
                Color(red: 0.56, green: 0.72, blue: 1.00).opacity(0.85),
                Color(red: 0.62, green: 0.91, blue: 1.00).opacity(0.85),
            ]
        case .abort:
            return [
                Color(red: 1.0, green: 0.35, blue: 0.3).opacity(0.85),
                Color(red: 1.0, green: 0.55, blue: 0.2).opacity(0.85),
                Color(red: 1.0, green: 0.35, blue: 0.3).opacity(0.85),
                Color(red: 1.0, green: 0.55, blue: 0.2).opacity(0.85),
            ]
        }
    }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let thickness: CGFloat = 18

            ZStack {
                // Top edge
                glowEdge(colors: colors)
                    .frame(width: w, height: thickness)
                    .blur(radius: 10)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

                // Bottom edge
                glowEdge(colors: colors.reversed())
                    .frame(width: w, height: thickness)
                    .blur(radius: 10)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)

                // Left edge
                glowEdge(colors: colors)
                    .rotationEffect(.degrees(90))
                    .frame(width: h, height: thickness)
                    .blur(radius: 10)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)

                // Right edge
                glowEdge(colors: colors.reversed())
                    .rotationEffect(.degrees(90))
                    .frame(width: h, height: thickness)
                    .blur(radius: 10)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
            }
            .allowsHitTesting(false)
        }
        .ignoresSafeArea()
    }

    private func glowEdge(colors: [Color]) -> some View {
        Rectangle()
            .fill(
                LinearGradient(colors: colors, startPoint: .leading, endPoint: .trailing)
            )
    }
}
