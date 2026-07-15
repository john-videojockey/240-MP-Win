<#
.SYNOPSIS
    Installs (or updates, or removes) 240-MP on Windows.

.DESCRIPTION
    Downloads the latest 240-MP release zip from GitHub, installs it to a
    per-user folder (no admin rights needed), creates a Start Menu shortcut,
    and installs the mpv playback engine via winget/scoop/choco if missing.

    One-liner (PowerShell):
        irm https://github.com/john-videojockey/240-MP-Win/releases/latest/download/install.ps1 | iex

    Or with options:
        .\install.ps1 -Autostart          # also start 240-MP at logon
        .\install.ps1 -SkipDeps           # don't touch mpv/yt-dlp
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

if ($Uninstall) {
    Get-Process 240mp -ErrorAction SilentlyContinue | Stop-Process -Force
    Remove-Item $InstallDir -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item $startMenuLnk, $startupLnk -Force -ErrorAction SilentlyContinue
    Write-Host "240-MP removed. Settings kept at $env:APPDATA\240-MP (delete manually if unwanted)."
    return
}

# ── Dependencies: mpv (required for playback), yt-dlp (YouTube module) ────────
if (-not $SkipDeps) {
    $haveMpv  = [bool](Get-Command mpv    -ErrorAction SilentlyContinue)
    $haveYtdl = [bool](Get-Command yt-dlp -ErrorAction SilentlyContinue)
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

Write-Host ''
Write-Host "240-MP $($release.tag_name) installed to $InstallDir"
Write-Host 'Launch it from the Start Menu, or run:'
Write-Host "    & `"$InstallDir\240mp.exe`""
