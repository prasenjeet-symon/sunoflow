# Fetch a self-contained LGPL ffmpeg.exe for the SunoFlow Windows sidecar bundle
# -> sidecars/windows/vendor/ffmpeg.exe
#
# Why: the app needs ffmpeg at runtime (the cloud path encodes WAV -> Opus; if a
# future Windows STT path decodes audio it uses ffmpeg too). We ship it so the
# app carries no system dependency. Source is BtbN's win64 **LGPL** static build
# (the -lgpl asset — no GPL components like x264/x265), so it is redistributable.
#
# Run on the Windows build machine before packaging (build.ps1 calls this).
# Idempotent: skips if the binary is already vendored (pass -Force to refresh).
param([switch]$Force)
$ErrorActionPreference = "Stop"

$Root   = Split-Path -Parent $MyInvocation.MyCommand.Path
$Vendor = Join-Path $Root "vendor"
$Bin    = Join-Path $Vendor "ffmpeg.exe"

# BtbN maintains a rolling "latest" release with stable asset names. The -lgpl
# (not -gpl) win64 build is what we ship. Pin $Sha256 after the first fetch.
$Url    = "https://github.com/BtbN/FFmpeg-Builds/releases/download/latest/ffmpeg-master-latest-win64-lgpl.zip"
$Sha256 = ""   # fill in after first fetch to pin; empty = print-and-proceed

if ((Test-Path $Bin) -and -not $Force) {
    Write-Host "ffmpeg already vendored at $Bin (use -Force to refresh):"
    & $Bin -hide_banner -version | Select-Object -First 1
    exit 0
}

New-Item -ItemType Directory -Force -Path $Vendor | Out-Null
$Zip = Join-Path $env:TEMP ("ffmpeg-lgpl-" + [guid]::NewGuid() + ".zip")
Write-Host "==> Downloading $Url"
Invoke-WebRequest -Uri $Url -OutFile $Zip

$got = (Get-FileHash -Algorithm SHA256 $Zip).Hash.ToLower()
Write-Host "  sha256 = $got"
if ($Sha256 -and ($got -ne $Sha256.ToLower())) {
    throw "checksum mismatch (expected $Sha256)"
}

$Extract = Join-Path $env:TEMP ("ffmpeg-" + [guid]::NewGuid())
Expand-Archive -Path $Zip -DestinationPath $Extract -Force
$src = Get-ChildItem -Path $Extract -Recurse -Filter ffmpeg.exe | Select-Object -First 1
if (-not $src) { throw "ffmpeg.exe not found in the downloaded archive" }
Copy-Item $src.FullName $Bin -Force
Remove-Item $Zip, $Extract -Recurse -Force -ErrorAction SilentlyContinue

Write-Host "==> Done: $Bin"
& $Bin -hide_banner -version | Select-Object -First 1
if (-not (& $Bin -hide_banner -encoders | Select-String -Quiet -Pattern "opus")) {
    throw "libopus encoder missing from the fetched build"
}
