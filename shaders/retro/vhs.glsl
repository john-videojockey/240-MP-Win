//!HOOK OUTPUT
//!BIND HOOKED
//!DESC 240-MP retro: VHS

// Composite-tape look: chroma bleed, visible tape grain, and an organic horizontal
// instability. The wobble is value noise (smooth but non-repeating), warping the
// picture rather than uniformly shifting it. A slow, calm-biased BURST level gates
// the amplitude so it mostly rests near-clean and swells into occasional dropouts —
// and during a burst the chroma bleed and grain kick up too, so a wobble reads as a
// momentary loss of signal rather than just a horizontal shift.
#define BLEED  0.0008  // base chroma horizontal offset (fraction of width — subtle;
                       // it's a colour fringe, not full chromatic aberration)
#define SMEAR  0.06    // faint tape softness
#define GRAIN  0.07    // base tape grain
#define WOBBLE 0.0016  // peak horizontal instability amplitude (fraction of width)

// 1D value noise in [-0.5, 0.5]: smoothstep-interpolated hash, so it varies
// continuously with no visible periodicity.
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

    // Organic horizontal instability: a broad waver plus a gentle secondary bend.
    // Kept low-frequency on purpose — a high-frequency displacement shifts adjacent
    // scanlines by different amounts and slices the image into visible lines, so we
    // low-pass it into a smooth, diffused warp that holds a beat rather than sliding.
    float w = vnoise(p.y * 6.0  + t * 0.03) * 0.72
            + vnoise(p.y * 13.0 - t * 0.02) * 0.28;

    // Burst level: slow, calm-biased noise. Mostly ~0 (clean) with occasional swells.
    // Decorrelated from the waver so dropouts land on their own rhythm.
    float burst = vnoise(t * 0.025 + 100.0) + 0.5;   // 0..1
    burst = burst * burst;                           // bias toward calm
    float gate = 0.18 + 1.6 * burst;                 // ~0.18 rest .. ~1.78 peak

    p.x += w * WOBBLE * gate;

    // During a burst the signal degrades a little: a touch more chroma fringe and
    // grain (kept modest so colours still mostly line up).
    float bleed = BLEED * (1.0 + 1.5 * burst);
    float grain = GRAIN * (1.0 + 1.5 * burst);

    // Chroma bleed: pull red left and blue right of the luma.
    vec3 col;
    col.r = HOOKED_tex(vec2(p.x - bleed, p.y)).r;
    col.g = HOOKED_tex(p).g;
    col.b = HOOKED_tex(vec2(p.x + bleed, p.y)).b;

    // Whisper of one-pixel smear (tape bandwidth) — not enough to gloss it over.
    vec3 smear = (HOOKED_tex(vec2(p.x - HOOKED_pt.x, p.y)).rgb
                + HOOKED_tex(vec2(p.x + HOOKED_pt.x, p.y)).rgb) * 0.5;
    col = mix(col, smear, SMEAR);

    // Tape grain — per-pixel, animated, and stronger during a burst.
    float n = fract(sin(dot(p * HOOKED_size + t, vec2(12.9898, 78.233))) * 43758.5453);
    col += (n - 0.5) * grain;

    return vec4(col, 1.0);
}
