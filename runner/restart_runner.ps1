# 重啟 GitHub Actions 的自架 runner。
#
# ## 為什麼不是 Stop-ScheduledTask 再 Start-ScheduledTask
#
# 2026-08-28 踩到：`Stop-ScheduledTask` 只砍掉排程動作那個 cmd.exe，
# **Runner.Listener 活了下來變成孤兒**，而且還握著 GitHub 那一端的 session。
# 接著 Start 起來的新實例一連上就撞：
#
#     A session for this runner already exists.
#     Runner connect error: Error: Conflict.
#
# 工作在幾秒後以 LastTaskResult=1 收場。那個結果看起來像「以 SYSTEM 跑不動」，
# 實際上是前一個沒死乾淨 —— 而那個誤判會讓人回頭去改排程設定，改一個沒有壞
# 的東西。
#
# 所以停完**一定要確認 Runner.Listener 真的不在了**，再啟動。順序不能顛倒，
# 中間那一步也不能省。
#
# ## 用法
#
#     powershell -ExecutionPolicy Bypass -File scripts\restart_runner.ps1
#
# runner 以 SYSTEM 身分跑的話，這支要用系統管理員開的終端機執行。

[CmdletBinding()]
param(
    [string]$TaskName = 'Example-CI-Runner',

    # runner 的輸出。用來確認它真的接上，而不是只確認行程還在。
    [string]$LogPath = 'C:\actions-runner\_diag\run-detached.log',

    # 等它接上多久。GitHub 那端的舊 session 有時要一分多鐘才釋放。
    [int]$WaitSeconds = 150,

    # 停止之後留多久讓它自己收尾，超過才動手砍。見 2/4 的說明。
    [int]$GraceSeconds = 15
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Say($text) { Write-Host $text }

# ── 1/4 停掉排程工作 ───────────────────────────────────────
Say "== 1/4 停掉 $TaskName"
try {
    Stop-ScheduledTask -TaskName $TaskName -ErrorAction Stop
    Say "   已下達停止"
} catch {
    Say "   停止時的訊息：$($_.Exception.Message)"
}

# ── 2/4 等它結束，必要時才動手 ─────────────────────────────
#
# 這一步就是這支腳本存在的理由：下一步起來的實例只要撞到還活著的舊行程，
# 就會拿到 "A session for this runner already exists" 然後退出。
#
# 但**先等，不要先砍**。`Stop-ScheduledTask` 是非同步的 —— 它會成功，只是
# 需要幾秒讓 runner 收到 Ctrl-C 收尾。第一版沒等就去砍，砍到一個正在收尾的
# 行程；而 runner 以 SYSTEM 執行時，未提權的 Stop-Process 會拿到「存取被
# 拒」，於是腳本在「其實再等三秒就好了」的情況下中止。
Say "== 2/4 等 Runner.Listener 結束"
$grace = (Get-Date).AddSeconds($GraceSeconds)
while (@(Get-Process -Name 'Runner.Listener' -ErrorAction SilentlyContinue).Count -gt 0 `
       -and (Get-Date) -lt $grace) {
    Start-Sleep -Milliseconds 500
}

$leftover = @(Get-Process -Name 'Runner.Listener' -ErrorAction SilentlyContinue)

# 有沒有動手強殺，決定第 4 步要等多久。乾淨結束的 listener 會自己刪掉
# GitHub 那端的 session，下一個實例馬上連得上；被強殺的不會，新實例要一直
# 撞 `A session for this runner already exists` 直到 GitHub 讓那個 session
# 過期。2026-08-31 實測：強殺之後 167 秒才接上，而當時上限是 150 秒 ——
# 差 17 秒，於是腳本在它正在恢復的時候宣告失敗。
$wasForceKilled = $false

if ($leftover.Count -eq 0) {
    Say "   已自行結束"
} else {
    $wasForceKilled = $true
    Say "   $GraceSeconds 秒後還在，動手停止"
    foreach ($proc in $leftover) {
        try {
            Stop-Process -Id $proc.Id -Force -ErrorAction Stop
            Say "   停止 PID $($proc.Id)"
        } catch {
            Write-Error "停不掉 PID $($proc.Id)：$($_.Exception.Message)。runner 若以 SYSTEM 執行，請用系統管理員身分再跑一次。"
        }
    }
}

# 確認真的沒了才往下走 —— 送出停止不代表它已經結束。
$deadline = (Get-Date).AddSeconds(20)
while (@(Get-Process -Name 'Runner.Listener' -ErrorAction SilentlyContinue).Count -gt 0) {
    if ((Get-Date) -gt $deadline) {
        Write-Error "Runner.Listener 還在，沒有繼續啟動 —— 硬起下去只會撞 session。"
    }
    Start-Sleep -Milliseconds 500
}
Say "   確認乾淨"

# ── 3/4 啟動 ──────────────────────────────────────────────
Say "== 3/4 啟動 $TaskName"
$before = 0
if (Test-Path $LogPath) {
    $before = @(Get-Content $LogPath).Count
}
Start-ScheduledTask -TaskName $TaskName
Say "   已下達啟動（日誌原本 $before 行）"

# ── 4/4 確認它真的接上 ────────────────────────────────────
#
# 只看「行程在不在」不夠：撞 session 的時候行程也在，只是一直重試。要看
# 日誌講 Listening for Jobs。
Say "== 4/4 等它接上"

# 強殺過就多給一倍時間 —— 見第 2 步的說明。
$allowed = if ($wasForceKilled) { $WaitSeconds * 2 } else { $WaitSeconds }
if ($wasForceKilled) {
    Say "   （剛才強殺過，等待上限放寬到 $allowed 秒：舊 session 要等 GitHub 讓它過期）"
}

$deadline = (Get-Date).AddSeconds($allowed)
$connected = $false
while ((Get-Date) -lt $deadline) {
    if (Test-Path $LogPath) {
        # 看最後幾行，不是只看最後一行 —— 接上之後可能立刻有工作進來，
        # 「Listening for Jobs」就不再是最後一行了。
        $tail = @(Get-Content $LogPath -Tail 10 -ErrorAction SilentlyContinue)
        if ($tail -match 'Listening for Jobs') {
            $connected = $true
            break
        }
    }
    Start-Sleep -Seconds 3
}

$state = (Get-ScheduledTask -TaskName $TaskName).State
$proc = @(Get-Process -Name 'Runner.Listener' -ErrorAction SilentlyContinue)

# `$proc.Id` 在空陣列上會炸。
#
# `Set-StrictMode -Version Latest` 之下，取一個不存在的屬性是終止錯誤 ——
# 而 `@()` 沒有 Id。2026-09-01 救 runner 的時候就撞到：前三步（停掉、確認乾淨、
# 啟動）全部成功，第 4 步在**報告成功**的那一行掛掉：
#
#     The property 'Id' cannot be found on this object.
#
# 那一段只有在強殺過之後才走得到（等待上限放寬到 300 秒的那條路），所以從來
# 沒被跑過。**一支救援腳本在它自己的成功路徑上有 bug，而那條路徑只在真的
# 出事時才會執行。**
$pids = if ($proc.Count) { ($proc | ForEach-Object { $_.Id }) -join ', ' } else { '（查不到，可能正在啟動）' }

if ($connected) {
    Say "   接上了。工作狀態 $state；PID $pids"
} else {
    Say "   $allowed 秒內沒看到 Listening for Jobs。工作狀態 $state"
    if (Test-Path $LogPath) {
        Say "   日誌最後幾行："
        Get-Content $LogPath -Tail 5 | ForEach-Object { Say "     $_" }
    }
    Write-Error "runner 沒有接上。"
}

Say ""
Say "完成。"
