param([Parameter(Mandatory=$true)][string]$AppPath, [string]$OutputDirectory = "$PSScriptRoot/artifacts")
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes, System.Drawing
$originalData = $env:AGENTWATCH_DATA_DIR
$temporary = Join-Path $env:TEMP ('agentwatch-ui-' + [guid]::NewGuid().ToString('N'))
$env:AGENTWATCH_DATA_DIR = $temporary
$process = $null
function Find-Control([string]$Name) {
    return $script:window.FindFirst([Windows.Automation.TreeScope]::Descendants,
        (New-Object Windows.Automation.PropertyCondition([Windows.Automation.AutomationElement]::NameProperty, $Name)))
}
function Click-Control([string]$Name) {
    $control = Find-Control $Name
    if (-not $control) { throw "Missing control: $Name" }
    $control.GetCurrentPattern([Windows.Automation.InvokePattern]::Pattern).Invoke()
}
function Wait-Control([string]$Name) {
    $deadline = [DateTime]::UtcNow.AddSeconds(10)
    do { $found = Find-Control $Name; if ($found -and -not $found.Current.IsOffscreen) { return $found }; Start-Sleep -Milliseconds 100 } while ([DateTime]::UtcNow -lt $deadline)
    throw "Control did not become visible: $Name"
}
try {
    $process = Start-Process (Resolve-Path $AppPath) -PassThru
    $deadline = [DateTime]::UtcNow.AddSeconds(20)
    do { $process.Refresh(); if ($process.MainWindowHandle -ne 0) { break }; Start-Sleep -Milliseconds 100 } while ([DateTime]::UtcNow -lt $deadline)
    if ($process.MainWindowHandle -eq 0) { throw 'App did not open a native window.' }
    $script:window = [Windows.Automation.AutomationElement]::FromHandle($process.MainWindowHandle)
    Wait-Control 'Bắt đầu với Agent Watch' | Out-Null
    # Wait for the startup status check to release the controls.
    $deadline = [DateTime]::UtcNow.AddSeconds(10)
    do { $next = Find-Control 'Tiếp tục →'; if ($next.Current.IsEnabled) { break }; Start-Sleep -Milliseconds 100 } while ([DateTime]::UtcNow -lt $deadline)
    Click-Control 'Tiếp tục →'
    Wait-Control 'Kết nối đúng Studio, đúng key' | Out-Null
    if ((Find-Control 'Tiếp tục →').Current.IsEnabled) { throw 'Unverified key allowed advancing.' }
    $radio = Find-Control 'Địa chỉ + key riêng'
    $radio.GetCurrentPattern([Windows.Automation.SelectionItemPattern]::Pattern).Select()
    Wait-Control 'Địa chỉ API Studio' | Out-Null
    Click-Control 'Kiểm tra kết nối & key'
    Start-Sleep -Milliseconds 300
    if ((Find-Control 'Tiếp tục →').Current.IsEnabled) { throw 'Empty key allowed advancing.' }
    if (Test-Path (Join-Path $temporary 'profiles.json')) { throw 'Key verification unexpectedly saved a profile.' }
    New-Item -ItemType Directory -Force $OutputDirectory | Out-Null
    $bounds = $script:window.Current.BoundingRectangle
    $bitmap = New-Object Drawing.Bitmap([int]$bounds.Width, [int]$bounds.Height)
    $graphics = [Drawing.Graphics]::FromImage($bitmap)
    try {
        $graphics.CopyFromScreen([int]$bounds.X, [int]$bounds.Y, 0, 0, $bitmap.Size)
        $bitmap.Save((Join-Path (Resolve-Path $OutputDirectory) 'windows-key-step.png'), [Drawing.Imaging.ImageFormat]::Png)
    } finally { $graphics.Dispose(); $bitmap.Dispose() }
    Click-Control 'Quay lại'
    Wait-Control 'Bắt đầu với Agent Watch' | Out-Null
    Write-Host 'PASS: native wizard navigation, key entry options, verification gate and no credential persistence.'
} finally {
    if ($process -and -not $process.HasExited) { Stop-Process -Id $process.Id -Force }
    $env:AGENTWATCH_DATA_DIR = $originalData
    if (Test-Path $temporary) { Remove-Item $temporary -Recurse -Force }
}
