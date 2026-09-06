<#
  actci.ps1 — 視窗。三個分頁：執行 / 監看 / 環境。

  執行：選 repo、讀 job、用 act 跑工作目錄現況，輸出即時串流。可勾選推回 GitHub
        （context actci/manual）。手動跑的判定**不存進 store**，否則 watcher 會把那個
        commit 當成已判定而跳過。
  監看：watcher 的心跳幾秒前（每秒重算，停了會自己變色）、排程工作狀態與啟停、
        最近判定。它只讀 store，不自己去問 GitHub —— 它是一面鏡子，不是第二個 CI。
  環境：WSL / Docker / act / .actrc / gh 的檢查與一鍵處理。

  啟動：雙擊 actci.bat
#>
param(
    [int]$AutoCloseSeconds = 0,   # 煙霧測試用：開起來幾秒後自己關掉
    [int]$ShowTab = -1,           # 煙霧測試用：一開始切到第幾個分頁（0 執行、1 監看、2 環境）
    [string]$Screenshot = ''      # 煙霧測試用：關閉前把視窗截圖存到這個 PNG
)

# DPI：不向 Windows 宣告的話，在 125%/150% 縮放的螢幕上整個視窗會被當點陣圖放大，字就糊。
# 要在建立任何視窗之前呼叫。
try {
    Add-Type -Namespace actci -Name Dpi -MemberDefinition '[DllImport("user32.dll")] public static extern bool SetProcessDPIAware();'
    [actci.Dpi]::SetProcessDPIAware() | Out-Null
} catch {}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}

Import-Module (Join-Path $PSScriptRoot 'src\actci.psm1') -Force

$script:Root         = $PSScriptRoot
$script:Store        = Initialize-Store (New-Store)
$script:SettingsFile = Join-Path $script:Store.Root 'window.json'
$script:DockerExe    = Join-Path $env:ProgramFiles 'Docker\Docker\Docker Desktop.exe'
$script:LinuxHome    = ''
$script:LinuxUser    = ''
$script:StaleAfter   = 300

# 執行中的 act
$script:RunProc = $null; $script:RunStream = $null; $script:RunAsync = $null
$script:RunBuffer = New-Object byte[] 65536
$script:Decoder = $null; $script:LinePending = ''
$script:StopRequested = $null; $script:RunStopwatch = $null
$script:RunVerdict = $null; $script:RunOutput = $null

# ---------------------------------------------------------------------------
# 設定
# ---------------------------------------------------------------------------
function Load-Settings {
    $d = [pscustomobject]@{ Distro = 'Ubuntu'; RepoPath = ''; Event = 'push'; ExtraArgs = ''; Slug = ''; PushManual = $false; FontSize = 11 }
    if (Test-Path $script:SettingsFile) {
        try {
            $s = Get-Content $script:SettingsFile -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($p in 'Distro', 'RepoPath', 'Event', 'ExtraArgs', 'Slug') { if ($s.PSObject.Properties[$p]) { $d.$p = [string]$s.$p } }
            if ($s.PSObject.Properties['PushManual']) { $d.PushManual = [bool]$s.PushManual }
            if ($s.PSObject.Properties['FontSize']) { $fs = [double]$s.FontSize; if ($fs -ge 8 -and $fs -le 20) { $d.FontSize = $fs } }
        } catch {}
    }
    return $d
}
function Save-Settings($s) {
    try { $s | ConvertTo-Json | Set-Content -Path $script:SettingsFile -Encoding UTF8 } catch {}
}
$settings = Load-Settings
Set-WslDistro $settings.Distro

# ---------------------------------------------------------------------------
# 視窗骨架
# ---------------------------------------------------------------------------
$form = New-Object System.Windows.Forms.Form
$form.Text = 'actci — 本地 GitHub Actions CI'
$form.StartPosition = 'CenterScreen'
$form.ClientSize = New-Object System.Drawing.Size(1040, 760)
$form.MinimumSize = New-Object System.Drawing.Size(920, 640)
$form.Font = New-Object System.Drawing.Font('Microsoft JhengHei UI', 9)
$iconPath = Join-Path $script:Root 'assets\actci.ico'
if (Test-Path $iconPath) { try { $form.Icon = New-Object System.Drawing.Icon($iconPath) } catch {} }
# 宣告 DPI 之後，版面座標是以 96 DPI 設計的，讓 WinForms 依實際 DPI 把控制項一起放大。
$form.AutoScaleDimensions = New-Object System.Drawing.SizeF(96, 96)
$form.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::Dpi

$AnchorTLR = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
$AnchorTR  = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Right
$AnchorAll = $AnchorTLR -bor [System.Windows.Forms.AnchorStyles]::Bottom
$Green = [System.Drawing.Color]::ForestGreen; $Red = [System.Drawing.Color]::Firebrick
$Orange = [System.Drawing.Color]::DarkOrange; $Gray = [System.Drawing.Color]::DimGray

# 標籤與按鈕的寬度一律由文字決定（AutoSize）。固定寬度在字放大或換字型時會把字切掉。
function New-Label($text, $x, $y, $w, $h = 20) {
    $l = New-Object System.Windows.Forms.Label
    $l.Text = $text; $l.Location = New-Object System.Drawing.Point($x, $y)
    $l.AutoSize = $true; $l.Padding = New-Object System.Windows.Forms.Padding(0, 3, 0, 0)
    return $l
}
function New-Block($text, $x, $y, $w, $h) {
    # 多行或要固定大小的文字區塊
    $l = New-Object System.Windows.Forms.Label
    $l.Text = $text; $l.Location = New-Object System.Drawing.Point($x, $y)
    $l.AutoSize = $false; $l.Size = New-Object System.Drawing.Size($w, $h); $l.TextAlign = 'TopLeft'
    return $l
}
function New-Button($text, $x, $y, $w, $h = 28) {
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $text; $b.Location = New-Object System.Drawing.Point($x, $y); $b.Size = New-Object System.Drawing.Size($w, $h)
    $b.AutoSize = $true; $b.AutoSizeMode = 'GrowOnly'; $b.MinimumSize = New-Object System.Drawing.Size($w, $h)
    $b.Padding = New-Object System.Windows.Forms.Padding(8, 0, 8, 0)
    return $b
}
function New-Flow($x, $y, $w, $h) {
    $p = New-Object System.Windows.Forms.FlowLayoutPanel
    $p.Location = New-Object System.Drawing.Point($x, $y); $p.Size = New-Object System.Drawing.Size($w, $h)
    $p.AutoSize = $true; $p.AutoSizeMode = 'GrowAndShrink'; $p.WrapContents = $true
    return $p
}
function New-Check($text, $x, $y, $checked = $false) {
    $c = New-Object System.Windows.Forms.CheckBox
    $c.Text = $text; $c.Location = New-Object System.Drawing.Point($x, $y); $c.AutoSize = $true; $c.Checked = $checked
    return $c
}

$tabs = New-Object System.Windows.Forms.TabControl
$tabs.Location = New-Object System.Drawing.Point(8, 8)
$tabs.Size = New-Object System.Drawing.Size(($form.ClientSize.Width - 16), ($form.ClientSize.Height - 16 - 26))
$tabs.Anchor = $AnchorAll
$tabRun = New-Object System.Windows.Forms.TabPage; $tabRun.Text = '  執行  '
$tabWatch = New-Object System.Windows.Forms.TabPage; $tabWatch.Text = '  監看  '
$tabEnv = New-Object System.Windows.Forms.TabPage; $tabEnv.Text = '  環境  '
foreach ($t in @($tabRun, $tabWatch, $tabEnv)) { $t.Padding = New-Object System.Windows.Forms.Padding(6); $t.UseVisualStyleBackColor = $true }
$tabs.TabPages.AddRange(@($tabRun, $tabWatch, $tabEnv))
$form.Controls.Add($tabs)

