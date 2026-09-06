# 註冊（或更新）CI runner 的看門狗排程工作。
#
# ## 為什麼要有這支，而不是手動在工作排程器裡點
#
# 手點出來的設定只存在那台機器上。寫成腳本才說得出「這台的看門狗是什麼形狀」，
# 而且第二台、第三台（客戶的機器）照著跑就好。
#
# ## 為什麼是登入觸發 + 每 10 分鐘重複
#
# runner 工作本身的 LogonType 是 **Interactive** —— 它只有在使用者登入之後才
# 存在。所以看門狗做成同樣的形狀，蓋住的剛好是 runner 該在的那段時間。
#
# 用開機觸發的話，看門狗會在沒人登入的時候一直找一個本來就不該存在的行程，
# 然後每 10 分鐘試著重啟一個註定失敗的東西。
#
# 要讓 CI 不登入也能跑是另一件事：runner 工作的 LogonType 要改成 Password
# （把帳號密碼存進排程器）。那一步要人自己做。
#
# ## 為什麼有執行時間上限
#
# 看門狗自己卡住的話，下一次觸發不會執行（排程器不會同時跑兩個實例），於是
# 看門狗變成它要防的那種東西 —— 安靜地不在了。上限讓它被砍掉重來。
#
# ## 用法
#
#     powershell -ExecutionPolicy Bypass -File scripts\install_runner_watchdog.ps1
#
# 再跑一次是安全的：已經存在就整份覆蓋，不會長出第二個。

[CmdletBinding()]
param(
    [string]$TaskName = 'Example-CI-Runner-Watchdog',
    [string]$WatchedTask = 'Example-CI-Runner',
    [int]$EveryMinutes = 10,
    [int]$TimeLimitMinutes = 10
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# New-QuietScheduledTaskAction 住在這裡。
. (Join-Path $PSScriptRoot '_runner_common.ps1')

function Say([string]$Message) { Write-Output "   $Message" }

$script = Join-Path $PSScriptRoot 'runner_watchdog.ps1'
if (-not (Test-Path $script)) {
    Write-Error "找不到 $script"
}

Write-Output "== 1/4 確認被看的那個工作存在"
$watched = Get-ScheduledTask -TaskName $WatchedTask -ErrorAction SilentlyContinue
if (-not $watched) {
    Write-Error "找不到排程工作 $WatchedTask。看門狗沒有東西可以看。"
}
Say "$WatchedTask（LogonType $($watched.Principal.LogonType)）"

Write-Output "== 2/4 組出工作定義"

# conhost --headless 包起來 —— 見 _deployment_common.ps1 的 New-QuietScheduledTaskAction。
$action = New-QuietScheduledTaskAction `
    -Execute 'powershell.exe' `
    -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$script`"" `
    -WorkingDirectory (Split-Path -Parent $script)

# 兩個觸發器，缺一不可。
#
# ## 為什麼不能只有登入觸發
#
# 2026-08-31 第一版只掛登入觸發加重複，裝完看起來一切正常（工作已註冊、手動
# 跑一次結果 0）。實測殺掉 runner 之後**等了 13 分鐘完全沒有動靜** ——
# NextRunTime 是空的。
#
# 原因：登入觸發器的「重複」要等**觸發器本身觸發過**才開始計時。而註冊它的
# 時候使用者早就登入了，那個登入事件不會再發生。安裝腳本裡的
# Start-ScheduledTask 手動跑了一次，但那不會啟動重複排程。
#
# 結果是一個看起來裝好了、實際上永遠不會自己醒來的看門狗 —— 正是它要防的
# 那個形狀。
#
# ## 所以
#
#   一次性觸發（現在起算）+ 重複  ->  裝完立刻開始跑，不必等下一次登入
#   登入觸發          + 重複      ->  重開機登入後接手
#
# ## 無限期的寫法
#
# Duration 留空，不是給一個很大的值。[TimeSpan]::MaxValue 會生出
# P99999999DT23H59M59S，註冊時直接被擋：
#     The task XML contains a value which is incorrectly formatted or out of range.

$interval = New-TimeSpan -Minutes $EveryMinutes

$nowTrigger = New-ScheduledTaskTrigger -Once -At (Get-Date) -RepetitionInterval $interval
$nowTrigger.Repetition.Duration = $null

$logonTrigger = New-ScheduledTaskTrigger -AtLogOn -User $watched.Principal.UserId
$logonRepetition = (New-ScheduledTaskTrigger -Once -At (Get-Date) `
    -RepetitionInterval $interval).Repetition
$logonRepetition.Duration = $null
$logonTrigger.Repetition = $logonRepetition

$trigger = @($nowTrigger, $logonTrigger)
Say "立刻開始，每 $EveryMinutes 分鐘一次（無限期）；另加登入觸發供重開機後接手"

# 跟被看的那個工作同一個身分 —— 不同身分的話，看門狗看得到行程卻不一定
# 停得掉它。
$principal = New-ScheduledTaskPrincipal `
    -UserId $watched.Principal.UserId `
    -LogonType $watched.Principal.LogonType `
    -RunLevel $watched.Principal.RunLevel
Say "身分 $($watched.Principal.UserId)／$($watched.Principal.LogonType)"

$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -StartWhenAvailable `
    -ExecutionTimeLimit (New-TimeSpan -Minutes $TimeLimitMinutes) `
    -MultipleInstances IgnoreNew
Say "執行時間上限 $TimeLimitMinutes 分鐘，重疊時忽略新的"

Write-Output "== 3/4 註冊"
$existing = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
if ($existing) {
    Say "已經有一個，整份覆蓋"
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
}
Register-ScheduledTask `
    -TaskName $TaskName `
    -Action $action `
    -Trigger $trigger `
    -Principal $principal `
    -Settings $settings `
    -Description "Runner.Listener 不在就呼叫 restart_runner.ps1 把它救回來。見 scripts/runner_watchdog.ps1 的檔頭。" | Out-Null
Say "已註冊"

Write-Output "== 4/4 驗它跑得動，而且會自己再跑"
Start-ScheduledTask -TaskName $TaskName
Start-Sleep -Seconds 5
$info = Get-ScheduledTask -TaskName $TaskName | Get-ScheduledTaskInfo
Say "上次執行 $($info.LastRunTime)，結果 $($info.LastTaskResult)"
if ($info.LastTaskResult -ne 0) {
    Write-Error "看門狗跑起來不是 0（$($info.LastTaskResult)）。先處理它，不要留一個不會動的看門狗 —— 那比沒有還糟，因為你會以為有。"
}

# 這一條是第一版缺的。當時「手動跑一次結果 0」就放行了，而那個看門狗
# 永遠不會自己醒來 —— NextRunTime 是空的，因為它只掛了登入觸發，而使用者
# 早就登入了。
#
# 「它跑得動」跟「它會自己跑」是兩件事。只驗前者就等於驗了一個不重要的。
if (-not $info.NextRunTime) {
    Write-Error "工作註冊了，但沒有排定的下一次（NextRunTime 是空的）—— 這個看門狗不會自己醒來。檢查觸發器：只有登入觸發的話，重複要等下一次登入才開始。"
}
Say "下次自動執行 $($info.NextRunTime)"

Write-Output ""
Write-Output "完成。日誌在 C:\actions-runner\_diag\watchdog.log"
