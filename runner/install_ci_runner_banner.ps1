# 把 CI runner 的排程動作換成帶橫幅的外殼。
#
# ## 為什麼要複製到 C:\actions-runner 而不是直接指到 repo
#
# 排程工作指向 repo 裡的路徑，就等於「repo 資料夾一改名 CI 就掛」。runner 是
# 機器層級的基礎設施，它的東西住在自己的目錄裡。repo 保留原始版本，這支負責
# 把它送過去。
#
# ## 為什麼預設不重啟
#
# 換動作要重啟 runner 才生效，而重啟會砍掉當下正在跑的建置。裝的時候 CI 常常
# 正在跑（這支腳本第一次跑的時候就是），所以預設只換設定，用 -RestartNow 才
# 動手。不重啟的話，下一次重啟或登入時自然套用。

[CmdletBinding()]
param(
    [string]$TaskName = 'Example-CI-Runner',
    [string]$RunnerDir = 'C:\actions-runner',
    [switch]$RestartNow
)

Set-StrictMode -Version Latest

# New-QuietScheduledTaskAction 住在這裡。
. (Join-Path $PSScriptRoot '_runner_common.ps1')
$ErrorActionPreference = 'Stop'

function Say([string]$Message) { Write-Output "   $Message" }

$source = @(
    (Join-Path $PSScriptRoot 'ci_runner_banner.cmd'),
    (Join-Path $PSScriptRoot 'ci_runner_banner.txt')
)

Write-Output "== 1/4 檢查來源與目的地"
foreach ($file in $source) {
    if (-not (Test-Path $file)) { Write-Error "找不到 $file" }
}
if (-not (Test-Path $RunnerDir)) { Write-Error "找不到 runner 目錄 $RunnerDir" }
if (-not (Test-Path (Join-Path $RunnerDir 'run.cmd'))) {
    Write-Error "$RunnerDir 底下沒有 run.cmd —— 這看起來不是 runner 的目錄"
}
Say "來源兩個檔都在，$RunnerDir 也是 runner 的目錄"

Write-Output "== 2/4 複製過去"
foreach ($file in $source) {
    Copy-Item -Path $file -Destination $RunnerDir -Force
    Say (Split-Path -Leaf $file)
}

Write-Output "== 3/4 換掉排程工作的動作"
$task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
if (-not $task) { Write-Error "找不到排程工作 $TaskName" }

$wrapper = Join-Path $RunnerDir 'ci_runner_banner.cmd'
# 橫幅本來是**故意讓人看的** —— runner 自己的主控台，看得出它跑到哪一步、有沒有接到工作。
#
# 2026-09-02 改成不顯示，因為使用者說「全螢幕時會被打斷」，而 localci 現在有自己的狀態視窗（`localci-window.cmd`）把同樣的事
# 講得更清楚。橫幅還在，只是沒人看得到 —— 要看的話看
# `C:ctions-runner\_diag\` 底下的日誌。
#
# 想把視窗要回來：把下面改回 New-ScheduledTaskAction，並把這支腳本
# 加進 core/test_scheduled_tasks_are_quiet.py 的 DELIBERATELY_VISIBLE。
$action = New-QuietScheduledTaskAction `
    -Execute 'cmd.exe' `
    -Argument "/c `"$wrapper`"" `
    -WorkingDirectory $RunnerDir

Set-ScheduledTask -TaskName $TaskName -Action $action | Out-Null

# 驗它真的換過去了 —— Set-ScheduledTask 不會因為參數沒生效而報錯。
$after = (Get-ScheduledTask -TaskName $TaskName).Actions[0]
if ($after.Arguments -notlike "*ci_runner_banner.cmd*") {
    Write-Error "動作沒有換成功，現在是：$($after.Execute) $($after.Arguments)"
}
Say "現在是 $($after.Execute) $($after.Arguments)"

Write-Output "== 4/4 生效"
if ($RestartNow) {
    $restart = Join-Path $PSScriptRoot 'restart_runner.ps1'
    Say "重啟中（會砍掉當下正在跑的建置）"
    & powershell -ExecutionPolicy Bypass -File $restart -TaskName $TaskName
    if ($LASTEXITCODE -ne 0) { Write-Error "重啟失敗（$LASTEXITCODE）" }
} else {
    Say "沒有重啟 —— 下一次重啟或登入時套用。"
    Say "CI 閒下來之後想立刻看到，就加 -RestartNow 再跑一次。"
}

Write-Output ""
Write-Output "完成。"
