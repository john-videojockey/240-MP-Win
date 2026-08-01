//!HOOK OUTPUT
//!BIND HOOKED
//!DESC 240-MP retro: Heavy CRT

// Beefier CRT: the soft-tube base (bleed + glow) with a lighter scanline than before
// and everything else leaned into — a strong glow, a deeper vignette, and a touch of
// phosphor grain. No hard shadow mask (that reads as a screendoor). Heavier (glow
// taps + grain), so it is grouped with the high-cost filters.
#define LINES 320.0
#define SCAN_DEPTH 0.30   // lighter scanline (was 0.40) — lean on the other effects
#define BLEED 0.30        // horizontal softening/blend
#define GLOW 0.34         // strong bloom
#define VIGNETTE 0.48     // deep tube vignette
#define GRAIN 0.035       // subtle phosphor grain
#define CA 0.004          // radial chromatic aberration (R/B split, grows to the edges)
#define BRIGHTNESS 0.92   // overall level trimmed a notch

vec4 hook() {
    vec2 p  = HOOKED_pos;
    vec2 px = HOOKED_pt;
    float t = mod(float(frame), 2048.0);

    vec2 v = p - 0.5;
    float r2 = dot(v, v);   // 0 at centre, ~0.5 in the corners

    // Base sample with radial chromatic aberration: R/B split outward from the centre,
    // stronger toward the edges (convergence error). Then a horizontal bleed softens.
    vec2 ca = v * CA;
    vec3 c;
    c.r = HOOKED_tex(p + ca).r;
    c.g = HOOKED_tex(p).g;
    c.b = HOOKED_tex(p - ca).b;
    vec3 cl = HOOKED_tex(p - vec2(px.x, 0.0)).rgb;
    vec3 cr = HOOKED_tex(p + vec2(px.x, 0.0)).rgb;
    c = mix(c, (cl + c + cr) / 3.0, BLEED);

    // Phosphor glow: a soft cross neighbourhood so bright areas bloom, weighted a
    // little stronger toward the centre of the tube.
    vec2 s = px * 2.0;
    vec3 glow = HOOKED_tex(p + vec2( s.x, 0.0)).rgb + HOOKED_tex(p + vec2(-s.x, 0.0)).rgb
              + HOOKED_tex(p + vec2(0.0,  s.y)).rgb + HOOKED_tex(p + vec2(0.0, -s.y)).rgb;
    float centreBoost = 1.0 + 0.20 * (1.0 - r2 * 2.0);   // ~1.2 centre, ~1.0 corners
    c += glow * 0.25 * GLOW * centreBoost;

    // Lighter scanlines.
    float m = 0.5 + 0.5 * cos(p.y * LINES * 6.28318530718);
    c *= (1.0 - SCAN_DEPTH * (1.0 - m));

    // Subtle phosphor grain (per-pixel, animated).
    float n = fract(sin(dot(p * HOOKED_size + t, vec2(12.9898, 78.233))) * 43758.5453);
    c += (n - 0.5) * GRAIN;

    // Deep tube vignette.
    c *= 1.0 - VIGNETTE * r2 * 2.0;

    // Overall level trimmed a notch.
    c *= BRIGHTNESS;

    return vec4(c, 1.0);
}
