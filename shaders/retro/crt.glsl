//!HOOK OUTPUT
//!BIND HOOKED
//!DESC 240-MP retro: CRT

// Scanlines plus a soft RGB phosphor-stripe (aperture-grille) mask, applied to the
// final image. Flat tube — the curved variant appends curvature.glsl after this.
#define LINES 320.0       // visible scanlines across the screen height
#define SCAN_DEPTH 0.30   // scanline darkening
#define SCAN_BOOST 0.12   // line-center brightening
#define MASK_DEPTH 0.16   // phosphor-stripe strength (per output column-triad)

vec4 hook() {
    vec4 c = HOOKED_tex(HOOKED_pos);

    // Scanlines.
    float m = 0.5 + 0.5 * cos(HOOKED_pos.y * LINES * 6.28318530718);
    c.rgb *= (1.0 - SCAN_DEPTH * (1.0 - m)) * (1.0 + SCAN_BOOST * m);

    // Aperture grille: each output column favours one phosphor and dims the others,
    // cycling R/G/B every three columns.
    float col = mod(floor(HOOKED_pos.x * HOOKED_size.x), 3.0);
    vec3 mask = vec3(1.0 - MASK_DEPTH);
    if      (col < 1.0) mask.r = 1.0;
    else if (col < 2.0) mask.g = 1.0;
    else                mask.b = 1.0;
    c.rgb *= mask;

    return c;
}
