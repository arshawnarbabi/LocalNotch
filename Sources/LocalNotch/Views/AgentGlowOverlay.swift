import AppKit
import SwiftUI

// MARK: - Notifications

extension Notification.Name {
    static let agentModeEntered = Notification.Name("com.localnotch.agentModeEntered")
    static let agentModeExited  = Notification.Name("com.localnotch.agentModeExited")
}

// MARK: - Glow Variant

enum AgentGlowVariant { case enter, start, finish, abort }

// MARK: - Observable model — update variant without recreating the view

final class GlowModel: ObservableObject {
    @Published var variant: AgentGlowVariant = .enter
}

// MARK: - Palettes

private let pearlescentPalette: [Color] = [
    Color(red: 0.62, green: 0.25, blue: 1.00),
    Color(red: 0.40, green: 0.55, blue: 1.00),
    Color(red: 0.30, green: 0.75, blue: 1.00),
    Color(red: 0.60, green: 0.40, blue: 1.00),
    Color(red: 1.00, green: 0.35, blue: 0.75),
    Color(red: 1.00, green: 0.45, blue: 0.35),
    Color(red: 1.00, green: 0.70, blue: 0.25),
    Color(red: 0.80, green: 0.35, blue: 1.00),
    Color(red: 0.50, green: 0.50, blue: 1.00),
    Color(red: 0.62, green: 0.25, blue: 1.00),
]
private let abortPalette: [Color] = [
    Color(red: 1.0, green: 0.35, blue: 0.25, opacity: 1.0),
    Color(red: 1.0, green: 0.55, blue: 0.18, opacity: 0.55),
    Color(red: 1.0, green: 0.30, blue: 0.30, opacity: 1.0),
    Color(red: 1.0, green: 0.60, blue: 0.20, opacity: 0.65),
    Color(red: 1.0, green: 0.40, blue: 0.25, opacity: 1.0),
    Color(red: 1.0, green: 0.50, blue: 0.18, opacity: 0.50),
]

private func glowPalette(for variant: AgentGlowVariant) -> [Color] {
    variant == .abort ? abortPalette : pearlescentPalette
}

// MARK: - Screen Edge Glow Window
//
// NSHostingView is created once (in setupContent / prewarm) and kept alive between
// show/hide cycles. Subsequent show() calls update GlowModel.variant and fade the
// window back in — no SwiftUI re-init, no Metal shader recompilation.

final class AgentGlowWindow: NSWindow {
    private let model   = GlowModel()
    private var isSetUp = false

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
        level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        ignoresMouseEvents = true
        collectionBehavior = [.canJoinAllSpaces, .stationary]
        isReleasedWhenClosed = false
    }

    // Called once at app startup while the panel is compact.
    // Shows the window for a single runloop pass (one frame) at alpha=0 — invisible
    // to the user but enough to submit the first Metal command buffer and compile
    // blur/gradient shaders asynchronously before first real use.
    // AppDelegate ensures this is never called while the panel is expanded, because
    // this window sits at .screenSaver+1 (above DynamicNotchKit) and a full-screen
    // alpha=0 window at that level can disrupt hover tracking if shown at the wrong time.
    func prewarm() {
        guard !isSetUp else { return }
        setupContent()
        orderFront(nil)
        DispatchQueue.main.async { [weak self] in   // one runloop pass, then out
            self?.orderOut(nil)
        }
    }

    func show(variant: AgentGlowVariant) {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            print("[Glow] suppressed — System Settings ▸ Accessibility ▸ Display ▸ Reduce Motion is ON")
            return
        }
        if !isSetUp { setupContent() }
        model.variant = variant
        let screen = NSScreen.main ?? NSScreen.screens[0]
        setFrame(screen.frame, display: false)
        alphaValue = 0
        orderFront(nil)
        print("[Glow] AgentGlowWindow.show variant=\(variant) screen.frame=\(screen.frame) level=\(level.rawValue) isVisible=\(isVisible) onActiveSpace=\(isOnActiveSpace)")
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.40
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            animator().alphaValue = 1.0
        }
    }

    func cancelAndHide(duration: TimeInterval = 0.15) {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = duration
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            animator().alphaValue = 0
        } completionHandler: { [weak self] in
            self?.orderOut(nil)
            // contentView stays alive — no re-init cost on next show()
        }
    }

    private func setupContent() {
        isSetUp = true
        let screen = NSScreen.main ?? NSScreen.screens[0]
        setFrame(screen.frame, display: false)
        contentView = NSHostingView(rootView: ScreenGlowView(model: model))
        alphaValue = 0
    }
}

