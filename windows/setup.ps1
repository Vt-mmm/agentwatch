# Piagent and Agent Watch on Windows, in one command (PowerShell):
#   irm https://raw.githubusercontent.com/Vt-mmm/agentwatch/main/windows/setup.ps1 | iex
# Installs WSL2 and Ubuntu when missing, Piagent inside Ubuntu and Agent Watch,
# connects the company key the member pastes and binds Piagent in WSL to it,
# then adds a "Piagent" Start-menu entry and opens the dashboard. Running the
# same command again updates everything. Windows PowerShell 5.1 compatible.
& {
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
$base = if ($env:AGENTWATCH_SETUP_BASE) { $env:AGENTWATCH_SETUP_BASE } else { "https://raw.githubusercontent.com/Vt-mmm/agentwatch/main/windows" }
$distro = $env:PIAGENT_WSL_DISTRO
# CI: no prompts, no password, no reboot, no dashboard window; WSL 1 allowed.
$unattended = $env:PIAGENT_SETUP_UNATTENDED -eq "1"
$command = "irm $base/setup.ps1 | iex"
$steps = 5

function Write-Step([int]$Number, [string]$Text) { Write-Host ""; Write-Host "[$Number/$steps] $Text" -ForegroundColor Cyan }
function Write-Done([string]$Text) { Write-Host "  $Text" -ForegroundColor Green }

function Get-SetupFile([string]$Name) {
  if ($base -match '^https?://') { return (Invoke-WebRequest -UseBasicParsing "$base/$Name").Content }
  return [IO.File]::ReadAllText((Join-Path $base $Name))
}

# wsl.exe with its output on the console; returns the exit code only (a
# function's own output would otherwise join what it returns).
function Invoke-Wsl([string[]]$Arguments) {
  $ErrorActionPreference = "Continue"
  & wsl.exe @Arguments | Out-Host
  return $LASTEXITCODE
}

# wsl.exe captured (UTF-8 through WSL_UTF8; NULs of UTF-16 output dropped).
function Get-Wsl([string[]]$Arguments, [string]$InputText) {
  $ErrorActionPreference = "Continue"
  if ($PSBoundParameters.ContainsKey("InputText")) { $out = $InputText | & wsl.exe @Arguments 2>$null } else { $out = & wsl.exe @Arguments 2>$null }
  $code = $LASTEXITCODE
  return [pscustomobject]@{ Code = $code; Text = ((($out | Out-String) -replace "`0", "").Trim()) }
}

function Test-WslInstalled {
  if (-not (Get-Command wsl.exe -ErrorAction SilentlyContinue)) { return $false }
  return (Get-Wsl @("--status")).Code -eq 0
}

function Get-Distros { return @((Get-Wsl @("--list", "--quiet")).Text -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ }) }

# The WSL version of a distribution from "wsl -l -v" (0 when not listed).
function Get-DistroVersion([string]$Name) {
  foreach ($line in ((Get-Wsl @("--list", "--verbose")).Text -split "`r?`n")) {
    $fields = @(($line -replace '^\s*\*?\s*', '') -split '\s+' | Where-Object { $_ })
    if ($fields.Count -ge 3 -and $fields[0] -eq $Name) { return [int]$fields[-1] }
  }
  return 0
}

# A Linux user name from the Windows one: "Vĩnh Tâm" -> "vinhtam".
function ConvertTo-LinuxUser([string]$Name) {
  $plain = ($Name -replace 'đ', 'd' -replace 'Đ', 'D').Normalize([Text.NormalizationForm]::FormD)
  $plain = -join ($plain.ToCharArray() | Where-Object { [Globalization.CharUnicodeInfo]::GetUnicodeCategory($_) -ne [Globalization.UnicodeCategory]::NonSpacingMark })
  $plain = ($plain.ToLowerInvariant() -replace '[^a-z0-9_-]', '')
  if ($plain -notmatch '^[a-z_]') { $plain = "u$plain" }
  if ($plain.Length -gt 32) { $plain = $plain.Substring(0, 32) }
  if ($plain -eq "u" -or $plain -eq "root") { return "member" }
  return $plain
}

