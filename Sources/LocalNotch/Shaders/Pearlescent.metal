#include <metal_stdlib>
using namespace metal;

// Branch-free HSV → RGB.
static float3 hsv2rgb(float h, float s, float v) {
    float4 K = float4(1.0, 2.0 / 3.0, 1.0 / 3.0, 3.0);
    float3 p = abs(fract(float3(h) + K.xyz) * 6.0 - K.w);
    return v * mix(K.xxx, clamp(p - K.x, 0.0, 1.0), s);
}

// Smooth noise via a fast hash. Returns [0, 1].
static float hash21(float2 p) {
    p = fract(p * float2(127.1, 311.7));
    p += dot(p, p + 19.19);
    return fract(p.x * p.y);
}

static float smoothNoise(float2 p) {
    float2 i = floor(p);
    float2 f = fract(p);
    float2 u = f * f * (3.0 - 2.0 * f); // smoothstep
    return mix(mix(hash21(i + float2(0,0)), hash21(i + float2(1,0)), u.x),
               mix(hash21(i + float2(0,1)), hash21(i + float2(1,1)), u.x), u.y);
}

// distortionEffect: single Gaussian-envelope ripple wave traveling top → bottom.
// progress 0→1 moves the wave front from y=0 to y=viewHeight.
// cos gives peak displacement right at the wave front, with a natural trough behind it.
[[ stitchable ]] float2 screenRipple(float2 pos, float viewHeight, float progress, float amplitude) {
    float waveFront = progress * viewHeight;
    float dist      = pos.y - waveFront;
    float sigma     = 150.0;
    float envelope  = exp(-(dist * dist) / (2.0 * sigma * sigma));
    float dx        = amplitude * envelope * cos(dist * 0.025);
    return float2(pos.x + dx, pos.y + dx * 0.08);
}

// colorEffect signature: position is in local pixel coords, currentColor is the source pixel.
[[ stitchable ]] half4 pearlescentOrb(float2 pos, half4 currentColor, float t, float2 sz) {
    // Normalise to [-1, 1] with centre at (0, 0).
    float2 uv = (pos - sz * 0.5) / (min(sz.x, sz.y) * 0.5);
    float r   = length(uv);
    float theta = atan2(uv.y, uv.x);          // -π … +π
    float tN    = theta / (2.0 * M_PI_F);      // -0.5 … +0.5

    // --- Three independently-drifting hue waves ---
    // All hues are clamped to [0.50, 0.88]: cyan → blue → violet → pink.
    // No green, no yellow — stays in the pearlescent palette.
    float h1 = 0.50 + fract( tN       + r * 0.22 + t * 0.130) * 0.38;
    float h2 = 0.50 + fract(-tN * 0.9 + r * 0.18 - t * 0.090 + 0.40) * 0.38;
    float h3 = 0.50 + fract( r  * 0.6 + tN * 0.3 + t * 0.055 + 0.70) * 0.38;

    // Blend factors — sine/cosine waves with different periods so blending is never periodic.
    float b1 = 0.5 + 0.5 * sin(theta * 2.5 + t * 0.38);
    float b2 = 0.5 + 0.5 * cos(r * 2.8     + t * 0.23 + 1.1);

    // Add a thin turbulence layer so straight lines feel liquid.
    float noise = smoothNoise(uv * 2.8 + t * 0.09);
    float hFinal = mix(mix(h1, h2, saturate(b1)), h3, saturate(b2) * 0.44);
    hFinal = hFinal + (noise - 0.5) * 0.03; // micro-shimmer

    // High saturation so colors stay vivid; value handles depth via rim later.
    float3 col = hsv2rgb(hFinal, 0.84, 0.92);

    // --- Specular highlight — small, sharp, drifts slowly ---
    float2 sp = float2(
        -0.24 + 0.07 * sin(t * 0.09),
        -0.27 + 0.05 * cos(t * 0.07)
    );
    float spec = pow(max(0.0, 1.0 - length(uv - sp) * 2.5), 5.0);
    col = mix(col, float3(1.0), spec * 0.85);

    // --- Depth / rim --- darkens edges for a spherical look.
    float rim = smoothstep(1.0, 0.40, r);
    col *= 0.28 + 0.72 * rim;

    // Anti-aliased edge — soft 3 % feather.
    float alpha = smoothstep(1.0, 0.94, r);

    return half4(half3(col) * half(alpha), half(alpha));
}