$status = New-Object System.Windows.Forms.StatusStrip
$lblStatus = New-Object System.Windows.Forms.ToolStripStatusLabel; $lblStatus.Text = '就緒'
[void]$status.Items.Add($lblStatus)
$form.Controls.Add($status)
function Set-Status([string]$t) { $lblStatus.Text = $t; $status.Refresh() }
function Set-Busy([bool]$busy) {
    $form.Cursor = if ($busy) { [System.Windows.Forms.Cursors]::WaitCursor } else { [System.Windows.Forms.Cursors]::Default }
    [System.Windows.Forms.Application]::DoEvents()
}

$W = $tabRun.ClientSize.Width   # 分頁內可用寬度（設計時）

# ---------------------------------------------------------------------------
# 分頁一：執行
# ---------------------------------------------------------------------------
$tabRun.Controls.Add((New-Label 'Repo 路徑' 10 14 75))
$txtRepo = New-Object System.Windows.Forms.TextBox
$txtRepo.Location = New-Object System.Drawing.Point(88, 11); $txtRepo.Size = New-Object System.Drawing.Size(($W - 88 - 235), 24)
$txtRepo.Anchor = $AnchorTLR; $txtRepo.Text = $settings.RepoPath
$pnlRepoBtns = New-Flow ($W - 232) 8 225 32; $pnlRepoBtns.Anchor = $AnchorTR; $pnlRepoBtns.WrapContents = $false
$btnBrowse = New-Button '瀏覽…' 0 0 90
$btnList = New-Button '讀取 job 清單' 0 0 110
$pnlRepoBtns.Controls.AddRange(@($btnBrowse, $btnList))
$tabRun.Controls.AddRange(@($txtRepo, $pnlRepoBtns))

$lvJobs = New-Object System.Windows.Forms.ListView
$lvJobs.Location = New-Object System.Drawing.Point(10, 42); $lvJobs.Size = New-Object System.Drawing.Size(($W - 20), 120)
$lvJobs.Anchor = $AnchorTLR; $lvJobs.View = 'Details'; $lvJobs.FullRowSelect = $true; $lvJobs.MultiSelect = $false
$lvJobs.GridLines = $true; $lvJobs.HideSelection = $false
foreach ($c in @(@('Job ID', 160), @('Job 名稱', 200), @('Workflow', 180), @('檔案', 160), @('事件', 230))) { [void]$lvJobs.Columns.Add($c[0], $c[1]) }
$tabRun.Controls.Add($lvJobs)

$pnlEvent = New-Flow 10 168 ($W - 20) 30; $pnlEvent.Anchor = $AnchorTLR; $pnlEvent.WrapContents = $false
$lblEvent = New-Label '事件' 0 0 40; $lblEvent.Margin = New-Object System.Windows.Forms.Padding(0, 3, 4, 0)
$cboEvent = New-Object System.Windows.Forms.ComboBox
$cboEvent.Size = New-Object System.Drawing.Size(160, 24); $cboEvent.DropDownStyle = 'DropDown'
$cboEvent.Margin = New-Object System.Windows.Forms.Padding(0, 1, 14, 0)
[void]$cboEvent.Items.AddRange(@('push', 'pull_request', 'workflow_dispatch', 'schedule', 'release', 'workflow_call'))
$cboEvent.Text = $settings.Event
$chkSelected = New-Check '只跑選取的 job' 0 0 $true
$chkDry = New-Check 'Dry run (-n)' 0 0
$chkVerbose = New-Check '詳細 (-v)' 0 0
$chkReuse = New-Check '保留容器 (--reuse)' 0 0
foreach ($c in @($chkSelected, $chkDry, $chkVerbose, $chkReuse)) { $c.Margin = New-Object System.Windows.Forms.Padding(0, 4, 12, 0) }
$pnlEvent.Controls.AddRange(@($lblEvent, $cboEvent, $chkSelected, $chkDry, $chkVerbose, $chkReuse))
$tabRun.Controls.Add($pnlEvent)

$tabRun.Controls.Add((New-Label '額外參數' 10 202 70))
$txtExtra = New-Object System.Windows.Forms.TextBox
$txtExtra.Location = New-Object System.Drawing.Point(88, 199); $txtExtra.Size = New-Object System.Drawing.Size(($W - 88 - 20), 24)
$txtExtra.Anchor = $AnchorTLR; $txtExtra.Text = $settings.ExtraArgs
$tabRun.Controls.Add($txtExtra)

$pnlPush = New-Flow 10 228 ($W - 20 - 450) 30; $pnlPush.WrapContents = $false
$chkPush = New-Check '跑完推回 GitHub（context actci/manual，以 HEAD 的 sha 為準）' 0 0 $settings.PushManual
$chkPush.Margin = New-Object System.Windows.Forms.Padding(0, 4, 12, 0)
$lblSlug = New-Label 'Slug' 0 0 40; $lblSlug.Margin = New-Object System.Windows.Forms.Padding(0, 3, 4, 0)
$txtSlug = New-Object System.Windows.Forms.TextBox
$txtSlug.Size = New-Object System.Drawing.Size(200, 24); $txtSlug.Text = $settings.Slug; $txtSlug.Margin = New-Object System.Windows.Forms.Padding(0, 1, 0, 0)
$pnlPush.Controls.AddRange(@($chkPush, $lblSlug, $txtSlug))
$tabRun.Controls.Add($pnlPush)

$pnlRunBtns = New-Flow ($W - 20 - 440) 224 440 34; $pnlRunBtns.Anchor = $AnchorTR; $pnlRunBtns.WrapContents = $false
$btnRun = New-Button '▶  執行' 0 0 110 30
$btnStop = New-Button '■  停止' 0 0 100 30
$btnClear = New-Button '清除 log' 0 0 100 30
$btnSave = New-Button '儲存 log…' 0 0 107 30
$btnRun.Font = New-Object System.Drawing.Font($form.Font, [System.Drawing.FontStyle]::Bold)
$btnStop.Enabled = $false
$pnlRunBtns.Controls.AddRange(@($btnRun, $btnStop, $btnClear, $btnSave))
$tabRun.Controls.Add($pnlRunBtns)

$rtbLog = New-Object System.Windows.Forms.RichTextBox
$rtbLog.Location = New-Object System.Drawing.Point(10, 264)
$rtbLog.Size = New-Object System.Drawing.Size(($W - 20), ($tabRun.ClientSize.Height - 264 - 10))
$rtbLog.Anchor = $AnchorAll; $rtbLog.ReadOnly = $true; $rtbLog.WordWrap = $false; $rtbLog.ScrollBars = 'Both'; $rtbLog.DetectUrls = $false
$rtbLog.Font = New-Object System.Drawing.Font('Consolas', 9.5)
$rtbLog.BackColor = [System.Drawing.Color]::FromArgb(30, 30, 30); $rtbLog.ForeColor = [System.Drawing.Color]::Gainsboro
$tabRun.Controls.Add($rtbLog)

function Append-Log([string]$text, [System.Drawing.Color]$color) {
    if ([string]::IsNullOrEmpty($text)) { return }
    $rtbLog.SelectionStart = $rtbLog.TextLength; $rtbLog.SelectionLength = 0
    $rtbLog.SelectionColor = if ($color) { $color } else { $rtbLog.ForeColor }
    $rtbLog.AppendText($text); $rtbLog.SelectionColor = $rtbLog.ForeColor; $rtbLog.ScrollToCaret()
}
function Log-Info([string]$t)  { Append-Log "[actci] $t`n" ([System.Drawing.Color]::DeepSkyBlue) }
function Log-Ok([string]$t)    { Append-Log "[actci] $t`n" ([System.Drawing.Color]::LightGreen) }
function Log-Warn([string]$t)  { Append-Log "[actci] $t`n" ([System.Drawing.Color]::Gold) }
function Log-Error([string]$t) { Append-Log "[actci] $t`n" ([System.Drawing.Color]::Salmon) }

