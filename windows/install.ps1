# Agent Watch for Windows: installs (or updates) the latest release for this
# user in %LOCALAPPDATA%\AgentWatch\app and adds it to the Start menu.
#   irm https://raw.githubusercontent.com/Vt-mmm/agentwatch/main/windows/install.ps1 | iex
$ErrorActionPreference = "Stop"
$rid = if ($env:PROCESSOR_ARCHITECTURE -eq "ARM64") { "win-arm64" } else { "win-x64" }
$download = "https://github.com/Vt-mmm/agentwatch/releases/download"
# Windows PowerShell 5.1 redraws a progress bar per chunk, which took each
# 70 MB download two minutes; put back at the end, since `irm | iex` runs in
# the caller's session.
$progress = $ProgressPreference
$ProgressPreference = "SilentlyContinue"
$temp = Join-Path $env:TEMP ("agentwatch-" + [guid]::NewGuid())
New-Item -ItemType Directory $temp | Out-Null
try {
  # The tag comes from the version on main: raw.githubusercontent.com has no
  # rate limit, while the GitHub API allows 60 calls an hour per IP without a
  # login (shared offices and CI runners hit it). The API is only the fallback,
  # for the minutes between a version landing on main and its release.
  try {
    $props = [xml](Invoke-WebRequest -UseBasicParsing "https://raw.githubusercontent.com/Vt-mmm/agentwatch/main/windows/Directory.Build.props").Content
    $tag = "windows-v" + $props.SelectSingleNode("//Version").InnerText
    Invoke-WebRequest -UseBasicParsing "$download/$tag/SHA256SUMS" -OutFile "$temp\SHA256SUMS"
  } catch {
    # Through a variable: Windows PowerShell 5.1's Invoke-RestMethod writes a JSON
    # array as one object, so a filter piped straight after it never matched.
    $releases = Invoke-RestMethod "https://api.github.com/repos/Vt-mmm/agentwatch/releases?per_page=30"
    $release = $releases | Where-Object { $_.tag_name -like "windows-v*" -and -not $_.draft -and -not $_.prerelease } | Select-Object -First 1
    if (-not $release) { throw "Chưa có bản Agent Watch cho Windows." }
    $tag = $release.tag_name
    Invoke-WebRequest -UseBasicParsing "$download/$tag/SHA256SUMS" -OutFile "$temp\SHA256SUMS"
  }
  Invoke-WebRequest -UseBasicParsing "$download/$tag/AgentWatch-$rid.zip" -OutFile "$temp\AgentWatch.zip"
  $expected = (Get-Content "$temp\SHA256SUMS" | Where-Object { $_ -like "*AgentWatch-$rid.zip" }).Split(" ")[0]
  if ((Get-FileHash "$temp\AgentWatch.zip" -Algorithm SHA256).Hash.ToLower() -ne $expected) { throw "Tệp tải về không khớp SHA256SUMS." }
  $app = Join-Path $env:LOCALAPPDATA "AgentWatch\app"
  # Unpacked beside the installed copy first, so a failure up to the swap
  # leaves that copy working.
  $staged = "$app-" + [guid]::NewGuid()
  Expand-Archive "$temp\AgentWatch.zip" -DestinationPath $staged
  try {
    # The app and the broker (agentwatch.exe, which Piagent in WSL starts again
    # on its next call) hold the folder's DLLs. A killed process lets go of them
    # only once it has fully exited, which Stop-Process does not wait for: the
    # member's "Access to the path 'AgentWatch.Core.dll' is denied".
    for ($attempt = 1; Test-Path $app; $attempt++) {
      $running = @(Get-Process -ErrorAction SilentlyContinue | Where-Object {
        $_.Name -in @("AgentWatchApp", "agentwatch") -or ($_.Path -and $_.Path.StartsWith("$app\", [StringComparison]::OrdinalIgnoreCase)) })
      $running | Stop-Process -Force -ErrorAction SilentlyContinue
      $running | Wait-Process -Timeout 5 -ErrorAction SilentlyContinue
      try { Remove-Item $app -Recurse -Force; break } catch {
        if ($attempt -ge 6) { throw "Agent Watch vẫn đang chạy nên chưa thay được bản cũ. Thoát Agent Watch ở khay hệ thống (cạnh đồng hồ; nếu đã mở bằng quyền Administrator thì chạy lệnh này trong cửa sổ Administrator) rồi chạy lại lệnh. Chi tiết: $($_.Exception.Message)" }
        Start-Sleep -Seconds 1
      }
    }
    Move-Item $staged $app
  } finally { if (Test-Path $staged) { Remove-Item $staged -Recurse -Force -ErrorAction SilentlyContinue } }
  $shell = New-Object -ComObject WScript.Shell
  $link = $shell.CreateShortcut((Join-Path ([Environment]::GetFolderPath("Programs")) "Agent Watch.lnk"))
  $link.TargetPath = Join-Path $app "AgentWatchApp.exe"; $link.Save()
  # setup.ps1 connects and binds first, then starts the app itself.
  if ($env:AGENTWATCH_NO_LAUNCH -ne "1") { Start-Process (Join-Path $app "AgentWatchApp.exe") }
  Write-Host "Đã cài Agent Watch $($tag -replace 'windows-v','') vào $app"
} finally {
  Remove-Item $temp -Recurse -Force -ErrorAction SilentlyContinue
  $ProgressPreference = $progress
}
