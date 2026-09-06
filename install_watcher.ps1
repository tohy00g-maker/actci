# 把 watcher 裝成排程工作。
#
# ## 為什麼這支腳本要這麼囉嗦
#
# localci 2026-08-31 裝看門狗時，第一版通過了所有檢查（工作已註冊、手動跑一次
# 結果 0），而它**永遠不會自己醒來** —— NextRunTime 是空的。只掛了登入觸發，而登入
# 觸發的「重複」要等觸發器本身觸發過才開始計時；註冊時使用者早就登入了。
#
# 「它跑得動」跟「它會自己跑」是兩件事。第 4 步守的就是第二件。
#
# ## 用法
#
#     powershell -ExecutionPolicy Bypass -File install_watcher.ps1 `
#         -Repo C:\Users\me\src\myrepo -Slug owner/repo
#
# 再跑一次是安全的：已經存在就整份覆蓋，不會長出第二個。

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Repo,
    [Parameter(Mandatory)][string]$Slug,
    [string]$Event = 'pull_request',
    [string]$Job = '',              # 只跑這個 job id。一個事件觸發多個 workflow 時（例如兩個都收 workflow_dispatch）務必指定，否則全部都跑
    [int]$IntervalSeconds = 60,
    [string]$Distro = '',
    [string]$TaskName = 'actci-watcher',
    [int]$RestartMinutes = 10
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Say([string]$Message) { Write-Output "   $Message" }

$root = $PSScriptRoot
$watcher = Join-Path $root 'watcher.ps1'
Import-Module (Join-Path $root 'src\actci.psm1') -Force
if ($Distro) { Set-WslDistro $Distro } else { $Distro = Get-WslDistro }
$repoLinux = ConvertTo-WslPath $Repo

Write-Output '== 1/5 確認前提'
# 外部相依缺一個這支就完全沒用。註冊之前查清楚，不要讓它每分鐘安靜失敗一次
# —— 那正是這套東西要解決的那種失敗。
$distros = @(Get-WslDistros)
if ($distros -notcontains $Distro) { Write-Error "WSL 裡沒有發行版 $Distro（有：$($distros -join ', ')）" }
Say "WSL 發行版 $Distro"

$pre = Test-ActPreflight
if (-not $pre.Ok) { Write-Error "act / docker 還沒就緒：$($pre.Detail)" }
Say "act 與 docker 可以（$($pre.Detail)）"

$auth = Test-GhAuth
if (-not $auth.Ok) { Write-Error "gh 沒有認證：$($auth.Detail)。先跑 gh auth login。" }
Say "gh 已認證（$($auth.Detail)）"

$isRepo = Invoke-Wsl -BashCommand ('git -C ' + (ConvertTo-BashArg $repoLinux) + ' rev-parse --git-dir >/dev/null 2>&1 && echo yes || echo no') -TimeoutMs 30000
if ($isRepo.Output -notlike '*yes*') { Write-Error "$repoLinux 在 WSL 裡不是一個 git repo。" }
Say "被測的專案 $repoLinux"

# watcher 每一圈都要 git fetch PR 的 commit。私有 repo 而 WSL 的 git 沒有認證的話，這裡就會失敗，
# 而不是在試跑時對著沒人看的密碼提示卡五分鐘（2026-09-06 實測）。
$reach = Invoke-Wsl -BashCommand ('cd ' + (ConvertTo-BashArg $repoLinux) + ' && GIT_TERMINAL_PROMPT=0 git ls-remote --exit-code --heads origin >/dev/null 2>&1 && echo reachable || echo unreachable') -TimeoutMs 90000
if ($reach.Output -notlike '*reachable*' -or $reach.Output -like '*unreachable*') {
    Write-Error ("WSL 裡的 git 連不上 origin（多半是私有 repo 沒有認證）。讓 WSL 的 git 借用 Windows 的 Git Credential Manager：`n" +
        '  wsl -d ' + (Get-WslDistro) + ' -- git config --global credential.helper "/mnt/c/Program\ Files/Git/mingw64/bin/git-credential-manager.exe"' + "`n然後再跑一次安裝器。")
}
Say 'origin 連得上（fetch PR 用）'
if ($repoLinux -like '/mnt/*') { Say '（提醒：repo 在 Windows 磁碟上，Docker 掛載會慢。放到 Linux 檔案系統會快很多。）' }

Write-Output '== 2/5 先跑一圈'
# 註冊一個每分鐘失敗一次的排程，比沒有排程更糟：它會安靜地什麼都不做，
# 而儀表板上看起來就像「還沒有 PR 要跑」。
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $watcher -Repo $Repo -Slug $Slug -Event $Event -Job $Job -IntervalSeconds $IntervalSeconds -Distro $Distro -Once
$trial = $LASTEXITCODE
if ($trial -ne 0) { Write-Error "watcher 現在就跑不起來（離開碼 $trial，原因見上方訊息）。先處理它。" }
Say '跑得起來'

