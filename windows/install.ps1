# Agent Watch for Windows: installs (or updates) the latest release for this
# user in %LOCALAPPDATA%\AgentWatch\app and adds it to the Start menu.
#   irm https://raw.githubusercontent.com/Vt-mmm/agentwatch/main/windows/install.ps1 | iex
$ErrorActionPreference = "Stop"
$rid = if ($env:PROCESSOR_ARCHITECTURE -eq "ARM64") { "win-arm64" } else { "win-x64" }
$release = Invoke-RestMethod "https://api.github.com/repos/Vt-mmm/agentwatch/releases?per_page=30" |
  Where-Object { $_.tag_name -like "windows-v*" -and -not $_.draft -and -not $_.prerelease } | Select-Object -First 1
if (-not $release) { throw "Chưa có bản Agent Watch cho Windows." }
$zip = $release.assets | Where-Object { $_.name -eq "AgentWatch-$rid.zip" }
$sums = $release.assets | Where-Object { $_.name -eq "SHA256SUMS" }
$temp = Join-Path $env:TEMP ("agentwatch-" + [guid]::NewGuid())
New-Item -ItemType Directory $temp | Out-Null
try {
  Invoke-WebRequest $zip.browser_download_url -OutFile "$temp\AgentWatch.zip"
  Invoke-WebRequest $sums.browser_download_url -OutFile "$temp\SHA256SUMS"
  $expected = (Get-Content "$temp\SHA256SUMS" | Where-Object { $_ -like "*AgentWatch-$rid.zip" }).Split(" ")[0]
  if ((Get-FileHash "$temp\AgentWatch.zip" -Algorithm SHA256).Hash.ToLower() -ne $expected) { throw "Tệp tải về không khớp SHA256SUMS." }
  # The app and the broker (agentwatch.exe) hold files open in the folder being replaced.
  Get-Process AgentWatchApp, agentwatch -ErrorAction SilentlyContinue | Stop-Process -Force
  $app = Join-Path $env:LOCALAPPDATA "AgentWatch\app"
  if (Test-Path $app) { Remove-Item $app -Recurse -Force }
  Expand-Archive "$temp\AgentWatch.zip" -DestinationPath $app
  $shell = New-Object -ComObject WScript.Shell
  $link = $shell.CreateShortcut((Join-Path ([Environment]::GetFolderPath("Programs")) "Agent Watch.lnk"))
  $link.TargetPath = Join-Path $app "AgentWatchApp.exe"; $link.Save()
  # setup.ps1 connects and binds first, then starts the app itself.
  if ($env:AGENTWATCH_NO_LAUNCH -ne "1") { Start-Process (Join-Path $app "AgentWatchApp.exe") }
  Write-Host "Đã cài Agent Watch $($release.tag_name -replace 'windows-v','') vào $app"
} finally { Remove-Item $temp -Recurse -Force -ErrorAction SilentlyContinue }