# ---------------------------------------------------------------------------
# 分頁二：監看
# ---------------------------------------------------------------------------
$grpBeat = New-Object System.Windows.Forms.GroupBox
$grpBeat.Text = 'watcher 心跳'; $grpBeat.Location = New-Object System.Drawing.Point(10, 10); $grpBeat.Size = New-Object System.Drawing.Size(340, 110)
$lblBeat = New-Block '從來沒有' 14 26 310 40
$lblBeat.Font = New-Object System.Drawing.Font('Microsoft JhengHei UI', 16, [System.Drawing.FontStyle]::Bold); $lblBeat.ForeColor = $Gray
$lblBeatNote = New-Block 'watcher 沒被啟動過' 14 70 310 30; $lblBeatNote.ForeColor = $Gray
$grpBeat.Controls.AddRange(@($lblBeat, $lblBeatNote))
$tabWatch.Controls.Add($grpBeat)

$grpCfg = New-Object System.Windows.Forms.GroupBox
$grpCfg.Text = 'watcher 設定與排程工作'; $grpCfg.Location = New-Object System.Drawing.Point(360, 10); $grpCfg.Size = New-Object System.Drawing.Size(($W - 370), 110)
$grpCfg.Anchor = $AnchorTLR
$lblCfg = New-Block '尚未安裝。按「安裝 / 更新 watcher…」。' 14 22 ($W - 400) 44; $lblCfg.Anchor = $AnchorTLR
$lblTask = New-Block '' 14 66 ($W - 400) 40; $lblTask.Anchor = $AnchorTLR; $lblTask.ForeColor = $Gray
$grpCfg.Controls.AddRange(@($lblCfg, $lblTask))
$tabWatch.Controls.Add($grpCfg)

$pnlWatchBtns = New-Flow 10 128 ($W - 20) 36; $pnlWatchBtns.Anchor = $AnchorTLR
$btnInstallWatcher = New-Button '安裝 / 更新 watcher…' 0 0 150
$btnTaskStart = New-Button '啟動' 0 0 70
$btnTaskStop = New-Button '停止' 0 0 70
$btnTaskRemove = New-Button '移除排程' 0 0 90
$btnWatchLog = New-Button '開啟 watcher.log' 0 0 130
$btnOpenStore = New-Button '開啟資料夾' 0 0 100
$btnRefreshWatch = New-Button '重新整理' 0 0 90
$pnlWatchBtns.Controls.AddRange(@($btnInstallWatcher, $btnTaskStart, $btnTaskStop, $btnTaskRemove, $btnWatchLog, $btnOpenStore, $btnRefreshWatch))
$tabWatch.Controls.Add($pnlWatchBtns)

$tabWatch.Controls.Add((New-Label '最近判定（雙擊開啟該次的 act 日誌）' 10 172 400))
$lvVerdicts = New-Object System.Windows.Forms.ListView
$lvVerdicts.Location = New-Object System.Drawing.Point(10, 194)
$lvVerdicts.Size = New-Object System.Drawing.Size(($W - 20), ($tabWatch.ClientSize.Height - 194 - 10))
$lvVerdicts.Anchor = $AnchorAll; $lvVerdicts.View = 'Details'; $lvVerdicts.FullRowSelect = $true; $lvVerdicts.GridLines = $true; $lvVerdicts.HideSelection = $false
foreach ($c in @(@('完成時間', 130), @('sha', 100), @('結果', 90), @('測試', 60), @('事件', 100), @('說明', 480))) { [void]$lvVerdicts.Columns.Add($c[0], $c[1]) }
$tabWatch.Controls.Add($lvVerdicts)

# ---------------------------------------------------------------------------
# 分頁三：環境
# ---------------------------------------------------------------------------
# 按鈕整排放最上面，狀態行才有整個寬度可用（Docker 的提示很長）。
$pnlEnvBtns = New-Flow 10 10 ($W - 20) 36; $pnlEnvBtns.Anchor = $AnchorTLR
$btnCheck = New-Button '檢查環境' 0 0 110
$btnDocker = New-Button '啟動 Docker Desktop' 0 0 110
$btnInstallAct = New-Button '安裝 / 更新 act' 0 0 110
$btnActrc = New-Button '建立 ~/.actrc' 0 0 110
$btnSecrets = New-Button '編輯 secrets' 0 0 110
$btnOpenHome = New-Button '開啟 Linux 家目錄' 0 0 110
$pnlEnvBtns.Controls.AddRange(@($btnCheck, $btnDocker, $btnInstallAct, $btnActrc, $btnSecrets, $btnOpenHome))
$tabEnv.Controls.Add($pnlEnvBtns)

$lblDistro = New-Label 'WSL 發行版' 10 56 80
$cboDistro = New-Object System.Windows.Forms.ComboBox
$cboDistro.Location = New-Object System.Drawing.Point(110, 53); $cboDistro.Size = New-Object System.Drawing.Size(180, 24); $cboDistro.DropDownStyle = 'DropDownList'
$tabEnv.Controls.AddRange(@($lblDistro, $cboDistro))

$lblWsl    = New-Label 'WSL：未檢查'    10 90 420
$lblDocker = New-Label 'Docker：未檢查' 10 116 420
$lblAct    = New-Label 'act：未檢查'    10 142 420
$lblActrc  = New-Label '.actrc：未檢查' 10 168 420
$lblGh     = New-Label 'gh：未檢查'     10 194 420
$tabEnv.Controls.AddRange(@($lblWsl, $lblDocker, $lblAct, $lblActrc, $lblGh))

$lblEnvHelp = New-Block '' 10 236 ($W - 20) 200; $lblEnvHelp.ForeColor = $Gray; $lblEnvHelp.Anchor = $AnchorTLR
$lblEnvHelp.Text = @"
順序：啟動 Docker Desktop（並在 Settings > Resources > WSL integration 勾選發行版）→ 安裝 act → 建立 ~/.actrc → 編輯 secrets 填入 GITHUB_TOKEN=你的PAT。
四個燈都綠，執行分頁就能跑；gh 也綠，才能推回 GitHub 與安裝 watcher。
判定與日誌放在 $($script:Store.Root)
"@
$tabEnv.Controls.Add($lblEnvHelp)

# ---------------------------------------------------------------------------
# 共用
# ---------------------------------------------------------------------------
function Persist-Settings {
    $settings.Distro = Get-WslDistro; $settings.RepoPath = $txtRepo.Text; $settings.Event = $cboEvent.Text
    $settings.ExtraArgs = $txtExtra.Text; $settings.Slug = $txtSlug.Text; $settings.PushManual = $chkPush.Checked
    Save-Settings $settings   # FontSize 原樣寫回，使用者手動改過的值會保留
}
function Get-RepoLinuxPath {
    $p = ConvertTo-WslPath $txtRepo.Text
    if (-not $p) { [System.Windows.Forms.MessageBox]::Show('請先填入 repo 路徑。', 'actci') | Out-Null; return $null }
    return $p
}
function Get-LinuxHomeUnc {
    if (-not $script:LinuxHome) {
        $r = Invoke-Wsl -BashCommand 'echo $HOME' -TimeoutMs 15000
        if ($r.ExitCode -eq 0) { $script:LinuxHome = $r.Output.Trim() }
    }
    if (-not $script:LinuxHome) { return $null }
    return '\\wsl.localhost\' + (Get-WslDistro) + ($script:LinuxHome -replace '/', '\')
}
function Get-RepoSlug([string]$repo) {
    # 從 origin 的網址猜 owner/repo。猜不到回空字串。
    $r = Invoke-Wsl -BashCommand ('git -C ' + (ConvertTo-BashArg $repo) + ' remote get-url origin 2>/dev/null') -TimeoutMs 15000
    if ($r.ExitCode -eq 0 -and $r.Output -match 'github\.com[:/]([^/\s]+)/([^/\s]+?)(\.git)?$') { return "$($Matches[1])/$($Matches[2])" }
    return ''
}