// MARK: - Panel Glow Window
//
// Same prewarm strategy. PanelGlowView reads panelHeight from AppSettings directly
// so the view updates automatically when the user changes notchContentHeight in
// Settings — no parameters need to be passed on each show() call.

final class PanelGlowWindow: NSWindow {
    static let panelVisualWidth: CGFloat = 450
    static let dnkBottomInset:   CGFloat = 15
    static let padding:          CGFloat = 50

    private let model   = GlowModel()
    private var isSetUp = false

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
        level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue - 1)
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        ignoresMouseEvents = true
        collectionBehavior = [.canJoinAllSpaces, .stationary]
        isReleasedWhenClosed = false
    }

    func prewarm() {
        guard !isSetUp else { return }
        setupContent()
        orderFront(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.20) { [weak self] in
            self?.orderOut(nil)
        }
    }

    func show(variant: AgentGlowVariant) {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            print("[Glow] suppressed — System Settings ▸ Accessibility ▸ Display ▸ Reduce Motion is ON")
            return
        }
        if !isSetUp { setupContent() }
        model.variant = variant
        let screen = NSScreen.main ?? NSScreen.screens[0]
        setFrame(screen.frame, display: false)
        alphaValue = 0
        orderFront(nil)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            animator().alphaValue = 1.0
        }
    }

    func cancelAndHide(duration: TimeInterval = 0.15) {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = duration
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            animator().alphaValue = 0
        } completionHandler: { [weak self] in
            self?.orderOut(nil)
        }
    }

    func collapseToNotch(duration: TimeInterval = 0.25) {
        cancelAndHide(duration: duration)
    }

    private func setupContent() {
        isSetUp = true
        let screen = NSScreen.main ?? NSScreen.screens[0]
        setFrame(screen.frame, display: false)
        contentView = NSHostingView(rootView: PanelGlowView(model: model))
        alphaValue = 0
    }
}

// MARK: - Screen Perimeter Shape

private let capHide: CGFloat = 30

private struct ScreenPerimeter: Shape {
    let panelWidth: CGFloat
    let screenRadius: CGFloat
    let inset: CGFloat

    func path(in rect: CGRect) -> Path {
        let sw  = rect.width
        let sh  = rect.height
        let sr  = screenRadius
        let ins = inset
        let pl  = (sw - panelWidth) / 2
        let prx = (sw + panelWidth) / 2

        var p = Path()
        p.move(to: CGPoint(x: ins, y: sr + ins))
        p.addArc(center: CGPoint(x: sr + ins, y: sr + ins), radius: sr,
                 startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false)
        p.addLine(to: CGPoint(x: pl, y: -capHide))

        p.move(to: CGPoint(x: prx, y: -capHide))
        p.addLine(to: CGPoint(x: sw - sr - ins, y: ins))
        p.addArc(center: CGPoint(x: sw - sr - ins, y: sr + ins), radius: sr,
                 startAngle: .degrees(270), endAngle: .degrees(0), clockwise: false)
        p.addLine(to: CGPoint(x: sw - ins, y: sh - sr - ins))
        p.addArc(center: CGPoint(x: sw - sr - ins, y: sh - sr - ins), radius: sr,
                 startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false)
        p.addLine(to: CGPoint(x: sr + ins, y: sh - ins))
        p.addArc(center: CGPoint(x: sr + ins, y: sh - sr - ins), radius: sr,
                 startAngle: .degrees(90), endAngle: .degrees(180), clockwise: false)
        p.addLine(to: CGPoint(x: ins, y: sr + ins))
        return p
    }
}

// MARK: - Panel U-Shape

private struct PanelUShape: Shape {
    let panelLeft: CGFloat
    let panelRight: CGFloat
    let panelBottom: CGFloat
    let panelBottomRadius: CGFloat

    func path(in rect: CGRect) -> Path {
        let bR = panelBottomRadius
        var p = Path()
        p.move(to: CGPoint(x: panelLeft,  y: -capHide))
        p.addLine(to: CGPoint(x: panelLeft, y: panelBottom - bR))
        p.addQuadCurve(to: CGPoint(x: panelLeft + bR, y: panelBottom),
                       control: CGPoint(x: panelLeft, y: panelBottom))
        p.addLine(to: CGPoint(x: panelRight - bR, y: panelBottom))
        p.addQuadCurve(to: CGPoint(x: panelRight, y: panelBottom - bR),
                       control: CGPoint(x: panelRight, y: panelBottom))
        p.addLine(to: CGPoint(x: panelRight, y: -capHide))
        return p
    }
}

