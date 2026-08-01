//!HOOK OUTPUT
//!BIND HOOKED
//!DESC 240-MP retro: VHS

// Composite-tape look: horizontal chroma bleed, a soft luma smear, faint per-line
// tape wobble and moving grain. Applied to the final image, so subtitles/OSD (drawn
// by the VO on top of OUTPUT) stay crisp.
#define BLEED  0.004   // chroma horizontal offset (fraction of width)
#define SOFT   0.0016  // luma smear half-width
#define WOBBLE 0.0009  // per-line horizontal jitter amplitude
#define GRAIN  0.045   // additive noise amount

vec4 hook() {
    vec2 p = HOOKED_pos;

    // Tape wobble: each scanline nudged horizontally, drifting frame to frame.
    p.x += sin(p.y * 140.0 + float(frame) * 0.20) * WOBBLE;

    // Chroma bleed: pull red left and blue right of the luma.
    float r = HOOKED_tex(vec2(p.x - BLEED, p.y)).r;
    float g = HOOKED_tex(p).g;
    float b = HOOKED_tex(vec2(p.x + BLEED, p.y)).b;
    vec3 col = vec3(r, g, b);

    // Soft horizontal smear (limited tape bandwidth).
    vec3 smear = (HOOKED_tex(vec2(p.x - SOFT, p.y)).rgb
                + HOOKED_tex(vec2(p.x + SOFT, p.y)).rgb) * 0.5;
    col = mix(col, smear, 0.40);

    // Grain that shifts each frame.
    float n = fract(sin(dot(vec2(p.x, p.y) + float(frame) * 0.013,
                            vec2(12.9898, 78.233))) * 43758.5453);
    col += (n - 0.5) * GRAIN;

    return vec4(col, 1.0);
}
