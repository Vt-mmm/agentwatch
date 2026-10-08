# Per-user install/update. Compatible with Windows PowerShell 5.1 and PowerShell 7.
param([switch]$NoLaunch)
function Get-AgentWatchRid([string]$NativeArchitecture = [Environment]::GetEnvironmentVariable('PROCESSOR_ARCHITECTURE', 'Machine')) {
    # A 32-bit or emulated PowerShell must still install for the native OS.
    $architecture = if ($NativeArchitecture) { $NativeArchitecture } elseif ($env:PROCESSOR_ARCHITEW6432) { $env:PROCESSOR_ARCHITEW6432 } else { $env:PROCESSOR_ARCHITECTURE }
    switch ($architecture) {
        'ARM64' { return 'win-arm64' }
        'AMD64' { return 'win-x64' }
        default { throw 'Agent Watch requires 64-bit Windows (x64 or ARM64).' }
    }
}

function Get-AgentWatchChecksum($Lines, [string]$AssetName) {
    $entries = @($Lines | Where-Object { $_ -match ('^([a-fA-F0-9]{64})\s+\*?' + [regex]::Escape($AssetName) + '$') })
    if ($entries.Count -ne 1) { throw "Missing or ambiguous SHA256SUMS entry for $AssetName." }
    return ($entries[0] -split '\s+')[0].ToLowerInvariant()
}

function Test-AgentWatchCli([string]$File) {
    & $File --version
    if ($LASTEXITCODE -ne 0) { throw 'The installed CLI failed its startup check.' }
}

function New-AgentWatchShortcut([string]$App) {
    $shell = New-Object -ComObject WScript.Shell
    $link = $shell.CreateShortcut((Join-Path ([Environment]::GetFolderPath('Programs')) 'Agent Watch.lnk'))
    $link.TargetPath = Join-Path $App 'AgentWatchApp.exe'
    $link.WorkingDirectory = $App
    $link.Save()
}

function Invoke-AgentWatchFetch([string]$Url, [string]$OutFile) {
    # curl.exe (in Windows since 10 1803) continues a partial file; it aborts
    # a stalled transfer (< 1 KB/s for 60 s) instead of a fixed total timeout.
    $curl = Get-Command curl.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($curl) {
        & $curl.Source --fail --location --silent --show-error --connect-timeout 30 --speed-limit 1024 --speed-time 60 --continue-at - --output $OutFile $Url
        if ($LASTEXITCODE -eq 0) { return }
        # 22 (HTTP error, e.g. 416) and 33 (no range support): start over next time.
        if ($LASTEXITCODE -in 22, 33) { Remove-Item $OutFile -Force -ErrorAction SilentlyContinue }
        # 35: Schannel refused the TLS setup (revocation check on some networks).
        if ($LASTEXITCODE -ne 35) { throw "curl.exe exited with $LASTEXITCODE." }
    }
    Remove-Item $OutFile -Force -ErrorAction SilentlyContinue
    Invoke-WebRequest $Url -UseBasicParsing -TimeoutSec 300 -OutFile $OutFile
}

function Save-AgentWatchDownload([string]$Url, [string]$OutFile, [int]$Attempts = 5, [int]$DelaySeconds = 3) {
    # Member networks reset long GitHub downloads mid-way ("An existing
    # connection was forcibly closed"). Retry and keep what already arrived.
    for ($attempt = 1; ; $attempt++) {
        try { Invoke-AgentWatchFetch $Url $OutFile; return } catch {
            if ($attempt -ge $Attempts) {
                throw "Download failed $Attempts times: $($_.Exception.Message) Check the network, VPN or antivirus web filter, then run the command again. The installed app has not been changed."
            }
            Write-Host "Download interrupted ($attempt/$Attempts): $($_.Exception.Message) Retrying..."
            Start-Sleep -Seconds ($DelaySeconds * $attempt)
        }
    }
}

