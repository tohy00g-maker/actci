<#
  ActRunner.ps1 — 在本地 WSL 裡用 act 執行 GitHub Actions workflow 的圖形介面

  需求：Windows 10/11、WSL2 發行版（預設 Ubuntu）、Docker Desktop（需啟用 WSL integration）
  啟動：雙擊 ActRunner.bat
        或 powershell -NoProfile -ExecutionPolicy Bypass -STA -File ActRunner.ps1
  自測：powershell -File ActRunner.ps1 -SelfTest
#>
param([switch]$SelfTest)

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}

# ---------------------------------------------------------------------------
# 狀態與設定
# ---------------------------------------------------------------------------
$script:Distro       = 'Ubuntu'
$script:LinuxHome    = ''
$script:LinuxUser    = ''
$script:BashPrefix   = 'export PATH=$HOME/.local/bin:$PATH; '
$script:AnsiRegex    = [regex]'\x1B\[[0-?]*[ -/]*[@-~]'
$script:SettingsDir  = Join-Path $env:APPDATA 'ActRunner'
$script:SettingsFile = Join-Path $script:SettingsDir 'settings.json'
$script:DockerExe    = Join-Path $env:ProgramFiles 'Docker\Docker\Docker Desktop.exe'

# 執行中的 act 程序
$script:RunProc      = $null
$script:RunStream    = $null
$script:RunAsync     = $null
$script:RunBuffer    = New-Object byte[] 65536
$script:Decoder      = $null
$script:LinePending  = ''
$script:StopRequested = $null
$script:RunStarted   = $null

function Load-Settings {
    $default = [pscustomobject]@{ Distro = 'Ubuntu'; RepoPath = ''; Event = 'push'; ExtraArgs = '' }
    if (Test-Path $script:SettingsFile) {
        try {
            $s = Get-Content $script:SettingsFile -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($p in 'Distro', 'RepoPath', 'Event', 'ExtraArgs') {
                if ($s.PSObject.Properties[$p]) { $default.$p = [string]$s.$p }
            }
        } catch {}
    }
    return $default
}

function Save-Settings($s) {
    try {
        New-Item -ItemType Directory -Force -Path $script:SettingsDir | Out-Null
        $s | ConvertTo-Json | Set-Content -Path $script:SettingsFile -Encoding UTF8
    } catch {}
}

# ---------------------------------------------------------------------------
# 字串與路徑工具
# ---------------------------------------------------------------------------
function ConvertTo-BashArg([string]$s) {
    # 單引號包住，內部單引號改成 '\''
    return "'" + ($s -replace "'", "'\''") + "'"
}

