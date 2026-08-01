//!HOOK OUTPUT
//!BIND HOOKED
//!DESC 240-MP retro: VHS

// Subtle composite-tape look: a light chroma bleed, a gentle luma smear, faint
// grain, and a SLOW, LOW-FREQUENCY horizontal drift. The earlier version rippled
// at high frequency every frame ("underwater"); real tape wobble is a few wide,
// slowly-drifting bands — closer to the mpv shmup/vhs reference. Kept restrained:
// tape artefacts read best when they're barely there.
#define BLEED  0.0022  // chroma horizontal offset (fraction of width)
#define SMEAR  0.22    // luma smear blend (limited tape bandwidth)
#define GRAIN  0.020   // additive noise amount
#define WOBBLE 0.0006  // horizontal drift amplitude (fraction of width)
#define WFREQ  5.0     // drift bands down the screen (low = gentle, not a ripple)

vec4 hook() {
    vec2 p = HOOKED_pos;

    // Slow, gentle horizontal drift — a few wide bands, drifting slowly frame to
    // frame (the *0.03 keeps it lazy rather than a fast shimmer).
    p.x += sin(p.y * WFREQ + float(frame) * 0.03) * WOBBLE;

    // Chroma bleed: pull red left and blue right of the luma.
    float r = HOOKED_tex(vec2(p.x - BLEED, p.y)).r;
    float g = HOOKED_tex(p).g;
    float b = HOOKED_tex(vec2(p.x + BLEED, p.y)).b;
    vec3 col = vec3(r, g, b);

    // Gentle one-pixel horizontal smear.
    vec3 smear = (HOOKED_tex(vec2(p.x - HOOKED_pt.x, p.y)).rgb
                + HOOKED_tex(vec2(p.x + HOOKED_pt.x, p.y)).rgb) * 0.5;
    col = mix(col, smear, SMEAR);

    // Faint grain that shifts each frame.
    float n = fract(sin(dot(vec2(p.x, p.y) + float(frame) * 0.013,
                            vec2(12.9898, 78.233))) * 43758.5453);
    col += (n - 0.5) * GRAIN;

    return vec4(col, 1.0);
}
