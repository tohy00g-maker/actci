# 一圈一圈地看：有沒有還沒驗過的 PR commit，有就跑，跑完回報。
#
# ## 為什麼是輪詢，不是 webhook
#
# webhook 要一個 GitHub 連得進來的位址。這台機器在家用網路後面，為了 CI 去開一條
# 進來的路，代價遠大於「每分鐘問一次」。輪詢也好除錯：沒有狀態、沒有重送。
#
# ## 一圈只做一件事
#
# 每一圈最多跑一個 commit，跑完就回到頂端重新看一次。跑測試要幾分鐘，這段時間
# 可能又推了新的 commit、PR 可能被關掉。跑完重新看一次，自然會做當下最該做的事。
#
# ## 心跳在迴圈頂端，不在底端
#
# 頂端代表「我醒著而且開始看了」。底端的話，一個卡在跑測試中間的 watcher 會停止
# 心跳 —— 而那正是它最該報告的時刻。「還在」跟「還在動」是兩件事。
#
# ## 為什麼跑之前要 fetch refs/pull/N/head
#
# gh 給的是 PR head 的 sha，但本地 repo 未必有那個 commit —— 別人的分支、fork 來的
# PR 都不會在本地。git archive 找不到 commit 就是 errored，而那會被推成 error
# 狀態，看起來像 CI 壞了。所以先把那個 ref 拉下來；拉不下來才是真的 errored。

$script:WatcherConfigName = 'watcher.json'

function Get-WatcherConfigPath {
    param([Parameter(Mandatory)]$Store)
    return Join-Path $Store.Root $script:WatcherConfigName
}

function Save-WatcherConfig {
    # 安裝器寫、視窗讀：監看的是哪個 repo、哪個 slug、多久一圈。
    param([Parameter(Mandatory)]$Store, [Parameter(Mandatory)][hashtable]$Config)
    Initialize-Store $Store | Out-Null
    $ordered = [ordered]@{
        Repo            = [string]$Config.Repo
        Slug            = [string]$Config.Slug
        Event           = $(if ($Config.ContainsKey('Event') -and $Config.Event) { [string]$Config.Event } else { 'pull_request' })
        Job             = $(if ($Config.ContainsKey('Job')) { [string]$Config.Job } else { '' })
        IntervalSeconds = $(if ($Config.ContainsKey('IntervalSeconds')) { [int]$Config.IntervalSeconds } else { 60 })
        Distro          = $(if ($Config.ContainsKey('Distro')) { [string]$Config.Distro } else { '' })
        TaskName        = $(if ($Config.ContainsKey('TaskName') -and $Config.TaskName) { [string]$Config.TaskName } else { 'actci-watcher' })
        InstalledAt     = (Get-IsoNow)
    }
    Write-AtomicText -Path (Get-WatcherConfigPath $Store) -Text ($ordered | ConvertTo-Json)
}

function Get-WatcherConfig {
    param([Parameter(Mandatory)]$Store)
    $path = Get-WatcherConfigPath $Store
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    try {
        return ConvertFrom-Json -InputObject ([System.IO.File]::ReadAllText($path, $script:Utf8NoBom))
    } catch {
        return $null
    }
}

$script:RetryErroredAfterMinutes = 30
$script:HeartbeatStaleSeconds = 300      # 閒置這麼久沒跳，watcher 大概停了
$script:RunStuckSeconds = 3600           # 同一個 sha 跑這麼久，大概卡住了

function New-RunningNote {
    # 心跳要同時回答兩個問題，而它們的時間基準相反：
    #   「還在動嗎」  -> 看最後一次心跳多久前（脈搏每 30 秒刷新，所以永遠很新）
    #   「跑多久了」  -> 看這一輪什麼時候開始（**不能**被刷新）
    # 2026-09-06 加了脈搏之後只留了前者，於是畫面上的「已經 N 分鐘」一直被歸零。
    # 開始時間寫在備註裡，脈搏只換前面的時間戳，不動它。
    param([Parameter(Mandatory)][string]$Sha, [DateTime]$StartedAt = [DateTime]::UtcNow)
    return "running $Sha since " + $StartedAt.ToUniversalTime().ToString('o')
}

