import SwiftUI
import MetalKit
import MarkdownUI

// MARK: - Metal Shader Source

private let kOrbShaderSrc = """
#include <metal_stdlib>
using namespace metal;

// 17-color palette — light blues removed, darker blues kept.
constant float3 kPal[17] = {
    float3(0.9529, 0.6980, 0.1608), // #F3B229
    float3(0.9490, 0.7725, 0.4275), // #F2C56D
    float3(0.9059, 0.7765, 0.6627), // #E7C6A9
    float3(0.8471, 0.7804, 0.7451), // #D8C7BE
    float3(0.2980, 0.6118, 1.0000), // #4C9CFF
    float3(0.1373, 0.5647, 0.9686), // #2390F7
    float3(0.3961, 0.4941, 1.0000), // #657EFF
    float3(0.5412, 0.4353, 1.0000), // #8A6FFF
    float3(0.6431, 0.3569, 1.0000), // #A45BFF
    float3(0.7647, 0.3608, 0.9765), // #C35CF9
    float3(0.8510, 0.3804, 0.8431), // #D961D7
    float3(0.9059, 0.4078, 0.6902), // #E768B0
    float3(0.9608, 0.4157, 0.4863), // #F56A7C
    float3(0.9725, 0.3569, 0.4000), // #F85B66
    float3(0.9608, 0.2196, 0.5725), // #F53892
    float3(1.0000, 0.4784, 0.3412), // #FF7A57
    float3(0.9412, 0.5529, 0.2980), // #F08D4C
};

static float3 s_mod289(float3 x) { return x - floor(x*(1.0/289.0))*289.0; }
static float4 s_mod289(float4 x) { return x - floor(x*(1.0/289.0))*289.0; }
static float4 s_perm(float4 x)   { return s_mod289((x*34.0+1.0)*x); }

static float snoise(float3 v) {
    const float2 C = float2(1.0/6.0, 1.0/3.0);
    float3 i  = floor(v + dot(v, C.yyy));
    float3 x0 = v - i + dot(i, C.xxx);
    float3 g  = step(x0.yzx, x0.xyz), l = 1.0-g;
    float3 i1 = min(g.xyz,l.zxy), i2 = max(g.xyz,l.zxy);
    float3 x1 = x0-i1+C.x, x2 = x0-i2+C.y, x3 = x0-0.5;
    i = s_mod289(i);
    float4 p = s_perm(s_perm(s_perm(
        i.z+float4(0,i1.z,i2.z,1))+
        i.y+float4(0,i1.y,i2.y,1))+
        i.x+float4(0,i1.x,i2.x,1));
    float4 j  = p - 49.0*floor(p*(1.0/49.0));
    float4 x_ = floor(j*(1.0/7.0)), y_ = floor(j-7.0*x_);
    float4 x  = (x_*2.0+0.5)/7.0-1.0, y = (y_*2.0+0.5)/7.0-1.0;
    float4 h  = 1.0-abs(x)-abs(y);
    float4 b0 = float4(x.xy,y.xy), b1 = float4(x.zw,y.zw);
    float4 s0 = floor(b0)*2.0+1.0, s1 = floor(b1)*2.0+1.0;
    float4 sh = -step(h,float4(0));
    float4 a0 = b0.xzyw+s0.xzyw*sh.xxyy, a1 = b1.xzyw+s1.xzyw*sh.zzww;
    float3 p0 = float3(a0.xy,h.x), p1 = float3(a0.zw,h.y);
    float3 p2 = float3(a1.xy,h.z), p3 = float3(a1.zw,h.w);
    float4 nrm = 1.79284291400159 - 0.85373472095314 *
                 float4(dot(p0,p0),dot(p1,p1),dot(p2,p2),dot(p3,p3));
    p0*=nrm.x; p1*=nrm.y; p2*=nrm.z; p3*=nrm.w;
    float4 m = max(0.6-float4(dot(x0,x0),dot(x1,x1),dot(x2,x2),dot(x3,x3)),0.0);
    m = m*m;
    return 42.0*dot(m*m,float4(dot(p0,x0),dot(p1,x1),dot(p2,x2),dot(p3,x3)));
}

struct OrbUniforms { float4 meta; }; // .x = elapsed time
struct VOut { float4 pos [[position]]; float2 uv; };

vertex VOut orb_vert(uint vid [[vertex_id]]) {
    float2 ps[4] = {float2(-1,-1),float2(1,-1),float2(-1,1),float2(1,1)};
    float2 us[4] = {float2(0,1),  float2(1,1), float2(0,0), float2(1,0)};
    VOut o; o.pos = float4(ps[vid],0,1); o.uv = us[vid]; return o;
}

fragment float4 orb_frag(VOut in [[stage_in]], constant OrbUniforms &u [[buffer(0)]]) {
    float2 uv = in.uv;
    float  t  = u.meta.x;

    // Two orthogonal low-frequency noise fields for smooth 2D variation.
    // Scale 2.5 gives enough wavelengths for all 20 colors to appear in equal regions.
    float n1 = snoise(float3(uv * 1.3,                     t*0.22 + 40.0));
    float n2 = snoise(float3(uv * 1.3 + float2(7.3, 5.1), t*0.18 + 80.0));
    float tv = clamp((n1*0.6 + n2*0.4)*0.5 + 0.5, 0.0, 1.0);

    // Map tv to palette index — each of the 20 colors gets exactly 1/19 of the range.
    float  s   = tv * 16.0;
    int    idx = min(int(s), 15);
    float3 col = mix(kPal[idx], kPal[idx + 1], fract(s));

    // Soft circular mask — no rim darkening or saturation tricks so all colors appear equally.
    float2 cen  = uv - 0.5;
    float  dist = length(cen);
    float  alpha = smoothstep(0.5, 0.43, dist);

    return float4(col * alpha, alpha);
}
"""