# ---------------------------------------------------------------------------
# 環境檢查
# ---------------------------------------------------------------------------
function Refresh-Distros {
    $cboDistro.Items.Clear()
    $ds = @(Get-WslDistros)
    foreach ($d in $ds) { [void]$cboDistro.Items.Add($d) }
    if ($ds.Count -eq 0) { $lblWsl.Text = 'WSL：找不到任何發行版'; $lblWsl.ForeColor = $Red; return }
    if ($ds -contains (Get-WslDistro)) { $cboDistro.SelectedItem = (Get-WslDistro) } else { $cboDistro.SelectedIndex = 0; Set-WslDistro ([string]$cboDistro.SelectedItem) }
}

function Check-Environment {
    Set-Busy $true; Set-Status '檢查環境中…'
    $ok = $true
    $r = Invoke-Wsl -BashCommand 'echo __OK__; whoami; echo $HOME' -TimeoutMs 30000
    if ($r.ExitCode -eq 0 -and $r.Output -like '__OK__*') {
        $lines = $r.Output -split "`n"; $script:LinuxUser = $lines[1].Trim(); $script:LinuxHome = $lines[2].Trim()
        $lblWsl.Text = "WSL：$(Get-WslDistro) 可用（$($script:LinuxUser)）"; $lblWsl.ForeColor = $Green
    } else {
        $lblWsl.Text = "WSL：$(Get-WslDistro) 無法啟動"; $lblWsl.ForeColor = $Red
        Log-Error "WSL 發行版 $(Get-WslDistro) 無法啟動：$($r.Error) $($r.Output)"
        Set-Busy $false; Set-Status '環境檢查失敗'; return $false
    }
    $pre = Test-ActPreflight
    switch ($pre.Code) {
        'ok' {
            $lblAct.Text = "act：$($pre.Detail)"; $lblAct.ForeColor = $Green
            $lblDocker.Text = 'Docker：可用'; $lblDocker.ForeColor = $Green
        }
        'noact' {
            $lblAct.Text = 'act：未安裝'; $lblAct.ForeColor = $Red
            $lblDocker.Text = 'Docker：（先裝 act 再檢查）'; $lblDocker.ForeColor = $Gray
            Log-Warn 'act 未安裝。按「安裝 / 更新 act」會裝到 ~/.local/bin，不需要 sudo。'
        }
        default {
            $lblAct.Text = 'act：已安裝'; $lblAct.ForeColor = $Green
            $lblDocker.Text = "Docker：$($pre.Detail)"; $lblDocker.ForeColor = $Red
            Log-Warn $pre.Detail
        }
    }
    if (-not $pre.Ok) { $ok = $false }
    $c = Invoke-Wsl -BashCommand 'if [ -f ~/.actrc ]; then grep -c . ~/.actrc; else echo __NOACTRC__; fi' -TimeoutMs 15000
    if ($c.Output -like '*__NOACTRC__*') {
        $lblActrc.Text = '.actrc：不存在（第一次執行會卡在互動式選單）'; $lblActrc.ForeColor = $Orange
        Log-Warn '~/.actrc 不存在。沒有它 act 第一次執行會停下來問你選映像，視窗接不到。請按「建立 ~/.actrc」。'
        $ok = $false
    } else { $lblActrc.Text = ".actrc：已設定（$($c.Output.Trim()) 行）"; $lblActrc.ForeColor = $Green }
    $gh = Test-GhAuth
    if ($gh.Ok) { $lblGh.Text = "gh：$($gh.Detail)"; $lblGh.ForeColor = $Green }
    else { $lblGh.Text = "gh：未認證（$($gh.Detail)）"; $lblGh.ForeColor = $Orange; Log-Warn '推回 GitHub 與 watcher 需要 gh auth login。' }
    Set-Busy $false
    if ($ok) { Set-Status '環境正常'; Log-Ok '環境檢查通過。' } else { Set-Status '環境有待處理項目' }
    return $ok
}

function Start-DockerDesktop {
    if (-not (Test-Path $script:DockerExe)) { [System.Windows.Forms.MessageBox]::Show("找不到 Docker Desktop：`n$($script:DockerExe)", 'actci') | Out-Null; return }
    if (Get-Process -Name 'Docker Desktop' -ErrorAction SilentlyContinue) { Log-Info 'Docker Desktop 已在執行。若 WSL 內仍找不到 docker，請檢查 WSL integration 設定。'; return }
    Log-Info '啟動 Docker Desktop…（初始化通常需要 30 到 90 秒，之後再按「檢查環境」）'
    Start-Process -FilePath $script:DockerExe | Out-Null
}

function Install-Act {
    $msg = "將在 $(Get-WslDistro) 內執行 act 官方安裝腳本：`n`ncurl -sSf https://raw.githubusercontent.com/nektos/act/master/install.sh | bash -s -- -b ~/.local/bin`n`n安裝到 ~/.local/bin，不需要 sudo。要繼續嗎？"
    if ([System.Windows.Forms.MessageBox]::Show($msg, '安裝 act', 'YesNo', 'Question') -ne 'Yes') { return }
    Set-Busy $true; Set-Status '安裝 act 中…'; Log-Info '下載並安裝 act…'
    $r = Invoke-Wsl -BashCommand 'mkdir -p ~/.local/bin && curl --proto =https --tlsv1.2 -sSf https://raw.githubusercontent.com/nektos/act/master/install.sh | bash -s -- -b ~/.local/bin 2>&1' -TimeoutMs 300000
    if ($r.Output) { Append-Log ((Remove-AnsiCodes $r.Output) + "`n") }
    if ($r.Error) { Append-Log ((Remove-AnsiCodes $r.Error) + "`n") }
    if ($r.ExitCode -eq 0) { Log-Ok 'act 安裝完成。' } else { Log-Error "安裝失敗（exit $($r.ExitCode)）。" }
    Set-Busy $false; Check-Environment | Out-Null
}

function Create-Actrc {
    $exists = Invoke-Wsl -BashCommand 'test -f ~/.actrc && echo yes || echo no' -TimeoutMs 15000
    if ($exists.Output -like '*yes*') {
        if ([System.Windows.Forms.MessageBox]::Show('~/.actrc 已存在，要覆寫嗎？', 'actci', 'YesNo', 'Warning') -ne 'Yes') { return }
    }
    $msg = "選擇 runner 映像：`n`n是 = full（約 20 GB，最接近 GitHub 的 ubuntu-latest）`n否 = medium（約 500 MB，大多數專案夠用）`n`n映像只在第一次執行時下載一次。"
    $ans = [System.Windows.Forms.MessageBox]::Show($msg, '建立 ~/.actrc', 'YesNoCancel', 'Question')
    if ($ans -eq 'Cancel') { return }
    $tag = if ($ans -eq 'Yes') { 'full' } else { 'act' }
    if (-not $script:LinuxHome) { Get-LinuxHomeUnc | Out-Null }
    $secret = if ($script:LinuxHome) { "$($script:LinuxHome)/.act-secrets" } else { '~/.act-secrets' }
    $lines = @("-P ubuntu-latest=catthehacker/ubuntu:$tag-latest", "-P ubuntu-24.04=catthehacker/ubuntu:$tag-24.04", "-P ubuntu-22.04=catthehacker/ubuntu:$tag-22.04",
               '--container-architecture linux/amd64', '--artifact-server-path /tmp/act-artifacts', '--action-offline-mode', "--secret-file $secret")
    $content = ($lines -join "`n") + "`n"
    $r = Invoke-Wsl -BashCommand ('printf %s ' + (ConvertTo-BashArg $content) + ' > ~/.actrc && touch ~/.act-secrets && chmod 600 ~/.act-secrets && cat ~/.actrc') -TimeoutMs 15000
    if ($r.ExitCode -eq 0) { Log-Ok '已寫入 ~/.actrc：'; Append-Log ($r.Output + "`n"); Log-Info '已建立空的 ~/.act-secrets。按「編輯 secrets」填入 GITHUB_TOKEN=你的PAT。' }
    else { Log-Error "寫入失敗：$($r.Error)" }
    Check-Environment | Out-Null
}

