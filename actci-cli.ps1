# actci 指令列：給機器（AI agent、腳本、合併門檻）用的入口。視窗是給人看的，這支才是主要介面。
#
#     powershell -NoProfile -ExecutionPolicy Bypass -File actci-cli.ps1 <command> [args] [--json]
#
# 指令與離開碼：
#   gate <sha>                    這個 commit 有一份值得相信的通過嗎？
#                                 0 = 有，可以合併
#                                 1 = 有判定但不可信（0 支測試、測試紅了、CI 自己出錯）—— 不要合併
#                                 2 = 還沒判定，而 watcher 活著 —— 等它，一輪約 8 到 11 分鐘
#                                 3 = 還沒判定，而 watcher 沒在動 —— 等下去沒有意義，去修 CI
#   verdict <sha>                 印出判定（--json 給完整 JSON）。沒有 → 2
#   status [--limit N]            watcher 健康狀態 + 最近判定。永遠 0，因為「現在的狀態」不是成功或失敗
#   run <repo> [--sha S] [--event E] [--job J] [--save] [--push owner/repo] [--context C]
#                                 用 act 跑一次，印判定。0 = 值得相信的通過；1 = 其他。--save 存進 store，
#                                 --push 推 commit status（context 預設 actci/manual）
#   preflight                     WSL / act / docker / gh 就緒嗎？ 0 = 全部就緒；1 = 有缺
#   prs <owner/repo>              開著的 PR 與各自的判定狀態。0 = 問到了；1 = 問不到
#   help
#
# 共用選項：--json（機器可讀輸出）、--state <dir>（store 位置，預設 ~\.actci）、--distro <name>
#
# ## 為什麼 gate 問的是 trustworthy 不是 passed
#
# 一個 passed 而 0 支測試的判定看起來跟真的通過一模一樣，而它什麼都沒驗。合併門檻要問的是
# 「驗過而且過了」。localci 的 README 記錄了三次把「看起來成功」讀成「成功」的事故，
# 這個離開碼存在的理由就是讓那個判斷不必經過任何人（或任何模型）的閱讀理解。

[CmdletBinding()]
param(
    [Parameter(Position = 0)][string]$Command = 'help',
    [Parameter(Position = 1, ValueFromRemainingArguments = $true)][string[]]$Rest = @()
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}
Import-Module (Join-Path $PSScriptRoot 'src\actci.psm1') -Force

# --- 極簡參數解析：--flag 或 --key value；其餘是位置參數 --------------------------------
$opts = @{}; $positional = New-Object System.Collections.Generic.List[string]
$i = 0
$valueFlags = @('sha', 'event', 'job', 'push', 'context', 'state', 'distro', 'limit', 'timeout-minutes')
while ($i -lt $Rest.Count) {
    $a = $Rest[$i]
    if ($a -like '--*') {
        $key = $a.Substring(2)
        if ($valueFlags -contains $key -and ($i + 1) -lt $Rest.Count) { $opts[$key] = $Rest[$i + 1]; $i += 2; continue }
        $opts[$key] = $true; $i++; continue
    }
    $positional.Add($a); $i++
}
$json = $opts.ContainsKey('json')
if ($opts.ContainsKey('distro')) { Set-WslDistro $opts['distro'] }
$store = New-Store -Path $(if ($opts.ContainsKey('state')) { $opts['state'] } else { '' })

function Write-Usage([string]$msg) {
    # 用法錯誤走 stderr 然後用離開碼講話。不用 Write-Error：在 ErrorActionPreference=Stop 之下它會先丟例外，
    # 離開碼就變成 1 而不是我們要的那個數字。
    [Console]::Error.WriteLine("actci: $msg")
}
function Out-Result($obj, [string]$human) {
    if ($json) { $obj | ConvertTo-Json -Depth 6 } else { $human }
}
function Get-VerdictSummary($v) {
    [ordered]@{
        sha = $v.Sha; outcome = $v.Outcome; testsRun = $v.TestsRun; testsSource = @($v.TestsSource)
        trustworthy = (Test-VerdictTrustworthy $v); state = (Get-StatusState $v); headline = (Get-VerdictHeadline $v)
        event = $v.Event; job = $v.Job; seconds = [Math]::Round($v.Seconds, 1); finishedAt = $v.FinishedAt
        # testsRun 是 ranJobs 裡各 job 的加總；requestedJob 是傳給 act -j 的，空字串代表該事件下全部
        testsRunIsSumOfJobs = $true
        requestedJob = $v.Job
        ranJobs = @($v.Jobs | ForEach-Object { [ordered]@{ workflow = $_.Workflow; job = $_.Job; status = $_.Status; testsRun = $_.TestsRun } })
        note = $v.Note; logPath = $v.LogPath
    }
}