// MARK: - Uniforms (just time — palette is hardcoded in the shader)

private struct OrbUniforms {
    var meta: SIMD4<Float>   // .x = elapsed time
}

// MARK: - Orb Renderer

private final class OrbRenderer {
    private let queue:    MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let t0 = CACurrentMediaTime()

    init?(device: MTLDevice) {
        guard let q = device.makeCommandQueue() else { return nil }
        let lib: MTLLibrary
        do { lib = try device.makeLibrary(source: kOrbShaderSrc, options: MTLCompileOptions()) }
        catch { print("[OrbRenderer] shader compile error: \(error)"); return nil }

        guard let vert = lib.makeFunction(name: "orb_vert"),
              let frag = lib.makeFunction(name: "orb_frag") else {
            print("[OrbRenderer] missing function"); return nil
        }
        let pd = MTLRenderPipelineDescriptor()
        pd.vertexFunction   = vert
        pd.fragmentFunction = frag
        let ca = pd.colorAttachments[0]!
        ca.pixelFormat                 = .bgra8Unorm
        ca.isBlendingEnabled           = true
        ca.sourceRGBBlendFactor        = .one
        ca.destinationRGBBlendFactor   = .oneMinusSourceAlpha
        ca.sourceAlphaBlendFactor      = .one
        ca.destinationAlphaBlendFactor = .oneMinusSourceAlpha

        do { self.pipeline = try device.makeRenderPipelineState(descriptor: pd) }
        catch { print("[OrbRenderer] pipeline error: \(error)"); return nil }
        self.queue = q
    }

    func draw(in view: MTKView) {
        guard let drawable = view.currentDrawable,
              let rp       = view.currentRenderPassDescriptor,
              let cmdbuf   = queue.makeCommandBuffer(),
              let enc      = cmdbuf.makeRenderCommandEncoder(descriptor: rp) else { return }

        var u = OrbUniforms(meta: SIMD4(Float(CACurrentMediaTime() - t0), 0, 0, 0))
        enc.setRenderPipelineState(pipeline)
        enc.setFragmentBytes(&u, length: MemoryLayout<OrbUniforms>.size, index: 0)
        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        enc.endEncoding()
        cmdbuf.present(drawable)
        cmdbuf.commit()
    }
}

