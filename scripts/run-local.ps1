<#
.SYNOPSIS
    Configures, builds, and runs 240-MP from the repo for development.

.DESCRIPTION
    Wraps the CMake/Ninja build documented in BUILDING.md:
        .\scripts\run-local.ps1                 # configure (if needed), build, run
        .\scripts\run-local.ps1 -BuildOnly      # skip the run
        .\scripts\run-local.ps1 -Reconfigure    # wipe the CMake cache first

    Qt/SDL2/OpenSSL locations can be overridden with -QtDir/-Sdl2Dir/-OpenSslDir
    or the QT_DIR/SDL2_DIR/OPENSSL_DIR environment variables.
#>
[CmdletBinding()]
param(
    [string]$QtDir      = $(if ($env:QT_DIR)      { $env:QT_DIR }      else { 'C:\Qt\6.10.3\msvc2022_64' }),
    [string]$Sdl2Dir    = $(if ($env:SDL2_DIR)    { $env:SDL2_DIR }    else { 'C:\Qt\SDL2\SDL2-2.32.10' }),
    [string]$OpenSslDir = $(if ($env:OPENSSL_DIR) { $env:OPENSSL_DIR } else { 'C:\Qt\Tools\OpenSSLv3\Win_x64' }),
    [switch]$BuildOnly,
    [switch]$Reconfigure
)

$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
$build = Join-Path $repo 'build'

foreach ($dir in $QtDir, $Sdl2Dir, $OpenSslDir) {
    if (-not (Test-Path $dir)) { throw "Dependency folder not found: $dir (see BUILDING.md)" }
}

# Prefer cmake/ninja from PATH; fall back to the copies Visual Studio bundles.
$cmake = (Get-Command cmake -ErrorAction SilentlyContinue).Source
$vsRoot = & "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe" -latest -products * -property installationPath
if (-not $cmake) {
    $cmake = Join-Path $vsRoot 'Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\cmake.exe'
    $env:PATH = (Split-Path $cmake) + ';' + (Join-Path $vsRoot 'Common7\IDE\CommonExtensions\Microsoft\CMake\Ninja') + ';' + $env:PATH
}
if (-not (Test-Path $cmake)) { throw 'cmake not found - install Visual Studio 2022+ with the C++ workload.' }

if ($Reconfigure) { Remove-Item $build -Recurse -Force -ErrorAction SilentlyContinue }

$vcvars = Join-Path $vsRoot 'VC\Auxiliary\Build\vcvars64.bat'
$prefix = "$QtDir;$Sdl2Dir"
if (-not (Test-Path "$build\CMakeCache.txt")) {
    cmd /c "`"$vcvars`" >nul 2>&1 && cmake -B `"$build`" -S `"$repo`" -G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_PREFIX_PATH=`"$prefix`" -DOPENSSL_ROOT_DIR=`"$OpenSslDir`""
    if ($LASTEXITCODE -ne 0) { throw 'CMake configure failed.' }
}

cmd /c "`"$vcvars`" >nul 2>&1 && cmake --build `"$build`""
if ($LASTEXITCODE -ne 0) { throw 'Build failed.' }

if ($BuildOnly) { return }

# Qt DLLs come from the Qt install for dev runs; the deployed package carries
# its own copies (windeployqt). APP_ROOT points the app at the repo's QML.
$env:PATH = "$QtDir\bin;" + $env:PATH
$env:APP_ROOT = $repo
# This is a deliberate run-from-terminal, so opt in to console logging (the app
# only attaches to the parent console when MP240_CONSOLE is set).
$env:MP240_CONSOLE = '1'
Write-Host "Running $build\240mp.exe (logs also land in %APPDATA%\240-MP\logs\240mp.log; Ctrl+Q quits)"
& "$build\240mp.exe"
