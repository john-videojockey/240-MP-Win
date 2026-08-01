//!HOOK OUTPUT
//!BIND HOOKED
//!DESC 240-MP retro: Heavy CRT

// A beefier CRT: the same soft-tube base as crt.glsl (bleed + glow + gentle mask)
// but with deeper scanlines, a stronger glow and a tube vignette. The shadow mask
// is still kept modest — depth, not screendoor. Heavier (extra glow taps), so it
// is grouped with the high-cost filters.
#define LINES 320.0
#define SCAN_DEPTH 0.38   // deeper scanlines than the plain CRT
#define BLEED 0.30        // horizontal softening/blend
#define MASK_DEPTH 0.16   // modest phosphor tint (was a screendoor at 0.34)
#define PHOSPHOR 2.0
#define GLOW 0.22
#define VIGNETTE 0.22

vec4 hook() {
    vec2 p  = HOOKED_pos;
    vec2 px = HOOKED_pt;

    // Horizontal bleed (tube softness).
    vec3 c  = HOOKED_tex(p).rgb;
    vec3 cl = HOOKED_tex(p - vec2(px.x, 0.0)).rgb;
    vec3 cr = HOOKED_tex(p + vec2(px.x, 0.0)).rgb;
    c = mix(c, (cl + c + cr) / 3.0, BLEED);

    // Phosphor glow: a soft neighbourhood so bright areas bloom.
    vec2 s = px * 2.0;
    vec3 glow = HOOKED_tex(p + vec2( s.x, 0.0)).rgb + HOOKED_tex(p + vec2(-s.x, 0.0)).rgb
              + HOOKED_tex(p + vec2(0.0,  s.y)).rgb + HOOKED_tex(p + vec2(0.0, -s.y)).rgb;
    c += glow * 0.25 * GLOW;

    // Deep scanlines.
    float m = 0.5 + 0.5 * cos(p.y * LINES * 6.28318530718);
    c *= (1.0 - SCAN_DEPTH * (1.0 - m));

    // Modest aperture-grille tint with brightness compensation.
    float cell = mod(floor(p.x * HOOKED_size.x / PHOSPHOR), 3.0);
    vec3 mask = vec3(1.0 - MASK_DEPTH);
    if      (cell < 1.0) mask.r = 1.0;
    else if (cell < 2.0) mask.g = 1.0;
    else                 mask.b = 1.0;
    c *= mask * (1.0 + MASK_DEPTH * 0.5);

    // Tube vignette.
    vec2 v = p - 0.5;
    c *= 1.0 - VIGNETTE * dot(v, v) * 2.0;

    return vec4(c, 1.0);
}