function Get-WatcherHealth {
    # watcher 現在是活的嗎？回 @{ State; Alive; SecondsAgo; RunningSha; Detail }。
    #
    # 這一支存在的理由：`gate <sha>` 沒有判定時，「還沒輪到它」跟「CI 已經死了」是兩件事，
    # 而它們對呼叫端的意思完全相反 —— 一個該等，一個等下去沒有意義。2026-09-06 之前
    # 兩者都回離開碼 2，於是一個 agent 面對死掉的 CI 只會一直等下去。這正是 localci 那次
    # 「runner 停擺 90 分鐘而每個人都以為它在排隊」的形狀，只是換到我們自己身上。
    #
    # State：never（從來沒跳過）、running（正在跑某個 sha）、idle（在輪詢）、
    #        stale（閒置太久）、stuck（同一個 sha 跑太久）。
    param([Parameter(Mandatory)]$Store, [DateTime]$Now = [DateTime]::UtcNow)

    $age = Get-HeartbeatAge -Store $Store -Now $Now
    if (-not $age) {
        return [pscustomobject]@{ State = 'never'; Alive = $false; SecondsAgo = $null; RunningSha = ''
                                  RunningSeconds = $null; Detail = 'watcher 從來沒有跳過心跳 —— 沒被安裝或沒被啟動過' }
    }
    $s = [Math]::Round($age.Seconds)
    if ($age.Note -match '^running\s+(\S+)(?:\s+since\s+(\S+))?') {
        $sha = $Matches[1]
        # 跑多久了看開始時間；沒有 since 的是舊格式的心跳，退回用心跳年齡（會低估，但不會誤報）。
        $running = $s
        if ($Matches[2]) {
            try {
                $startedAt = [DateTime]::Parse($Matches[2], [Globalization.CultureInfo]::InvariantCulture,
                                               [Globalization.DateTimeStyles]::RoundtripKind).ToUniversalTime()
                $running = [Math]::Round([Math]::Max(0, ($Now.ToUniversalTime() - $startedAt).TotalSeconds))
            } catch {}
        }
        $mins = [int]($running / 60)
        if ($running -gt $script:RunStuckSeconds) {
            return [pscustomobject]@{ State = 'stuck'; Alive = $false; SecondsAgo = $s; RunningSha = $sha
                                      RunningSeconds = $running; Detail = "watcher 卡在 $sha 已經 $mins 分鐘，超過一小時" }
        }
        $elapsed = if ($running -lt 90) { "$running 秒" } else { "$mins 分鐘" }
        return [pscustomobject]@{ State = 'running'; Alive = $true; SecondsAgo = $s; RunningSha = $sha
                                  RunningSeconds = $running; Detail = "正在跑 $sha（$elapsed）" }
    }
    if ($age.Seconds -gt $script:HeartbeatStaleSeconds) {
        return [pscustomobject]@{ State = 'stale'; Alive = $false; SecondsAgo = $s; RunningSha = ''
                                  RunningSeconds = $null; Detail = "心跳 $s 秒沒更新，watcher 可能停了" }
    }
    return [pscustomobject]@{ State = 'idle'; Alive = $true; SecondsAgo = $s; RunningSha = ''
                              RunningSeconds = $null; Detail = "在輪詢（$s 秒前）" }
}

