//!HOOK OUTPUT
//!BIND HOOKED
//!DESC 240-MP retro: CRT

// A soft CRT tube: gentle scanlines, a light horizontal bleed/blur, and a mild glow.
// Deliberately NO aperture-grille mask — a hard RGB stripe reads as a screendoor at
// flat-panel resolutions, so the CRT character comes from softening + scanline bloom
// instead. That softness is also what sets it apart from the crisp Scanlines look.
// Flat tube — the curved variant appends curvature.glsl.
#define LINES 320.0       // visible scanlines across the screen height
#define SCAN_DEPTH 0.18   // gentle scanline darkening
#define BLEED 0.30        // horizontal softening/blend (0 = sharp, 1 = very soft)
#define GLOW 0.12         // mild bloom from the neighbourhood

vec4 hook() {
    vec2 p  = HOOKED_pos;
    vec2 px = HOOKED_pt;

    // Horizontal bleed: blend with the immediate neighbours so the picture softens
    // and colours smear slightly — the tube look.
    vec3 c  = HOOKED_tex(p).rgb;
    vec3 cl = HOOKED_tex(p - vec2(px.x, 0.0)).rgb;
    vec3 cr = HOOKED_tex(p + vec2(px.x, 0.0)).rgb;
    c = mix(c, (cl + c + cr) / 3.0, BLEED);

    // Mild glow from a slightly wider neighbourhood so bright areas bloom.
    vec3 glow = HOOKED_tex(p + vec2(px.x * 2.0, 0.0)).rgb
              + HOOKED_tex(p - vec2(px.x * 2.0, 0.0)).rgb;
    c += glow * 0.5 * GLOW;

    // Gentle scanlines.
    float m = 0.5 + 0.5 * cos(p.y * LINES * 6.28318530718);
    c *= (1.0 - SCAN_DEPTH * (1.0 - m));

    return vec4(c, 1.0);
}
