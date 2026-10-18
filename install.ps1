# Conver Terminal Installer for Windows (PowerShell)
$ErrorActionPreference = "Stop"

$Repo = if ($env:CONVER_REPO) { $env:CONVER_REPO } else { "kushagrmishra/conver" }
$Url = "https://github.com/$Repo/releases/latest/download/Conver-Setup.exe"
$Out = Join-Path $env:TEMP "Conver-Setup.exe"

Write-Host "==========================================" -ForegroundColor Cyan
Write-Host "  ⚡ Conver Installer (Windows)" -ForegroundColor Cyan
Write-Host "==========================================" -ForegroundColor Cyan

Write-Host "==> Downloading Conver-Setup.exe..."
Invoke-WebRequest -Uri $Url -OutFile $Out

Write-Host "==> Launching Conver Installer..."
Start-Process -FilePath $Out

Write-Host "✅ Installer started! Once installed, press Shift + Z anytime to summon the Drop Wheel." -ForegroundColor Green
