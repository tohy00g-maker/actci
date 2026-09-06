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

function Invoke-WatcherRun {
    param(
        [Parameter(Mandatory)]$Store,
        [Parameter(Mandatory)][string]$Slug,
        [Parameter(Mandatory)][string]$RepoPath,
        [Parameter(Mandatory)]$Target,
        [string]$Event = 'pull_request',
        [string]$Distro = '',
        [int]$TimeoutMs = 3600000,
        [scriptblock]$Log = { param($m) Write-Host $m }
    )
    $sha = [string]$Target.Sha
    $short = $sha.Substring(0, [Math]::Min(8, $sha.Length))
    $title = [string]$Target.Title
    if ($title.Length -gt 40) { $title = $title.Substring(0, 40) }
    & $Log ("#{0} {1} {2}" -f $Target.Number, $short, $title)

    Send-PendingStatus -Slug $Slug -Sha $sha -Note "actci 開始跑 #$($Target.Number)" | Out-Null
    Write-Heartbeat -Store $Store -Note "running $short"

    $fetch = Update-PullRequestRef -RepoPath $RepoPath -Number ([int]$Target.Number) -Distro $Distro
    if ($fetch.Ok) {
        $verdict = Invoke-ActRun -RepoPath $RepoPath -Sha $sha -Event $Event -LogDir $Store.Logs -TimeoutMs $TimeoutMs -Distro $Distro
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
}

function Invoke-WatcherTick {
    # 看一次。回傳這一圈做了什麼（給測試與日誌用）。
    param(
        [Parameter(Mandatory)]$Store,
        [Parameter(Mandatory)][string]$Slug,
        [Parameter(Mandatory)][string]$RepoPath,
        [string]$Event = 'pull_request',
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
    if ($pending.Count -eq 0) {
        # 「沒事做」也要留一行。空日誌有兩種解釋：一切正常，或它根本沒在轉。
        & $Log "沒事做（開著的 PR：$($pulls.Count)）"
        return @{ Action = 'nothing-to-do'; Open = $pulls.Count }
    }

    # 最舊的 PR 先做。新的一直進來的話，先到的不該永遠排在後面。
    $target = $pending | Sort-Object -Property Number | Select-Object -First 1
    return Invoke-WatcherRun -Store $Store -Slug $Slug -RepoPath $RepoPath -Target $target -Event $Event -Distro $Distro -TimeoutMs $TimeoutMs -Log $Log
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
            $result = Invoke-WatcherTick -Store $Store -Slug $Slug -RepoPath $RepoPath -Event $Event -Distro $Distro -TimeoutMs $TimeoutMs -Log $Log
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
