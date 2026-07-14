# Upscaler shaders

Real-time upscaler GLSL shaders used by the **Upscaler** row on a movie/episode's
info screen. They run through mpv's `gpu-next` video output, so they work on any
GPU (AMD/Intel/NVIDIA) — no CUDA/TensorRT.

## Getting the files

Run once from the repo root:

```powershell
.\scripts\get-upscalers.ps1
```

This downloads the shaders below into this folder. The **Off** and **Built-in HQ**
upscaler options need no files. If a shader file is missing, mpv logs a warning and
plays without it — so a not-yet-downloaded option just means "no upscaling" until
you fetch it.

## The shaders

| Upscaler option | File(s) | Source (license) |
|---|---|---|
| **ArtCNN** (recommended) | `ArtCNN_C4F32.glsl` | [Artoriuz/ArtCNN](https://github.com/Artoriuz/ArtCNN) (MIT) |
| **FSRCNNX** | `FSRCNNX_x2_16-0-4-1.glsl` | [igv/FSRCNN-TensorFlow](https://github.com/igv/FSRCNN-TensorFlow) (MIT) |
| **Anime4K** (Mode A, Fast) | `Anime4K_Clamp_Highlights.glsl`, `Anime4K_Restore_CNN_M.glsl`, `Anime4K_Upscale_CNN_x2_M.glsl`, `Anime4K_AutoDownscalePre_x2.glsl`, `Anime4K_AutoDownscalePre_x4.glsl`, `Anime4K_Upscale_CNN_x2_S.glsl` | [bloc97/Anime4K](https://github.com/bloc97/Anime4K) (MIT) |

## Which to pick

- **ArtCNN** — best all-round real-time luma upscaler; great for HD anime and holds
  up on live-action. Start here.
- **FSRCNNX** — "pure" scaling with no art alteration; pick it if you dislike the ML
  "oil-painting" look.
- **Anime4K** — strongest on **SD / low-quality / heavily-compressed** anime
  (artifact removal + line reconstruction); can over-process true 1080p.
- **Built-in HQ** — mpv's `ewa_lanczossharp` + sigmoid; no download, mild boost.

These files are not committed to the repo (they're fetched on demand); only this
README is tracked.