// MARK: - MTKView subclass (owns display link via MTKView's built-in animation loop)

private final class OrbMTKView: MTKView, MTKViewDelegate {
    private var orbRenderer: OrbRenderer?

    var animated: Bool = true {
        didSet { isPaused = !animated }
    }

    init() {
        let dev = MTLCreateSystemDefaultDevice()
        super.init(frame: .zero, device: dev)
        clearColor          = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        colorPixelFormat    = .bgra8Unorm
        layer?.isOpaque     = false
        enableSetNeedsDisplay = false
        isPaused            = false
        preferredFramesPerSecond = 60
        delegate            = self
        if let d = dev { orbRenderer = OrbRenderer(device: d) }
        else { print("[OrbMTKView] no Metal device") }
    }
    required init(coder: NSCoder) { fatalError() }

    override var isOpaque: Bool { false }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}
    func draw(in view: MTKView) { orbRenderer?.draw(in: view) }
}

// MARK: - SwiftUI wrapper

private struct OrbShaderView: NSViewRepresentable {
    let animated: Bool
    func makeNSView(context: Context) -> OrbMTKView { OrbMTKView() }
    func updateNSView(_ v: OrbMTKView, context: Context) { v.animated = animated }
    static func dismantleNSView(_ v: OrbMTKView, coordinator: ()) { v.isPaused = true }
}

// MARK: - Pearlescent Orb (compact-mode indicator only — panel uses FluidBubble)

struct PearlescentOrb: View {
    let size: CGFloat
    let animated: Bool

    var body: some View {
        ZStack {
            Color(red: 0.2980, green: 0.6118, blue: 1.0)
            OrbShaderView(animated: animated)
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }
}

// MARK: - Fluid Bubble

// Smooth closed curve through a polygon of points using Catmull-Rom tangents.
private func catmullRomPath(_ pts: [CGPoint]) -> Path {
    let n = pts.count
    guard n > 2 else { return Path() }
    var path = Path()
    path.move(to: pts[0])
    for i in 0..<n {
        let p0 = pts[(i - 1 + n) % n]
        let p1 = pts[i]
        let p2 = pts[(i + 1) % n]
        let p3 = pts[(i + 2) % n]
        let cp1 = CGPoint(x: p1.x + (p2.x - p0.x) / 6,
                          y: p1.y + (p2.y - p0.y) / 6)
        let cp2 = CGPoint(x: p2.x - (p3.x - p1.x) / 6,
                          y: p2.y - (p3.y - p1.y) / 6)
        path.addCurve(to: p2, control1: cp1, control2: cp2)
    }
    path.closeSubpath()
    return path
}

// Sine-wave distorted circle — multiple incommensurate harmonics give a continuously
// changing organic shape that never obviously repeats.
private func fluidBlobPath(in rect: CGRect, phase t: Double) -> Path {
    let cx = rect.midX, cy = rect.midY
    let baseR = min(rect.width, rect.height) / 2.0 * 0.87
    let count = 120
    var pts: [CGPoint] = []
    for i in 0..<count {
        let θ = Double(i) / Double(count) * 2 * .pi
        let warp = sin(2 * θ + t)              * 0.048
                 + sin(3 * θ + t * 1.57) * 0.030
                 + cos(5 * θ + t * 0.83) * 0.018
                 + sin(4 * θ + t * 1.29) * 0.012
        let r = baseR * (1.0 + CGFloat(warp))
        pts.append(CGPoint(x: cx + r * CGFloat(cos(θ)),
                           y: cy + r * CGFloat(sin(θ))))
    }
    return catmullRomPath(pts)
}

struct FluidBubble: View {
    let size: CGFloat
    let animated: Bool

