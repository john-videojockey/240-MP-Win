//!HOOK OUTPUT
//!BIND HOOKED
//!DESC 240-MP retro: Heavy CRT

// Beefier CRT: the same soft-tube base as crt.glsl (bleed + glow) but with deeper
// scanlines, a much stronger glow and a tube vignette. Like CRT it has NO hard
// shadow mask (that reads as a screendoor). Heavier (more glow taps), so it is
// grouped with the high-cost filters.
#define LINES 320.0
#define SCAN_DEPTH 0.40   // deeper scanlines than the plain CRT
#define BLEED 0.30        // horizontal softening/blend
#define GLOW 0.28         // strong bloom
#define VIGNETTE 0.24

vec4 hook() {
    vec2 p  = HOOKED_pos;
    vec2 px = HOOKED_pt;

    // Horizontal bleed (tube softness).
    vec3 c  = HOOKED_tex(p).rgb;
    vec3 cl = HOOKED_tex(p - vec2(px.x, 0.0)).rgb;
    vec3 cr = HOOKED_tex(p + vec2(px.x, 0.0)).rgb;
    c = mix(c, (cl + c + cr) / 3.0, BLEED);

    // Phosphor glow: a soft cross neighbourhood so bright areas bloom.
    vec2 s = px * 2.0;
    vec3 glow = HOOKED_tex(p + vec2( s.x, 0.0)).rgb + HOOKED_tex(p + vec2(-s.x, 0.0)).rgb
              + HOOKED_tex(p + vec2(0.0,  s.y)).rgb + HOOKED_tex(p + vec2(0.0, -s.y)).rgb;
    c += glow * 0.25 * GLOW;

    // Deep scanlines.
    float m = 0.5 + 0.5 * cos(p.y * LINES * 6.28318530718);
    c *= (1.0 - SCAN_DEPTH * (1.0 - m));

    // Tube vignette.
    vec2 v = p - 0.5;
    c *= 1.0 - VIGNETTE * dot(v, v) * 2.0;

    return vec4(c, 1.0);
}
