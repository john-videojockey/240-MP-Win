//!HOOK OUTPUT
//!BIND HOOKED
//!DESC 240-MP retro: VHS

// Composite-tape look: chroma bleed, visible tape grain, and an organic horizontal
// instability. The wobble is value noise (two octaves drifting in opposite
// directions) so it warps the picture rather than shifting it uniformly. A slow,
// calm-biased BURST level gates the amplitude — mostly at rest, swelling into
// occasional dropouts that also nudge the chroma bleed and grain up, so a wobble
// reads as a momentary loss of signal.
#define BLEED  0.0008  // base chroma horizontal offset (fraction of width — a fringe)
#define SMEAR  0.06    // faint tape softness
#define GRAIN  0.05    // base tape grain (subtle; bursts kick it up)
#define WOBBLE 0.0016  // peak horizontal instability amplitude (fraction of width)

// 1D value noise in [-0.5, 0.5]: smoothstep-interpolated hash for the wobble.
float vnoise(float x) {
    float i = floor(x);
    float f = fract(x);
    float a = fract(sin(i * 12.9898) * 43758.5453);
    float b = fract(sin((i + 1.0) * 12.9898) * 43758.5453);
    f = f * f * (3.0 - 2.0 * f);
    return mix(a, b, f) - 0.5;
}

// Resolution-independent per-pixel hash (Dave Hoskins). No sin(), so it can't lose
// precision at high pixel coordinates the way sin(dot(pixel,...)) does — that
// precision collapse is what turned the old grain into structured moiré contours.
float hash12(vec2 p) {
    vec3 p3 = fract(vec3(p.xyx) * 0.1031);
    p3 += dot(p3, p3.yzx + 33.33);
    return fract((p3.x + p3.y) * p3.z);
}

vec4 hook() {
    vec2 p = HOOKED_pos;
    float t = mod(float(frame), 4096.0);   // bounded so the animation stays crisp

    // Organic horizontal instability: a broad waver plus a finer jitter, drifting
    // slowly in opposite directions so it warps and holds a beat rather than sliding.
    float w = vnoise(p.y * 6.0  + t * 0.03) * 0.72
            + vnoise(p.y * 13.0 - t * 0.02) * 0.28;

    // Burst level: slow, calm-biased noise. Mostly ~0 (clean) with occasional swells,
    // decorrelated from the waver so dropouts land on their own rhythm.
    float burst = vnoise(t * 0.025 + 100.0) + 0.5;   // 0..1
    burst = burst * burst;                           // bias toward calm
    float gate = 0.16 + 1.2 * burst;                 // gentle rest, swells on a burst

    p.x += w * WOBBLE * gate;

    // During a burst the signal degrades a little: a touch more chroma fringe and grain.
    float bleed = BLEED * (1.0 + 1.5 * burst);
    float grain = GRAIN * (1.0 + 1.8 * burst);

    // Chroma bleed: pull red left and blue right of the luma.
    vec3 col;
    col.r = HOOKED_tex(vec2(p.x - bleed, p.y)).r;
    col.g = HOOKED_tex(p).g;
    col.b = HOOKED_tex(vec2(p.x + bleed, p.y)).b;

    // Whisper of one-pixel smear (tape bandwidth).
    vec3 smear = (HOOKED_tex(vec2(p.x - HOOKED_pt.x, p.y)).rgb
                + HOOKED_tex(vec2(p.x + HOOKED_pt.x, p.y)).rgb) * 0.5;
    col = mix(col, smear, SMEAR);

    // Tape grain — genuinely per-pixel and animated, no structured moiré.
    float n = hash12(floor(p * HOOKED_size) + vec2(t, t * 1.7));
    col += (n - 0.5) * grain;

    return vec4(col, 1.0);
}
