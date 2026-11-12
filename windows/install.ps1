# Darnell Jr. (formerly Work Clock) for Windows: installs (or updates) and opens it.
#
#   irm https://raw.githubusercontent.com/team-angeleski/work-clock/main/windows/install.ps1 | iex
#
# With a friend's board code filled in:
#   & ([scriptblock]::Create((irm https://raw.githubusercontent.com/team-angeleski/work-clock/main/windows/install.ps1))) BOARDCODE
param([string]$Code = $env:WORKCLOCK_CODE)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

Write-Host ""
Write-Host "Installing Darnell Jr. ..." -ForegroundColor Cyan

# The newest release that has a Windows build (some releases are Mac-only).
$releases = Invoke-RestMethod "https://api.github.com/repos/team-angeleski/work-clock/releases?per_page=20" -Headers @{ "User-Agent" = "WorkClock-Installer" }
$asset = $releases | Where-Object { -not $_.draft } | ForEach-Object { $_.assets } |
    Where-Object { $_.name -eq "WorkClock-Setup.exe" } | Select-Object -First 1
if (-not $asset) { throw "No Windows build has been released yet." }

$setup = Join-Path $env:TEMP "WorkClock-Setup.exe"
Invoke-WebRequest $asset.browser_download_url -OutFile $setup -UseBasicParsing

# Replace any running copy. Your focus history is kept: it lives in %APPDATA%\WorkClock.
# (The installer also removes a copy installed under the old name, Work Clock.)
Get-Process WorkClock -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep -Seconds 1
Start-Process $setup -ArgumentList "/S" -Wait
Remove-Item $setup -Force -ErrorAction SilentlyContinue

if ($Code) {
    $dir = Join-Path $env:APPDATA "WorkClock"
    New-Item -ItemType Directory -Force $dir | Out-Null
    Set-Content (Join-Path $dir "invite.txt") $Code.Trim().ToUpper()
}

# Installed as "Darnell Jr" (Windows drops the full stop from folder names). Older builds used "Work Clock".
$exe = @("Darnell Jr", "Darnell Jr.", "Work Clock") | ForEach-Object { Join-Path $env:LOCALAPPDATA "$_\WorkClock.exe" } |
    Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $exe) { throw "The installer didn't finish. Try running it again." }
Start-Process $exe

Write-Host ""
Write-Host "Darnell Jr. is installed and open." -ForegroundColor Green
Write-Host "The clock sits above the taskbar, bottom right. A setup window walks you"
Write-Host "through signing in (or joining your friends' board). Takes a minute."
Write-Host ""
