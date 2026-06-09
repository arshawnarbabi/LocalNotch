import AppKit
import SwiftUI
import CoreGraphics

// MARK: - Pearlescent palette (matches AgentGlowOverlay)

private let pearlescentRGB: [(r: Double, g: Double, b: Double)] = [
    (0.62, 0.25, 1.00),
    (0.40, 0.55, 1.00),
    (0.30, 0.75, 1.00),
    (0.60, 0.40, 1.00),
    (1.00, 0.35, 0.75),
    (1.00, 0.45, 0.35),
    (1.00, 0.70, 0.25),
    (0.80, 0.35, 1.00),
    (0.50, 0.50, 1.00),
    (0.62, 0.25, 1.00),
]

private func pearlescentColor(dist: CGFloat, progress: Double, bandWidth: Double) -> Color {
    let cyclePixels = bandWidth * 280.0
    let raw = Double(abs(dist)) / cyclePixels + progress * 2.5
    let t   = raw - floor(raw)
    let s   = t * Double(pearlescentRGB.count - 1)
    let lo  = Int(s) % (pearlescentRGB.count - 1)
    let hi  = lo + 1
    let f   = s - Double(lo)
    let c0  = pearlescentRGB[lo], c1 = pearlescentRGB[hi]
    return Color(red:   c0.r + (c1.r - c0.r) * f,
                 green: c0.g + (c1.g - c0.g) * f,
                 blue:  c0.b + (c1.b - c0.b) * f)
}

/// 60-stop radial gradient — smooth concentric color rings, GPU-accelerated.
private func tintRadialGradient(
    maxDist: CGFloat,
    waveD: CGFloat,
    sigma: CGFloat,
    tintIntensity: Double,
    tintBandWidth: Double,
    progress: Double
) -> Gradient {
    var stops: [Gradient.Stop] = []
    for i in 0...60 {
        let r     = CGFloat(i) / 60.0 * maxDist
        let dist  = r - waveD
        let env   = gaussEnv(dist, sigma: sigma)
        let color = pearlescentColor(dist: dist, progress: progress, bandWidth: tintBandWidth)
        stops.append(.init(color: color.opacity(Double(env) * tintIntensity * 0.40),
                           location: CGFloat(i) / 60.0))
    }
    return Gradient(stops: stops)
}

private func gaussEnv(_ dist: CGFloat, sigma: CGFloat) -> CGFloat {
    let f = Float(dist); let s = Float(sigma)
    return CGFloat(exp(-f * f / (2 * s * s)))
}

// MARK: - Window

final class ScreenRippleWindow: NSWindow {
    init() {
        super.init(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
        // One below .screenSaver so the DynamicNotchKit panel (which is at .screenSaver)
        // always renders above the ripple — notch stays visible during the animation.
        level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue - 1)
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        ignoresMouseEvents = true
        collectionBehavior = [.canJoinAllSpaces, .stationary]
        isReleasedWhenClosed = false
    }

    func play() {
        guard !isVisible else { return }
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }

        let screen = NSScreen.main ?? NSScreen.screens[0]

        if CGPreflightScreenCaptureAccess() {
            if let cgImage = CGDisplayCreateImage(CGMainDisplayID()) {
                showRipple(screenshot: NSImage(cgImage: cgImage, size: screen.frame.size), screen: screen)
                return
            }
        } else {
            NSApp.activate(ignoringOtherApps: true)
            CGRequestScreenCaptureAccess()
        }

        showFallback(screen: screen)
    }

    private func showRipple(screenshot: NSImage, screen: NSScreen) {
        setFrame(screen.frame, display: false)
        let view = NSHostingView(rootView: ScreenRippleView(screenshot: screenshot,
                                                            screenSize: screen.frame.size))
        view.wantsLayer = true
        contentView = view
        alphaValue = 0.0
        orderFront(nil)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.08
            self.animator().alphaValue = 1.0
        }
        scheduleDismiss()
    }

    private func showFallback(screen: NSScreen) {
        setFrame(screen.frame, display: false)
        contentView = NSHostingView(rootView: RippleFallbackView(screenSize: screen.frame.size))
        alphaValue = 1.0
        orderFront(nil)
        scheduleDismiss()
    }

    private func scheduleDismiss() {
        Task {
            try? await Task.sleep(for: .milliseconds(700))
            await MainActor.run {
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.18
                    self.animator().alphaValue = 0
                } completionHandler: {
                    self.orderOut(nil)
                    self.contentView = nil
                    self.alphaValue = 1.0
                }
            }
        }
    }
}

// MARK: - Fallback (no screen-capture permission)

struct RippleFallbackView: View {
    let screenSize: CGSize
    private let startDate = Date()
    private let duration  = 1.5