function Test-VerdictStored {
    # 「已判定」= 有判定檔，而且不是一份放太久的 errored。
    #
    # errored 是 CI 自己的問題（fetch 沒認證、Docker 沒開）。修好之後那個 PR 應該要再跑一次，
    # 不能因為一份錯誤的判定就永遠跳過它。但也不能每分鐘重試：基礎設施壞著的時候那會每分鐘
    # 往 PR 推一次 error。折衷：errored 超過 RetryErroredAfterMinutes 就當成沒判定過。
    param($Store, [string]$Sha, [DateTime]$Now = [DateTime]::UtcNow)
    try {
        $v = Get-StoredVerdict -Store $Store -Sha $Sha
        if ($null -eq $v) { return $false }
        if ($v.Outcome -ne 'errored') { return $true }
        $stamp = if ($v.FinishedAt) { $v.FinishedAt } else { $v.StartedAt }
        try {
            $at = [DateTime]::Parse($stamp, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind).ToUniversalTime()
        } catch { return $false }
        return (($Now.ToUniversalTime() - $at).TotalMinutes -lt $script:RetryErroredAfterMinutes)
    } catch { return $false }
}

function Update-PullRequestRef {
    # 把 PR 的 head 拉進本地 repo。回傳 @{ Ok; Detail }。
    param(
        [Parameter(Mandatory)][string]$RepoPath,
        [Parameter(Mandatory)][int]$Number,
        [string]$Distro = ''
    )
    $ref = "+refs/pull/$Number/head:refs/actci/pr/$Number"
    # GIT_TERMINAL_PROMPT=0：沒有認證就立刻失敗，不要對著一個沒人看的 tty 等密碼直到逾時。
    # 2026-09-06 實測：私有 repo、WSL 沒設 credential helper，fetch 卡了五分鐘。
    $cmd = 'GIT_TERMINAL_PROMPT=0 git -C ' + (ConvertTo-BashArg $RepoPath) + ' fetch --quiet origin ' + (ConvertTo-BashArg $ref) + ' 2>&1'
    $r = Invoke-Wsl -BashCommand $cmd -TimeoutMs 300000 -Distro $Distro
    if ($r.ExitCode -eq 0) { return [pscustomobject]@{ Ok = $true; Detail = '' } }
    $detail = (($r.Output + ' ' + $r.Error) -replace '\s+', ' ').Trim()
    if ($detail.Length -gt 300) { $detail = $detail.Substring($detail.Length - 300) }
    return [pscustomobject]@{ Ok = $false; Detail = "git fetch PR #$Number 失敗：$detail" }
}

function Start-HeartbeatPulse {
    # 跑測試那十幾分鐘裡，主執行緒卡在 act 上，心跳不會更新 —— 於是一個健康的 watcher 在畫面上
    # 看起來像停了。開一個獨立 runspace 定期寫心跳：它跳，就證明 watcher 這個**行程**還活著，
    # 而不只是「它啟動了某個東西」。這正是 localci 那條「還在跟還在動是兩件事」的另一面。
    param(
        [Parameter(Mandatory)]$Store,
        [Parameter(Mandatory)][string]$Note,
        [int]$IntervalSeconds = 30
    )
    try {
        $rs = [runspacefactory]::CreateRunspace()
        $rs.Open()
        $ps = [PowerShell]::Create()
        $ps.Runspace = $rs
        # 一句一句加，不要串成一條再 [void] + Out-Null —— 那樣會拿到「參數型別不能是 Void」。
        $null = $ps.AddScript({
            param($Path, $Note, $Interval)
            while ($true) {
                try {
                    $tmp = "$Path.tmp"
                    $text = [DateTime]::UtcNow.ToString('o') + "`n" + $Note + "`n"
                    [System.IO.File]::WriteAllText($tmp, $text, (New-Object System.Text.UTF8Encoding $false))
                    [System.IO.File]::Copy($tmp, $Path, $true)
                    [System.IO.File]::Delete($tmp)
                } catch {}
                Start-Sleep -Seconds $Interval
            }
        })
        $null = $ps.AddArgument($Store.Heartbeat)
        $null = $ps.AddArgument($Note)
        $null = $ps.AddArgument($IntervalSeconds)
        $handle = $ps.BeginInvoke()
        return [pscustomobject]@{ PowerShell = $ps; Runspace = $rs; Handle = $handle }
    } catch {
        # 心跳是監測，不是工作本身。開不起來就算了，不能讓它擋住跑測試。
        return $null
    }
}

