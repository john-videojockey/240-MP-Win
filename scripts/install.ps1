<#
.SYNOPSIS
    Installs (or updates, or removes) 240-MP on Windows.

.DESCRIPTION
    Downloads the latest 240-MP release zip from GitHub, installs it to a
    per-user folder (no admin rights needed), creates a Start Menu shortcut,
    and installs the runtime helpers it uses — mpv (playback), yt-dlp (YouTube)
    and ffmpeg (Local Files extra thumbnails) — via winget/scoop/choco if missing.

    One-liner (PowerShell):
        irm https://github.com/john-videojockey/240-MP-Win/releases/latest/download/install.ps1 | iex

    Or with options:
        .\install.ps1 -Autostart          # also start 240-MP at logon
        .\install.ps1 -SkipDeps           # don't touch mpv/yt-dlp
        .\install.ps1 -SkipUpscalers      # don't download the upscaler shaders
        .\install.ps1 -Uninstall          # remove app + shortcuts (keeps settings)

.NOTES
    Install location: %LOCALAPPDATA%\Programs\240-MP  (user-writable, which is
    what lets the in-app self-updater swap the folder without elevation).
    Settings live separately in %APPDATA%\240-MP and survive install/uninstall.
#>
[CmdletBinding()]
param(
    [string]$InstallDir = "$env:LOCALAPPDATA\Programs\240-MP",
    [string]$Repo = 'john-videojockey/240-MP-Win',
    [switch]$Autostart,
    [switch]$SkipDeps,
    [switch]$SkipUpscalers,
    [switch]$NoShortcut,
    [switch]$Uninstall
)

$ErrorActionPreference = 'Stop'
$startMenuLnk = [Environment]::GetFolderPath('Programs') + '\240-MP.lnk'
$startupLnk   = [Environment]::GetFolderPath('Startup')  + '\240-MP.lnk'

function New-Shortcut([string]$LinkPath, [string]$Target, [string]$WorkDir) {
    $shell = New-Object -ComObject WScript.Shell
    $lnk = $shell.CreateShortcut($LinkPath)
    $lnk.TargetPath = $Target
    $lnk.WorkingDirectory = $WorkDir
    $lnk.IconLocation = "$Target,0"
    $lnk.Description = '240-MP retro VCR style media frontend'
    $lnk.Save()
}

function Get-Shader([string]$Url, [string]$Path) {
    # Any download failure just warns — the app still runs; that upscaler option
    # simply won't kick in until its shader file is present.
    try {
        Invoke-WebRequest -Uri $Url -OutFile $Path -UseBasicParsing
        Write-Host "  [ok]   $(Split-Path $Path -Leaf)"
    } catch {
        Write-Warning "  [skip] $(Split-Path $Path -Leaf) (grab manually: $Url)"
    }
}

