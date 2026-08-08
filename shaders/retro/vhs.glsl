//!HOOK OUTPUT
//!BIND HOOKED
//!DESC 240-MP retro: VHS

// Composite-tape look: chroma bleed, visible tape grain, and an organic horizontal
// instability. The wobble is value noise (two octaves drifting in opposite
// directions) so it warps the picture rather than shifting it uniformly. A slow,
// calm-biased BURST level gates the amplitude — mostly at rest, swelling into
// occasional dropouts that also nudge the chroma bleed and grain up, so a wobble
// reads as a momentary loss of signal.
#define BLEED  0.0006  // R/B chromatic-aberration fringe
#define SMEAR  0.06    // faint tape softness (luma)
#define CHROMA_SHIFT 0.0010  // colour carried slightly off from luma (trails right)
#define CHROMA_SMEAR 0.0014  // base chroma horizontal softening (low chroma bandwidth)
#define CHROMA_AMT   0.6     // how much shifted/smeared chroma to use
#define CHROMA_JUMP  0.0008  // per-field jump added to the chroma shift
#define CHROMA_TAPS  8       // left-scan steps that accumulate a warm colour's "charge"
#define CHROMA_STEP  0.0016  // distance per scan step (TAPS*STEP ~= max streak reach)
#define CHROMA_BAND  2.0     // longer/stronger warm streak across the tracking band
#define CHROMA_SPILL 2.0     // how strongly an accumulated warm colour spills over darks
#define GRAIN  0.07    // base tape grain (subtle; bursts kick it up)
#define WOBBLE 0.0016  // peak horizontal instability amplitude (fraction of width)
#define BAND_H      0.30   // traveling tracking-bar height (fraction of screen)
#define BAND_AMT    0.06   // tracking-bar brightness lift (subtle)
#define BAND_PERIOD 540.0  // frames per pass (~9s at 60fps; raise if it travels too fast)
#define HS_H      0.012    // head-switching strip height (very thin — ~2-3 lines of 240p)
#define HS_LINES  240.0    // tape vertical resolution — pixelate the strip low-res, not HD
#define HS_CHUNK  16.0     // horizontal colour-chunk blocks across the width
#define HS_DRIFT  0.05     // consistent sideways offset of the strip (~5%; +right / -left)
#define HS_JITTER 0.02     // small per-frame jump around the drift (~+/-2%)
#define DESAT      0.08    // extra overall desaturation (tape colour never fully saturates)
#define SOFTEN     0.12    // extra overall softening (a small 4-tap cross blur)
#define STATIC_AMT  0.60   // max static strength inside an island (varies down per tick)
#define STATIC_AMT_MIN 0.25 // min static strength
#define STATIC_WIN  15.0   // frames per 1/4-second tick (~4/sec @60fps)
#define STATIC_DUTY 0.25   // fraction of each tick the static is on screen (a brief flash)
#define STATIC_START 0.05  // chance a static burst starts on an idle tick
#define STATIC_SUSTAIN 0.50 // chance it sustains once going (short, bursty)
#define STATIC_LINES 1     // thin tracking lines drawn per burst
#define STATIC_THK  0.001  // tracking-line thickness (fraction of screen height)
#define STATIC_ISLE 0.58   // max island threshold — sparsest (varies down per tick)
#define STATIC_ISLE_MIN 0.42 // min island threshold — densest islands
#define GRAINBAND  0.04    // extra grain concentrated in the trouble zones

// 1D value noise in [-0.5, 0.5]: smoothstep-interpolated hash for the wobble.
float vnoise(float x) {
    float i = floor(x);
    float f = fract(x);
    float a = fract(sin(i * 12.9898) * 43758.5453);
    float b = fract(sin((i + 1.0) * 12.9898) * 43758.5453);
    f = f * f * (3.0 - 2.0 * f);
    return mix(a, b, f) - 0.5;
}

// Resolution-independent per-pixel hash (Dave Hoskins). No sin(), so it can't lose
// precision at high pixel coordinates the way sin(dot(pixel,...)) does — that
// precision collapse is what turned the old grain into structured moiré contours.
float hash12(vec2 p) {
    vec3 p3 = fract(vec3(p.xyx) * 0.1031);
    p3 += dot(p3, p3.yzx + 33.33);
    return fract((p3.x + p3.y) * p3.z);
}