function Edit-Secrets {
    $home = Get-LinuxHomeUnc
    if (-not $home) { Log-Error '無法取得 Linux 家目錄。'; return }
    Invoke-Wsl -BashCommand 'touch ~/.act-secrets && chmod 600 ~/.act-secrets' -TimeoutMs 15000 | Out-Null
    $file = Join-Path $home '.act-secrets'
    Log-Info "以記事本開啟 $file（一行一個 KEY=value）"
    Start-Process notepad.exe -ArgumentList "`"$file`"" | Out-Null
}

# ---------------------------------------------------------------------------
# job 清單
# ---------------------------------------------------------------------------
function Parse-ActList([string]$text) {
    $jobs = @()
    foreach ($line in ($text -split "`r?`n")) {
        $l = (Remove-AnsiCodes $line).TrimEnd()
        if (-not $l -or $l -match '^\s*Stage\s+Job ID' -or $l -match '^\s*(WARN|INFO|ERRO|DEBU|FATA|level=|time=)') { continue }
        $cols = [regex]::Split($l.Trim(), '\s{2,}')
        if ($cols.Count -lt 6 -or $cols[0] -notmatch '^\d+$') { continue }
        $jobs += [pscustomobject]@{ Stage = $cols[0]; JobId = $cols[1]; JobName = $cols[2]; Workflow = $cols[3]; File = $cols[4]; Events = $cols[5] }
    }
    return ,$jobs
}

function Load-Jobs {
    $repo = Get-RepoLinuxPath; if (-not $repo) { return }
    Set-Busy $true; Set-Status '讀取 job 清單…'; $lvJobs.Items.Clear()
    $r = Invoke-Wsl -BashCommand ('export PATH="$HOME/.local/bin:$PATH"; cd ' + (ConvertTo-BashArg $repo) + ' && NO_COLOR=1 act -l 2>&1') -TimeoutMs 120000
    Set-Busy $false
    if ($r.ExitCode -ne 0 -and -not $r.Output) { Log-Error "act -l 失敗：$($r.Error)"; Set-Status '讀取失敗'; return }
    $jobs = Parse-ActList $r.Output
    if ($jobs.Count -eq 0) { Log-Warn '沒有解析到任何 job。act 原始輸出：'; Append-Log ((Remove-AnsiCodes $r.Output) + "`n"); Set-Status '沒有 job'; return }
    foreach ($j in $jobs) {
        $item = New-Object System.Windows.Forms.ListViewItem($j.JobId)
        foreach ($s in @($j.JobName, $j.Workflow, $j.File, $j.Events)) { [void]$item.SubItems.Add($s) }
        $item.Tag = $j; [void]$lvJobs.Items.Add($item)
        foreach ($e in ($j.Events -split ',')) { $e = $e.Trim(); if ($e -and -not $cboEvent.Items.Contains($e)) { [void]$cboEvent.Items.Add($e) } }
    }
    if ($lvJobs.Items.Count -gt 0) { $lvJobs.Items[0].Selected = $true }
    if (-not $txtSlug.Text) { $txtSlug.Text = Get-RepoSlug $repo }
    Log-Ok "讀到 $($jobs.Count) 個 job。"; Set-Status "$($jobs.Count) 個 job"; Persist-Settings
}

# ---------------------------------------------------------------------------
# 手動執行（串流）
# ---------------------------------------------------------------------------
$runTimer = New-Object System.Windows.Forms.Timer; $runTimer.Interval = 100

function Start-Run {
    if ($script:RunProc) { return }
    $repo = Get-RepoLinuxPath; if (-not $repo) { return }
    $job = ''
    if ($chkSelected.Checked -and $lvJobs.SelectedItems.Count -gt 0) { $job = $lvJobs.SelectedItems[0].Tag.JobId }
    $extra = @()
    if ($chkDry.Checked) { $extra += '-n' }
    if ($chkVerbose.Checked) { $extra += '-v' }
    if ($chkReuse.Checked) { $extra += '--reuse' }
    $ev = $cboEvent.Text.Trim()
    $cmd = New-ActCommand -RepoPath $repo -Event $ev -Job $job -ExtraArgs $extra -RawArgs $txtExtra.Text.Trim()

    $head = Get-RepoHeadSha -RepoPath $repo
    if (-not $head) { $head = '0000000' }
    $script:RunVerdict = New-Verdict -Sha $head -Repo $repo -Event $ev -Job $job -Note '跑的是工作目錄現況，不是 commit'
    $script:RunOutput = New-Object System.Text.StringBuilder

    if ($repo -like '/mnt/*') { Log-Warn 'repo 在 Windows 磁碟上，Docker 掛載會很慢。建議放到 Linux 檔案系統。' }
    Log-Info "執行：act $ev $(if ($job) { "-j $job" }) $($extra -join ' ') $($txtExtra.Text.Trim())"
    Log-Info "目錄：$repo（HEAD $($head.Substring(0, [Math]::Min(8, $head.Length)))）"
    Append-Log ("-" * 100 + "`n") ([System.Drawing.Color]::Gray)

    try {
        $psi = New-WslStartInfo -BashCommand $cmd
        $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $false; $psi.RedirectStandardInput = $true
        $p = [System.Diagnostics.Process]::Start($psi); $p.StandardInput.Close()
        $script:RunProc = $p; $script:RunStream = $p.StandardOutput.BaseStream
        $script:Decoder = [System.Text.Encoding]::UTF8.GetDecoder(); $script:LinePending = ''
        $script:StopRequested = $null; $script:RunStopwatch = [Diagnostics.Stopwatch]::StartNew()
        $script:RunAsync = $script:RunStream.BeginRead($script:RunBuffer, 0, $script:RunBuffer.Length, $null, $null)
    } catch {
        Log-Error "無法啟動：$($_.Exception.Message)"; $script:RunProc = $null; return
    }
    $btnRun.Enabled = $false; $btnStop.Enabled = $true; $btnList.Enabled = $false
    Set-Status '執行中…'; Persist-Settings; $runTimer.Start()
}

function Emit-Chunk([string]$chunk) {
    [void]$script:RunOutput.Append($chunk)
    $text = $script:LinePending + ($chunk -replace "`r", '')
    $lastNl = $text.LastIndexOf("`n")
    if ($lastNl -lt 0) { $script:LinePending = $text; return }
    $script:LinePending = $text.Substring($lastNl + 1)
    Append-Log (Remove-AnsiCodes $text.Substring(0, $lastNl + 1))
}

function Finish-Run {
    $runTimer.Stop()
    $p = $script:RunProc; $code = -1
    try { $p.WaitForExit(2000) | Out-Null; $code = $p.ExitCode } catch {}
    if ($script:LinePending) { Append-Log ((Remove-AnsiCodes $script:LinePending) + "`n"); $script:LinePending = '' }
    $elapsed = $script:RunStopwatch.Elapsed.TotalSeconds
    Append-Log ("-" * 100 + "`n") ([System.Drawing.Color]::Gray)

    $v = Complete-ActVerdict -Verdict $script:RunVerdict -ExitCode $code -Output $script:RunOutput.ToString() -Seconds $elapsed
    if ($script:StopRequested) { $v.Outcome = 'errored'; $v.Note = '已手動停止' }
    $headline = Get-VerdictHeadline $v
    $timeText = '用時 ' + [TimeSpan]::FromSeconds($elapsed).ToString('mm\:ss')
    switch ($v.Outcome) {
        'passed'  { if (Test-VerdictTrustworthy $v) { Log-Ok "$headline，$timeText"; Set-Status '通過' } else { Log-Warn "$headline，$timeText"; Set-Status '通過但沒有驗證' } }
        'failed'  { Log-Error "$headline，$timeText"; Set-Status '失敗' }
        default   { Log-Error "$headline，$timeText"; Set-Status '錯誤' }
    }
    try { $p.Dispose() } catch {}
    $script:RunProc = $null; $script:RunStream = $null; $script:RunAsync = $null
    $btnRun.Enabled = $true; $btnStop.Enabled = $false; $btnList.Enabled = $true

    if ($chkPush.Checked -and -not $script:StopRequested) { Push-ManualVerdict $v }
}