function Install-Upscalers([string]$Dir) {
    # Real-time upscaler GLSL shaders the info-screen "Upscaler" selector uses.
    # Pulled from their upstream open-source repos rather than redistributed in
    # the release zip. Mirrors scripts/get-upscalers.ps1.
    New-Item -ItemType Directory -Force -Path $Dir | Out-Null
    Get-Shader 'https://raw.githubusercontent.com/Artoriuz/ArtCNN/main/GLSL/ArtCNN_C4F32.glsl' (Join-Path $Dir 'ArtCNN_C4F32.glsl')
    Get-Shader 'https://raw.githubusercontent.com/awused/dotfiles/master/mpv/.config/mpv/shaders/fsrcnnx/FSRCNNX_x2_16-0-4-1.glsl' (Join-Path $Dir 'FSRCNNX_x2_16-0-4-1.glsl')

    # Anime4K ships as a release zip; copy out the Mode-A files 240-MP references.
    $need = @(
        'Anime4K_Clamp_Highlights.glsl',   'Anime4K_Restore_CNN_M.glsl',
        'Anime4K_Upscale_CNN_x2_M.glsl',   'Anime4K_AutoDownscalePre_x2.glsl',
        'Anime4K_AutoDownscalePre_x4.glsl','Anime4K_Upscale_CNN_x2_S.glsl'
    )
    $zip = Join-Path $env:TEMP 'Anime4K_v4.zip'
    $ex  = Join-Path $env:TEMP 'Anime4K_v4'
    try {
        Invoke-WebRequest -Uri 'https://github.com/bloc97/Anime4K/releases/download/v4.0.1/Anime4K_v4.0.zip' -OutFile $zip -UseBasicParsing
        if (Test-Path $ex) { Remove-Item -Recurse -Force $ex }
        Expand-Archive -Path $zip -DestinationPath $ex -Force
        foreach ($f in $need) {
            $src = Get-ChildItem -Recurse -Path $ex -Filter $f | Select-Object -First 1
            if ($src) { Copy-Item $src.FullName (Join-Path $Dir $f) -Force; Write-Host "  [ok]   $f" }
            else      { Write-Warning "  [missing] $f" }
        }
    } catch {
        Write-Warning '  [skip] Anime4K (grab from https://github.com/bloc97/Anime4K/releases)'
    } finally {
        Remove-Item -Force $zip -ErrorAction SilentlyContinue
        Remove-Item -Recurse -Force $ex -ErrorAction SilentlyContinue
    }
}

if ($Uninstall) {
    Get-Process 240mp -ErrorAction SilentlyContinue | Stop-Process -Force
    Remove-Item $InstallDir -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item $startMenuLnk, $startupLnk -Force -ErrorAction SilentlyContinue
    Write-Host "240-MP removed. Settings kept at $env:APPDATA\240-MP (delete manually if unwanted)."
    return
}

# ── Dependencies: mpv (required for playback), yt-dlp (YouTube module) ────────
if (-not $SkipDeps) {
    $haveMpv    = [bool](Get-Command mpv    -ErrorAction SilentlyContinue)
    $haveYtdl   = [bool](Get-Command yt-dlp -ErrorAction SilentlyContinue)
    $haveFfmpeg = [bool](Get-Command ffmpeg -ErrorAction SilentlyContinue)
    $winget   = Get-Command winget -ErrorAction SilentlyContinue
    $scoop    = Get-Command scoop  -ErrorAction SilentlyContinue
    $choco    = Get-Command choco  -ErrorAction SilentlyContinue

    if (-not $haveMpv) {
        Write-Host 'Installing mpv (playback engine)...'
        if ($winget) {
            # shinchiro.mpv is the standard mpv build for Windows; the official
            # CI build is the fallback. (mpv.net is a different application.)
            winget install -e --id shinchiro.mpv --accept-source-agreements --accept-package-agreements
            if ($LASTEXITCODE -ne 0) { winget install -e --id mpv-player.mpv-CI.MSVC --accept-source-agreements --accept-package-agreements }
        }
        elseif ($scoop) { scoop install mpv }
        elseif ($choco) { choco install mpv -y }
        else {
            Write-Warning ('No winget/scoop/choco found. Install mpv manually from https://mpv.io/installation/ ' +
                           "or drop mpv.exe into $InstallDir\mpv\ - 240-MP checks there first.")
        }
    }
    if (-not $haveYtdl) {
        Write-Host 'Installing yt-dlp (optional, used by the YouTube module)...'
        if ($winget)     { winget install -e --id yt-dlp.yt-dlp --accept-source-agreements --accept-package-agreements }
        elseif ($scoop)  { scoop install yt-dlp }
        elseif ($choco)  { choco install yt-dlp -y }
        else             { Write-Warning 'yt-dlp not installed - the YouTube module will be unavailable.' }
    }
    if (-not $haveFfmpeg) {
        Write-Host 'Installing ffmpeg (optional; used for Local Files extra thumbnails, and by yt-dlp)...'
        if ($winget)     { winget install -e --id Gyan.FFmpeg --accept-source-agreements --accept-package-agreements }
        elseif ($scoop)  { scoop install ffmpeg }
        elseif ($choco)  { choco install ffmpeg -y }
        else             { Write-Warning 'ffmpeg not installed - Local Files extras will show a play icon instead of a thumbnail.' }
    }
}