switch ($Command.ToLower()) {

    'gate' {
        if ($positional.Count -lt 1) { Write-Usage 'gate 需要 <sha>'; exit 2 }
        $sha = $positional[0]
        $v = Get-StoredVerdict -Store $store -Sha $sha -WarningAction SilentlyContinue
        if ($null -eq $v) {
            # 沒有判定分兩種，對呼叫端的意思相反：watcher 活著就是「還沒輪到」，該等；
            # watcher 沒在動就是「等下去沒有意義」，該去修 CI。合成一個離開碼會讓 agent 永遠等下去。
            $health = Get-WatcherHealth -Store $store
            $short = $sha.Substring(0, [Math]::Min(12, $sha.Length))
            if ($health.Alive) {
                $code = 2
                $human = if ($health.RunningSha -and $sha.StartsWith($health.RunningSha)) {
                    "$short 正在判定中（已經 $([int]([int]$health.RunningSeconds / 60)) 分鐘），等它跑完"
                } else {
                    "$short 還沒判定，watcher $($health.Detail) —— 等它接走"
                }
            } else {
                $code = 3
                $human = "$short 沒有判定，而且 actci 沒在動：$($health.Detail)。等下去沒有意義。"
            }
            $obj = [ordered]@{
                sha = $sha; verdict = $null; trustworthy = $false; exitCode = $code
                watcher = [ordered]@{ state = $health.State; alive = $health.Alive; secondsAgo = $health.SecondsAgo; runningSha = $health.RunningSha; detail = $health.Detail }
            }
            Out-Result $obj $human
            exit $code
        }
        $ok = Test-VerdictTrustworthy $v
        $code = if ($ok) { 0 } else { 1 }
        $s = Get-VerdictSummary $v; $s.exitCode = $code
        $s.watcher = $null
        Out-Result $s (Get-VerdictHeadline $v)
        exit $code
    }

    'verdict' {
        if ($positional.Count -lt 1) { Write-Usage 'verdict 需要 <sha>'; exit 2 }
        $v = Get-StoredVerdict -Store $store -Sha $positional[0] -WarningAction SilentlyContinue
        if ($null -eq $v) { Out-Result ([ordered]@{ sha = $positional[0]; verdict = $null }) "$($positional[0]) 沒有判定紀錄"; exit 2 }
        if ($json) { ConvertTo-VerdictJson $v } else { Get-VerdictHeadline $v; "  log: $($v.LogPath)" }
        exit 0
    }

    'status' {
        $limit = if ($opts.ContainsKey('limit')) { [int]$opts['limit'] } else { 10 }
        $age = Get-HeartbeatAge -Store $store
        $cfg = Get-WatcherConfig -Store $store
        $recent = @(Get-RecentVerdicts -Store $store -Limit $limit -WarningAction SilentlyContinue)
        # 健康狀態的定義只有一份，跟 gate 用的是同一支 Get-WatcherHealth。
        $health = Get-WatcherHealth -Store $store
        $beat = [ordered]@{
            # secondsAgo = 距離上次心跳多久（還在動嗎）；runningSeconds = 這一輪跑多久了。兩者不同。
            state = $health.State; alive = $health.Alive; secondsAgo = $health.SecondsAgo
            runningSha = $health.RunningSha; runningSeconds = $health.RunningSeconds; detail = $health.Detail
            note = $(if ($age) { $age.Note } else { $null }); at = $(if ($age) { $age.At.ToString('o') } else { $null })
            stale = (-not $health.Alive)
        }
        $obj = [ordered]@{
            store = $store.Root
            heartbeat = $beat
            watcher = $cfg
            recent = @($recent | ForEach-Object { Get-VerdictSummary $_ })
        }
        $lines = New-Object System.Collections.Generic.List[string]
        $lines.Add("store：$($store.Root)")
        $lines.Add("心跳：$($health.Detail)" + $(if (-not $health.Alive) { '  ** actci 沒在動 **' } else { '' }))
        if ($cfg) { $lines.Add("watcher：$($cfg.Slug) 事件 $($cfg.Event) $(if ($cfg.PSObject.Properties['Job'] -and $cfg.Job) { "job $($cfg.Job)" }) 每 $($cfg.IntervalSeconds) 秒") }
        if ($recent.Count -eq 0) { $lines.Add('還沒有任何判定。') }
        foreach ($v in $recent) {
            $mark = if (Test-VerdictTrustworthy $v) { '[ok]' } else { '[--]' }
            $lines.Add("$mark $($v.Sha.Substring(0, 12))  $($v.FinishedAt)  $(Get-VerdictHeadline $v)")
        }
        Out-Result $obj ($lines -join "`n")
        exit 0
    }

    'run' {
        if ($positional.Count -lt 1) { Write-Usage 'run 需要 <repo>'; exit 1 }
        $repo = ConvertTo-WslPath $positional[0]
        $sha = if ($opts.ContainsKey('sha')) { $opts['sha'] } else { '' }
        $ev = if ($opts.ContainsKey('event')) { $opts['event'] } else { 'push' }
        $job = if ($opts.ContainsKey('job')) { $opts['job'] } else { '' }
        $timeout = if ($opts.ContainsKey('timeout-minutes')) { [int]$opts['timeout-minutes'] * 60000 } else { 3600000 }
        $logDir = if ($opts.ContainsKey('save')) { $store.Logs } else { '' }
        # 一次只准一個 act 在跑，否則兩邊搶六核、還會撞同一個 artifact server 埠。
        # 這裡等而不是失敗：手動跑的人要的是結果，不是「現在很忙」。
        $waitMs = 1000 * 60 * $(if ($opts.ContainsKey('lock-timeout-minutes')) { [int]$opts['lock-timeout-minutes'] } else { 60 })
        $lock = Enter-ActLock -Store $store -TimeoutMs $waitMs -OnWait { if (-not $json) { Write-Host '另一個 act 正在跑，排隊等它結束…' } }
        if (-not $lock) {
            Out-Result ([ordered]@{ error = 'busy'; detail = '另一個 act 正在跑，等不到' }) '另一個 act 正在跑，等不到。稍後再試，或用 --lock-timeout-minutes 等久一點。'
            exit 1
        }
        try {
        $v = Invoke-ActRun -RepoPath $repo -Sha $sha -Event $ev -Job $job -LogDir $logDir -TimeoutMs $timeout
        $posted = $null
        if ($opts.ContainsKey('save')) { Save-Verdict -Store $store -Verdict $v | Out-Null }
        if ($opts.ContainsKey('push')) {
            $ctx = if ($opts.ContainsKey('context')) { $opts['context'] } else { 'actci/manual' }
            $posted = Send-CommitStatus -Slug $opts['push'] -Verdict $v -Context $ctx
        }
        $s = Get-VerdictSummary $v
        $s.saved = $opts.ContainsKey('save')
        $s.posted = $(if ($posted) { [ordered]@{ ok = $posted.Posted; state = $posted.State; detail = $posted.Detail } } else { $null })
        $human = Get-VerdictHeadline $v
        if ($posted) { $human += "`n回報：" + $(if ($posted.Posted) { $posted.State } else { "失敗 $($posted.Detail)" }) }
        Out-Result $s $human
        exit $(if (Test-VerdictTrustworthy $v) { 0 } else { 1 })
        } finally { Exit-ActLock $lock }
    }

    'preflight' {
        $pre = Test-ActPreflight
        $gh = Test-GhAuth
        $obj = [ordered]@{ distro = (Get-WslDistro); act = [ordered]@{ ok = $pre.Ok; code = $pre.Code; detail = $pre.Detail }; gh = [ordered]@{ ok = $gh.Ok; detail = $gh.Detail } }
        Out-Result $obj ("act/docker：$(if ($pre.Ok) { 'ok ' } else { 'NOT OK ' })$($pre.Detail)`ngh：$(if ($gh.Ok) { 'ok ' } else { 'NOT OK ' })$($gh.Detail)")
        exit $(if ($pre.Ok -and $gh.Ok) { 0 } else { 1 })
    }

    'prs' {
        if ($positional.Count -lt 1) { Write-Usage 'prs 需要 <owner/repo>'; exit 1 }
        $list = Get-OpenPullRequests -Slug $positional[0]
        if ($list.Problem) { Out-Result ([ordered]@{ problem = $list.Problem; pulls = @() }) "問不到：$($list.Problem)"; exit 1 }
        $rows = @(foreach ($p in $list.Pulls) {
            $v = Get-StoredVerdict -Store $store -Sha $p.Sha -WarningAction SilentlyContinue
            [ordered]@{
                number = $p.Number; sha = $p.Sha; branch = $p.Branch; title = $p.Title
                judged = (Test-VerdictStored $store $p.Sha)
                verdict = $(if ($v) { Get-VerdictSummary $v } else { $null })
            }
        })
        $human = @(foreach ($r in $rows) { "#$($r.number) $($r.sha.Substring(0, 8)) $(if ($r.verdict) { $r.verdict.headline } else { '（沒有判定）' })  $($r.title)" }) -join "`n"
        if (-not $human) { $human = '沒有開著的 PR。' }
        Out-Result ([ordered]@{ pulls = $rows }) $human
        exit 0
    }

    default {
        Get-Content $PSCommandPath -Encoding UTF8 | Select-Object -Skip 1 -First 24 | ForEach-Object { $_ -replace '^#\s?', '' }
        exit $(if ($Command -eq 'help') { 0 } else { 1 })
    }
}
