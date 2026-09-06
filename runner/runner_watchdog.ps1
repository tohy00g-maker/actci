# 看門狗：Runner.Listener 不在就把它救回來。
#
# ## 為什麼需要
#
# 2026-08-31 07:27 runner 停了，08:17 推上去的工作排了 3 小時 48 分沒有人接，
# 是使用者問「跑那麼久是卡住了嗎」才發現的。
#
# 排程工作本身**有**自動重啟（RestartCount=3、RestartInterval=PT1M），但那
# 三次沒救回來。最可能的原因是撞上 session 衝突：舊 session 還沒釋放，新實例
# 一連上就拿到 `A session for this runner already exists`，幾秒後退出。
#
# **排程器做不了「確認前一個真的死了」那一步** —— 而那正是
# restart_runner.ps1 存在的理由。所以這支不自己重啟，它呼叫那支。
#
# ## 為什麼只看「行程在不在」
#
# 行程活著但卡住（連不上 GitHub 卻不退出）這一種，這一版偵測不到。誠實寫在
# 這裡：今天出事的是「行程不見了」，先接住那一種。要偵測假死得去讀
# run-detached.log 的時間戳，而那會把「安靜但正常」誤判成死掉。
#
# ## 為什麼有冷卻時間
#
# 重啟失敗的話，每 10 分鐘試一次就變成每 10 分鐘打 GitHub 一次。冷卻讓它退
# 一步，也讓日誌看得出「試過了、沒成功」，而不是被同一行洗掉。
#
# ## 為什麼連「一切正常」也要寫日誌
#
# 不寫的話，空的日誌有兩種解釋：看門狗運作正常，或看門狗從來沒跑過。這兩件
# 事長得一樣，就等於沒有監測 —— 今天出事的正是這個形狀。

[CmdletBinding()]
param(
    [string]$TaskName = 'Example-CI-Runner',
    [string]$LogPath = 'C:\actions-runner\_diag\watchdog.log',
    [string]$StatePath = 'C:\actions-runner\_diag\watchdog-last-restart.txt',
    [int]$CooldownMinutes = 30,
    [int]$KeepLogLines = 500
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-Line([string]$Message) {
    $stamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line = "$stamp  $Message"
    Write-Output $line
    try {
        $dir = Split-Path -Parent $LogPath
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
        Add-Content -Path $LogPath -Value $line -Encoding utf8
        # 修剪：這支每 10 分鐘跑一次，不修剪的話一年會長到五萬行。
        $existing = @(Get-Content -Path $LogPath -ErrorAction SilentlyContinue)
        if ($existing.Count -gt $KeepLogLines) {
            $existing | Select-Object -Last $KeepLogLines |
                Set-Content -Path $LogPath -Encoding utf8
        }
    } catch {
        # 寫不了日誌不該讓看門狗本身死掉 —— 它的工作是重啟 runner，不是記帳。
    }
}

$listener = @(Get-Process -Name 'Runner.Listener' -ErrorAction SilentlyContinue)

if ($listener.Count -gt 0) {
    Write-Line "正常：Runner.Listener 在（PID $($listener[0].Id)）"
    exit 0
}

# 冷卻。上一次動手是什麼時候？
$lastRestart = $null
if (Test-Path $StatePath) {
    try {
        $raw = (Get-Content -Path $StatePath -Raw).Trim()
        if ($raw) { $lastRestart = [datetime]::Parse($raw) }
    } catch {
        # 讀不懂就當作沒重啟過 —— 寧可多試一次，也不要因為一個壞掉的時間戳
        # 讓 CI 永遠不回來。
        $lastRestart = $null
    }
}

if ($lastRestart) {
    $elapsed = (Get-Date) - $lastRestart
    if ($elapsed.TotalMinutes -lt $CooldownMinutes) {
        $left = [math]::Round($CooldownMinutes - $elapsed.TotalMinutes, 1)
        Write-Line "不在，但還在冷卻（上次 $($lastRestart.ToString('HH:mm:ss'))，還要 $left 分）。這次不動。"
        exit 0
    }
}

Write-Line "Runner.Listener 不在 —— 開始重啟"

try {
    Set-Content -Path $StatePath -Value (Get-Date).ToString('o') -Encoding utf8
} catch {
    Write-Line "警告：時間戳寫不進去（$($_.Exception.Message)）。冷卻這次會失效。"
}

$restart = Join-Path $PSScriptRoot 'restart_runner.ps1'
if (-not (Test-Path $restart)) {
    Write-Line "錯誤：找不到 $restart。沒有動作。"
    exit 1
}

# 呼叫既有的那支，不要在這裡重寫四步驟 —— 它的順序是兩次事故換來的，
# 抄一份就等於多一個會走樣的版本。
try {
    $output = & powershell -ExecutionPolicy Bypass -File $restart -TaskName $TaskName
    $code = $LASTEXITCODE
    foreach ($line in @($output)) { Write-Line "  | $line" }
    if ($code -eq 0) {
        Write-Line "重啟完成"
    } else {
        Write-Line "重啟失敗（離開碼 $code）。冷卻 $CooldownMinutes 分鐘後再試。"
    }
    exit $code
} catch {
    Write-Line "重啟丟出例外：$($_.Exception.Message)"
    exit 1
}