    var body: some View {
        Group {
            if animated {
                TimelineView(.animation) { tl in
                    bubbleCanvas(phase: tl.date.timeIntervalSinceReferenceDate * 0.52)
                }
            } else {
                bubbleCanvas(phase: 1.8)
            }
        }
        .blur(radius: 2.0)   // just enough to soften the ring edge without blurring it away
        .frame(width: size, height: size)
    }

    private func bubbleCanvas(phase: Double) -> some View {
        Canvas { ctx, sz in
            let path  = fluidBlobPath(in: CGRect(origin: .zero, size: sz), phase: phase)
            let r     = min(sz.width, sz.height) / 2.0
            let cx    = sz.width / 2, cy = sz.height / 2

            // Ring band: startRadius punches a transparent hole in the center.
            // Everything inside innerR gets location=0 (clear) → hollow bubble center.
            let innerR = r * 0.52
            let outerR = r * 0.98

            // Three gradient centers orbit slowly — their overlapping rings create
            // the iridescent blue / purple / pink color variation around the circumference.
            let a = phase * 0.22
            let blueC   = CGPoint(x: cx + r * 0.14 * cos(a),        y: cy + r * 0.14 * sin(a))
            let purpleC = CGPoint(x: cx + r * 0.14 * cos(a + 2.09), y: cy + r * 0.14 * sin(a + 2.09))
            let pinkC   = CGPoint(x: cx + r * 0.14 * cos(a + 4.19), y: cy + r * 0.14 * sin(a + 4.19))

            func ring(_ stops: [Gradient.Stop], center: CGPoint) {
                ctx.fill(path, with: .radialGradient(
                    Gradient(stops: stops), center: center,
                    startRadius: innerR, endRadius: outerR))
            }

            ring([
                .init(color: .clear,                                               location: 0.00),
                .init(color: Color(red: 0.30, green: 0.50, blue: 1.00, opacity: 0.92), location: 0.45),
                .init(color: Color(red: 0.38, green: 0.55, blue: 1.00, opacity: 0.55), location: 0.75),
                .init(color: .clear,                                               location: 1.00),
            ], center: blueC)

            ring([
                .init(color: .clear,                                               location: 0.00),
                .init(color: Color(red: 0.60, green: 0.30, blue: 1.00, opacity: 0.95), location: 0.45),
                .init(color: Color(red: 0.65, green: 0.35, blue: 1.00, opacity: 0.50), location: 0.75),
                .init(color: .clear,                                               location: 1.00),
            ], center: purpleC)

            ring([
                .init(color: .clear,                                               location: 0.00),
                .init(color: Color(red: 0.88, green: 0.25, blue: 0.85, opacity: 0.85), location: 0.45),
                .init(color: Color(red: 0.80, green: 0.30, blue: 0.80, opacity: 0.40), location: 0.75),
                .init(color: .clear,                                               location: 1.00),
            ], center: pinkC)

            // Subtle top-left specular highlight — the "light bounce" that makes it read as a sphere.
            ctx.fill(path, with: .radialGradient(
                Gradient(stops: [
                    .init(color: Color.white.opacity(0.50), location: 0.00),
                    .init(color: Color.white.opacity(0.12), location: 0.55),
                    .init(color: .clear,                    location: 1.00),
                ]),
                center: CGPoint(x: cx - r * 0.22, y: cy - r * 0.26),
                startRadius: 0, endRadius: r * 0.40))
        }
    }
}

// MARK: - Soft Blur In Text
// Spec: pixel-point/animate-text — soft-blur-in
// Enter: opacity 0→1, blur 6→0 px, y +10→0 px, 900 ms, stagger 15 ms, cubic-bezier(0.22,1,0.36,1)
// Exit:  opacity 1→0, blur 0→6 px, y 0→-10 px, 600 ms, stagger 11 ms, cubic-bezier(0.64,0,0.78,0)
// Loop:  enter → hold 550 ms → exit → enter next → gap 320 ms → …

private struct SoftBlurText: View {
    let phrases: [String]