function Push-ManualVerdict($v) {
    $slug = $txtSlug.Text.Trim()
    if (-not $slug) { $slug = Get-RepoSlug $v.Repo; $txtSlug.Text = $slug }
    if (-not $slug) { Log-Warn '沒有 slug，猜不到 owner/repo，沒有推回 GitHub。'; return }
    if ($v.Sha -eq '0000000') { Log-Warn '不是 git repo，沒有 sha 可以推。'; return }
    $state = Get-StatusState $v
    $msg = "要把這次結果推到 $slug 的 commit $($v.Sha.Substring(0,8)) 嗎？`n`ncontext：actci/manual`nstate：$state`n$(Get-VerdictHeadline $v)`n`n注意：跑的是工作目錄現況，未提交的改動也算在內，不一定等於那個 commit。"
    if ([System.Windows.Forms.MessageBox]::Show($msg, '推回 GitHub', 'YesNo', 'Question') -ne 'Yes') { Log-Info '沒有推回。'; return }
    $r = Send-CommitStatus -Slug $slug -Verdict $v -Context 'actci/manual'
    if ($r.Posted) { Log-Ok "已推回 $slug：$($r.State)（actci/manual）" } else { Log-Error "推回失敗：$($r.Detail)" }
}

$runTimer.Add_Tick({
    $p = $script:RunProc
    if (-not $p) { $runTimer.Stop(); return }
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
    } catch { $eof = $true; $script:RunAsync = $null }
    if ($script:StopRequested -and -not $p.HasExited -and ((Get-Date) - $script:StopRequested).TotalSeconds -gt 10) {
        Log-Warn 'act 未在 10 秒內結束，強制終止。'; try { $p.Kill() } catch {}; $script:StopRequested = (Get-Date).AddHours(1)
    }
    if (($eof -or -not $script:RunAsync) -and $p.HasExited) { Finish-Run }
})

function Stop-Run {
    if (-not $script:RunProc -or $script:StopRequested) { return }
    $script:StopRequested = Get-Date
    Log-Warn '送出 SIGINT 給 act（會嘗試清理容器）…'; Set-Status '停止中…'
    Invoke-Wsl -BashCommand 'pkill -INT -x act' -TimeoutMs 10000 | Out-Null
}

# ---------------------------------------------------------------------------
# 監看分頁的更新
# ---------------------------------------------------------------------------
$watchTimer = New-Object System.Windows.Forms.Timer; $watchTimer.Interval = 1000
$script:WatchTicks = 0
$script:WatchCfg = $null

function Refresh-Heartbeat {
    $age = Get-HeartbeatAge -Store $script:Store
    if (-not $age) { $lblBeat.Text = '從來沒有'; $lblBeat.ForeColor = $Gray; $lblBeatNote.Text = 'watcher 沒被啟動過'; $lblBeatNote.ForeColor = $Gray; return }
    $s = [int][Math]::Round($age.Seconds)
    $interval = if ($script:WatchCfg -and $script:WatchCfg.IntervalSeconds) { [int]$script:WatchCfg.IntervalSeconds } else { 60 }
    $lblBeat.Text = if ($s -lt 120) { "$s 秒前" } elseif ($s -lt 7200) { "$([int]($s / 60)) 分鐘前" } else { "$([int]($s / 3600)) 小時前" }
    if ($s -le 2 * $interval) { $lblBeat.ForeColor = $Green; $lblBeatNote.Text = "在動：$($age.Note)"; $lblBeatNote.ForeColor = $Green }
    elseif ($s -le $script:StaleAfter) { $lblBeat.ForeColor = $Orange; $lblBeatNote.Text = "有點久了：$($age.Note)"; $lblBeatNote.ForeColor = $Orange }
    else { $lblBeat.ForeColor = $Red; $lblBeatNote.Text = "太久了，watcher 可能停了（上次：$($age.Note)）"; $lblBeatNote.ForeColor = $Red }
}

function Refresh-WatcherConfig {
    $script:WatchCfg = Get-WatcherConfig -Store $script:Store
    $cfg = $script:WatchCfg
    if (-not $cfg) {
        $lblCfg.Text = '尚未安裝。按「安裝 / 更新 watcher…」。'; $lblTask.Text = ''
        $btnTaskStart.Enabled = $false; $btnTaskStop.Enabled = $false; $btnTaskRemove.Enabled = $false
        return
    }
    $jobText = if ($cfg.PSObject.Properties['Job'] -and $cfg.Job) { "job $($cfg.Job)" } else { '全部 job' }
    $lblCfg.Text = "$($cfg.Slug)  ←  $($cfg.Repo)`n事件 $($cfg.Event)，$jobText，每 $($cfg.IntervalSeconds) 秒，發行版 $($cfg.Distro)，安裝於 $($cfg.InstalledAt)"
    $task = Get-ScheduledTask -TaskName $cfg.TaskName -ErrorAction SilentlyContinue
    if (-not $task) {
        $lblTask.Text = "排程工作 $($cfg.TaskName) 不存在（被移除了？）"; $lblTask.ForeColor = $Red
        $btnTaskStart.Enabled = $false; $btnTaskStop.Enabled = $false; $btnTaskRemove.Enabled = $false
        return
    }
    $info = $task | Get-ScheduledTaskInfo
    $next = if ($info.NextRunTime) { $info.NextRunTime.ToString('MM-dd HH:mm') } else { '（沒有！不會自己回來）' }
    $last = if ($info.LastRunTime -and $info.LastRunTime.Year -gt 2000) { $info.LastRunTime.ToString('MM-dd HH:mm') } else { '從未' }
    $lblTask.Text = "排程工作 $($cfg.TaskName)：$($task.State)，上次啟動 $last，下次 $next，上次結果 $($info.LastTaskResult)"
    $lblTask.ForeColor = if ($task.State -eq 'Running') { $Green } elseif ($info.NextRunTime) { $Gray } else { $Red }
    $btnTaskStart.Enabled = $task.State -ne 'Running'; $btnTaskStop.Enabled = $task.State -eq 'Running'; $btnTaskRemove.Enabled = $true
}

function Refresh-Verdicts {
    $recent = @(Get-RecentVerdicts -Store $script:Store -Limit 50 -WarningAction SilentlyContinue)
    $selected = if ($lvVerdicts.SelectedItems.Count) { $lvVerdicts.SelectedItems[0].SubItems[1].Text } else { '' }
    $lvVerdicts.BeginUpdate(); $lvVerdicts.Items.Clear()
    foreach ($v in $recent) {
        $when = $v.FinishedAt; if (-not $when) { $when = $v.StartedAt }
        try { $when = [DateTime]::Parse($when, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind).ToLocalTime().ToString('MM-dd HH:mm:ss') } catch {}
        $item = New-Object System.Windows.Forms.ListViewItem($when)
        $short = $v.Sha.Substring(0, [Math]::Min(10, $v.Sha.Length))
        $mark = if (Test-VerdictTrustworthy $v) { '通過' } elseif ($v.Outcome -eq 'passed') { '未驗證' } elseif ($v.Outcome -eq 'failed') { '失敗' } else { 'CI 錯誤' }
        foreach ($s in @($short, $mark, [string]$v.TestsRun, $v.Event, (Get-VerdictHeadline $v))) { [void]$item.SubItems.Add($s) }
        $item.ForeColor = if (Test-VerdictTrustworthy $v) { $Green } elseif ($v.Outcome -eq 'errored') { $Orange } else { $Red }
        $item.Tag = $v
        [void]$lvVerdicts.Items.Add($item)
        if ($short -eq $selected) { $item.Selected = $true }
    }
    $lvVerdicts.EndUpdate()
}