function Stop-HeartbeatPulse {
    param($Pulse)
    if (-not $Pulse) { return }
    try { $Pulse.PowerShell.Stop() } catch {}
    try { $Pulse.PowerShell.Dispose() } catch {}
    try { $Pulse.Runspace.Close(); $Pulse.Runspace.Dispose() } catch {}
}

function Invoke-WatcherRun {
    param(
        [Parameter(Mandatory)]$Store,
        [Parameter(Mandatory)][string]$Slug,
        [Parameter(Mandatory)][string]$RepoPath,
        [Parameter(Mandatory)]$Target,
        [string]$Event = 'pull_request',
        [string]$Job = '',
        [string]$Distro = '',
        [int]$TimeoutMs = 3600000,
        [scriptblock]$Log = { param($m) Write-Host $m }
    )
    $sha = [string]$Target.Sha
    $short = $sha.Substring(0, [Math]::Min(8, $sha.Length))
    $title = [string]$Target.Title
    if ($title.Length -gt 40) { $title = $title.Substring(0, 40) }
    & $Log ("#{0} {1} {2}" -f $Target.Number, $short, $title)

    # 先拿鎖再宣告開始。拿不到就整圈跳過：不推 pending、不存判定，下一圈再來。
    # 「有人在跑」不是這個 commit 的判定，把它寫成任何一種紅字都是謊報。
    $lock = Enter-ActLock -Store $Store
    if (-not $lock) {
        & $Log "   另一個 act 正在跑，這一圈跳過 #$($Target.Number)"
        return @{ Action = 'busy'; Number = [int]$Target.Number; Sha = $sha }
    }
    try {

    Send-PendingStatus -Slug $Slug -Sha $sha -Note "actci 開始跑 #$($Target.Number)" | Out-Null
    # 開始時間只決定一次，心跳與脈搏共用同一個，畫面上的「已經 N 分鐘」才會往上累計。
    $runNote = New-RunningNote -Sha $short -StartedAt ([DateTime]::UtcNow)
    Write-Heartbeat -Store $Store -Note $runNote

    $fetch = Update-PullRequestRef -RepoPath $RepoPath -Number ([int]$Target.Number) -Distro $Distro
    if ($fetch.Ok) {
        $pulse = Start-HeartbeatPulse -Store $Store -Note $runNote
        try {
            $verdict = Invoke-ActRun -RepoPath $RepoPath -Sha $sha -Event $Event -Job $Job -LogDir $Store.Logs -TimeoutMs $TimeoutMs -Distro $Distro
        } finally {
            Stop-HeartbeatPulse $pulse
        }
    } else {
        $verdict = New-Verdict -Sha $sha -Repo $RepoPath -Event $Event -Outcome 'errored' -Note $fetch.Detail
        $verdict.FinishedAt = Get-IsoNow
    }

    Save-Verdict -Store $Store -Verdict $verdict | Out-Null
    $posted = Send-CommitStatus -Slug $Slug -Verdict $verdict
    & $Log ('   ' + (Get-VerdictHeadline $verdict))
    if (-not $posted.Posted) { & $Log "   !! 回報失敗：$($posted.Detail)" }

    return @{
        Action   = 'ran'
        Sha      = $sha
        Number   = [int]$Target.Number
        Outcome  = $verdict.Outcome
        TestsRun = $verdict.TestsRun
        Posted   = [bool]$posted.Posted
    }

    } finally { Exit-ActLock $lock }
}