# ── Download the latest release zip ────────────────────────────────────────────
Write-Host "Fetching latest release of $Repo..."
$release = Invoke-RestMethod "https://api.github.com/repos/$Repo/releases/latest" -Headers @{ 'User-Agent' = '240-MP-install' }
$asset = $release.assets | Where-Object name -like '*-windows-x64.zip' | Select-Object -First 1
if (-not $asset) { throw "Release $($release.tag_name) has no -windows-x64.zip asset." }

$zip = Join-Path $env:TEMP $asset.name
Write-Host "Downloading $($asset.name)..."
Invoke-WebRequest $asset.browser_download_url -OutFile $zip

# Verify against SHA256SUMS when the release ships one.
$sums = $release.assets | Where-Object name -eq 'SHA256SUMS' | Select-Object -First 1
if ($sums) {
    $expected = ((Invoke-RestMethod $sums.browser_download_url) -split "`n" |
        Where-Object { $_ -like "*$($asset.name)" }) -split '\s+' | Select-Object -First 1
    $actual = (Get-FileHash $zip -Algorithm SHA256).Hash.ToLower()
    if ($expected -and $actual -ne $expected.ToLower()) { throw 'Downloaded zip failed SHA256 verification.' }
    Write-Host 'Checksum OK.'
}

# ── Install ───────────────────────────────────────────────────────────────────
Get-Process 240mp -ErrorAction SilentlyContinue | Stop-Process -Force
$stage = "$InstallDir.new"
Remove-Item $stage -Recurse -Force -ErrorAction SilentlyContinue
Expand-Archive -LiteralPath $zip -DestinationPath $stage -Force

# Release zips wrap everything in a single top-level folder - hoist it.
$entries = Get-ChildItem $stage
if ($entries.Count -eq 1 -and $entries[0].PSIsContainer) {
    $inner = $entries[0].FullName
    Get-ChildItem $inner -Force | Move-Item -Destination $stage
    Remove-Item $inner -Recurse -Force
}
if (-not (Test-Path "$stage\240mp.exe")) { throw '240mp.exe missing from package.' }

# Preserve an app-bundled mpv folder across updates, then swap.
if (Test-Path "$InstallDir\mpv") { Copy-Item "$InstallDir\mpv" $stage -Recurse -Force }
# Preserve already-downloaded upscaler shaders too (the release zip has none), so
# an update — or a -SkipUpscalers re-run — doesn't wipe them.
if (Test-Path "$InstallDir\shaders") { Copy-Item "$InstallDir\shaders" $stage -Recurse -Force }
Remove-Item $InstallDir -Recurse -Force -ErrorAction SilentlyContinue
Move-Item $stage $InstallDir
Remove-Item $zip -Force -ErrorAction SilentlyContinue

# ── Shortcuts ─────────────────────────────────────────────────────────────────
if (-not $NoShortcut) {
    New-Shortcut $startMenuLnk "$InstallDir\240mp.exe" $InstallDir
    Write-Host 'Start Menu shortcut created.'
}
if ($Autostart) {
    New-Shortcut $startupLnk "$InstallDir\240mp.exe" $InstallDir
    Write-Host '240-MP will start automatically at logon (shortcut in shell:startup).'
}

# ── Upscaler shaders (optional) ───────────────────────────────────────────────
if (-not $SkipUpscalers) {
    Write-Host 'Fetching upscaler shaders (ArtCNN / FSRCNNX / Anime4K)...'
    Install-Upscalers "$InstallDir\shaders\upscalers"
}

Write-Host ''
Write-Host "240-MP $($release.tag_name) installed to $InstallDir"
Write-Host 'Launch it from the Start Menu, or run:'
Write-Host "    & `"$InstallDir\240mp.exe`""