Write-Output '== 3/5 註冊'
# conhost --headless：不彈主控台視窗。watcher 是長駐的，它的視窗會一直占著；
# 不用 -WindowStyle Hidden（起來才藏，會閃）也不用 LogonType S4U（改它要提權，
# 權限不夠的帳號會變成工作跑不起來）。
$argument = ('--headless powershell.exe -NoProfile -ExecutionPolicy Bypass -File "{0}" -Repo "{1}" -Slug "{2}" -Event "{3}" -Job "{6}" -IntervalSeconds {4} -Distro "{5}"' -f
    $watcher, $Repo, $Slug, $Event, $IntervalSeconds, $Distro, $Job)
$action = New-ScheduledTaskAction -Execute 'conhost.exe' -Argument $argument -WorkingDirectory $root

# 兩個觸發器，缺一不可：
#   一次性（現在起算）+ 重複  ->  裝完立刻開始，不必等下一次登入
#   登入觸發          + 重複  ->  重開機登入後接手
# 無限期的寫法是 Duration 留空。watcher 自己是無窮迴圈，所以「每 N 分鐘」實際上
# 是重啟保險：排程器看到上一個實例還在就忽略新的，它一旦死了最多 N 分鐘就被叫回來。
$interval = New-TimeSpan -Minutes $RestartMinutes
$nowTrigger = New-ScheduledTaskTrigger -Once -At (Get-Date) -RepetitionInterval $interval
$nowTrigger.Repetition.Duration = $null

$currentUser = "$env:USERDOMAIN\$env:USERNAME"
$logonTrigger = New-ScheduledTaskTrigger -AtLogOn -User $currentUser
$logonRepetition = (New-ScheduledTaskTrigger -Once -At (Get-Date) -RepetitionInterval $interval).Repetition
$logonRepetition.Duration = $null
$logonTrigger.Repetition = $logonRepetition

# Interactive：WSL 與 gh 的認證都是這個使用者的，換身分就都沒了。
$principal = New-ScheduledTaskPrincipal -UserId $currentUser -LogonType Interactive -RunLevel Limited

$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -StartWhenAvailable `
    -ExecutionTimeLimit ([TimeSpan]::Zero) `
    -MultipleInstances IgnoreNew

function Get-OldWatchers {
    @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -and $_.CommandLine -like '*watcher.ps1*' -and $_.CommandLine -like "*$Slug*" })
}

$existing = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
if ($existing) {
    Say '已經有一個，整份覆蓋'
    # 先把正在跑的那個停掉再重新註冊。Unregister 不會殺已在跑的行程，而 IgnoreNew
    # 會讓新的起不來 —— 於是重裝之後舊的程式碼繼續跑，而你以為修好了。
    Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
    $deadline = (Get-Date).AddSeconds(20)
    while ((Get-Date) -lt $deadline -and (Get-OldWatchers).Count) { Start-Sleep -Seconds 1 }
    $alive = Get-OldWatchers
    if ($alive.Count) {
        Say "   $($alive.Count) 個舊行程還在，動手停止"
        foreach ($one in $alive) { Stop-Process -Id $one.ProcessId -Force -ErrorAction SilentlyContinue }
        Start-Sleep -Seconds 2
    }
    if ((Get-OldWatchers).Count) {
        Write-Error '還有舊的 watcher 停不掉。不要在這個狀態上註冊新的 —— 新的會被 IgnoreNew 擋住，而你會以為裝好了。'
    }
    Say '   舊的已經停乾淨'
}
Register-ScheduledTask -TaskName $TaskName -Action $action `
    -Trigger @($nowTrigger, $logonTrigger) -Principal $principal -Settings $settings `
    -Description "actci：看著 $Slug 的 PR，在本機用 act 跑並把結果推回 GitHub。" | Out-Null
Say "已註冊 $TaskName，身分 $currentUser"

Write-Output '== 4/5 驗它會自己醒來'
Start-ScheduledTask -TaskName $TaskName
Start-Sleep -Seconds 8
$info = Get-ScheduledTask -TaskName $TaskName | Get-ScheduledTaskInfo
Say "上次執行 $($info.LastRunTime)"
if (-not $info.NextRunTime) {
    Write-Error '工作註冊了，但沒有排定的下一次（NextRunTime 是空的）—— 這個 watcher 不會自己回來。檢查觸發器。'
}
Say "下次自動執行 $($info.NextRunTime)"

Write-Output '== 5/5 記下設定給視窗用'
$store = New-Store
Save-WatcherConfig -Store $store -Config @{
    Repo = $repoLinux; Slug = $Slug; Event = $Event; Job = $Job
    IntervalSeconds = $IntervalSeconds; Distro = $Distro; TaskName = $TaskName
}
Say (Get-WatcherConfigPath $store)
Say "日誌：$(Join-Path $store.Root 'watcher.log')"
Write-Output '完成。'
