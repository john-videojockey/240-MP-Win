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
#define BAND_H      0.30   // traveling tracking-bar height (fraction of screen)
#define BAND_AMT    0.06   // tracking-bar brightness lift (subtle)
#define BAND_PERIOD 540.0  // frames per pass (~9s at 60fps; raise if it travels too fast)
#define HS_H     0.012     // head-switching strip height (very thin — ~2-3 lines of 240p)
#define HS_CHUNK 32.0      // horizontal blocks across the width (pixelated colour chunks)
#define HS_ROWS  3.0       // independent rows within the strip (so rows don't share colour)
#define HS_TEAR  0.08      // per-block sideways crunch amplitude

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

    // Traveling tracking bar (a "tape crease" / slow brightness beat): a tall, soft
    // band that scrolls slowly up the frame. Sharp-ish onset at its bottom edge, a
    // gradual fade upward, then a quick fade-out over the top 20% — matching how the
    // real artefact looks. Very subtle. (Flip the sign on `edge` to travel downward.)
    float tb   = mod(float(frame), BAND_PERIOD);         // one loop per pass = seamless wrap
    float edge = fract(-tb / BAND_PERIOD);               // bottom edge, travels upward (~9s/pass)
    float f    = fract(edge - p.y) / BAND_H;             // 0 at the sharp bottom edge .. 1 at top
    float onset = smoothstep(0.0, 0.15, f);              // soft, diffused bottom edge
    float fade  = mix(1.0, 0.35, clamp(f / 0.8, 0.0, 1.0)); // gradual fade over the lower 80%
    float tail  = 1.0 - smoothstep(0.8, 1.0, f);         // quick fade over the top 20%
    float band  = onset * fade * tail;                   // 0 everywhere outside the band
    col *= 1.0 + BAND_AMT * band;                        // brightness lift
    col = mix(col, vec3(dot(col, vec3(0.299, 0.587, 0.114))), 0.14 * band);  // wash-out

    // Head-switching noise: a very thin strip at the very bottom edge (only ~2-3 lines
    // of a 240p frame) where the head leaves the tape. The picture there breaks into
    // wide horizontal colour chunks that crunch sideways, concentrated hard at the very
    // edge. (Shares the bottom edge with the tracking bar; if that shows at the top
    // instead, this will too — one flip fixes both.)
    float hsw = smoothstep(1.0 - HS_H, 1.0, p.y);        // 0 above the strip .. 1 at the very edge
    if (hsw > 0.0) {
        // Dice the thin strip into coarse blocks (pixelated), each an independent tape
        // fragment — so adjacent rows and columns don't share colour and it reads hard-
        // edged rather than a smooth rainbow smear.
        float rowf = (p.y - (1.0 - HS_H)) / HS_H;                    // 0..1 down the strip
        vec2  bi   = floor(vec2(p.x * HS_CHUNK, rowf * HS_ROWS));    // block (col, row) index
        float cs   = (hash12(bi + vec2(tb, tb * 1.7)) - 0.5) * HS_TEAR * hsw;  // per-block crunch
        float sx   = (bi.x + 0.5) / HS_CHUNK + cs;                   // snapped x (+crunch) = pixelated
        float sy   = (1.0 - HS_H) + (bi.y + 0.5) / HS_ROWS * HS_H;   // snapped y (per-row)
        vec3  base = HOOKED_tex(vec2(fract(sx), sy)).rgb;
        // Blocky, hard-edged colour corruption per block (no smooth channel split, so
        // no rainbow banding) — each block a different wrong colour.
        vec3  corrupt = vec3(hash12(bi + 11.0), hash12(bi + 23.0), hash12(bi + 37.0));
        vec3  hsCol   = mix(base, base * (0.4 + 1.6 * corrupt), 0.6);
        col = mix(col, hsCol, hsw);
    }

    return vec4(col, 1.0);
}
