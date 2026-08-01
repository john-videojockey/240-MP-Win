//!HOOK OUTPUT
//!BIND HOOKED
//!DESC 240-MP retro: curvature

// Subtle CRT-tube barrel warp, appended AFTER a base look so it curves the already
// shaded image. Samples outside the tube read black. Kept gentle for a media player.
#define CURVE 0.10   // 0 = flat; larger = more pronounced bulge

vec4 hook() {
    vec2 uv = HOOKED_pos * 2.0 - 1.0;         // center to -1..1
    vec2 off = abs(uv.yx) * CURVE;
    uv += uv * off * off;                     // barrel distortion
    vec2 s = uv * 0.5 + 0.5;                  // back to 0..1
    if (s.x < 0.0 || s.x > 1.0 || s.y < 0.0 || s.y > 1.0)
        return vec4(0.0, 0.0, 0.0, 1.0);      // outside the curved tube
    return HOOKED_tex(s);
}