// Smooth 2D value noise (bilinear-interpolated hash12) in [0,1] — for soft, natural
// streaks with no hard cell edges.
float vnoise2(vec2 p) {
    vec2 i = floor(p);
    vec2 f = fract(p);
    f = f * f * (3.0 - 2.0 * f);
    float a = hash12(i);
    float b = hash12(i + vec2(1.0, 0.0));
    float c = hash12(i + vec2(0.0, 1.0));
    float d = hash12(i + vec2(1.0, 1.0));
    return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}

vec4 hook() {
    vec2 p = HOOKED_pos;
    float t = mod(float(frame), 4096.0);   // bounded so the animation stays crisp

    // Organic horizontal instability: a broad waver plus a finer jitter, drifting
    // slowly in opposite directions so it warps and holds a beat rather than sliding.
    float w = vnoise(p.y * 6.0  + t * 0.03) * 0.72
            + vnoise(p.y * 13.0 - t * 0.02) * 0.28;

    // Burst level: slow, calm-biased noise. Mostly ~0 (clean) with occasional swells,
    // decorrelated from the waver so dropouts land on their own rhythm.
    float burst = vnoise(t * 0.025 + 100.0) + 0.5;   // 0..1
    burst = burst * burst;                           // bias toward calm
    float gate = 0.08 + 1.28 * burst;                // calmer at rest, same peak on a burst

    p.x += w * WOBBLE * gate;

    // During a burst the signal degrades a little: a touch more chroma fringe and grain.
    float bleed = BLEED * (1.0 + 1.5 * burst);
    float grain = GRAIN * (1.0 + 1.8 * burst);

    // Traveling tracking-bar factor (a "tape crease" / slow brightness beat): a tall,
    // soft band scrolling slowly up the frame — sharp-ish onset at its bottom edge, a
    // gradual fade upward, a quick fade over the top 20%. Computed here so it can also
    // drive extra chroma degradation across the band; the brightness/wash are applied
    // after grain, below. (Flip the sign on `edge` to travel downward.)
    float tb   = mod(float(frame), BAND_PERIOD);         // one loop per pass = seamless wrap
    float edge = fract(-tb / BAND_PERIOD);               // bottom edge, travels upward (~9s/pass)
    float bf   = fract(edge - p.y) / BAND_H;             // 0 at the sharp bottom edge .. 1 at top
    float band = smoothstep(0.0, 0.15, bf)               // soft, diffused bottom edge
               * mix(1.0, 0.35, clamp(bf / 0.8, 0.0, 1.0))  // gradual fade over the lower 80%
               * (1.0 - smoothstep(0.8, 1.0, bf));       // quick fade over the top 20%

    // Chroma bleed: pull red left and blue right of the luma (light R/B aberration).
    vec3 col;
    col.r = HOOKED_tex(vec2(p.x - bleed, p.y)).r;
    col.g = HOOKED_tex(p).g;
    col.b = HOOKED_tex(vec2(p.x + bleed, p.y)).b;

    // Whisper of one-pixel smear (tape bandwidth).
    vec3 smear = (HOOKED_tex(vec2(p.x - HOOKED_pt.x, p.y)).rgb
                + HOOKED_tex(vec2(p.x + HOOKED_pt.x, p.y)).rgb) * 0.5;
    col = mix(col, smear, SMEAR);

    // A little overall softening (tape resolution loss): blend a small 4-tap cross
    // blur so fine detail loses its edge without the picture going muddy.
    vec3 softb = (HOOKED_tex(vec2(p.x - HOOKED_pt.x, p.y)).rgb
                + HOOKED_tex(vec2(p.x + HOOKED_pt.x, p.y)).rgb
                + HOOKED_tex(vec2(p.x, p.y - HOOKED_pt.y)).rgb
                + HOOKED_tex(vec2(p.x, p.y + HOOKED_pt.y)).rgb) * 0.25;
    col = mix(col, softb, SOFTEN);

    // Chroma smear + shift. Base: sharp luma + a softened, shifted, per-field-jumped
    // chroma (the general tape colour softness). On warm/saturated colour it does much
    // more: VHS chroma overloads on a sustained saturated signal, so the smear length
    // scales with how much warm colour runs to the LEFT — a full orange sky streaks
    // dozens of pixels over the black silhouettes in front of it, while a small intense
    // spot spills only a little. Weighted on the source colour (not this pixel) so it
    // shows over blacks, blotchy rather than an even shade, and worse on the band.
    float cjump  = (hash12(vec2(t, 7.0)) - 0.5) * 2.0 * CHROMA_JUMP;   // per-field offset jump
    float cx     = p.x - CHROMA_SHIFT - cjump;
    float ylum   = dot(col, vec3(0.299, 0.587, 0.114));

    // Base general chroma smear/shift (luma kept sharp).
    vec3  csrc   = (HOOKED_tex(vec2(cx - CHROMA_SMEAR, p.y)).rgb
                 +  HOOKED_tex(vec2(cx,                p.y)).rgb
                 +  HOOKED_tex(vec2(cx + CHROMA_SMEAR, p.y)).rgb) / 3.0;
    vec3  target = vec3(ylum) + (csrc - vec3(dot(csrc, vec3(0.299, 0.587, 0.114))));

    // March left, accumulating warm colour and a blotchy "charge". A long run of
    // saturation builds a large charge that streaks far; an isolated spot barely charges.
    float reach   = CHROMA_STEP * (1.0 + CHROMA_BAND * band);   // longer smear across the band
    vec3  warmCol = vec3(0.0);
    float wsum    = 0.0;
    float charge  = 0.0;
    for (int i = 1; i <= CHROMA_TAPS; i++) {
        float d = float(i) * reach;
        vec3  s = HOOKED_tex(vec2(cx - d, p.y)).rgb;
        // Weight saturated reds/oranges only: R - max(G,B) drops yellows (high G) and
        // magentas (high B), and the threshold drops skin / desaturated warm tones — so
        // those don't smear, only deep reds and oranges do.
        float w = smoothstep(0.2, 0.6, s.r - max(s.g, s.b));
        // Smooth 2D-noise streak modulation (soft horizontal-ish bands drifting slowly),
        // so the spill breaks into natural diffused streaks — no hard blocks or bands.
        float streak = 0.4 + 0.6 * vnoise2(vec2((p.x - d) * 8.0 + t * 0.4, p.y * 12.0));
        warmCol += s * w;
        wsum    += w;
        charge  += w * streak;
    }
    warmCol = wsum > 0.0 ? warmCol / wsum : target;
    charge  = clamp(charge / (float(CHROMA_TAPS) * 0.6), 0.0, 1.0);

    // The accumulated warm colour spills its own colour onto darker pixels, so it shows
    // over the blacks; strength scales with the charge (region size) and the brightness gap.
    float srcY  = dot(warmCol, vec3(0.299, 0.587, 0.114));
    float spill = clamp(charge * CHROMA_SPILL * clamp(srcY - ylum + 0.05, 0.0, 1.0), 0.0, 1.0);
    target = mix(target, warmCol, spill);

    col = mix(col, target, CHROMA_AMT);

    // Tape trouble concentrates in two zones: a broad mid / mid-high hump and the
    // bottom edge. Grain rises across the whole frame but heaviest here — the same
    // areas where the static needles (below) pop up.
    float dz      = (p.y - 0.45) / 0.16;
    float midZone = exp(-dz * dz);                       // soft hump, mid..mid-high
    float botZone = smoothstep(0.95, 1.0, p.y);          // bottom ~5%
    float zone    = clamp(0.6 * midZone + botZone, 0.0, 1.0);
    grain += GRAINBAND * zone;                           // grainier in the trouble zones

    // Tape grain — genuinely per-pixel and animated, no structured moiré.
    float n = hash12(floor(p * HOOKED_size) + vec2(t, t * 1.7));
    col += (n - 0.5) * grain;

    // Tracking bar applied: a subtle brightness lift plus a wash-out over the band.
    col *= 1.0 + BAND_AMT * band;                        // brightness lift
    col = mix(col, vec3(dot(col, vec3(0.299, 0.587, 0.114))), 0.14 * band);  // wash-out

    // Static burst timing: a two-state chain per ~1/4-second tick — a STATIC_START
    // chance to begin when idle, building to STATIC_SUSTAIN to hold once going — so
    // static arrives in short bursts. mpv shaders can't keep cross-frame state, so
    // the current state is reconstructed statelessly by replaying the chain over the
    // last several ticks (bursts are short, so a bounded lookback catches where the
    // current one began). Rolled off `frame` so the pattern never repeats on a cycle.
    float seg = floor(float(frame) / STATIC_WIN);
    float ph  = fract(float(frame) / STATIC_WIN);   // position within the current tick
    float stOn = 0.0;
    for (int k = 8; k >= 0; k--)
        stOn = step(hash12(vec2(seg - float(k), 3.0)), mix(STATIC_START, STATIC_SUSTAIN, stOn));

    // Flash only for the first STATIC_DUTY of each tick, so an active tick shows the
    // static as a brief pop rather than holding it for the whole quarter-second.
    if (stOn > 0.5 && ph < STATIC_DUTY) {
        // A few thin, gently-wavy tracking lines, each carrying irregular bright
        // islands of coarse static (VHS dropout on the tracking line). Line heights
        // are biased toward the bottom (head-switch), then the middle, then the top.
        vec2 res = vec2(HS_LINES * HOOKED_size.x / HOOKED_size.y, HS_LINES);
        for (int s = 0; s < STATIC_LINES; s++) {
            float id     = seg * 7.0 + float(s) * 13.0;
            float zpick  = hash12(vec2(id, 8.0));
            float jitter = hash12(vec2(id, 5.0));
            float lineY  = zpick < 0.45 ? (0.86 + 0.12 * jitter)   // bottom (favoured)
                         : zpick < 0.75 ? (0.42 + 0.16 * jitter)   // middle
                                        : (0.03 + 0.10 * jitter);  // top
            lineY += 0.008 * vnoise(p.x * 3.0 + id);               // gentle wave
            float lb = 1.0 - smoothstep(0.0, STATIC_THK, abs(p.y - lineY));
            if (lb <= 0.0) continue;
            // Per-tick strength and island density (each up to its #define ceiling),
            // so no two flashes read the same.
            float amt  = mix(STATIC_AMT_MIN,  STATIC_AMT,  hash12(vec2(id, 71.0)));
            float isle = mix(STATIC_ISLE_MIN, STATIC_ISLE, hash12(vec2(id, 83.0)));
            // Irregular islands: smooth noise along the line gates sparse clumps of
            // varying width; only its peaks turn to static, so the line breaks into
            // organic islands rather than one continuous streak.
            float isl = smoothstep(isle, isle + 0.14, vnoise2(vec2(p.x * 20.0, id + floor(t * 0.5))));
            // Coarse 240p bright static inside an island, flickering per frame.
            float sn = 0.45 + 0.55 * hash12(floor(p * res) + vec2(t, t * 1.7));
            col = mix(col, vec3(sn), lb * isl * amt);
        }
    }

    // Head-switching noise: a very thin strip at the very bottom edge (only ~2-3 lines
    // of a 240p frame) where the head leaves the tape. The picture there is pixelated
    // down to tape resolution (so it stops betraying the source's sharp HD detail),
    // torn into wide chunks that crunch sideways, with the colour going unstable. The
    // effect fades toward the top of the strip, so the top line still reads the video.
    // (Shares the bottom edge with the tracking bar; if that shows at the top instead,
    // this will too — one flip fixes both.)
    float hsw = smoothstep(1.0 - HS_H, 1.0, p.y);        // 0 at the strip's top .. 1 at the very edge
    if (hsw > 0.0) {
        vec2  res   = vec2(HS_LINES * HOOKED_size.x / HOOKED_size.y, HS_LINES);  // square 240p pixels
        float line  = floor(p.y * res.y);                // which tape line
        float chunk = floor(p.x * HS_CHUNK);             // which colour-chunk block
        vec2  key   = vec2(chunk, line);                 // per-chunk, per-line — rows don't match colour
        // Horizontal head-switch offset: a consistent sideways drift plus a small jump
        // that varies PER LINE (and per frame), so each tape line jumps sharply by its
        // own amount — jumbled — instead of the whole strip sliding as one clean cut.
        // Scaled by hsw so it still fades in from the top of the strip.
        float jump  = (hash12(vec2(line, tb)) - 0.5) * 2.0 * HS_JITTER;  // ~+/-2%, per line, per frame
        float shift = (HS_DRIFT + jump) * hsw;           // +HS_DRIFT drifts the picture right
        vec2  uv    = (floor(vec2(p.x - shift, p.y) * res) + 0.5) / res; // sample left -> drifts right
        vec3  base  = HOOKED_tex(vec2(fract(uv.x), uv.y)).rgb;
        // Mild per-block colour wobble — unstable colour, but it's still the real picture.
        vec3  tint  = 0.6 + 0.8 * vec3(hash12(key + 11.0), hash12(key + 23.0), hash12(key + 37.0));
        vec3  hsCol = base * mix(vec3(1.0), tint, 0.25);
        col = mix(col, hsCol, hsw);
    }

    // A touch more overall desaturation — tape colour is never fully saturated.
    col = mix(col, vec3(dot(col, vec3(0.299, 0.587, 0.114))), DESAT);

    return vec4(col, 1.0);
}