# WSL2 runs Ubuntu in a virtual machine through the Host Compute Service,
# which "Virtual Machine Platform" installs. Seen on 2026-10-06: the feature
# read Enabled while vmcompute.exe was missing, so wsl --install asked for a
# restart after every restart and Ubuntu failed with 0x80370114.
function Test-VmPlatform { return (Test-Path (Join-Path $env:windir "System32\vmcompute.exe")) }

# Asks for a restart, and continues at the next sign-in. A second request
# after a restart means Windows did not finish the feature: say how to fix it
# instead of asking again.
function Request-Restart {
  $key = "HKCU:\Software\Piagent\Setup"
  $boot = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToString("o")
  $asked = (Get-ItemProperty $key -ErrorAction SilentlyContinue).RestartAskedAtBoot
  if ($asked -and $asked -ne $boot -and -not (Test-VmPlatform)) {
    Write-Host ""
    Write-Host "Máy đã khởi động lại nhưng Windows vẫn thiếu dịch vụ máy ảo (vmcompute.exe) của Virtual Machine Platform, nên WSL2 chưa chạy được." -ForegroundColor Yellow
    Write-Host "Sửa trong PowerShell mở bằng Run as administrator, rồi chạy lại lệnh cài này:"
    Write-Host "  DISM /Online /Cleanup-Image /RestoreHealth"
    Write-Host "  sfc /scannow"
    Write-Host "  dism.exe /online /disable-feature /featurename:VirtualMachinePlatform /norestart     (rồi Restart)"
    Write-Host "  dism.exe /online /enable-feature /featurename:VirtualMachinePlatform /all /norestart (rồi Restart)"
    Write-Host "Kiểm tra: Test-Path C:\Windows\System32\vmcompute.exe phải ra True. Vẫn False: bản Pro bật thêm Hyper-V"
    Write-Host "  (dism.exe /online /enable-feature /featurename:Microsoft-Hyper-V-All /all /norestart), hoặc cài đè Windows 11"
    Write-Host "  bằng Installation Assistant, chọn giữ file và ứng dụng."
    Remove-ItemProperty $key RestartAskedAtBoot -ErrorAction SilentlyContinue
    return
  }
  if (-not (Test-Path $key)) { New-Item $key -Force | Out-Null }
  Set-ItemProperty $key RestartAskedAtBoot $boot
  $runOnce = "HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce"
  if (-not (Test-Path $runOnce)) { New-Item $runOnce -Force | Out-Null }
  Set-ItemProperty $runOnce "PiagentSetup" "powershell.exe -NoProfile -ExecutionPolicy Bypass -NoExit -Command `"$command`""
  Write-Host ""
  Write-Host "Cần khởi động lại máy để Windows hoàn tất WSL. Sau khi đăng nhập lại, cài đặt tự chạy tiếp." -ForegroundColor Yellow
  Write-Host "Dùng Restart (không dùng Shut down). Nếu WSL báo lỗi ảo hoá (Virtualization), bật nó trong BIOS rồi chạy lại lệnh này."
  if ((Read-Host "Khởi động lại ngay? (Y/n)") -notmatch '^[nN]') { Restart-Computer }
}

function Read-Secret([string]$Prompt) {
  $secure = Read-Host $Prompt -AsSecureString
  $pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
  try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer) } finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer) }
}

function Install-Piagent {
  if ([Environment]::OSVersion.Version.Build -lt 19041) { throw "WSL2 cần Windows 10 bản 2004 (build 19041) trở lên hoặc Windows 11." }

  Write-Step 1 "WSL"
  # A listed distribution means WSL is there, also where an older wsl.exe has no --status.
  if (@(Get-Distros).Count -eq 0 -and -not (Test-WslInstalled)) {
    if ($unattended) { throw "WSL chưa được cài." }
    Write-Host "  Cài WSL; Windows sẽ hỏi quyền quản trị."
    $install = Start-Process wsl.exe -ArgumentList "--install", "--no-distribution" -Verb RunAs -Wait -PassThru
    if ($install.ExitCode -ne 0) { $install = Start-Process wsl.exe -ArgumentList "--install" -Verb RunAs -Wait -PassThru }
    if (-not (Test-WslInstalled)) { Request-Restart; return }
  }
  if (-not $unattended) { $null = Get-Wsl @("--set-default-version", "2") }
  Write-Done "WSL sẵn sàng."

  # An Ubuntu the member already has (Ubuntu, Ubuntu-24.04, Ubuntu-22.04) is
  # used rather than a second one; otherwise "Ubuntu" is installed.
  if (-not $distro) {
    $distro = @(Get-Distros | Where-Object { $_ -match '^Ubuntu(-2[2-9]\.04)?$' } | Sort-Object @{ Expression = { $_ -ne "Ubuntu" } }, @{ Expression = { $_ }; Descending = $true })[0]
    if (-not $distro) { $distro = "Ubuntu" }
  }
  Write-Step 2 "Ubuntu ($distro)"
  if ((Get-Distros) -notcontains $distro) {
    if ($unattended) { throw "Chưa có $distro trong WSL." }
    $installed = Invoke-Wsl @("--install", "-d", $distro, "--no-launch")
    # Without the VM service, wsl --install only enables Virtual Machine
    # Platform and waits for a restart.
    if ((Get-Distros) -notcontains $distro -and -not (Test-VmPlatform)) { Request-Restart; return }
    if ($installed -ne 0 -and (Get-Distros) -notcontains $distro) {
      # The Store download can drop (WININET_E_CONNECTION_ABORTED, seen
      # 2026-10-06); the web download comes from GitHub instead.
      Write-Host "  Tải lại Ubuntu theo đường web…"
      $installed = Invoke-Wsl @("--install", "-d", $distro, "--no-launch", "--web-download")
    }
    if ($installed -ne 0 -and (Get-Distros) -notcontains $distro) { throw "Không tải được $distro. Thử mạng khác hoặc tắt VPN/proxy, rồi chạy lại lệnh này." }
    if ((Get-Distros) -notcontains $distro) {
      # Store-packaged Ubuntu registers through its launcher; --root skips its
      # user prompt, the user is made below.
      $launcher = (($distro -replace '[^A-Za-z0-9]', '').ToLowerInvariant()) + ".exe"
      if (Get-Command $launcher -ErrorAction SilentlyContinue) { & $launcher install --root | Out-Null }
      if ((Get-Distros) -notcontains $distro) { throw "Mở Ubuntu một lần từ Start menu, tạo user, rồi chạy lại lệnh này." }
    }
  }
  if ((Get-DistroVersion $distro) -eq 1 -and -not $unattended) {
    Write-Host "  Chuyển $distro sang WSL2 (vài phút)…"
    if ((Invoke-Wsl @("--set-version", $distro, "2")) -ne 0) { throw "Không chuyển được $distro sang WSL2. Bật Virtualization trong BIOS rồi chạy lại lệnh này." }
  }
  $user = (Get-Wsl @("-d", $distro, "-u", "root", "-e", "sh", "-c", "getent passwd 1000 | cut -d: -f1")).Text
  if (-not $user) {
    $user = ConvertTo-LinuxUser $env:USERNAME
    Write-Host "  Tạo user '$user' trong Ubuntu."
    $made = Get-Wsl @("-d", $distro, "-u", "root", "-e", "sh", "-c", "useradd -m -s /bin/bash -u 1000 -G sudo $user")
    if ($made.Code -ne 0) { throw "Không tạo được user $user trong Ubuntu: $($made.Text)" }
    if (-not $unattended) {
      while ($true) {
        $first = Read-Secret "  Đặt mật khẩu cho $user (dùng khi chạy sudo trong Ubuntu)"
        $second = Read-Secret "  Nhập lại mật khẩu"
        if ($first -and $first -eq $second) { break }
        Write-Host "  Hai lần nhập không khớp hoặc để trống, nhập lại." -ForegroundColor Yellow
      }
      # Through standard input, never on a command line.
      $previous = $OutputEncoding; $OutputEncoding = New-Object Text.UTF8Encoding $false
      try { $set = Get-Wsl @("-d", $distro, "-u", "root", "-e", "sh", "-c", "tr -d '\r' | chpasswd") "${user}:$first" } finally { $OutputEncoding = $previous }
      $first = $null; $second = $null
      if ($set.Code -ne 0) { throw "Không đặt được mật khẩu cho $user." }
    }
  }
  # Ubuntu opens as the member: Agent Watch's binding (and the member's own
  # terminals) run as WSL's default user, which can be root even when the
  # user exists (2026-10-06: bind-wsl looked in /root for Piagent).
  if ((Get-Wsl @("-d", $distro, "-e", "id", "-un")).Text -ne $user) {
    $conf = "f=/etc/wsl.conf; touch `$f; if grep -q '^\[user\]' `$f; then sed -i '/^\[user\]/,/^\[/{/^default *=/d}' `$f; sed -i '/^\[user\]/a default=$user' `$f; else printf '\n[user]\ndefault=%s\n' $user >> `$f; fi"
    if ((Get-Wsl @("-d", $distro, "-u", "root", "-e", "sh", "-c", $conf)).Code -ne 0) { throw "Không đặt được user mặc định cho Ubuntu." }
    $null = Get-Wsl @("--terminate", $distro)
  }
  Remove-ItemProperty "HKCU:\Software\Piagent\Setup" RestartAskedAtBoot -ErrorAction SilentlyContinue
  Write-Done "Ubuntu sẵn sàng, user $user."

  Write-Step 3 "Piagent trong Ubuntu (lần đầu mất vài phút)"
  $local = Join-Path $env:TEMP "piagent-setup-ubuntu.sh"
  [IO.File]::WriteAllText($local, ((Get-SetupFile "setup-ubuntu.sh") -replace "`r`n", "`n"), (New-Object Text.UTF8Encoding $false))
  $script = (Get-Wsl @("-d", $distro, "-u", "root", "-e", "wslpath", "-a", $local)).Text
  if (-not $script) { throw "Ubuntu không đọc được ổ C: (wslpath)." }
  $epoch = [string][DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
  if ((Invoke-Wsl @("-d", $distro, "-u", "root", "-e", "bash", $script, "system", $user, $epoch)) -ne 0) { throw "Cài gói Ubuntu không xong; xem lỗi phía trên rồi chạy lại lệnh này." }
  $gitName = ""; $gitEmail = ""
  if (Get-Command git.exe -ErrorAction SilentlyContinue) {
    $ErrorActionPreference = "Continue"
    $gitName = "$(git.exe config --global user.name 2>$null)".Trim(); $gitEmail = "$(git.exe config --global user.email 2>$null)".Trim()
    $ErrorActionPreference = "Stop"
  }
  $ErrorActionPreference = "Continue"
  # "-" stands for an empty value: Windows PowerShell drops empty arguments.
  if (-not $gitName) { $gitName = "-" }; if (-not $gitEmail) { $gitEmail = "-" }
  $lines = @(& wsl.exe -d $distro -u $user --cd "~" -e bash $script piagent $gitName $gitEmail | ForEach-Object { Write-Host "  $_"; $_ })
  $exit = $LASTEXITCODE
  $ErrorActionPreference = "Stop"
  Remove-Item $local -ErrorAction SilentlyContinue
  if ($exit -ne 0) {
    if ($lines -contains "HINT-CLOCK") { throw "Ubuntu không kết nối HTTPS được vì đồng hồ lệch. Chạy: wsl --shutdown, rồi chạy lại lệnh này." }
    if ($lines -contains "HINT-DNS") { throw "Ubuntu không phân giải được tên miền (DNS). Chạy: wsl --shutdown, rồi chạy lại lệnh này; vẫn lỗi thì tắt VPN hoặc thử mạng khác." }
    if ($lines -contains "HINT-NETWORK") { throw "Ubuntu không tải được từ nodejs.org. Kiểm tra mạng, tắt VPN/proxy, chạy wsl --shutdown, rồi chạy lại lệnh này." }
    throw "Cài Piagent trong Ubuntu không xong; xem lỗi phía trên rồi chạy lại lệnh này."
  }
  $version = ($lines | Where-Object { $_ -like "PIAGENT-VERSION *" } | Select-Object -Last 1) -replace '^PIAGENT-VERSION\s+', ''
  Write-Done "Piagent $version đã cài trong Ubuntu."
  if ($lines -contains "SANDBOX-UNAVAILABLE") { Write-Host "  Sandbox của chế độ công ty chưa chạy được trong $distro (cần WSL2). Chế độ cá nhân vẫn dùng được." -ForegroundColor Yellow }

  Write-Step 4 "Agent Watch và key công ty"
  $cli = Join-Path $env:LOCALAPPDATA "AgentWatch\app\agentwatch.exe"
  $code = if ($env:AGENTWATCH_CODE) { $env:AGENTWATCH_CODE } elseif ($unattended) { "" } else { Read-Secret "  Dán mã kết nối admin gửi (Enter để bỏ qua nếu chỉ dùng tài khoản AI của riêng bạn)" }
  if (-not $code -and -not (Test-Path $cli)) {
    Write-Done "Bỏ qua: chỉ dùng chế độ cá nhân. Chạy lại lệnh này khi có mã kết nối."
  } else {
    if (Get-Process agentwatch -ErrorAction SilentlyContinue) { Write-Host "  Cập nhật Agent Watch sẽ dừng phiên Piagent công ty đang chạy; mở lại sau khi xong." -ForegroundColor Yellow }
    $env:AGENTWATCH_NO_LAUNCH = "1"
    try { Invoke-Expression (Get-SetupFile "install.ps1") } finally { Remove-Item Env:AGENTWATCH_NO_LAUNCH -ErrorAction SilentlyContinue }
    $ErrorActionPreference = "Continue"
    if ($code) {
      $code | & $cli connect - | ForEach-Object { Write-Host "  $_" }
      if ($LASTEXITCODE -ne 0) { $ErrorActionPreference = "Stop"; throw "Mã kết nối không dùng được; hỏi admin mã mới rồi chạy lại lệnh này." }
    }
    $code = $null
    & $cli bind-wsl --distro $distro | ForEach-Object { Write-Host "  $_" }
    $bound = $LASTEXITCODE -eq 0
    $ErrorActionPreference = "Stop"
    if (-not $bound) { Write-Host "  Chưa nối được Piagent với key công ty (chỉ key công ty mới cần). Chế độ cá nhân vẫn dùng được." -ForegroundColor Yellow }
    # Starts with Windows, so it binds Piagent again after its own updates.
    $app = Join-Path $env:LOCALAPPDATA "AgentWatch\app\AgentWatchApp.exe"
    Set-ItemProperty "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run" "AgentWatch" "`"$app`" --background"
    if (-not $unattended) { Start-Process $app -ArgumentList "--background" }
    Write-Done "Agent Watch đã cài$(if ($bound) { ' và Piagent trong Ubuntu dùng được key công ty' })."
  }

  Write-Step 5 "Mở Piagent"
  $wsl = (Get-Command wsl.exe).Source
  $arguments = "-d $distro --cd ~ -e bash -lic `"piagent dashboard; exec bash`""
  $shell = New-Object -ComObject WScript.Shell
  $link = $shell.CreateShortcut((Join-Path ([Environment]::GetFolderPath("Programs")) "Piagent.lnk"))
  $link.TargetPath = $wsl; $link.Arguments = $arguments; $link.Description = "Piagent dashboard ($distro)"; $link.Save()
  Write-Done "Start menu có mục Piagent: mở dashboard trong trình duyệt. Giữ cửa sổ Ubuntu đó mở khi dùng."
  if (-not $unattended) { Start-Process $wsl -ArgumentList $arguments }
  Write-Host ""
  Write-Host "Xong. Cập nhật sau này: chạy lại đúng lệnh vừa dùng." -ForegroundColor Green
}

$previousEncoding = [Console]::OutputEncoding
$previousWslUtf8 = $env:WSL_UTF8
try {
  try { [Console]::OutputEncoding = New-Object Text.UTF8Encoding $false } catch { }
  $env:WSL_UTF8 = "1"
  Install-Piagent
} catch {
  Write-Host ""
  Write-Host "Chưa cài xong: $($_.Exception.Message)" -ForegroundColor Red
  if ($unattended) { throw }
} finally {
  try { [Console]::OutputEncoding = $previousEncoding } catch { }
  $env:WSL_UTF8 = $previousWslUtf8
}
}
