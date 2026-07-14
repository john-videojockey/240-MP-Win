# get-upscalers.ps1 — download the real-time upscaler GLSL shaders 240-MP's
# "Upscaler" selector uses, into shaders/upscalers/. Run once; safe to re-run.
#
#   .\scripts\get-upscalers.ps1
#
# All shaders are open-source (see shaders/upscalers/README.md). A failed download
# just warns and prints the manual URL — the app still runs, that option simply
# won't upscale until its file is present.

$ErrorActionPreference = 'Continue'
$dest = Join-Path $PSScriptRoot '..\shaders\upscalers'
New-Item -ItemType Directory -Force -Path $dest | Out-Null

function Get-Shader($url, $name) {
    $out = Join-Path $dest $name
    try {
        Invoke-WebRequest -Uri $url -OutFile $out -UseBasicParsing
        Write-Host "  [ok]   $name"
    } catch {
        Write-Warning "  [fail] $name"
        Write-Warning "         grab manually: $url"
    }
}

Write-Host "ArtCNN (recommended)..."
Get-Shader 'https://raw.githubusercontent.com/Artoriuz/ArtCNN/main/GLSL/ArtCNN_C4F32.glsl' 'ArtCNN_C4F32.glsl'

Write-Host "FSRCNNX..."
Get-Shader 'https://raw.githubusercontent.com/igv/FSRCNN-TensorFlow/master/FSRCNNX_x2_8-0-4-1.glsl' 'FSRCNNX_x2_8-0-4-1.glsl'

Write-Host "Anime4K (release zip)..."
$zip     = Join-Path $env:TEMP 'Anime4K_v4.zip'
$extract = Join-Path $env:TEMP 'Anime4K_v4'
$need = @(
    'Anime4K_Clamp_Highlights.glsl',
    'Anime4K_Restore_CNN_M.glsl',
    'Anime4K_Upscale_CNN_x2_M.glsl',
    'Anime4K_AutoDownscalePre_x2.glsl',
    'Anime4K_AutoDownscalePre_x4.glsl',
    'Anime4K_Upscale_CNN_x2_S.glsl'
)
try {
    Invoke-WebRequest -Uri 'https://github.com/bloc97/Anime4K/releases/download/v4.0.1/Anime4K_v4.0.zip' -OutFile $zip -UseBasicParsing
    if (Test-Path $extract) { Remove-Item -Recurse -Force $extract }
    Expand-Archive -Path $zip -DestinationPath $extract -Force
    foreach ($f in $need) {
        $src = Get-ChildItem -Recurse -Path $extract -Filter $f | Select-Object -First 1
        if ($src) { Copy-Item $src.FullName (Join-Path $dest $f) -Force; Write-Host "  [ok]   $f" }
        else      { Write-Warning "  [missing in zip] $f" }
    }
    Remove-Item -Force $zip -ErrorAction SilentlyContinue
    Remove-Item -Recurse -Force $extract -ErrorAction SilentlyContinue
} catch {
    Write-Warning "  [fail] Anime4K release zip — grab from https://github.com/bloc97/Anime4K/releases"
}

Write-Host ""
Write-Host "Done. Shaders in: $dest"
Write-Host "Pick one in a movie/episode's info screen -> Upscaler row."