function Invoke-WatcherTick {
    # 看一次。回傳這一圈做了什麼（給測試與日誌用）。
    param(
        [Parameter(Mandatory)]$Store,
        [Parameter(Mandatory)][string]$Slug,
        [Parameter(Mandatory)][string]$RepoPath,
        [string]$Event = 'pull_request',
        [string]$Job = '',                 # 空字串 = 該事件下的所有 job
        [string]$Distro = '',
        [int]$TimeoutMs = 3600000,
        [scriptblock]$Log = { param($m) Write-Host $m }
    )
    Write-Heartbeat -Store $Store -Note 'looking'

    $list = Get-OpenPullRequests -Slug $Slug
    if ($list.Problem) {
        & $Log "問不到 PR 清單：$($list.Problem)"
        return @{ Action = 'no-pull-requests'; Reason = $list.Problem }
    }

    $pulls = @($list.Pulls)
    $pending = @($pulls | Where-Object { -not (Test-VerdictStored $Store $_.Sha) })
    if ($pending.Count -gt 0) {
        # 講清楚為什麼要跑：是沒有判定檔，還是舊的 errored 要重試。2026-09-06 第一次安裝時
        # 一個剛存好判定的 PR 被排程啟動的 watcher 又跑了一次，日誌裡看不出原因。
        foreach ($p in $pending) {
            $path = Join-Path $Store.Verdicts (([string]$p.Sha).ToLower() + '.json')
            $why = if (Test-Path -LiteralPath $path) { "判定檔在（$path）但不算已判定，重試" } else { "沒有判定檔 $path" }
            & $Log "   待跑 #$($p.Number)：$why"
        }
    }
    if ($pending.Count -eq 0) {
        # 「沒事做」也要留一行。空日誌有兩種解釋：一切正常，或它根本沒在轉。
        & $Log "沒事做（開著的 PR：$($pulls.Count)）"
        return @{ Action = 'nothing-to-do'; Open = $pulls.Count }
    }

    # 最舊的 PR 先做。新的一直進來的話，先到的不該永遠排在後面。
    $target = $pending | Sort-Object -Property Number | Select-Object -First 1
    return Invoke-WatcherRun -Store $Store -Slug $Slug -RepoPath $RepoPath -Target $target -Event $Event -Job $Job -Distro $Distro -TimeoutMs $TimeoutMs -Log $Log
}

function Start-WatcherLoop {
    # 一直轉。-Once 只轉一圈（安裝器的試跑與測試用）。
    # 迴圈本身不能因為任何一個 PR 出事就停：一個壞掉的 PR 讓整套 CI 停擺，是把
    # 小問題變成大問題。
    param(
        [Parameter(Mandatory)]$Store,
        [Parameter(Mandatory)][string]$Slug,
        [Parameter(Mandatory)][string]$RepoPath,
        [string]$Event = 'pull_request',
        [string]$Job = '',
        [string]$Distro = '',
        [int]$TimeoutMs = 3600000,
        [int]$IntervalSeconds = 60,
        [switch]$Once,
        [int]$MaxTicks = 0,
        [scriptblock]$Sleeper = { param($s) Start-Sleep -Seconds $s },
        [scriptblock]$Log = { param($m) Write-Host $m }
    )
    $ticks = 0
    while ($true) {
        try {
            # 只留 hashtable：呼叫端給的 -Log 若用 Write-Output，字串會混進來，這裡濾掉。
            $result = @(Invoke-WatcherTick -Store $Store -Slug $Slug -RepoPath $RepoPath -Event $Event -Job $Job -Distro $Distro -TimeoutMs $TimeoutMs -Log $Log) |
                Where-Object { $_ -is [hashtable] } | Select-Object -Last 1
            if ($null -eq $result) { $result = @{ Action = 'crashed'; Error = '這一圈沒有回傳結果' } }
        } catch {
            & $Log "這一圈掛了：$($_.Exception.GetType().Name): $($_.Exception.Message)"
            $result = @{ Action = 'crashed'; Error = $_.Exception.Message }
        }
        $ticks++
        if ($Once) { return $result }
        if ($MaxTicks -gt 0 -and $ticks -ge $MaxTicks) { return $result }
        & $Sleeper $IntervalSeconds
    }
}