    @State private var currentPhrase = ""
    @State private var yOffsets:  [CGFloat] = []
    @State private var opacities: [Double]  = []
    @State private var blurs:     [CGFloat] = []

    private let enterDuration: Double  = 0.9
    private let enterStagger:  Double  = 0.015   // 15 ms — tuned down for 28 pt body text
    private let exitDuration:  Double  = 0.6
    private let exitStagger:   Double  = 0.011
    private let blurAmount:    CGFloat = 6        // spec says reduce from 12 for body text
    private let yAmount:       CGFloat = 10       // 16 * 0.58 ≈ 9, rounded to 10
    private let holdTime:      Double  = 2.55
    private let gapTime:       Double  = 0.32

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(currentPhrase.enumerated()), id: \.offset) { i, char in
                Text(String(char))
                    .blur(radius:  blurs.indices.contains(i)    ? blurs[i]     : blurAmount)
                    .opacity(      opacities.indices.contains(i) ? opacities[i] : 0)
                    .offset(y:     yOffsets.indices.contains(i)  ? yOffsets[i]  : yAmount)
            }
        }
        .font(.system(size: 28, weight: .medium))
        .foregroundColor(.white.opacity(0.82))
        .task {
            guard !phrases.isEmpty else { return }
            reset(to: phrases[0])
            try? await Task.sleep(for: .milliseconds(80))
            await performEnter()
            var idx = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(holdTime))
                if Task.isCancelled { break }
                await performExit()
                if Task.isCancelled { break }
                idx = (idx + 1) % phrases.count
                reset(to: phrases[idx])
                await performEnter()
                try? await Task.sleep(for: .seconds(gapTime))
            }
        }
    }

    private func reset(to phrase: String) {
        currentPhrase = phrase
        let n = phrase.count
        yOffsets  = Array(repeating: yAmount,    count: n)
        opacities = Array(repeating: 0.0,        count: n)
        blurs     = Array(repeating: blurAmount, count: n)
    }

    private func performEnter() async {
        for i in 0..<yOffsets.count {
            guard !Task.isCancelled else { return }
            withAnimation(.timingCurve(0.22, 1, 0.36, 1, duration: enterDuration)) {
                guard yOffsets.indices.contains(i) else { return }
                yOffsets[i]  = 0
                opacities[i] = 1
                blurs[i]     = 0
            }
            if i < yOffsets.count - 1 {
                try? await Task.sleep(for: .seconds(enterStagger))
            }
        }
        try? await Task.sleep(for: .seconds(enterDuration))
    }

    private func performExit() async {
        for i in 0..<yOffsets.count {
            guard !Task.isCancelled else { return }
            withAnimation(.timingCurve(0.64, 0, 0.78, 0, duration: exitDuration)) {
                guard yOffsets.indices.contains(i) else { return }
                yOffsets[i]  = -yAmount
                opacities[i] = 0
                blurs[i]     = blurAmount
            }
            if i < yOffsets.count - 1 {
                try? await Task.sleep(for: .seconds(exitStagger))
            }
        }
        try? await Task.sleep(for: .seconds(exitDuration))
    }
}

// MARK: - Agent Mode View

struct AgentModeView: View {
    @ObservedObject private var runner = AgentRunner.shared
    @ObservedObject private var settings = AppSettings.shared

    let onExit: () -> Void
    @Binding var showingHistory: Bool

    @State private var isHoveringOrb = false
    @State private var scrollProxy: ScrollViewProxy? = nil

    private let agentPhrases = [
        "How can I help?",
        "What should I do?",
        "What do you need done?",
        "Got a task for me?",
        "What's on your list?",
        "Ready when you are.",
        "What can I take off your plate?",
        "Name the task.",
        "What are we doing?",
        "Put me to work.",
    ]