function ConvertTo-WinArg([string]$s) {
    # 依 Windows CommandLineToArgvW 規則加雙引號並跳脫
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('"')
    $bs = 0
    foreach ($ch in $s.ToCharArray()) {
        if ($ch -eq '\') { $bs++ }
        elseif ($ch -eq '"') { [void]$sb.Append('\' * ($bs * 2 + 1)); [void]$sb.Append('"'); $bs = 0 }
        else { if ($bs) { [void]$sb.Append('\' * $bs); $bs = 0 }; [void]$sb.Append($ch) }
    }
    if ($bs) { [void]$sb.Append('\' * ($bs * 2)) }
    [void]$sb.Append('"')
    return $sb.ToString()
}

function Convert-ToWslPath([string]$p) {
    if ([string]::IsNullOrWhiteSpace($p)) { return '' }
    $p = $p.Trim().TrimEnd('\')
    # \\wsl.localhost\Ubuntu\home\me\src  或  \\wsl$\Ubuntu\home\me\src
    if ($p -match '^\\\\wsl(\$|\.localhost)\\[^\\]+(\\.*)?$') {
        $rest = $Matches[2]
        if (-not $rest) { return '/' }
        return ($rest -replace '\\', '/')
    }
    # C:\Users\me\src  ->  /mnt/c/Users/me/src
    if ($p -match '^([A-Za-z]):(\\.*)?$') {
        $drive = $Matches[1].ToLower()
        $rest = $Matches[2]
        if (-not $rest) { return "/mnt/$drive" }
        return "/mnt/$drive" + ($rest -replace '\\', '/')
    }
    # 已經是 Linux 路徑
    return $p
}

function Strip-Ansi([string]$s) {
    return $script:AnsiRegex.Replace($s, '')
}

# ---------------------------------------------------------------------------
# WSL 呼叫
# ---------------------------------------------------------------------------
function Get-WslDistros {
    $result = @()
    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = 'wsl.exe'
        $psi.Arguments = '-l -q'
        $psi.UseShellExecute = $false
        $psi.RedirectStandardOutput = $true
        $psi.CreateNoWindow = $true
        $psi.StandardOutputEncoding = [System.Text.Encoding]::Unicode   # wsl.exe 自身輸出是 UTF-16LE
        $p = [System.Diagnostics.Process]::Start($psi)
        $out = $p.StandardOutput.ReadToEnd()
        $p.WaitForExit(10000) | Out-Null
        foreach ($line in ($out -split "`r?`n")) {
            $n = ($line -replace "`0", '').Trim()
            if ($n -and $n -notlike 'docker-desktop*') { $result += $n }
        }
    } catch {}
    return ,$result
}

function ConvertFrom-WslBytes([byte[]]$bytes) {
    # Linux 程式輸出 UTF-8；wsl.exe 自身的訊息（例如找不到發行版）卻是 UTF-16LE。依零位元組比例判斷。
    if (-not $bytes -or $bytes.Length -eq 0) { return '' }
    $zeros = 0
    $i = 1
    while ($i -lt $bytes.Length) { if ($bytes[$i] -eq 0) { $zeros++ }; $i += 2 }
    $half = [Math]::Max(1, [int]($bytes.Length / 2))
    if ($zeros * 100 / $half -gt 30) { return [System.Text.Encoding]::Unicode.GetString($bytes) -replace "`0", '' }
    return [System.Text.Encoding]::UTF8.GetString($bytes)
}

function New-WslStartInfo([string]$BashCommand) {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = 'wsl.exe'
    # 注意：wsl.exe 不會去掉發行版名稱兩側的引號，這裡不能用 ConvertTo-WinArg 包 -d 的值
    $psi.Arguments = '-d ' + $script:Distro + ' -- bash -lc ' + (ConvertTo-WinArg $BashCommand)
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.WorkingDirectory = $env:SystemRoot   # 避免 WSL 對目前目錄 chdir 失敗的警告
    return $psi
}

function Invoke-Wsl([string]$BashCommand, [int]$TimeoutMs = 60000) {
    try {
        $psi = New-WslStartInfo $BashCommand
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $p = [System.Diagnostics.Process]::Start($psi)
        $msOut = New-Object System.IO.MemoryStream
        $msErr = New-Object System.IO.MemoryStream
        $tOut = $p.StandardOutput.BaseStream.CopyToAsync($msOut)
        $tErr = $p.StandardError.BaseStream.CopyToAsync($msErr)
        if (-not $p.WaitForExit($TimeoutMs)) {
            try { $p.Kill() } catch {}
            return [pscustomobject]@{ ExitCode = -1; Output = ''; Error = "逾時（${TimeoutMs} ms）" }
        }
        [System.Threading.Tasks.Task]::WaitAll(@($tOut, $tErr))
        $out = (ConvertFrom-WslBytes $msOut.ToArray()).TrimEnd()
        $err = (ConvertFrom-WslBytes $msErr.ToArray()).TrimEnd()
        return [pscustomobject]@{ ExitCode = $p.ExitCode; Output = $out; Error = $err }
    } catch {
        return [pscustomobject]@{ ExitCode = -1; Output = ''; Error = $_.Exception.Message }
    }
}

function Parse-ActList([string]$text) {
    $jobs = @()
    foreach ($line in ($text -split "`r?`n")) {
        $l = (Strip-Ansi $line).TrimEnd()
        if (-not $l) { continue }
        if ($l -match '^\s*Stage\s+Job ID') { continue }
        if ($l -match '^\s*(WARN|INFO|ERRO|DEBU|FATA|level=|time=)') { continue }
        $cols = [regex]::Split($l.Trim(), '\s{2,}')
        if ($cols.Count -lt 6) { continue }
        if ($cols[0] -notmatch '^\d+$') { continue }
        $jobs += [pscustomobject]@{
            Stage = $cols[0]; JobId = $cols[1]; JobName = $cols[2]
            Workflow = $cols[3]; File = $cols[4]; Events = $cols[5]
        }
    }
    return ,$jobs
}

# ---------------------------------------------------------------------------
# 自測模式（不開視窗）
# ---------------------------------------------------------------------------
if ($SelfTest) {
    $fail = 0
    function Assert($cond, $msg) { if ($cond) { Write-Host "  PASS  $msg" } else { Write-Host "  FAIL  $msg"; $script:fail++ } }

    Write-Host '[路徑轉換]'
    Assert ((Convert-ToWslPath 'C:\Users\me\src') -eq '/mnt/c/Users/me/src') 'C:\ -> /mnt/c'
    Assert ((Convert-ToWslPath 'D:\') -eq '/mnt/d') 'D:\ -> /mnt/d'
    Assert ((Convert-ToWslPath '\\wsl.localhost\Ubuntu\home\me\src\') -eq '/home/me/src') 'wsl.localhost -> /home'
    Assert ((Convert-ToWslPath '\\wsl$\Ubuntu\home\me') -eq '/home/me') 'wsl$ -> /home'
    Assert ((Convert-ToWslPath '/home/me/src') -eq '/home/me/src') 'linux path passthrough'
    Assert ((Convert-ToWslPath '~/src') -eq '~/src') 'tilde passthrough'

    Write-Host '[引號]'
    Assert ((ConvertTo-BashArg "it's") -eq "'it'\''s'") 'bash single quote escape'
    Assert ((ConvertTo-WinArg 'a "b" c\') -eq '"a \"b\" c\\"') 'win arg quoting'

    Write-Host '[act -l 解析]'
    $sample = @"
INFO[0000] Using docker host 'unix:///var/run/docker.sock'
Stage  Job ID  Job name     Workflow name  Workflow file  Events
0      build   Build app    CI             ci.yml         push,pull_request
0      lint    lint         CI             ci.yml         push
1      deploy  Deploy prod  Deploy         deploy.yml     workflow_dispatch
"@
    $jobs = Parse-ActList $sample
    Assert ($jobs.Count -eq 3) "parsed 3 jobs (got $($jobs.Count))"
    Assert ($jobs[0].JobId -eq 'build' -and $jobs[0].JobName -eq 'Build app') 'job with space in name'
    Assert ($jobs[2].Events -eq 'workflow_dispatch') 'events column'

    Write-Host '[WSL]'
    $distros = Get-WslDistros
    Write-Host "  發行版: $($distros -join ', ')"
    if ($distros.Count -gt 0) {
        $script:Distro = $distros[0]
        $r = Invoke-Wsl 'echo 中文OK; echo "$HOME"; command -v act || echo __NOACT__' 30000
        Write-Host "  exit=$($r.ExitCode)"
        Write-Host ("  out=" + ($r.Output -replace "`n", ' | '))
        if ($r.Error) { Write-Host "  err=$($r.Error)" }
        Assert ($r.Output -like '*中文OK*') 'UTF-8 round trip'
    }
    Write-Host ''
    if ($fail) { Write-Host "$fail 項失敗"; exit 1 } else { Write-Host '全部通過'; exit 0 }
}

# ---------------------------------------------------------------------------
# UI
# ---------------------------------------------------------------------------
$settings = Load-Settings
$script:Distro = $settings.Distro

$form = New-Object System.Windows.Forms.Form
$form.Text = 'ActRunner — GitHub Actions 本地執行器'
$form.StartPosition = 'CenterScreen'
$form.ClientSize = New-Object System.Drawing.Size(1000, 740)
$form.MinimumSize = New-Object System.Drawing.Size(900, 620)
$form.Font = New-Object System.Drawing.Font('Microsoft JhengHei UI', 9)

$W = $form.ClientSize.Width
$AnchorTLR  = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
$AnchorTR   = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Right
$AnchorAll  = $AnchorTLR -bor [System.Windows.Forms.AnchorStyles]::Bottom

function New-Label($text, $x, $y, $w) {
    $l = New-Object System.Windows.Forms.Label
    $l.Text = $text; $l.Location = New-Object System.Drawing.Point($x, $y)
    $l.AutoSize = $false; $l.Size = New-Object System.Drawing.Size($w, 20)
    $l.TextAlign = 'MiddleLeft'
    return $l
}
function New-Button($text, $x, $y, $w, $h) {
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $text; $b.Location = New-Object System.Drawing.Point($x, $y)
    $b.Size = New-Object System.Drawing.Size($w, $h)
    return $b
}

# ---- 環境群組 --------------------------------------------------------------
$grpEnv = New-Object System.Windows.Forms.GroupBox
$grpEnv.Text = '環境'
$grpEnv.Location = New-Object System.Drawing.Point(10, 8)
$grpEnv.Size = New-Object System.Drawing.Size(($W - 20), 108)
$grpEnv.Anchor = $AnchorTLR

$grpEnv.Controls.Add((New-Label 'WSL 發行版' 12 26 80))
$cboDistro = New-Object System.Windows.Forms.ComboBox
$cboDistro.Location = New-Object System.Drawing.Point(95, 23)
$cboDistro.Size = New-Object System.Drawing.Size(160, 24)
$cboDistro.DropDownStyle = 'DropDownList'
$grpEnv.Controls.Add($cboDistro)

$lblWsl    = New-Label 'WSL：未檢查'    12 52 240
$lblDocker = New-Label 'Docker：未檢查' 12 76 240
$lblAct    = New-Label 'act：未檢查'    270 26 300
$lblActrc  = New-Label '.actrc：未檢查' 270 52 300
$lblHint   = New-Label '' 270 76 300
$lblHint.ForeColor = [System.Drawing.Color]::DimGray
$grpEnv.Controls.AddRange(@($lblWsl, $lblDocker, $lblAct, $lblActrc, $lblHint))

$pnlEnvBtns = New-Object System.Windows.Forms.FlowLayoutPanel
$pnlEnvBtns.Location = New-Object System.Drawing.Point(($W - 20 - 400), 18)
$pnlEnvBtns.Size = New-Object System.Drawing.Size(390, 82)
$pnlEnvBtns.Anchor = $AnchorTR
$btnCheck   = New-Button '檢查環境' 0 0 120 30
$btnDocker  = New-Button '啟動 Docker Desktop' 0 0 130 30
$btnInstall = New-Button '安裝 / 更新 act' 0 0 120 30
$btnActrc   = New-Button '建立 ~/.actrc' 0 0 120 30
$btnSecrets = New-Button '編輯 secrets' 0 0 130 30
$btnOpenHome = New-Button '開啟 Linux 家目錄' 0 0 120 30
$pnlEnvBtns.Controls.AddRange(@($btnCheck, $btnDocker, $btnInstall, $btnActrc, $btnSecrets, $btnOpenHome))
$grpEnv.Controls.Add($pnlEnvBtns)
$form.Controls.Add($grpEnv)

# ---- 專案群組 --------------------------------------------------------------
$grpRepo = New-Object System.Windows.Forms.GroupBox
$grpRepo.Text = '專案與 workflow'
$grpRepo.Location = New-Object System.Drawing.Point(10, 122)
$grpRepo.Size = New-Object System.Drawing.Size(($W - 20), 262)
$grpRepo.Anchor = $AnchorTLR

$grpRepo.Controls.Add((New-Label 'Repo 路徑' 12 26 75))
$txtRepo = New-Object System.Windows.Forms.TextBox
$txtRepo.Location = New-Object System.Drawing.Point(90, 23)
$txtRepo.Size = New-Object System.Drawing.Size(($W - 20 - 90 - 230), 24)
$txtRepo.Anchor = $AnchorTLR
$txtRepo.Text = $settings.RepoPath
$grpRepo.Controls.Add($txtRepo)

$btnBrowse = New-Button '瀏覽…' ($W - 20 - 225) 21 100 28
$btnBrowse.Anchor = $AnchorTR
$btnList = New-Button '讀取 job 清單' ($W - 20 - 118) 21 108 28
$btnList.Anchor = $AnchorTR
$grpRepo.Controls.AddRange(@($btnBrowse, $btnList))

$lvJobs = New-Object System.Windows.Forms.ListView
$lvJobs.Location = New-Object System.Drawing.Point(12, 54)
$lvJobs.Size = New-Object System.Drawing.Size(($W - 20 - 24), 130)
$lvJobs.Anchor = $AnchorTLR
$lvJobs.View = 'Details'; $lvJobs.FullRowSelect = $true; $lvJobs.MultiSelect = $false
$lvJobs.GridLines = $true; $lvJobs.HideSelection = $false
[void]$lvJobs.Columns.Add('Job ID', 160)
[void]$lvJobs.Columns.Add('Job 名稱', 200)
[void]$lvJobs.Columns.Add('Workflow', 180)
[void]$lvJobs.Columns.Add('檔案', 160)
[void]$lvJobs.Columns.Add('事件', 220)
$grpRepo.Controls.Add($lvJobs)

$grpRepo.Controls.Add((New-Label '事件' 12 194 40))
$cboEvent = New-Object System.Windows.Forms.ComboBox
$cboEvent.Location = New-Object System.Drawing.Point(55, 191)
$cboEvent.Size = New-Object System.Drawing.Size(170, 24)
$cboEvent.DropDownStyle = 'DropDown'
[void]$cboEvent.Items.AddRange(@('push', 'pull_request', 'workflow_dispatch', 'schedule', 'release', 'workflow_call'))
$cboEvent.Text = $settings.Event
$grpRepo.Controls.Add($cboEvent)

$chkSelected = New-Object System.Windows.Forms.CheckBox
$chkSelected.Text = '只跑選取的 job'; $chkSelected.Checked = $true
$chkSelected.Location = New-Object System.Drawing.Point(240, 192); $chkSelected.AutoSize = $true
$chkDry = New-Object System.Windows.Forms.CheckBox
$chkDry.Text = 'Dry run (-n)'; $chkDry.Location = New-Object System.Drawing.Point(370, 192); $chkDry.AutoSize = $true
$chkVerbose = New-Object System.Windows.Forms.CheckBox
$chkVerbose.Text = '詳細輸出 (-v)'; $chkVerbose.Location = New-Object System.Drawing.Point(475, 192); $chkVerbose.AutoSize = $true
$chkReuse = New-Object System.Windows.Forms.CheckBox
$chkReuse.Text = '保留容器 (--reuse)'; $chkReuse.Location = New-Object System.Drawing.Point(590, 192); $chkReuse.AutoSize = $true
$grpRepo.Controls.AddRange(@($chkSelected, $chkDry, $chkVerbose, $chkReuse))

$grpRepo.Controls.Add((New-Label '額外參數' 12 226 70))
$txtExtra = New-Object System.Windows.Forms.TextBox
$txtExtra.Location = New-Object System.Drawing.Point(90, 223)
$txtExtra.Size = New-Object System.Drawing.Size(($W - 20 - 90 - 450), 24)
$txtExtra.Anchor = $AnchorTLR
$txtExtra.Text = $settings.ExtraArgs
$grpRepo.Controls.Add($txtExtra)

$btnRun  = New-Button '▶  執行' ($W - 20 - 445) 220 110 30
$btnStop = New-Button '■  停止' ($W - 20 - 330) 220 100 30
$btnClear = New-Button '清除 log' ($W - 20 - 222) 220 100 30
$btnSave  = New-Button '儲存 log…' ($W - 20 - 117) 220 105 30
foreach ($b in @($btnRun, $btnStop, $btnClear, $btnSave)) { $b.Anchor = $AnchorTR }
$btnRun.Font = New-Object System.Drawing.Font($form.Font, [System.Drawing.FontStyle]::Bold)
$btnStop.Enabled = $false
$grpRepo.Controls.AddRange(@($btnRun, $btnStop, $btnClear, $btnSave))
$form.Controls.Add($grpRepo)

# ---- Log ------------------------------------------------------------------
$rtbLog = New-Object System.Windows.Forms.RichTextBox
$rtbLog.Location = New-Object System.Drawing.Point(10, 392)
$rtbLog.Size = New-Object System.Drawing.Size(($W - 20), ($form.ClientSize.Height - 392 - 34))
$rtbLog.Anchor = $AnchorAll
$rtbLog.ReadOnly = $true
$rtbLog.Font = New-Object System.Drawing.Font('Consolas', 9.5)
$rtbLog.BackColor = [System.Drawing.Color]::FromArgb(30, 30, 30)
$rtbLog.ForeColor = [System.Drawing.Color]::Gainsboro
$rtbLog.WordWrap = $false
$rtbLog.ScrollBars = 'Both'
$rtbLog.DetectUrls = $false
$form.Controls.Add($rtbLog)

$status = New-Object System.Windows.Forms.StatusStrip
$lblStatus = New-Object System.Windows.Forms.ToolStripStatusLabel
$lblStatus.Text = '就緒'
[void]$status.Items.Add($lblStatus)
$form.Controls.Add($status)

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 100

# ---------------------------------------------------------------------------
# UI 輔助
# ---------------------------------------------------------------------------
function Append-Log([string]$text, [System.Drawing.Color]$color) {
    if ([string]::IsNullOrEmpty($text)) { return }
    $rtbLog.SelectionStart = $rtbLog.TextLength
    $rtbLog.SelectionLength = 0
    if ($color) { $rtbLog.SelectionColor = $color } else { $rtbLog.SelectionColor = $rtbLog.ForeColor }
    $rtbLog.AppendText($text)
    $rtbLog.SelectionColor = $rtbLog.ForeColor
    $rtbLog.ScrollToCaret()
}
function Log-Info([string]$t)  { Append-Log ("[ActRunner] $t`n") ([System.Drawing.Color]::DeepSkyBlue) }
function Log-Ok([string]$t)    { Append-Log ("[ActRunner] $t`n") ([System.Drawing.Color]::LightGreen) }
function Log-Warn([string]$t)  { Append-Log ("[ActRunner] $t`n") ([System.Drawing.Color]::Gold) }
function Log-Error([string]$t) { Append-Log ("[ActRunner] $t`n") ([System.Drawing.Color]::Salmon) }
function Set-Status([string]$t) { $lblStatus.Text = $t; $status.Refresh() }

function Set-Busy([bool]$busy) {
    if ($busy) { $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor } else { $form.Cursor = [System.Windows.Forms.Cursors]::Default }
    [System.Windows.Forms.Application]::DoEvents()
}

function Get-RepoLinuxPath {
    $p = Convert-ToWslPath $txtRepo.Text
    if (-not $p) { [System.Windows.Forms.MessageBox]::Show('請先填入 repo 路徑。', 'ActRunner') | Out-Null; return $null }
    return $p
}

function Persist-Settings {
    $settings.Distro = $script:Distro
    $settings.RepoPath = $txtRepo.Text
    $settings.Event = $cboEvent.Text
    $settings.ExtraArgs = $txtExtra.Text
    Save-Settings $settings
}

# ---------------------------------------------------------------------------
# 環境檢查
# ---------------------------------------------------------------------------
function Refresh-Distros {
    $cboDistro.Items.Clear()
    $ds = Get-WslDistros
    foreach ($d in $ds) { [void]$cboDistro.Items.Add($d) }
    if ($ds.Count -eq 0) {
        $lblWsl.Text = 'WSL：找不到任何發行版'; $lblWsl.ForeColor = [System.Drawing.Color]::Firebrick
        return
    }
    if ($ds -contains $script:Distro) { $cboDistro.SelectedItem = $script:Distro }
    else { $cboDistro.SelectedIndex = 0; $script:Distro = [string]$cboDistro.SelectedItem }
}

function Check-Environment {
    Set-Busy $true
    Set-Status '檢查環境中…'
    $ok = $true

    # WSL
    $r = Invoke-Wsl 'echo __OK__; whoami; echo $HOME' 30000
    if ($r.ExitCode -eq 0 -and $r.Output -like '__OK__*') {
        $lines = $r.Output -split "`n"
        $script:LinuxUser = $lines[1].Trim(); $script:LinuxHome = $lines[2].Trim()
        $lblWsl.Text = "WSL：$($script:Distro) 可用（$($script:LinuxUser)）"; $lblWsl.ForeColor = [System.Drawing.Color]::ForestGreen
    } else {
        $lblWsl.Text = "WSL：$($script:Distro) 無法啟動"; $lblWsl.ForeColor = [System.Drawing.Color]::Firebrick
        Log-Error "WSL 發行版 $($script:Distro) 無法啟動：$($r.Error) $($r.Output)"
        Set-Busy $false; Set-Status '環境檢查失敗'; return $false
    }

    # Docker
    $d = Invoke-Wsl ($script:BashPrefix + 'if command -v docker >/dev/null 2>&1; then v=$(docker info --format {{.ServerVersion}} 2>/dev/null); if [ -n "$v" ]; then echo __DOCKER__ $v; else echo __NODAEMON__; fi; else echo __NODOCKER__; fi') 30000
    if ($d.Output -like '__DOCKER__*') {
        $lblDocker.Text = "Docker：$($d.Output -replace '__DOCKER__\s*','') 可用"; $lblDocker.ForeColor = [System.Drawing.Color]::ForestGreen
    } elseif ($d.Output -like '*__NODAEMON__*') {
        $lblDocker.Text = 'Docker：有指令但 daemon 未回應'; $lblDocker.ForeColor = [System.Drawing.Color]::DarkOrange
        Log-Warn 'Docker daemon 未回應。請確認 Docker Desktop 已啟動並完成初始化。'
        $ok = $false
    } else {
        $lblDocker.Text = 'Docker：WSL 內找不到 docker'; $lblDocker.ForeColor = [System.Drawing.Color]::Firebrick
        Log-Warn 'WSL 內沒有 docker 指令。請啟動 Docker Desktop，並在 Settings > Resources > WSL integration 勾選此發行版。'
        $ok = $false
    }

    # act
    $a = Invoke-Wsl ($script:BashPrefix + 'if command -v act >/dev/null 2>&1; then act --version 2>&1; else echo __NOACT__; fi') 30000
    if ($a.Output -like '*__NOACT__*' -or -not $a.Output) {
        $lblAct.Text = 'act：未安裝'; $lblAct.ForeColor = [System.Drawing.Color]::Firebrick
        Log-Warn 'act 未安裝。按「安裝 / 更新 act」會裝到 ~/.local/bin，不需要 sudo。'
        $ok = $false
    } else {
        $lblAct.Text = "act：$($a.Output.Trim())"; $lblAct.ForeColor = [System.Drawing.Color]::ForestGreen
    }

    # .actrc
    $c = Invoke-Wsl 'if [ -f ~/.actrc ]; then grep -c . ~/.actrc; else echo __NOACTRC__; fi' 15000
    if ($c.Output -like '*__NOACTRC__*') {
        $lblActrc.Text = '.actrc：不存在（第一次執行會卡在互動式選單）'; $lblActrc.ForeColor = [System.Drawing.Color]::DarkOrange
        Log-Warn '~/.actrc 不存在。沒有它，act 第一次執行會停下來問你選映像，視窗程式接不到。請按「建立 ~/.actrc」。'
        $ok = $false
    } else {
        $lblActrc.Text = ".actrc：已設定（$($c.Output.Trim()) 行）"; $lblActrc.ForeColor = [System.Drawing.Color]::ForestGreen
    }

    Set-Busy $false
    if ($ok) { Set-Status '環境正常'; Log-Ok '環境檢查通過。' } else { Set-Status '環境有待處理項目' }
    return $ok
}

# ---------------------------------------------------------------------------
# 環境操作
# ---------------------------------------------------------------------------
function Start-DockerDesktop {
    if (-not (Test-Path $script:DockerExe)) {
        [System.Windows.Forms.MessageBox]::Show("找不到 Docker Desktop：`n$($script:DockerExe)`n`n請先安裝 Docker Desktop，或手動啟動。", 'ActRunner') | Out-Null
        return
    }
    $running = Get-Process -Name 'Docker Desktop' -ErrorAction SilentlyContinue
    if ($running) { Log-Info 'Docker Desktop 已在執行。若 WSL 內仍找不到 docker，請檢查 WSL integration 設定。'; return }
    Log-Info '啟動 Docker Desktop…（初始化通常需要 30 到 90 秒，之後再按「檢查環境」）'
    Start-Process -FilePath $script:DockerExe | Out-Null
}

function Install-Act {
    $msg = "將在 $($script:Distro) 內執行 act 官方安裝腳本：`n`n" +
           "curl -sSf https://raw.githubusercontent.com/nektos/act/master/install.sh | bash -s -- -b ~/.local/bin`n`n" +
           "安裝到 ~/.local/bin，不需要 sudo。要繼續嗎？"
    $ans = [System.Windows.Forms.MessageBox]::Show($msg, '安裝 act', 'YesNo', 'Question')
    if ($ans -ne 'Yes') { return }
    Set-Busy $true; Set-Status '安裝 act 中…'
    Log-Info '下載並安裝 act…'
    $cmd = 'mkdir -p ~/.local/bin && curl --proto =https --tlsv1.2 -sSf https://raw.githubusercontent.com/nektos/act/master/install.sh | bash -s -- -b ~/.local/bin 2>&1'
    $r = Invoke-Wsl $cmd 300000
    if ($r.Output) { Append-Log ((Strip-Ansi $r.Output) + "`n") }
    if ($r.Error) { Append-Log ((Strip-Ansi $r.Error) + "`n") }
    if ($r.ExitCode -eq 0) { Log-Ok 'act 安裝完成。' } else { Log-Error "安裝失敗（exit $($r.ExitCode)）。" }
    Set-Busy $false
    Check-Environment | Out-Null
}

function Create-Actrc {
    $exists = Invoke-Wsl 'test -f ~/.actrc && echo yes || echo no' 15000
    if ($exists.Output -like '*yes*') {
        $ans = [System.Windows.Forms.MessageBox]::Show('~/.actrc 已存在，要覆寫嗎？', 'ActRunner', 'YesNo', 'Warning')
        if ($ans -ne 'Yes') { return }
    }
    $msg = "選擇 runner 映像：`n`n" +
           "是 = full（約 20 GB，最接近 GitHub 的 ubuntu-latest，相容性最好）`n" +
           "否 = medium（約 500 MB，常用工具都有，大多數專案夠用）`n`n" +
           "映像只在第一次執行時下載一次。"
    $ans = [System.Windows.Forms.MessageBox]::Show($msg, '建立 ~/.actrc', 'YesNoCancel', 'Question')
    if ($ans -eq 'Cancel') { return }
    $tag = 'act'
    if ($ans -eq 'Yes') { $tag = 'full' }

    $lines = @(
        "-P ubuntu-latest=catthehacker/ubuntu:$tag-latest",
        "-P ubuntu-24.04=catthehacker/ubuntu:$tag-24.04",
        "-P ubuntu-22.04=catthehacker/ubuntu:$tag-22.04",
        '--container-architecture linux/amd64',
        '--artifact-server-path /tmp/act-artifacts',
        '--action-offline-mode',
        '--secret-file ~/.act-secrets'
    )
    # ~ 在 secret-file 不會展開，改用實際家目錄
    if ($script:LinuxHome) { $lines[6] = "--secret-file $($script:LinuxHome)/.act-secrets" }

    $content = ($lines -join "`n") + "`n"
    $cmd = 'printf %s ' + (ConvertTo-BashArg $content) + ' > ~/.actrc && touch ~/.act-secrets && chmod 600 ~/.act-secrets && cat ~/.actrc'
    $r = Invoke-Wsl $cmd 15000
    if ($r.ExitCode -eq 0) {
        Log-Ok '已寫入 ~/.actrc，內容：'
        Append-Log ($r.Output + "`n")
        Log-Info '已建立空的 ~/.act-secrets。按「編輯 secrets」填入 GITHUB_TOKEN=你的PAT 及專案需要的其他 secrets。'
    } else {
        Log-Error "寫入失敗：$($r.Error)"
    }
    Check-Environment | Out-Null
}

function Get-LinuxHomeUnc {
    if (-not $script:LinuxHome) {
        $r = Invoke-Wsl 'echo $HOME' 15000
        if ($r.ExitCode -eq 0) { $script:LinuxHome = $r.Output.Trim() }
    }
    if (-not $script:LinuxHome) { return $null }
    return '\\wsl.localhost\' + $script:Distro + ($script:LinuxHome -replace '/', '\')
}

function Edit-Secrets {
    $home = Get-LinuxHomeUnc
    if (-not $home) { Log-Error '無法取得 Linux 家目錄。'; return }
    Invoke-Wsl 'touch ~/.act-secrets && chmod 600 ~/.act-secrets' 15000 | Out-Null
    $file = Join-Path $home '.act-secrets'
    Log-Info "以記事本開啟 $file（格式：一行一個 KEY=value）"
    Start-Process notepad.exe -ArgumentList "`"$file`"" | Out-Null
}

function Open-LinuxHome {
    $home = Get-LinuxHomeUnc
    if (-not $home) { Log-Error '無法取得 Linux 家目錄。'; return }
    Start-Process explorer.exe -ArgumentList "`"$home`"" | Out-Null
}

# ---------------------------------------------------------------------------
# job 清單
# ---------------------------------------------------------------------------
function Load-Jobs {
    $repo = Get-RepoLinuxPath
    if (-not $repo) { return }
    Set-Busy $true; Set-Status '讀取 job 清單…'
    $lvJobs.Items.Clear()
    $cmd = $script:BashPrefix + 'cd ' + (ConvertTo-BashArg $repo) + ' && NO_COLOR=1 act -l 2>&1'
    $r = Invoke-Wsl $cmd 120000
    Set-Busy $false
    if ($r.ExitCode -ne 0 -and -not $r.Output) {
        Log-Error "act -l 失敗：$($r.Error)"; Set-Status '讀取失敗'; return
    }
    $jobs = Parse-ActList $r.Output
    if ($jobs.Count -eq 0) {
        Log-Warn "沒有解析到任何 job。act 原始輸出："
        Append-Log ((Strip-Ansi $r.Output) + "`n")
        Set-Status '沒有 job'; return
    }
    $events = New-Object System.Collections.Generic.HashSet[string]
    foreach ($j in $jobs) {
        $item = New-Object System.Windows.Forms.ListViewItem($j.JobId)
        [void]$item.SubItems.Add($j.JobName)
        [void]$item.SubItems.Add($j.Workflow)
        [void]$item.SubItems.Add($j.File)
        [void]$item.SubItems.Add($j.Events)
        $item.Tag = $j
        [void]$lvJobs.Items.Add($item)
        foreach ($e in ($j.Events -split ',')) { if ($e.Trim()) { [void]$events.Add($e.Trim()) } }
    }
    foreach ($e in $events) { if (-not $cboEvent.Items.Contains($e)) { [void]$cboEvent.Items.Add($e) } }
    if ($lvJobs.Items.Count -gt 0) { $lvJobs.Items[0].Selected = $true }
    Log-Ok "讀到 $($jobs.Count) 個 job。"
    Set-Status "$($jobs.Count) 個 job"
    Persist-Settings
}

# ---------------------------------------------------------------------------
# 執行 / 停止
# ---------------------------------------------------------------------------
function Start-Run {
    if ($script:RunProc) { return }
    $repo = Get-RepoLinuxPath
    if (-not $repo) { return }

    $actArgs = New-Object System.Collections.Generic.List[string]
    $ev = $cboEvent.Text.Trim()
    if ($ev) { $actArgs.Add($ev) }
    if ($chkSelected.Checked -and $lvJobs.SelectedItems.Count -gt 0) {
        $actArgs.Add('-j'); $actArgs.Add($lvJobs.SelectedItems[0].Tag.JobId)
    }
    if ($chkDry.Checked) { $actArgs.Add('-n') }
    if ($chkVerbose.Checked) { $actArgs.Add('-v') }
    if ($chkReuse.Checked) { $actArgs.Add('--reuse') }

    $extra = $txtExtra.Text.Trim()
    $quotedArgs = ($actArgs | ForEach-Object { ConvertTo-BashArg $_ }) -join ' '
    # 額外參數交給 bash 自己解析引號
    $cmd = $script:BashPrefix + 'cd ' + (ConvertTo-BashArg $repo) + ' && NO_COLOR=1 TERM=dumb act ' + $quotedArgs
    if ($extra) { $cmd += ' ' + $extra }
    $cmd += ' 2>&1'

    if ($repo -like '/mnt/*') { Log-Warn 'repo 位於 /mnt/ 下（Windows 磁碟），Docker 掛載會很慢。建議把 repo 放到 Linux 檔案系統，例如 ~/src。' }
    Log-Info "執行：act $quotedArgs $extra"
    Log-Info "目錄：$repo"
    Append-Log ("-" * 100 + "`n") ([System.Drawing.Color]::Gray)

    try {
        $psi = New-WslStartInfo $cmd
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $false
        $psi.RedirectStandardInput = $true
        $p = [System.Diagnostics.Process]::Start($psi)
        $p.StandardInput.Close()
        $script:RunProc = $p
        $script:RunStream = $p.StandardOutput.BaseStream
        $script:Decoder = [System.Text.Encoding]::UTF8.GetDecoder()
        $script:LinePending = ''
        $script:StopRequested = $null
        $script:RunStarted = Get-Date
        $script:RunAsync = $script:RunStream.BeginRead($script:RunBuffer, 0, $script:RunBuffer.Length, $null, $null)
    } catch {
        Log-Error "無法啟動：$($_.Exception.Message)"
        $script:RunProc = $null
        return
    }

    $btnRun.Enabled = $false; $btnStop.Enabled = $true
    $btnList.Enabled = $false; $btnInstall.Enabled = $false; $btnActrc.Enabled = $false
    Set-Status '執行中…'
    Persist-Settings
    $timer.Start()
}

function Emit-Chunk([string]$chunk) {
    # 以行為單位去除 ANSI 色碼，避免跨 chunk 被切斷
    $text = $script:LinePending + ($chunk -replace "`r", '')
    $lastNl = $text.LastIndexOf("`n")
    if ($lastNl -lt 0) { $script:LinePending = $text; return }
    $complete = $text.Substring(0, $lastNl + 1)
    $script:LinePending = $text.Substring($lastNl + 1)
    Append-Log (Strip-Ansi $complete)
}

function Finish-Run {
    $timer.Stop()
    $p = $script:RunProc
    $code = -1
    try { $p.WaitForExit(2000) | Out-Null; $code = $p.ExitCode } catch {}
    if ($script:LinePending) { Append-Log ((Strip-Ansi $script:LinePending) + "`n"); $script:LinePending = '' }
    $elapsed = ''
    if ($script:RunStarted) { $elapsed = ' 用時 ' + ((Get-Date) - $script:RunStarted).ToString('mm\:ss') }
    Append-Log ("-" * 100 + "`n") ([System.Drawing.Color]::Gray)
    if ($script:StopRequested) { Log-Warn "已停止。$elapsed" ; Set-Status '已停止' }
    elseif ($code -eq 0) { Log-Ok "完成，exit code 0。$elapsed"; Set-Status '成功' }
    else { Log-Error "失敗，exit code $code。$elapsed"; Set-Status "失敗（exit $code）" }
    try { $p.Dispose() } catch {}
    $script:RunProc = $null; $script:RunStream = $null; $script:RunAsync = $null
    $btnRun.Enabled = $true; $btnStop.Enabled = $false
    $btnList.Enabled = $true; $btnInstall.Enabled = $true; $btnActrc.Enabled = $true
}

$timer.Add_Tick({
    $p = $script:RunProc
    if (-not $p) { $timer.Stop(); return }
    $eof = $false
    try {
        $guard = 0
        while ($script:RunAsync -and $script:RunAsync.IsCompleted -and $guard -lt 50) {
            $guard++
            $n = $script:RunStream.EndRead($script:RunAsync)
            if ($n -le 0) { $script:RunAsync = $null; $eof = $true; break }
            $chars = New-Object char[] ($script:Decoder.GetCharCount($script:RunBuffer, 0, $n))
            $cnt = $script:Decoder.GetChars($script:RunBuffer, 0, $n, $chars, 0)
            Emit-Chunk (New-Object string ($chars, 0, $cnt))
            $script:RunAsync = $script:RunStream.BeginRead($script:RunBuffer, 0, $script:RunBuffer.Length, $null, $null)
        }
    } catch {
        $eof = $true; $script:RunAsync = $null
    }
    if ($script:StopRequested -and -not $p.HasExited) {
        if (((Get-Date) - $script:StopRequested).TotalSeconds -gt 10) {
            Log-Warn 'act 未在 10 秒內結束，強制終止 wsl 程序。'
            try { $p.Kill() } catch {}
            $script:StopRequested = (Get-Date).AddHours(1)   # 避免重複 Kill
        }
    }
    if (($eof -or -not $script:RunAsync) -and $p.HasExited) { Finish-Run }
})

function Stop-Run {
    if (-not $script:RunProc) { return }
    if ($script:StopRequested) { return }
    $script:StopRequested = Get-Date
    Log-Warn '送出 SIGINT 給 act（會嘗試清理容器）…'
    Set-Status '停止中…'
    Invoke-Wsl 'pkill -INT -x act' 10000 | Out-Null
}

# ---------------------------------------------------------------------------
# 事件綁定
# ---------------------------------------------------------------------------
$cboDistro.Add_SelectedIndexChanged({
    if ($cboDistro.SelectedItem) { $script:Distro = [string]$cboDistro.SelectedItem; $script:LinuxHome = ''; $script:LinuxUser = '' }
})
$btnCheck.Add_Click({ Check-Environment | Out-Null })
$btnDocker.Add_Click({ Start-DockerDesktop })
$btnInstall.Add_Click({ Install-Act })
$btnActrc.Add_Click({ Create-Actrc })
$btnSecrets.Add_Click({ Edit-Secrets })
$btnOpenHome.Add_Click({ Open-LinuxHome })

$btnBrowse.Add_Click({
    $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
    $dlg.Description = '選擇含有 .github/workflows 的 repo 資料夾（可選 \\wsl.localhost\ 底下的 Linux 目錄）'
    $dlg.ShowNewFolderButton = $false
    if ($txtRepo.Text -and (Test-Path $txtRepo.Text)) { $dlg.SelectedPath = $txtRepo.Text }
    if ($dlg.ShowDialog($form) -eq 'OK') {
        $txtRepo.Text = $dlg.SelectedPath
        $linux = Convert-ToWslPath $dlg.SelectedPath
        Log-Info "選擇 $($dlg.SelectedPath)  →  $linux"
    }
})
$btnList.Add_Click({ Load-Jobs })
$lvJobs.Add_DoubleClick({ if ($lvJobs.SelectedItems.Count -gt 0) { Start-Run } })
$btnRun.Add_Click({ Start-Run })
$btnStop.Add_Click({ Stop-Run })
$btnClear.Add_Click({ $rtbLog.Clear() })
$btnSave.Add_Click({
    $dlg = New-Object System.Windows.Forms.SaveFileDialog
    $dlg.Filter = '文字檔 (*.log;*.txt)|*.log;*.txt|所有檔案|*.*'
    $dlg.FileName = 'act-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.log'
    if ($dlg.ShowDialog($form) -eq 'OK') {
        [System.IO.File]::WriteAllText($dlg.FileName, $rtbLog.Text, [System.Text.Encoding]::UTF8)
        Log-Ok "已儲存 $($dlg.FileName)"
    }
})

$form.Add_FormClosing({
    if ($script:RunProc -and -not $script:RunProc.HasExited) {
        $ans = [System.Windows.Forms.MessageBox]::Show('act 仍在執行，要停止並關閉嗎？', 'ActRunner', 'YesNo', 'Warning')
        if ($ans -ne 'Yes') { $_.Cancel = $true; return }
        Invoke-Wsl 'pkill -INT -x act' 10000 | Out-Null
        try { $script:RunProc.WaitForExit(5000) | Out-Null; if (-not $script:RunProc.HasExited) { $script:RunProc.Kill() } } catch {}
    }
    Persist-Settings
})

$form.Add_Shown({
    Log-Info 'ActRunner 啟動。流程：檢查環境 → 選 repo → 讀取 job 清單 → 選事件與 job → 執行。'
    Refresh-Distros
    if ($cboDistro.Items.Count -gt 0) { Check-Environment | Out-Null }
})

[void]$form.ShowDialog()
