# Dependency-free behavioral tests; network, processes and shortcuts are mocked.
$ErrorActionPreference = 'Stop'
$windows = Split-Path $PSScriptRoot -Parent
foreach ($file in @('install.ps1', 'setup.ps1')) {
    $tokens = $null; $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $windows $file), [ref]$tokens, [ref]$errors)
    if ($errors.Count) { throw ($errors | Out-String) }
    if ($file -eq 'install.ps1') {
        foreach ($function in $ast.FindAll({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst]}, $false)) {
            . ([scriptblock]::Create($function.Extent.Text))
        }
    }
}
function Assert($Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
function Must-Fail([scriptblock]$Action, [string]$Pattern) {
    $failure = $null
    try { & $Action } catch { $failure = $_.Exception.Message }
    Assert ($failure -and $failure -match $Pattern) "Expected failure '$Pattern', got '$failure'"
}
$original = @{}
foreach ($name in @('OS','PROCESSOR_ARCHITECTURE','PROCESSOR_ARCHITEW6432','LOCALAPPDATA')) { $original[$name] = [Environment]::GetEnvironmentVariable($name) }
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('agentwatch-installer-test-' + [guid]::NewGuid().ToString('N'))
try {
    $env:OS = 'Windows_NT'; $env:PROCESSOR_ARCHITECTURE = 'AMD64'; $env:PROCESSOR_ARCHITEW6432 = ''
    Assert ((Get-AgentWatchRid -NativeArchitecture '') -eq 'win-x64') 'x64 selection'
    Assert ((Get-AgentWatchRid -NativeArchitecture 'ARM64') -eq 'win-arm64') 'x64 emulation must use native OS architecture'
    $env:PROCESSOR_ARCHITECTURE = 'x86'; $env:PROCESSOR_ARCHITEW6432 = 'ARM64'
    Assert ((Get-AgentWatchRid -NativeArchitecture '') -eq 'win-arm64') 'Emulated shell must select native ARM64'
    $env:PROCESSOR_ARCHITEW6432 = ''
    Must-Fail { Get-AgentWatchRid -NativeArchitecture '' } '64-bit'
    $env:PROCESSOR_ARCHITECTURE = 'AMD64'
    $digest = 'a' * 64
    Assert ((Get-AgentWatchChecksum @("$digest  AgentWatch-win-x64.zip") 'AgentWatch-win-x64.zip') -eq $digest) 'checksum parse'
    Must-Fail { Get-AgentWatchChecksum @("$digest  AgentWatch-win-x64.zip", "$digest  AgentWatch-win-x64.zip") 'AgentWatch-win-x64.zip' } 'ambiguous'
    Must-Fail { Get-AgentWatchChecksum @('bad  AgentWatch-win-x64.zip') 'AgentWatch-win-x64.zip' } 'Missing'

    $source = Join-Path $testRoot 'source'
    New-Item -ItemType Directory -Force $source | Out-Null
    foreach ($file in @('AgentWatchApp.exe','AgentWatchApp.dll','agentwatch.exe','agentwatch.dll')) { Set-Content (Join-Path $source $file) 'new' }
    $archive = Join-Path $testRoot 'release.zip'
    Compress-Archive "$source/*" $archive
    $hash = (Get-FileHash $archive -Algorithm SHA256).Hash.ToLowerInvariant()
    $script:failSmoke = $false; $script:wrongHash = $false; $script:missingAsset = $false; $script:useFeed = $false
    function Invoke-RestMethod {
        $assets = @(@{name='AgentWatch-win-x64.zip';browser_download_url='zip'}, @{name='SHA256SUMS';browser_download_url='sums'})
        if ($script:missingAsset) { $assets = @() }
        return @{tag_name='windows-v0.1.1';draft=$false;prerelease=$false;assets=$assets}
    }
    function Invoke-WebRequest($Uri, $OutFile, [switch]$UseBasicParsing, $TimeoutSec) {
        if ($Uri -like '*Directory.Build.props') {
            if ($script:useFeed) { return @{ Content = '<Project><PropertyGroup><Version>0.1.4</Version></PropertyGroup></Project>' } }
            throw 'Exercise API fallback'
        }
        if ($Uri -eq 'zip' -or $Uri -like '*/AgentWatch-win-x64.zip') { Copy-Item $archive $OutFile }
        else { $value = if ($script:wrongHash) { '0' * 64 } else { $hash }; Set-Content $OutFile "$value  AgentWatch-win-x64.zip" }
    }
    function Get-Process { return @() }
    function New-AgentWatchShortcut { }
    function Test-AgentWatchCli { if ($script:failSmoke) { throw 'smoke failure' } }
    function Start-Process { throw 'NoLaunch must not start the app in installer tests' }
    $env:LOCALAPPDATA = Join-Path $testRoot 'local'
    $app = Join-Path $env:LOCALAPPDATA 'AgentWatch/app'
    New-Item -ItemType Directory -Force $app | Out-Null
    Set-Content (Join-Path $app 'old.txt') 'old'
    Set-Content (Join-Path $env:LOCALAPPDATA 'AgentWatch/profiles.json') 'preserved'
    $script:missingAsset = $true
    Must-Fail { Install-AgentWatch -NoLaunch } 'incomplete'
    Assert (Test-Path "$app/old.txt") 'Missing release must preserve old app'
    $script:missingAsset = $false; $script:wrongHash = $true
    Must-Fail { Install-AgentWatch -NoLaunch } 'checksum mismatch'
    Assert (Test-Path "$app/old.txt") 'Bad checksum must preserve old app'
    $script:wrongHash = $false; $script:failSmoke = $true
    Must-Fail { Install-AgentWatch -NoLaunch } 'smoke failure'
    Assert (Test-Path "$app/old.txt") 'Failed startup must roll back old app'
    $script:failSmoke = $false
    Install-AgentWatch -NoLaunch
    Assert (Test-Path "$app/agentwatch.exe") 'CLI must coexist with AgentWatchApp.exe'
    Assert (Test-Path (Join-Path $env:LOCALAPPDATA 'AgentWatch/app.previous/old.txt')) 'Previous app retained'
    Assert ((Get-Content (Join-Path $env:LOCALAPPDATA 'AgentWatch/profiles.json')) -eq 'preserved') 'Connections preserved'
    Remove-Item $app -Recurse -Force
    $script:missingAsset = $true
    Must-Fail { Install-AgentWatch -NoLaunch } 'incomplete'
    Assert (Test-Path "$app/old.txt") 'Interrupted swap must recover previous app before downloading'
    $script:missingAsset = $false
    $lock = [IO.File]::Open((Join-Path $env:LOCALAPPDATA 'AgentWatch/install.lock'), 'Open', 'ReadWrite', 'None')
    try { Must-Fail { Install-AgentWatch -NoLaunch } 'Another Agent Watch' } finally { $lock.Dispose() }
    $script:useFeed = $true
    Install-AgentWatch -NoLaunch
    Assert (Test-Path "$app/AgentWatchApp.exe") 'Direct version-feed installation preserves the current GUI name'
    Write-Host 'PASS: syntax, native architecture, checksums, missing assets, rollback, preservation and concurrent install lock.'
} finally {
    foreach ($name in $original.Keys) { [Environment]::SetEnvironmentVariable($name, $original[$name]) }
    if (Test-Path $testRoot) { Remove-Item $testRoot -Recurse -Force }
}