// MARK: - Glow Layer helper

private struct GlowLayer<S: Shape>: View {
    let shape: S
    let palette: [Color]
    let angle: Double
    let lineWidth: CGFloat
    let blur: CGFloat

    var body: some View {
        shape
            .stroke(
                AngularGradient(
                    colors: palette,
                    center: .center,
                    startAngle: .degrees(angle),
                    endAngle: .degrees(angle + 360)
                ),
                lineWidth: lineWidth
            )
            .blur(radius: blur)
    }
}

// MARK: - Screen Glow View
//
// Reads variant from GlowModel (no re-init on variant change).
// Uses withAnimation(.linear.repeatForever) so Core Animation handles
// interpolation — no Swift code runs per frame once the animation starts.
// @State angle values survive window orderOut/orderFront: CA pauses and
// resumes from wherever the animation was, giving seamless continuation.

struct ScreenGlowView: View {
    @ObservedObject var model: GlowModel

    private static let panelWidth:  CGFloat = PanelGlowWindow.panelVisualWidth
    private static let screenR:     CGFloat = 12
    private static let strokeInset: CGFloat = 0

    @State private var angle1: Double = 0
    @State private var angle2: Double = 0

    var body: some View {
        let pal = glowPalette(for: model.variant)
        let perimeter = ScreenPerimeter(
            panelWidth:   Self.panelWidth,
            screenRadius: Self.screenR,
            inset:        Self.strokeInset
        )
        ZStack {
            GlowLayer(shape: perimeter, palette: pal, angle: angle1, lineWidth: 4,  blur: 0)
            GlowLayer(shape: perimeter, palette: pal, angle: angle2, lineWidth: 14, blur: 10)
            GlowLayer(shape: perimeter, palette: pal, angle: angle1, lineWidth: 30, blur: 24)
        }
        .drawingGroup()
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .onAppear {
            withAnimation(.linear(duration: 3.5).repeatForever(autoreverses: false)) {
                angle1 = 360
            }
            withAnimation(.linear(duration: 7.0).repeatForever(autoreverses: false)) {
                angle2 = 360
            }
        }
    }
}

// MARK: - Panel Glow View
//
// Reads panelHeight live from AppSettings so it adapts to Settings changes.
// Screen width is read from NSScreen.main, which is fresh on every body evaluation.

struct PanelGlowView: View {
    @ObservedObject var model: GlowModel
    @ObservedObject private var settings = AppSettings.shared

    private static let panelVisualWidth: CGFloat = PanelGlowWindow.panelVisualWidth
    private static let panelBottomR:     CGFloat = 38

    @State private var angle1: Double = 0
    @State private var angle2: Double = 0

    private var panelHeight: CGFloat {
        let screen  = NSScreen.main ?? NSScreen.screens[0]
        let safeTop = screen.safeAreaInsets.top
        let notchH: CGFloat = safeTop > 0 ? safeTop : (screen.frame.maxY - screen.visibleFrame.maxY)
        return notchH + settings.notchContentHeight + PanelGlowWindow.dnkBottomInset
    }

    var body: some View {
        let pal        = glowPalette(for: model.variant)
        let screen     = NSScreen.main ?? NSScreen.screens[0]
        let sw         = screen.frame.width
        let panelLeft  = (sw - Self.panelVisualWidth) / 2
        let panelRight = (sw + Self.panelVisualWidth) / 2
        let shape = PanelUShape(
            panelLeft:         panelLeft,
            panelRight:        panelRight,
            panelBottom:       panelHeight,
            panelBottomRadius: Self.panelBottomR
        )
        ZStack {
            GlowLayer(shape: shape, palette: pal, angle: angle2, lineWidth: 16, blur: 16)
            GlowLayer(shape: shape, palette: pal, angle: angle1, lineWidth: 36, blur: 32)
        }
        .drawingGroup()
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .onAppear {
            withAnimation(.linear(duration: 3.5).repeatForever(autoreverses: false)) {
                angle1 = 360
            }
            withAnimation(.linear(duration: 7.0).repeatForever(autoreverses: false)) {
                angle2 = 360
            }
        }
    }
}
