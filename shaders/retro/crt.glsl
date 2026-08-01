//!HOOK OUTPUT
//!BIND HOOKED
//!DESC 240-MP retro: CRT

// A soft CRT tube. Modeled on crt-pi's philosophy: the "CRT feel" comes from a
// light horizontal bleed/blur and gentle scanline bloom, NOT a hard shadow mask.
// The phosphor tint is kept to a whisper so it reads as colour warmth rather than
// a screendoor grille. Flat tube — the curved variant appends curvature.glsl.
#define LINES 320.0       // visible scanlines across the screen height
#define SCAN_DEPTH 0.18   // gentle scanline darkening
#define BLEED 0.30        // horizontal softening/blend (0 = sharp, 1 = very soft)
#define GLOW 0.10         // mild bloom from the neighbourhood
#define MASK_DEPTH 0.10   // whisper of phosphor tint (deliberately low — no grid)
#define PHOSPHOR 2.0      // output pixels per phosphor stripe

vec4 hook() {
    vec2 p  = HOOKED_pos;
    vec2 px = HOOKED_pt;

    // Horizontal bleed: blend with the immediate neighbours so the picture softens
    // and colours smear slightly — the tube look, and what blends the phosphor tint.
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

    // Whisper of aperture-grille tint (low depth + the bleed above blends it, so it
    // colours the image rather than laying down a hard stripe pattern).
    float cell = mod(floor(p.x * HOOKED_size.x / PHOSPHOR), 3.0);
    vec3 mask = vec3(1.0 - MASK_DEPTH);
    if      (cell < 1.0) mask.r = 1.0;
    else if (cell < 2.0) mask.g = 1.0;
    else                 mask.b = 1.0;
    c *= mask * (1.0 + MASK_DEPTH * 0.5);

    return vec4(c, 1.0);
}
