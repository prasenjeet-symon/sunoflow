#Requires -Version 5.1
<#
.SYNOPSIS
  Freezes the SunoFlow Windows sidecar into a one-folder bundle with PyInstaller.

.DESCRIPTION
  Creates a clean venv, installs the sidecar deps + PyInstaller, runs the spec,
  and emits dist/SunoFlowSidecar/. Run this on a Windows box with a DirectX 12
  GPU (the DirectML provider must be present in onnxruntime-directml at build
  time or it won't be collected into the bundle).

  The Parakeet ONNX model (~2.5 GB) is NOT bundled. Users download it on first
  run from the tray app's Settings -> Model tab.

.PARAMETER Clean
  Remove the venv and dist/ before building (default: true).

.EXAMPLE
  .\build.ps1
#>
[CmdletBinding()]
param(
    [switch]$Clean = $true
)

$ErrorActionPreference = "Stop"
Set-Location $PSScriptRoot

Write-Host "==> Building SunoFlow Windows sidecar (PyInstaller one-folder)" -ForegroundColor Cyan

# --- clean -----------------------------------------------------------------
if ($Clean) {
    foreach ($p in @(".venv-build", "build", "dist")) {
        if (Test-Path $p) {
            Write-Host "  removing $p"
            Remove-Item -Recurse -Force $p
        }
    }
}

# --- venv + deps -----------------------------------------------------------
if (-not (Test-Path ".venv-build")) {
    Write-Host "==> Creating build venv (.venv-build)"
    python -m venv .venv-build
}
& .\.venv-build\Scripts\Activate.ps1

Write-Host "==> Installing dependencies"
python -m pip install --upgrade pip
python -m pip install -r requirements.txt pyinstaller

# --- freeze ----------------------------------------------------------------
Write-Host "==> Running PyInstaller (sidecar.spec)"
pyinstaller --clean --noconfirm sidecar.spec
if ($LASTEXITCODE -ne 0) { throw "PyInstaller failed (exit $LASTEXITCODE)" }

$dist = Join-Path $PSScriptRoot "dist\SunoFlowSidecar"
if (-not (Test-Path (Join-Path $dist "SunoFlowSidecar.exe"))) {
    throw "Build finished but SunoFlowSidecar.exe not found in $dist"
}

Write-Host ""
Write-Host "==> Done. Output: $dist" -ForegroundColor Green
Write-Host "    Run: .\dist\SunoFlowSidecar\SunoFlowSidecar.exe"
Write-Host "    Then start the tray app; download the model from Settings -> Model."