    var body: some View {
        TimelineView(.animation) { tl in
            let elapsed  = tl.date.timeIntervalSince(startDate)
            let t        = min(max(elapsed / duration, 0), 1)
            let progress = t < 0.5 ? 2 * t * t : -1 + (4 - 2 * t) * t
            let waveY    = progress * screenSize.height
            let half: CGFloat = 160

            Canvas { ctx, size in
                let top    = max(0, waveY - half)
                let bottom = min(size.height, waveY + half)
                guard bottom > top else { return }
                ctx.fill(
                    Path(CGRect(x: 0, y: top, width: size.width, height: bottom - top)),
                    with: .linearGradient(
                        Gradient(stops: [
                            .init(color: Color(red: 0.65, green: 0.45, blue: 1.0).opacity(0),    location: 0),
                            .init(color: Color(red: 0.65, green: 0.45, blue: 1.0).opacity(0.20), location: 0.35),
                            .init(color: .white.opacity(0.55),                                    location: 0.5),
                            .init(color: Color(red: 1.0, green: 0.55, blue: 0.85).opacity(0.20), location: 0.65),
                            .init(color: Color(red: 1.0, green: 0.55, blue: 0.85).opacity(0),    location: 1),
                        ]),
                        startPoint: CGPoint(x: 0, y: top),
                        endPoint:   CGPoint(x: 0, y: bottom)
                    )
                )
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

// MARK: - Radial Expand ripple
// Settings: Speed 1.5×, Intensity 0.5×, Wave Width 1.0×, Tint 100%, Band Width 20.0×

struct ScreenRippleView: View {
    let screenshot: NSImage
    let screenSize: CGSize

    private let startDate     = Date()
    private let duration:      Double  = 1.0 / 1.0   // Speed 1.0×
    private let amplitude:     CGFloat = 13           // Intensity 0.5× (base 26 × 0.5)
    private let sigma:         CGFloat = 130          // Wave Width 1.0× (base 130 × 1.0)
    private let tintIntensity: Double  = 1.0          // Tint Amount 100%
    private let tintBandWidth: Double  = 20.0         // Band Width 20.0×
    // Ramp Curve: Linear — tint scales from 0 at start to full at end
    private let tile:          CGFloat = 28           // larger tile → fewer drawLayer calls

    var body: some View {
        TimelineView(.periodic(from: startDate, by: 1.0 / 60.0)) { tl in
            let elapsed  = tl.date.timeIntervalSince(startDate)
            let t        = min(max(elapsed / duration, 0), 1)
            let progress = easeInOut(t)

            Canvas { ctx, size in
                let img     = ctx.resolve(Image(nsImage: screenshot))
                let cx      = size.width  / 2
                let cy      = size.height / 2
                let maxDist = hypot(cx, cy)
                let waveD   = CGFloat(progress) * (maxDist + 6*sigma) - 3*sigma
                // Adaptive cos frequency: 0.0075 at sigma=130, scales down for wider waves
                let cosFreq = min(0.025, 0.975 / Double(sigma))
                // Beyond 2.75σ the gaussian envelope drops below 0.023 → dr < 0.3pt always;
                // use 2.8σ as the hard cutoff so we never even compute env/cos for those tiles.
                let skipThresh = 2.8 * sigma

                // Draw the base screenshot once — fast single GPU blit covering the whole screen.
                // Displaced tiles will overdraw their regions on top.
                ctx.draw(img, in: CGRect(origin: .zero, size: size))

                // Bounding box of the active annulus — skip the full-screen tile scan when the
                // wave is off-screen (start/end of animation where waveD has 3σ padding).
                let outerR = waveD + skipThresh
                guard outerR > 0 else { return }   // wave still off-screen, nothing to displace
                let bboxX0 = max(0,           floor((cx - outerR) / tile) * tile)
                let bboxX1 = min(size.width,  cx + outerR)
                let bboxY0 = max(0,           floor((cy - outerR) / tile) * tile)
                let bboxY1 = min(size.height, cy + outerR)

                var y = bboxY0
                while y < bboxY1 {
                    let tcy = y + tile / 2
                    let ddy = tcy - cy
                    var x = bboxX0
                    while x < bboxX1 {
                        let tcx  = x + tile / 2
                        let ddx  = tcx - cx
                        let dist = hypot(ddx, ddy)
                        let d    = dist - waveD

                        // Skip tiles outside the active band — base layer already shows them correctly
                        if abs(d) < skipThresh {
                            let env = gaussEnv(d, sigma: sigma)
                            let dr  = amplitude * env * CGFloat(cos(Double(d) * cosFreq))
                            // Skip tiles with sub-pixel displacement — visually identical to base
                            if abs(dr) > 0.3 {
                                let nx = dist > 0 ? ddx / dist : 0
                                let ny = dist > 0 ? ddy / dist : 0
                                ctx.drawLayer { inner in
                                    inner.clip(to: Path(CGRect(x: x, y: y, width: tile, height: tile)))
                                    inner.draw(img, in: CGRect(x: nx * dr, y: ny * dr,
                                                               width: size.width, height: size.height))
                                }
                            }
                        }
                        x += tile
                    }
                    y += tile
                }

                // Smooth radial gradient tint — single GPU pass; linear ramp from 0→max
                let grad = tintRadialGradient(maxDist: maxDist, waveD: waveD,
                                              sigma: sigma,
                                              tintIntensity: tintIntensity * progress,
                                              tintBandWidth: tintBandWidth,
                                              progress: progress)
                ctx.fill(Path(CGRect(origin: .zero, size: size)),
                         with: .radialGradient(grad,
                                               center: CGPoint(x: cx, y: cy),
                                               startRadius: 0,
                                               endRadius: maxDist))
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    private func easeInOut(_ t: Double) -> Double {
        t < 0.5 ? 2*t*t : -1 + (4 - 2*t)*t
    }
}
