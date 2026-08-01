//!HOOK OUTPUT
//!BIND HOOKED
//!DESC 240-MP retro: VHS

// Composite-tape look: a light chroma bleed, a slow low-frequency horizontal drift,
// and — the point of the look — visible tape GRAIN. The earlier version was soft and
// glossy because the smear dominated and the grain was both too weak and hashed in
// normalised coords (so it came out smooth). Grain is now strong and hashed in true
// pixel coordinates; the smear is only a whisper so it reads as noise, not gloss.
#define BLEED  0.0022  // chroma horizontal offset (fraction of width)
#define SMEAR  0.08    // faint tape softness (kept low — was glossy at 0.22)
#define GRAIN  0.07    // visible tape grain
#define WOBBLE 0.0006  // horizontal drift amplitude (fraction of width)
#define WFREQ  5.0     // drift bands down the screen (low = gentle, not a ripple)

vec4 hook() {
    vec2 p = HOOKED_pos;
    float t = mod(float(frame), 2048.0);   // bounded so the animation stays crisp

    // Slow, gentle horizontal drift — a few wide bands, drifting lazily.
    p.x += sin(p.y * WFREQ + t * 0.03) * WOBBLE;

    // Chroma bleed: pull red left and blue right of the luma.
    float r = HOOKED_tex(vec2(p.x - BLEED, p.y)).r;
    float g = HOOKED_tex(p).g;
    float b = HOOKED_tex(vec2(p.x + BLEED, p.y)).b;
    vec3 col = vec3(r, g, b);

    // Whisper of one-pixel smear (tape bandwidth) — not enough to gloss it over.
    vec3 smear = (HOOKED_tex(vec2(p.x - HOOKED_pt.x, p.y)).rgb
                + HOOKED_tex(vec2(p.x + HOOKED_pt.x, p.y)).rgb) * 0.5;
    col = mix(col, smear, SMEAR);

    // Tape grain — hashed in pixel coords + frame so it's genuinely per-pixel and
    // animates. This is what should read as "grainy" rather than soft.
    float n = fract(sin(dot(p * HOOKED_size + t, vec2(12.9898, 78.233))) * 43758.5453);
    col += (n - 0.5) * GRAIN;

    return vec4(col, 1.0);
}
