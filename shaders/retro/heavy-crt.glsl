//!HOOK OUTPUT
//!BIND HOOKED
//!DESC 240-MP retro: Heavy CRT

// A fuller CRT: soft phosphor glow, deep scanlines, a strong aperture-grille mask
// and a gentle tube vignette. Heavier than the plain CRT look (extra glow taps), so
// it is grouped with the high-cost filters. Runs on the final image.
#define LINES 320.0
#define SCAN_DEPTH 0.42
#define SCAN_BOOST 0.15
#define MASK_DEPTH 0.34
#define PHOSPHOR 2.0
#define GLOW 0.22
#define VIGNETTE 0.22

vec4 hook() {
    vec2 p = HOOKED_pos;
    vec3 c = HOOKED_tex(p).rgb;

    // Phosphor glow: add a soft neighbourhood so bright areas bloom.
    vec2 s = HOOKED_pt * 2.0;
    vec3 glow = HOOKED_tex(p + vec2( s.x, 0.0)).rgb + HOOKED_tex(p + vec2(-s.x, 0.0)).rgb
              + HOOKED_tex(p + vec2(0.0,  s.y)).rgb + HOOKED_tex(p + vec2(0.0, -s.y)).rgb;
    c += glow * 0.25 * GLOW;

    // Deep scanlines.
    float m = 0.5 + 0.5 * cos(p.y * LINES * 6.28318530718);
    c *= (1.0 - SCAN_DEPTH * (1.0 - m)) * (1.0 + SCAN_BOOST * m);

    // Strong aperture grille with brightness compensation.
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
