//!HOOK OUTPUT
//!BIND HOOKED
//!DESC 240-MP retro: CRT

// Scanlines plus a soft RGB phosphor-stripe (aperture-grille) mask, applied to the
// final image. Flat tube — the curved variant appends curvature.glsl after this.
// CRT leans on its phosphor mask (bolder than the plain Scanlines look) and keeps
// its own scanline gentle, so the two looks read distinctly from each other.
#define LINES 320.0       // visible scanlines across the screen height
#define SCAN_DEPTH 0.20   // scanline darkening (kept gentle — the mask is the star)
#define SCAN_BOOST 0.10   // line-center brightening
#define MASK_DEPTH 0.30   // phosphor-stripe strength
#define PHOSPHOR 2.0      // output pixels per phosphor stripe (wider = more visible)

vec4 hook() {
    vec4 c = HOOKED_tex(HOOKED_pos);

    // Scanlines.
    float m = 0.5 + 0.5 * cos(HOOKED_pos.y * LINES * 6.28318530718);
    c.rgb *= (1.0 - SCAN_DEPTH * (1.0 - m)) * (1.0 + SCAN_BOOST * m);

    // Aperture grille: each PHOSPHOR-wide stripe favours one channel and dims the
    // others, cycling R/G/B. A little overall gain compensates for the darkening so
    // the mask adds visible texture rather than just dimming the picture.
    float cell = mod(floor(HOOKED_pos.x * HOOKED_size.x / PHOSPHOR), 3.0);
    vec3 mask = vec3(1.0 - MASK_DEPTH);
    if      (cell < 1.0) mask.r = 1.0;
    else if (cell < 2.0) mask.g = 1.0;
    else                 mask.b = 1.0;
    c.rgb *= mask * (1.0 + MASK_DEPTH * 0.5);

    return c;
}