function Refresh-WatchTab {
    Refresh-WatcherConfig; Refresh-Heartbeat; Refresh-Verdicts
}

$watchTimer.Add_Tick({
    $script:WatchTicks++
    try {
        Refresh-Heartbeat
        if ($script:WatchTicks % 5 -eq 0) { Refresh-Verdicts }
        if ($script:WatchTicks % 10 -eq 0) { Refresh-WatcherConfig }
    } catch {}
})

function Show-InstallWatcherDialog {
    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = '安裝 / 更新 watcher'; $dlg.StartPosition = 'CenterParent'; $dlg.FormBorderStyle = 'FixedDialog'
    $dlg.MaximizeBox = $false; $dlg.MinimizeBox = $false; $dlg.ClientSize = New-Object System.Drawing.Size(560, 230); $dlg.Font = $form.Font
    $dlg.AutoScaleDimensions = New-Object System.Drawing.SizeF(96, 96); $dlg.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::Dpi
    $cfg = $script:WatchCfg
    $dlg.Controls.Add((New-Label 'Repo 路徑' 12 16 90))
    $tRepo = New-Object System.Windows.Forms.TextBox; $tRepo.Location = New-Object System.Drawing.Point(110, 13); $tRepo.Size = New-Object System.Drawing.Size(340, 24)
    $tRepo.Text = if ($cfg) { $cfg.Repo } else { $txtRepo.Text }
    $bBrowse = New-Button '瀏覽…' 458 11 90
    $dlg.Controls.AddRange(@($tRepo, $bBrowse))
    $dlg.Controls.Add((New-Label 'Slug (owner/repo)' 12 50 100))
    $tSlug = New-Object System.Windows.Forms.TextBox; $tSlug.Location = New-Object System.Drawing.Point(110, 47); $tSlug.Size = New-Object System.Drawing.Size(340, 24)
    $tSlug.Text = if ($cfg) { $cfg.Slug } else { $txtSlug.Text }
    $dlg.Controls.Add($tSlug)
    $dlg.Controls.Add((New-Label '事件' 12 84 90))
    $tEvent = New-Object System.Windows.Forms.ComboBox; $tEvent.Location = New-Object System.Drawing.Point(110, 81); $tEvent.Size = New-Object System.Drawing.Size(160, 24)
    [void]$tEvent.Items.AddRange(@('pull_request', 'push')); $tEvent.Text = if ($cfg) { $cfg.Event } else { 'pull_request' }
    $dlg.Controls.Add($tEvent)
    $dlg.Controls.Add((New-Label '每幾秒一圈' 290 84 80))
    $tInt = New-Object System.Windows.Forms.NumericUpDown; $tInt.Location = New-Object System.Drawing.Point(370, 81); $tInt.Size = New-Object System.Drawing.Size(80, 24)
    $tInt.Minimum = 15; $tInt.Maximum = 3600; $tInt.Value = if ($cfg) { [int]$cfg.IntervalSeconds } else { 60 }
    $dlg.Controls.Add($tInt)
    $dlg.Controls.Add((New-Label 'Job ID' 12 118 90))
    $tJob = New-Object System.Windows.Forms.TextBox; $tJob.Location = New-Object System.Drawing.Point(110, 115); $tJob.Size = New-Object System.Drawing.Size(160, 24)
    $tJob.Text = if ($cfg -and $cfg.PSObject.Properties['Job']) { [string]$cfg.Job } elseif ($lvJobs.SelectedItems.Count -gt 0) { $lvJobs.SelectedItems[0].Tag.JobId } else { '' }
    $dlg.Controls.Add($tJob)
    $jobHint = New-Label '留空 = 該事件下所有 job 都跑。多個 workflow 收同一事件時要填。' 280 118 260; $jobHint.ForeColor = $Gray
    $dlg.Controls.Add($jobHint)
    $help = New-Block '會開一個主控台視窗執行 install_watcher.ps1，顯示五個步驟。前提：Docker、act、gh 都已就緒。裝完回到這個分頁按「重新整理」。' 12 148 536 40
    $help.ForeColor = $Gray; $dlg.Controls.Add($help)
    $dlg.ClientSize = New-Object System.Drawing.Size(560, 236)
    $bOk = New-Button '安裝' 350 196 95 30; $bCancel = New-Button '取消' 453 196 95 30
    $dlg.Controls.AddRange(@($bOk, $bCancel)); $dlg.AcceptButton = $bOk; $dlg.CancelButton = $bCancel
    $bBrowse.Add_Click({
        $fb = New-Object System.Windows.Forms.FolderBrowserDialog; $fb.ShowNewFolderButton = $false
        if ($fb.ShowDialog($dlg) -eq 'OK') { $tRepo.Text = $fb.SelectedPath }
    })
    $bOk.Add_Click({
        if (-not $tRepo.Text.Trim() -or $tSlug.Text.Trim() -notmatch '^[^/\s]+/[^/\s]+$') {
            [System.Windows.Forms.MessageBox]::Show('Repo 路徑與 owner/repo 都要填。', 'actci') | Out-Null; return
        }
        $dlg.Tag = @{ Repo = $tRepo.Text.Trim(); Slug = $tSlug.Text.Trim(); Event = $tEvent.Text.Trim(); Interval = [int]$tInt.Value; Job = $tJob.Text.Trim() }
        $dlg.DialogResult = 'OK'; $dlg.Close()
    })
    $bCancel.Add_Click({ $dlg.DialogResult = 'Cancel'; $dlg.Close() })
    if ($dlg.ShowDialog($form) -ne 'OK') { return }
    $a = $dlg.Tag
    $installer = Join-Path $script:Root 'install_watcher.ps1'
    $args = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-NoExit', '-File', "`"$installer`"",
              '-Repo', "`"$($a.Repo)`"", '-Slug', "`"$($a.Slug)`"", '-Event', "`"$($a.Event)`"", '-Job', "`"$($a.Job)`"",
              '-IntervalSeconds', $a.Interval, '-Distro', "`"$(Get-WslDistro)`"")
    Start-Process powershell.exe -ArgumentList $args | Out-Null
    Set-Status '安裝器已在另一個視窗執行，完成後按「重新整理」'
}

