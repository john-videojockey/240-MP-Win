//!HOOK OUTPUT
//!BIND HOOKED
//!DESC 240-MP retro: scanlines

// Horizontal scanlines applied to the final image (OUTPUT hook, so it lands after
// any upscaler and never touches subtitles/OSD, which the VO draws on top).
//
// The line count is fixed rather than one-per-output-row: at 1080p+ a per-row
// pattern is invisible, so we lay down a constant number of visible lines across
// the height regardless of resolution. Tunable by eye.
#define LINES 320.0   // visible scanlines across the screen height
#define DEPTH 0.28    // 0..1 darkening in the gaps between lines
#define BOOST 0.12    // brighten line centers so the picture isn't just dimmed

vec4 hook() {
    vec4 c = HOOKED_tex(HOOKED_pos);
    // m: 1.0 at a line center, 0.0 midway between lines.
    float m = 0.5 + 0.5 * cos(HOOKED_pos.y * LINES * 6.28318530718);
    float gain = (1.0 - DEPTH * (1.0 - m)) * (1.0 + BOOST * m);
    c.rgb *= gain;
    return c;
}
