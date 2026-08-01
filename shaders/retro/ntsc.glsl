//!HOOK OUTPUT
//!BIND HOOKED
//!DESC 240-MP retro: NTSC

// Composite-video look done in YIQ, NTSC's native colour encoding. The signature
// NTSC trait — "Never The Same Color" — is a hue error from the colour subcarrier's
// phase rotating in transmission; in YIQ that is literally a rotation of the (I,Q)
// vector, and scaling it changes saturation. I carries more bandwidth than Q, so
// chroma is band-limited with Q softer than I. Steps: RGB->YIQ, sharp luma + blurred
// chroma, rotate hue, desaturate a touch, YIQ->RGB, then a dot-crawl shimmer keyed to
// where colour is. Heavier than the CRT looks. Runs on the final image (subs crisp).
#define BLEED 0.0015  // chroma sample spacing — band-limits I/Q (Q wider than I)
#define HUE  -0.24    // chroma phase rotation, radians — negative drifts colours toward blue/green
#define SAT   0.86    // chroma scale — the slight NTSC desaturation
#define WARM  0.06    // warm white-point cast (lift red / drop blue; 0 = neutral)
#define CRAWL 0.03    // dot-crawl shimmer along colour edges

vec3 rgb2yiq(vec3 c) {
    return vec3(dot(c, vec3(0.299,  0.587,  0.114)),
                dot(c, vec3(0.596, -0.274, -0.322)),
                dot(c, vec3(0.211, -0.523,  0.312)));
}
vec3 yiq2rgb(vec3 v) {
    return vec3(v.x + 0.956 * v.y + 0.621 * v.z,
                v.x - 0.272 * v.y - 0.647 * v.z,
                v.x - 1.106 * v.y + 1.703 * v.z);
}

vec4 hook() {
    vec2 p = HOOKED_pos;
    float dx = BLEED;

    vec3 c  = rgb2yiq(HOOKED_tex(p).rgb);
    vec3 l  = rgb2yiq(HOOKED_tex(vec2(p.x - dx,       p.y)).rgb);
    vec3 r  = rgb2yiq(HOOKED_tex(vec2(p.x + dx,       p.y)).rgb);
    vec3 l2 = rgb2yiq(HOOKED_tex(vec2(p.x - 2.0 * dx, p.y)).rgb);
    vec3 r2 = rgb2yiq(HOOKED_tex(vec2(p.x + 2.0 * dx, p.y)).rgb);

    float Y = c.x;                                        // sharp luma (broadband)
    float I = (l.y + c.y + r.y) / 3.0;                    // I: moderate bandwidth
    float Q = (l2.z + l.z + c.z + r.z + r2.z) / 5.0;      // Q: narrower bandwidth

    // Hue rotation (phase error) + slight desaturation.
    float ca = cos(HUE), sa = sin(HUE);
    float Ir = (I * ca - Q * sa) * SAT;
    float Qr = (I * sa + Q * ca) * SAT;

    vec3 col = yiq2rgb(vec3(Y, Ir, Qr));

    // Warm white-point cast (aged NTSC sets ran warm): lift red, drop blue. The hue
    // rotation above drifts saturated colours toward green; this warms the overall
    // tone on top of it.
    col *= vec3(1.0 + WARM, 1.0, 1.0 - WARM);

    // Dot crawl: a moving shimmer wherever there is chroma (subcarrier bleeding into
    // luma), which is exactly where composite dot crawl appears.
    float phase = p.x * HOOKED_size.x * 0.5
                + p.y * HOOKED_size.y * 3.14159265
                + float(frame);
    col += sin(phase) * CRAWL * length(vec2(Ir, Qr));

    return vec4(col, 1.0);
}
