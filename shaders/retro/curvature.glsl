//!HOOK OUTPUT
//!BIND HOOKED
//!DESC 240-MP retro: curvature

// Subtle CRT-tube barrel warp, appended AFTER a base look so it curves the already
// shaded image. Supersampled (SSxSS) so warping the base look's fine detail
// (scanlines, grain) is antialiased instead of beating into faint curved moiré
// lines — those showed up mid-quadrant, exposed where bright sits against black.
// Samples outside the tube contribute black, so the edge is soft (antialiased) too.
#define CURVE 0.10   // 0 = flat; larger = more pronounced bulge
#define SS    3      // supersample grid (SS*SS taps per output pixel)

vec4 hook() {
    vec3 acc = vec3(0.0);
    for (int j = 0; j < SS; j++)
    for (int i = 0; i < SS; i++) {
        // Sub-pixel offset spanning the output pixel footprint (-0.5..0.5 px).
        vec2 o  = ((vec2(float(i), float(j)) + 0.5) / float(SS) - 0.5) * HOOKED_pt;
        vec2 uv = (HOOKED_pos + o) * 2.0 - 1.0;   // center to -1..1
        vec2 off = abs(uv.yx) * CURVE;
        uv += uv * off * off;                     // barrel distortion
        vec2 s = uv * 0.5 + 0.5;                  // back to 0..1
        if (s.x >= 0.0 && s.x <= 1.0 && s.y >= 0.0 && s.y <= 1.0)
            acc += HOOKED_tex(s).rgb;             // outside the tube contributes black
    }
    return vec4(acc / float(SS * SS), 1.0);
}