# ---------------------------------------------------------------------------
# 事件綁定
# ---------------------------------------------------------------------------
$cboDistro.Add_SelectedIndexChanged({ if ($cboDistro.SelectedItem) { Set-WslDistro ([string]$cboDistro.SelectedItem); $script:LinuxHome = ''; $script:LinuxUser = '' } })
$btnCheck.Add_Click({ Check-Environment | Out-Null })
$btnDocker.Add_Click({ Start-DockerDesktop })
$btnInstallAct.Add_Click({ Install-Act })
$btnActrc.Add_Click({ Create-Actrc })
$btnSecrets.Add_Click({ Edit-Secrets })
$btnOpenHome.Add_Click({ $h = Get-LinuxHomeUnc; if ($h) { Start-Process explorer.exe -ArgumentList "`"$h`"" | Out-Null } else { Log-Error '無法取得 Linux 家目錄。' } })

$btnBrowse.Add_Click({
    $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
    $dlg.Description = '選擇含有 .github/workflows 的 repo 資料夾（可選 \\wsl.localhost\ 底下的 Linux 目錄）'; $dlg.ShowNewFolderButton = $false
    if ($txtRepo.Text -and (Test-Path $txtRepo.Text)) { $dlg.SelectedPath = $txtRepo.Text }
    if ($dlg.ShowDialog($form) -eq 'OK') { $txtRepo.Text = $dlg.SelectedPath; Log-Info "選擇 $($dlg.SelectedPath)  →  $(ConvertTo-WslPath $dlg.SelectedPath)" }
})
$btnList.Add_Click({ Load-Jobs })
$lvJobs.Add_DoubleClick({ if ($lvJobs.SelectedItems.Count -gt 0) { Start-Run } })
$btnRun.Add_Click({ Start-Run })
$btnStop.Add_Click({ Stop-Run })
$btnClear.Add_Click({ $rtbLog.Clear() })
$btnSave.Add_Click({
    $dlg = New-Object System.Windows.Forms.SaveFileDialog
    $dlg.Filter = '文字檔 (*.log;*.txt)|*.log;*.txt|所有檔案|*.*'; $dlg.FileName = 'act-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.log'
    if ($dlg.ShowDialog($form) -eq 'OK') { [System.IO.File]::WriteAllText($dlg.FileName, $rtbLog.Text, [System.Text.Encoding]::UTF8); Log-Ok "已儲存 $($dlg.FileName)" }
})

$btnInstallWatcher.Add_Click({ Show-InstallWatcherDialog })
$btnTaskStart.Add_Click({ try { Start-ScheduledTask -TaskName $script:WatchCfg.TaskName; Set-Status '已送出啟動' } catch { Set-Status "啟動失敗：$($_.Exception.Message)" }; Refresh-WatcherConfig })
$btnTaskStop.Add_Click({
    try {
        Stop-ScheduledTask -TaskName $script:WatchCfg.TaskName
        # Stop-ScheduledTask 只砍 conhost，watcher 的 powershell 可能還活著。
        Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
            Where-Object { $_.CommandLine -and $_.CommandLine -like '*watcher.ps1*' } |
            ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
        Set-Status '已停止'
    } catch { Set-Status "停止失敗：$($_.Exception.Message)" }
    Refresh-WatcherConfig
})
$btnTaskRemove.Add_Click({
    if ([System.Windows.Forms.MessageBox]::Show("移除排程工作 $($script:WatchCfg.TaskName)？判定與日誌會留著。", 'actci', 'YesNo', 'Warning') -ne 'Yes') { return }
    try {
        Stop-ScheduledTask -TaskName $script:WatchCfg.TaskName -ErrorAction SilentlyContinue
        Unregister-ScheduledTask -TaskName $script:WatchCfg.TaskName -Confirm:$false
        Remove-Item -LiteralPath (Get-WatcherConfigPath -Store $script:Store) -ErrorAction SilentlyContinue
        Set-Status '已移除'
    } catch { Set-Status "移除失敗：$($_.Exception.Message)" }
    Refresh-WatchTab
})
$btnWatchLog.Add_Click({ $p = Join-Path $script:Store.Root 'watcher.log'; if (Test-Path $p) { Start-Process notepad.exe -ArgumentList "`"$p`"" | Out-Null } else { Set-Status '還沒有 watcher.log' } })
$btnOpenStore.Add_Click({ Start-Process explorer.exe -ArgumentList "`"$($script:Store.Root)`"" | Out-Null })
$btnRefreshWatch.Add_Click({ Refresh-WatchTab })
$lvVerdicts.Add_DoubleClick({
    if ($lvVerdicts.SelectedItems.Count -eq 0) { return }
    $v = $lvVerdicts.SelectedItems[0].Tag
    if ($v.LogPath -and (Test-Path $v.LogPath)) { Start-Process notepad.exe -ArgumentList "`"$($v.LogPath)`"" | Out-Null } else { Set-Status '這次判定沒有日誌檔' }
})
$tabs.Add_SelectedIndexChanged({ if ($tabs.SelectedTab -eq $tabWatch) { Refresh-WatchTab } })

$form.Add_FormClosing({
    if ($script:RunProc -and -not $script:RunProc.HasExited) {
        if ([System.Windows.Forms.MessageBox]::Show('act 仍在執行，要停止並關閉嗎？', 'actci', 'YesNo', 'Warning') -ne 'Yes') { $_.Cancel = $true; return }
        Invoke-Wsl -BashCommand 'pkill -INT -x act' -TimeoutMs 10000 | Out-Null
        try { $script:RunProc.WaitForExit(5000) | Out-Null; if (-not $script:RunProc.HasExited) { $script:RunProc.Kill() } } catch {}
    }
    $watchTimer.Stop(); Persist-Settings
})

$form.Add_Shown({
    Log-Info 'actci 啟動。執行分頁：選 repo → 讀取 job → 執行。監看分頁：watcher 的心跳與判定。環境分頁：檢查與安裝。'
    Refresh-Distros
    Refresh-WatchTab
    $watchTimer.Start()
    if ($cboDistro.Items.Count -gt 0) { Check-Environment | Out-Null }
    if ($AutoCloseSeconds -gt 0) {
        # 事件處理器裡的輸出不會進管線，先記著，關閉後再印。
        $script:SmokeInfo = "SMOKE: shown title=[$($form.Text)] tabs=$($tabs.TabPages.Count) distro=[$($cboDistro.Text)] dpi=$($form.DeviceDpi) client=$($form.ClientSize.Width)x$($form.ClientSize.Height) wsl=[$($lblWsl.Text)] act=[$($lblAct.Text)] gh=[$($lblGh.Text)] beat=[$($lblBeat.Text)]"
        if ($ShowTab -ge 0 -and $ShowTab -lt $tabs.TabPages.Count) { $tabs.SelectedIndex = $ShowTab }
        $script:Closer = New-Object System.Windows.Forms.Timer; $script:Closer.Interval = $AutoCloseSeconds * 1000
        $script:Closer.Add_Tick({
            $script:Closer.Stop()
            if ($Screenshot) {
                try {
                    # 用 DrawToBitmap 讓視窗自己畫，不抓螢幕：被別的視窗蓋住也抓得到自己。
                    [System.Windows.Forms.Application]::DoEvents()
                    $bmp = New-Object System.Drawing.Bitmap($form.Width, $form.Height)
                    $form.DrawToBitmap($bmp, (New-Object System.Drawing.Rectangle(0, 0, $form.Width, $form.Height)))
                    $bmp.Save($Screenshot, [System.Drawing.Imaging.ImageFormat]::Png); $bmp.Dispose()
                } catch { $script:SmokeInfo += " screenshot-failed=[$($_.Exception.Message)]" }
            }
            $form.Close()
        })
        $script:Closer.Start()
    }
})

# 字體大小：版面是以 9pt 設計的，這裡換成使用者要的大小並把整個版面等比放大。
# 想改就編輯 window.json 的 FontSize（8 到 20）。
$script:UiScale = [double]$settings.FontSize / 9
if ([Math]::Abs($script:UiScale - 1) -gt 0.01) {
    $k = $script:UiScale
    $form.Font = New-Object System.Drawing.Font('Microsoft JhengHei UI', [single]$settings.FontSize)
    $form.Scale((New-Object System.Drawing.SizeF($k, $k)))
    $form.MinimumSize = New-Object System.Drawing.Size([int](920 * $k), [int](640 * $k))
    # 自己指定過字型的控制項不會跟著 form 的字型走，逐一放大。
    $btnRun.Font = New-Object System.Drawing.Font($form.Font, [System.Drawing.FontStyle]::Bold)
    $rtbLog.Font = New-Object System.Drawing.Font('Consolas', [single](9.5 * $k))
    $lblBeat.Font = New-Object System.Drawing.Font('Microsoft JhengHei UI', [single](16 * $k), [System.Drawing.FontStyle]::Bold)
    foreach ($lv in @($lvJobs, $lvVerdicts)) { foreach ($col in $lv.Columns) { $col.Width = [int]($col.Width * $k) } }
}

[void]$form.ShowDialog()
if ($AutoCloseSeconds -gt 0) { Write-Output $script:SmokeInfo; Write-Output 'SMOKE: closed cleanly' }