    var body: some View {
        ZStack {
            if showingHistory {
                AgentHistoryView(runner: runner) { showingHistory = false }
                    .transition(.opacity.combined(with: .scale(scale: 0.97)))
            } else {
                contentArea
            }
        }
        .animation(.spring(response: 0.38, dampingFraction: 0.82), value: showingHistory)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: — Content area

    @ViewBuilder
    private var contentArea: some View {
        ZStack(alignment: .topLeading) {
            if !runner.bubbles.isEmpty || !runner.finalOutput.isEmpty {
                bubbleStack
            } else if runner.state != .running {
                // Don't mount SoftBlurText while a task is running — it starts animation tasks
                // that contend with mockStream on the main actor, causing visible streaming lag.
                SoftBlurText(phrases: agentPhrases)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: runner.bubbles.count)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var bubbleStack: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(runner.bubbles) { bubble in
                        AgentBubbleView(bubble: bubble, showReasoning: settings.agentShowReasoningTrace)
                            .id(bubble.id)
                    }

                    if !runner.finalOutput.isEmpty {
                        Markdown(runner.finalOutput)
                            .markdownTheme(.localNotch)
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
            .mask {
                VStack(spacing: 0) {
                    LinearGradient(
                        colors: [.black.opacity(0.05), .black],
                        startPoint: .top, endPoint: .bottom
                    )
                    .frame(height: 22)
                    Rectangle()
                    LinearGradient(
                        colors: [.black, .black.opacity(0.05)],
                        startPoint: .top, endPoint: .bottom
                    )
                    .frame(height: 22)
                }
            }
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
            FluidBubble(size: size, animated: !isFinished)
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

}

// MARK: - Pulsing Play Button (State G/H)

struct PulsingPlayButton: View {
    var icon: String = "play.fill"
    let onTap: () -> Void
    @State private var pulse = false

    var body: some View {
        Image(systemName: icon)
            .font(.system(size: 11, weight: .medium))
            .foregroundColor(.white.opacity(0.75))
            .frame(width: 30, height: 30)
            .modifier(GlassSphereModifier())
            .overlay(
                Circle()
                    .stroke(Color.white.opacity(pulse ? 0.0 : 0.3), lineWidth: 1)
                    .scaleEffect(pulse ? 1.22 : 1.0)
                    .animation(.easeInOut(duration: 1.5).repeatForever(autoreverses: false), value: pulse)
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
                    .frame(width: 6, height: 6)
                    .padding(.top, 7)

                VStack(alignment: .leading, spacing: 4) {
                    if bubble.text.isEmpty && bubble.isStreaming {
                        HStack(spacing: 7) {
                            AgentWorkingIndicator()
                            Text(bubble.placeholder)
                                .font(.system(size: 15))
                                .foregroundColor(.white.opacity(0.55))
                        }
                    } else {
                        Text(bubble.text)
                            .font(.system(size: 15))
                            .foregroundColor(textColor)
                            .fixedSize(horizontal: false, vertical: true)
                    }

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
        RoundedRectangle(cornerRadius: 10)
            .fill(Color.white.opacity(bubble.type == .error ? 0.08 : 0.06))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.white.opacity(0.1), lineWidth: 0.5))
    }
}

// MARK: - Working Indicator

/// Three softly pulsing dots shown while the agent is loading the model or thinking.
struct AgentWorkingIndicator: View {
    @State private var animating = false
    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .fill(Color.white.opacity(0.55))
                    .frame(width: 4, height: 4)
                    .scaleEffect(animating ? 1.0 : 0.5)
                    .opacity(animating ? 1.0 : 0.3)
                    .animation(
                        .easeInOut(duration: 0.5).repeatForever(autoreverses: true).delay(Double(i) * 0.18),
                        value: animating
                    )
            }
        }
        .onAppear { animating = true }
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
                    Markdown(runner.finalOutput)
                        .markdownTheme(.localNotch)
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
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
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
            if !entry.note.isEmpty {
                Text(entry.note)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(.white.opacity(0.28))
                    .lineLimit(2)
                    .truncationMode(.tail)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.white.opacity(0.04))
        )
    }
}
