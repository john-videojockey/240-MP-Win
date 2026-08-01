//!HOOK OUTPUT
//!BIND HOOKED
//!DESC 240-MP retro: NTSC

// Simplified composite-video look: sharp luma with band-limited (blurred) chroma,
// plus a shimmering dot-crawl along luma/chroma edges. A single-pass approximation
// of NTSC encode/decode artefacts — heavier than the CRT looks. Runs on the final
// image after the upscaler; subtitles/OSD are untouched.
#define BLEED 0.006   // chroma bandwidth (how far colour smears)
#define CRAWL 0.05    // dot-crawl strength

vec4 hook() {
    vec2 p = HOOKED_pos;

    vec3 c0 = HOOKED_tex(p).rgb;
    vec3 cl = HOOKED_tex(vec2(p.x - BLEED, p.y)).rgb;
    vec3 cr = HOOKED_tex(vec2(p.x + BLEED, p.y)).rgb;

    // Sharp luma, band-limited chroma: keep this pixel's brightness but average the
    // colour across the horizontal neighbourhood.
    vec3 luma = vec3(0.299, 0.587, 0.114);
    float y0 = dot(c0, luma);
    vec3 chroma = (cl + c0 + cr) / 3.0;
    vec3 col = chroma + (y0 - dot(chroma, luma));

    // Dot crawl: a moving pattern along edges where luma and chroma disagree.
    float phase = p.x * HOOKED_size.x * 0.5
                + p.y * HOOKED_size.y * 3.14159265
                + float(frame);
    col += sin(phase) * CRAWL * (c0 - chroma);

    return vec4(col, 1.0);
}
