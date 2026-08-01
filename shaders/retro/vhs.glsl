//!HOOK OUTPUT
//!BIND HOOKED
//!DESC 240-MP retro: VHS

// Composite-tape look: a light chroma bleed, visible tape grain, and an organic
// horizontal instability. The wobble is driven by value noise (smooth but
// non-repeating) rather than a pure sine, so it reads as irregular tape distortion
// instead of clean bands scrolling up the frame. Two octaves drift in opposite
// directions to break up any uniform scan.
#define BLEED  0.0022  // chroma horizontal offset (fraction of width)
#define SMEAR  0.08    // faint tape softness (kept low — was glossy higher)
#define GRAIN  0.07    // visible tape grain
#define WOBBLE 0.0009  // horizontal instability amplitude (fraction of width)

// 1D value noise in [-0.5, 0.5]: smoothstep-interpolated hash, so the displacement
// varies continuously down the frame with no visible periodicity.
float vnoise(float x) {
    float i = floor(x);
    float f = fract(x);
    float a = fract(sin(i * 12.9898) * 43758.5453);
    float b = fract(sin((i + 1.0) * 12.9898) * 43758.5453);
    f = f * f * (3.0 - 2.0 * f);
    return mix(a, b, f) - 0.5;
}

vec4 hook() {
    vec2 p = HOOKED_pos;
    float t = mod(float(frame), 4096.0);   // bounded so the animation stays crisp

    // Organic horizontal instability: a broad waver plus a finer jitter, drifting
    // slowly in opposite directions so the distortion holds a beat before it moves
    // (real tape wobble lingers) and never resolves into a clean travelling wave.
    float w = vnoise(p.y * 9.0  + t * 0.03) * 0.7
            + vnoise(p.y * 31.0 - t * 0.02) * 0.3;

    // Amplitude gate: a slow, calm-biased noise so the wobble mostly rests and
    // swells into occasional bursts (like tracking / head-switching instability).
    float g = vnoise(t * 0.03 + 100.0) + 0.5;   // 0..1, decorrelated from the waver
    float gate = 0.6 + 0.7 * (g * g);           // ~0.6 baseline, bursts past 1.0

    p.x += w * WOBBLE * gate;

    // Chroma bleed: pull red left and blue right of the luma.
    float r = HOOKED_tex(vec2(p.x - BLEED, p.y)).r;
    float g = HOOKED_tex(p).g;
    float b = HOOKED_tex(vec2(p.x + BLEED, p.y)).b;
    vec3 col = vec3(r, g, b);

    // Whisper of one-pixel smear (tape bandwidth) — not enough to gloss it over.
    vec3 smear = (HOOKED_tex(vec2(p.x - HOOKED_pt.x, p.y)).rgb
                + HOOKED_tex(vec2(p.x + HOOKED_pt.x, p.y)).rgb) * 0.5;
    col = mix(col, smear, SMEAR);

    // Tape grain — hashed in pixel coords + frame so it's genuinely per-pixel.
    float n = fract(sin(dot(p * HOOKED_size + t, vec2(12.9898, 78.233))) * 43758.5453);
    col += (n - 0.5) * GRAIN;

    return vec4(col, 1.0);
}