function Install-AgentWatch([switch]$NoLaunch) {
    $ErrorActionPreference = 'Stop'
    $ProgressPreference = 'SilentlyContinue'
    if ($env:OS -ne 'Windows_NT') { throw 'Run this installer in Windows PowerShell.' }
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $rid = Get-AgentWatchRid
    $root = Join-Path $env:LOCALAPPDATA 'AgentWatch'
    New-Item -ItemType Directory -Force $root | Out-Null
    # A file lock is shared across PowerShell versions and sessions for this user.
    try { $lock = [IO.File]::Open((Join-Path $root 'install.lock'), 'OpenOrCreate', 'ReadWrite', 'None') }
    catch { throw 'Another Agent Watch installation is running. Wait and try again.' }
    $work = Join-Path $root ('install-' + [guid]::NewGuid().ToString('N'))
    $app = Join-Path $root 'app'
    $backup = Join-Path $root 'app.previous'
    $swapped = $false
    try {
        # Recover an interrupted directory swap before attempting a new download.
        if ((Test-Path $backup) -and -not (Test-Path $app)) { Move-Item $backup $app }
        New-Item -ItemType Directory $work | Out-Null
        $download = 'https://github.com/Vt-mmm/agentwatch/releases/download'
        $assetName = "AgentWatch-$rid.zip"
        try {
            $props = [xml](Invoke-WebRequest -UseBasicParsing 'https://raw.githubusercontent.com/Vt-mmm/agentwatch/main/windows/Directory.Build.props' -TimeoutSec 60).Content
            $tag = 'windows-v' + $props.SelectSingleNode('//Version').InnerText
            # A tag pushed before its assets exist falls back to the release API quickly.
            Save-AgentWatchDownload "$download/$tag/SHA256SUMS" "$work/SHA256SUMS" -Attempts 2
            $zipUrl = "$download/$tag/$assetName"
        } catch {
            $releases = Invoke-RestMethod 'https://api.github.com/repos/Vt-mmm/agentwatch/releases?per_page=100' -TimeoutSec 60
            $release = $releases | Where-Object { $_.tag_name -match '^windows-v\d+\.\d+\.\d+$' -and -not $_.draft -and -not $_.prerelease } | Select-Object -First 1
            if (-not $release) { throw 'Chưa có bản Agent Watch cho Windows.' }
            $zip = @($release.assets | Where-Object { $_.name -ceq $assetName })
            $sums = @($release.assets | Where-Object { $_.name -ceq 'SHA256SUMS' })
            if ($zip.Count -ne 1 -or $sums.Count -ne 1) { throw "Release $($release.tag_name) is incomplete for $rid. Try again after the release finishes." }
            $tag = $release.tag_name
            $zipUrl = $zip[0].browser_download_url
            Save-AgentWatchDownload $sums[0].browser_download_url "$work/SHA256SUMS"
        }
        Write-Host "Downloading Agent Watch $tag..."
        Save-AgentWatchDownload $zipUrl "$work/app.zip"
        $expected = Get-AgentWatchChecksum (Get-Content "$work/SHA256SUMS") $assetName
        if ((Get-FileHash "$work/app.zip" -Algorithm SHA256).Hash.ToLowerInvariant() -ne $expected) { throw 'Download checksum mismatch. The installed app has not been changed.' }
        $staged = Join-Path $work 'app'
        Expand-Archive "$work/app.zip" -DestinationPath $staged
        foreach ($file in @('AgentWatchApp.exe', 'AgentWatchApp.dll', 'agentwatch.exe', 'agentwatch.dll')) {
            if (-not (Test-Path (Join-Path $staged $file) -PathType Leaf)) { throw "Release is missing $file. The installed app has not been changed." }
        }
        # Only stop processes running from this installation (app\ or the
        # previous copy). Seen on 2026-10-08: a process left running from
        # app.previous made the next update fail with "Access to the path
        # 'AgentWatch.Core.dll' is denied". A copy that still cannot be
        # deleted is renamed aside (Windows allows renaming a running image)
        # and removed by a later update.
        $installed = @($app, $backup) | ForEach-Object { $_ + [IO.Path]::DirectorySeparatorChar }
        function Stop-InstalledAgentWatch {
            $running = @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $path = $_.Path
                $path -and @($installed | Where-Object { $path.StartsWith($_, [StringComparison]::OrdinalIgnoreCase) }).Count })
            if ($running.Count) { Write-Host 'Closing Agent Watch and its company sessions for the update. Reopen Piagent after installation.' }
            $running | Stop-Process -Force -ErrorAction SilentlyContinue
            $running | Wait-Process -Timeout 5 -ErrorAction SilentlyContinue
        }
        Get-ChildItem $root -Directory -Filter 'app.previous-*' -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
        if (Test-Path $backup) {
            Stop-InstalledAgentWatch
            try { Remove-Item $backup -Recurse -Force -ErrorAction Stop } catch {
                Move-Item $backup ($backup + '-' + [guid]::NewGuid().ToString('N'))
            }
        }
        # Wait for DLL handles to close and retry the rename, retaining the
        # recoverable copy.
        for ($attempt = 1; Test-Path $app; $attempt++) {
            Stop-InstalledAgentWatch
            try { Move-Item $app $backup; break } catch {
                if ($attempt -ge 6) { throw "Agent Watch is still in use. Close it and its Piagent sessions, then retry. $($_.Exception.Message)" }
                Start-Sleep -Seconds 1
            }
        }
        try {
            Move-Item $staged $app
            $swapped = $true
            Test-AgentWatchCli (Join-Path $app 'agentwatch.exe')
        } catch {
            if ($swapped -and (Test-Path $app)) { Remove-Item $app -Recurse -Force }
            if (Test-Path $backup) { Move-Item $backup $app }
            throw
        }
        # App deployment succeeded. Shortcut failures must not roll back a running app.
        New-AgentWatchShortcut $app
        if (-not $NoLaunch -and $env:AGENTWATCH_NO_LAUNCH -ne "1") { Start-Process (Join-Path $app 'AgentWatchApp.exe') }
        Write-Host "Installed $tag in $app. Your Studio connections are preserved."
    } finally {
        if (Test-Path $work) { Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue }
        $lock.Dispose()
    }
}

Install-AgentWatch -NoLaunch:$NoLaunch
