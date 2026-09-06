BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\src\actci.psm1') -Force

    function script:Pull([int]$n, [string]$sha, [string]$title = 't') {
        [pscustomobject]@{ Number = $n; Sha = $sha; Branch = "b$n"; Title = $title }
    }
    function script:NewStore { New-Store -Path (Join-Path $TestDrive ('w-' + [guid]::NewGuid().ToString('N'))) }
}

Describe 'Invoke-WatcherTick' {
    BeforeEach {
        $script:log = New-Object System.Collections.Generic.List[string]
        $script:logger = { param($m) $script:log.Add($m) }
        $script:store = NewStore
        $script:actCalls = @()
        $script:statusCalls = @()
        $script:pendingCalls = @()
        $script:fetchCalls = @()

        Mock -ModuleName actci Get-OpenPullRequests { & $script:pullsScript }
        Mock -ModuleName actci Invoke-Wsl {
            param([string]$BashCommand, [int]$TimeoutMs, [string]$Distro)
            $script:fetchCalls += $BashCommand
            & $script:wslScript $BashCommand
        }
        Mock -ModuleName actci Invoke-ActRun {
            param([string]$RepoPath, [string]$Sha, [string]$Event, [string]$Job, [string[]]$ExtraArgs, [string]$RawArgs, [string]$LogDir, [int]$TimeoutMs, [string]$Distro, [switch]$SkipPreflight)
            $script:actCalls += ,@{ Sha = $Sha; Event = $Event; Job = $Job; LogDir = $LogDir; RepoPath = $RepoPath }
            & $script:actScript $Sha
        }
        Mock -ModuleName actci Send-PendingStatus {
            param([string]$Slug, [string]$Sha, [string]$Context, [string]$Note)
            $script:pendingCalls += ,@{ Slug = $Slug; Sha = $Sha; Note = $Note }
            [pscustomobject]@{ Posted = $true; State = 'pending'; Detail = 'pending' }
        }
        Mock -ModuleName actci Send-CommitStatus {
            param([string]$Slug, $Verdict, [string]$Context, [string]$TargetUrl)
            $script:statusCalls += ,@{ Slug = $Slug; Sha = $Verdict.Sha; State = (Get-StatusState $Verdict) }
            & $script:postScript $Verdict
        }

        # 預設劇本：fetch 成功、act 通過 12 支、回報成功
        $script:wslScript = { param($c) [pscustomobject]@{ ExitCode = 0; Output = ''; Error = '' } }
        $script:actScript = {
            param($sha)
            $v = New-Verdict -Sha $sha -Repo '/r' -Outcome 'passed' -TestsRun 12 -TestsSource @('pytest')
            $v.FinishedAt = Get-IsoNow
            $v
        }
        $script:postScript = { param($v) [pscustomobject]@{ Posted = $true; State = (Get-StatusState $v); Detail = 'ok' } }
    }

    It '問不到 PR：心跳照寫、記一行、不跑 act' {
        $script:pullsScript = { [pscustomobject]@{ Pulls = @(); Problem = 'error connecting to api.github.com' } }
        $r = Invoke-WatcherTick -Store $script:store -Slug 'me/repo' -RepoPath '/r' -Log $script:logger
        $r.Action | Should -Be 'no-pull-requests'
        (Get-HeartbeatAge $script:store).Note | Should -Be 'looking'
        $script:log[0] | Should -Match 'api.github.com'
        $script:actCalls.Count | Should -Be 0
    }

    It '沒有待判定的 PR：nothing-to-do，日誌留一行帶 PR 數' {
        $script:pullsScript = { [pscustomobject]@{ Pulls = @(); Problem = '' } }
        $r = Invoke-WatcherTick -Store $script:store -Slug 'me/repo' -RepoPath '/r' -Log $script:logger
        $r.Action | Should -Be 'nothing-to-do'
        $r.Open | Should -Be 0
        $script:log[0] | Should -Match '沒事做'
    }

    It 'errored 的判定放超過 30 分鐘就會重跑，剛發生的不會' {
        $sha = '9' * 40
        $v = New-Verdict -Sha $sha -Repo '/r' -Outcome 'errored' -Note 'docker down'
        $v.FinishedAt = '2026-09-06T00:00:00Z'
        Save-Verdict $script:store $v | Out-Null
        $t = { param($s) [DateTime]::Parse($s, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind) }
        Test-VerdictStored $script:store $sha -Now (& $t '2026-09-06T00:05:00Z') | Should -BeTrue    # 剛發生：算已判定
        Test-VerdictStored $script:store $sha -Now (& $t '2026-09-06T00:31:00Z') | Should -BeFalse   # 放了 31 分鐘：要重跑
        # passed / failed 不管多久都算已判定
        $ok = New-Verdict -Sha ('8' * 40) -Repo '/r' -Outcome 'failed' -TestsRun 3; $ok.FinishedAt = '2020-01-01T00:00:00Z'
        Save-Verdict $script:store $ok | Out-Null
        Test-VerdictStored $script:store ('8' * 40) | Should -BeTrue
        # 一圈實跑：31 分鐘前的 errored 會被挑起來重跑
        $v.FinishedAt = [DateTime]::UtcNow.AddMinutes(-31).ToString('yyyy-MM-ddTHH:mm:ssZ')
        Save-Verdict $script:store $v | Out-Null
        $script:pullsScript = { [pscustomobject]@{ Pulls = @((Pull 6 ('9' * 40))); Problem = '' } }
        (Invoke-WatcherTick -Store $script:store -Slug 'me/repo' -RepoPath '/r' -Log $script:logger).Action | Should -Be 'ran'
    }

    It 'fetch 指令帶 GIT_TERMINAL_PROMPT=0，沒認證就立刻失敗' {
        $script:pullsScript = { [pscustomobject]@{ Pulls = @((Pull 1 ('a' * 40))); Problem = '' } }
        Invoke-WatcherTick -Store $script:store -Slug 'me/repo' -RepoPath '/r' -Log $script:logger | Out-Null
        @($script:fetchCalls | Where-Object { $_ -like 'GIT_TERMINAL_PROMPT=0 git -C*fetch*' }).Count | Should -Be 1
    }

    It '已判定過的 PR 不再跑' {
        $sha = 'a' * 40
        Save-Verdict $script:store (New-Verdict -Sha $sha -Repo '/r' -Outcome 'failed' -TestsRun 3) | Out-Null
        $script:pullsScript = { [pscustomobject]@{ Pulls = @((Pull 5 ('a' * 40))); Problem = '' } }
        $r = Invoke-WatcherTick -Store $script:store -Slug 'me/repo' -RepoPath '/r' -Log $script:logger
        $r.Action | Should -Be 'nothing-to-do'
        $r.Open | Should -Be 1
    }

    It '完整一圈：最舊的 PR 先、pending、fetch、act、存判定、推 status、記 headline' {
        $script:pullsScript = { [pscustomobject]@{ Pulls = @((Pull 9 ('b' * 40) 'newer'), (Pull 4 ('c' * 40) 'older PR title that is quite long indeed yes')); Problem = '' } }
        $r = Invoke-WatcherTick -Store $script:store -Slug 'me/repo' -RepoPath '/r' -Event 'pull_request' -Log $script:logger
        $r.Action | Should -Be 'ran'
        $r.Number | Should -Be 4
        $r.Sha | Should -Be ('c' * 40)
        $r.Outcome | Should -Be 'passed'
        $r.TestsRun | Should -Be 12
        $r.Posted | Should -BeTrue

        $script:pendingCalls.Count | Should -Be 1
        $script:pendingCalls[0].Sha | Should -Be ('c' * 40)
        $script:pendingCalls[0].Note | Should -Match '#4'

        @($script:fetchCalls | Where-Object { $_ -like "*fetch --quiet origin '+refs/pull/4/head:refs/actci/pr/4'*" }).Count | Should -Be 1

        $script:actCalls.Count | Should -Be 1
        $script:actCalls[0].Sha | Should -Be ('c' * 40)
        $script:actCalls[0].Event | Should -Be 'pull_request'
        $script:actCalls[0].LogDir | Should -Be $script:store.Logs

        (Get-StoredVerdict $script:store ('c' * 40)).TestsRun | Should -Be 12
        $script:statusCalls.Count | Should -Be 1
        $script:statusCalls[0].State | Should -Be 'success'

        @($script:log | Where-Object { $_ -match '^#4 cccccccc older PR title' }).Count | Should -Be 1
        @($script:log | Where-Object { $_ -match '通過（12 支' }).Count | Should -Be 1
        (Get-HeartbeatAge $script:store).Note | Should -Match '^running cccccccc'
    }

    It '-Job 會傳給 act，只跑那個 job（兩個 workflow 都收 workflow_dispatch 時不會全跑）' {
        $script:pullsScript = { [pscustomobject]@{ Pulls = @((Pull 2 ('b' * 40))); Problem = '' } }
        Invoke-WatcherTick -Store $script:store -Slug 'me/repo' -RepoPath '/r' -Event 'workflow_dispatch' -Job 'validate' -Log $script:logger | Out-Null
        $script:actCalls.Count | Should -Be 1
        $script:actCalls[0].Event | Should -Be 'workflow_dispatch'
    }
    It '待跑的 PR 會在日誌裡講為什麼要跑' {
        $script:pullsScript = { [pscustomobject]@{ Pulls = @((Pull 3 ('c' * 40))); Problem = '' } }
        Invoke-WatcherTick -Store $script:store -Slug 'me/repo' -RepoPath '/r' -Log $script:logger | Out-Null
        @($script:log | Where-Object { $_ -like '*待跑 #3：沒有判定檔*' }).Count | Should -Be 1
    }
    It '一圈只跑一個，第二個留到下一圈' {
        $script:pullsScript = { [pscustomobject]@{ Pulls = @((Pull 1 ('d' * 40)), (Pull 2 ('e' * 40))); Problem = '' } }
        Invoke-WatcherTick -Store $script:store -Slug 'me/repo' -RepoPath '/r' -Log $script:logger | Out-Null
        $script:actCalls.Count | Should -Be 1
        $r2 = Invoke-WatcherTick -Store $script:store -Slug 'me/repo' -RepoPath '/r' -Log $script:logger
        $r2.Number | Should -Be 2
        $script:actCalls.Count | Should -Be 2
    }

    It 'fetch 失敗：不跑 act，存一份 errored 判定並推 error' {
        $script:pullsScript = { [pscustomobject]@{ Pulls = @((Pull 7 ('f' * 40))); Problem = '' } }
        $script:wslScript = { param($c) [pscustomobject]@{ ExitCode = 128; Output = 'fatal: could not read from remote'; Error = '' } }
        $r = Invoke-WatcherTick -Store $script:store -Slug 'me/repo' -RepoPath '/r' -Log $script:logger
        $r.Action | Should -Be 'ran'
        $r.Outcome | Should -Be 'errored'
        $script:actCalls.Count | Should -Be 0
        $saved = Get-StoredVerdict $script:store ('f' * 40)
        $saved.Outcome | Should -Be 'errored'
        $saved.Note | Should -Match 'git fetch PR #7 失敗：fatal'
        $script:statusCalls[0].State | Should -Be 'error'
    }

    It '回報失敗：判定照樣存，日誌有 !! 回報失敗，Posted false' {
        $script:pullsScript = { [pscustomobject]@{ Pulls = @((Pull 3 ('1' * 40))); Problem = '' } }
        $script:postScript = { param($v) [pscustomobject]@{ Posted = $false; State = 'success'; Detail = 'HTTP 502' } }
        $r = Invoke-WatcherTick -Store $script:store -Slug 'me/repo' -RepoPath '/r' -Log $script:logger
        $r.Posted | Should -BeFalse
        (Get-StoredVerdict $script:store ('1' * 40)) | Should -Not -BeNullOrEmpty
        @($script:log | Where-Object { $_ -like '*!! 回報失敗：HTTP 502*' }).Count | Should -Be 1
    }

    It '0 支測試的通過：存下來並推 failure，日誌講沒有驗證' {
        $script:pullsScript = { [pscustomobject]@{ Pulls = @((Pull 8 ('2' * 40))); Problem = '' } }
        $script:actScript = { param($sha) New-Verdict -Sha $sha -Repo '/r' -Outcome 'passed' -TestsRun 0 }
        $r = Invoke-WatcherTick -Store $script:store -Slug 'me/repo' -RepoPath '/r' -Log $script:logger
        $r.Outcome | Should -Be 'passed'
        $script:statusCalls[0].State | Should -Be 'failure'
        @($script:log | Where-Object { $_ -match '沒有驗證' }).Count | Should -Be 1
    }
}

Describe 'Start-WatcherLoop' {
    BeforeEach {
        $script:log = New-Object System.Collections.Generic.List[string]
        $script:logger = { param($m) $script:log.Add($m) }
        $script:store = NewStore
        $script:sleeps = @()
        $script:sleeper = { param($s) $script:sleeps += $s }
    }
    It '-Once 只轉一圈，不睡' {
        Mock -ModuleName actci Get-OpenPullRequests { [pscustomobject]@{ Pulls = @(); Problem = '' } }
        $r = Start-WatcherLoop -Store $script:store -Slug 'me/repo' -RepoPath '/r' -Once -Sleeper $script:sleeper -Log $script:logger
        $r.Action | Should -Be 'nothing-to-do'
        $script:sleeps.Count | Should -Be 0
    }
    It '-Log 用 Write-Output 也不會弄壞回傳值（第一次安裝踩到的）' {
        Mock -ModuleName actci Get-OpenPullRequests { [pscustomobject]@{ Pulls = @(); Problem = '' } }
        $r = Start-WatcherLoop -Store $script:store -Slug 'me/repo' -RepoPath '/r' -Once -Sleeper $script:sleeper -Log { param($m) Write-Output "LOG $m" }
        $r -is [hashtable] | Should -BeTrue
        $r.Action | Should -Be 'nothing-to-do'
    }
    It '一圈掛了不會停，記一行後繼續，睡 IntervalSeconds' {
        $script:n = 0
        Mock -ModuleName actci Get-OpenPullRequests {
            $script:n++
            if ($script:n -eq 1) { throw 'boom' }
            [pscustomobject]@{ Pulls = @(); Problem = '' }
        }
        $r = Start-WatcherLoop -Store $script:store -Slug 'me/repo' -RepoPath '/r' -MaxTicks 2 -IntervalSeconds 7 -Sleeper $script:sleeper -Log $script:logger
        $r.Action | Should -Be 'nothing-to-do'
        $script:log[0] | Should -Match '這一圈掛了：.*boom'
        $script:sleeps | Should -Be @(7)
    }
}

Describe '跑測試那十幾分鐘裡心跳要繼續跳' {
    It 'Start-HeartbeatPulse 立刻寫一次，Stop 之後不再寫' {
        $store = Initialize-Store (NewStore)
        $pulse = Start-HeartbeatPulse -Store $store -Note 'running abc12345' -IntervalSeconds 1
        try {
            $deadline = (Get-Date).AddSeconds(10)
            while ((Get-Date) -lt $deadline -and -not (Test-Path -LiteralPath $store.Heartbeat)) { Start-Sleep -Milliseconds 100 }
            $age = Get-HeartbeatAge -Store $store
            $age | Should -Not -BeNullOrEmpty
            $age.Note | Should -Be 'running abc12345'
            $age.Seconds | Should -BeLessThan 15
        } finally { Stop-HeartbeatPulse $pulse }
        # 停掉之後檔案不再更新
        $before = (Get-Item -LiteralPath $store.Heartbeat).LastWriteTimeUtc
        Start-Sleep -Seconds 3
        (Get-Item -LiteralPath $store.Heartbeat).LastWriteTimeUtc | Should -Be $before
    }
    It 'Stop-HeartbeatPulse 收到 null 不會炸（Start 失敗時就是 null）' {
        { Stop-HeartbeatPulse $null } | Should -Not -Throw
    }
    # 名稱不能有角括號：Pester 會把 <...> 當成 -ForEach 的樣板欄位去解析
    It 'Invoke-WatcherRun 期間心跳的備註是 running 加短 sha' {
        # act 執行中被記下的心跳，UI 與 CLI 都靠這個字串分辨「執行中」與「停了」
        $store = Initialize-Store (NewStore)
        Mock -ModuleName actci Invoke-Wsl { [pscustomobject]@{ ExitCode = 0; Output = ''; Error = '' } }
        Mock -ModuleName actci Send-PendingStatus { [pscustomobject]@{ Posted = $true; State = 'pending'; Detail = '' } }
        Mock -ModuleName actci Send-CommitStatus { [pscustomobject]@{ Posted = $true; State = 'success'; Detail = '' } }
        Mock -ModuleName actci Invoke-ActRun {
            param([string]$RepoPath, [string]$Sha)
            $h = Get-WatcherHealth -Store $store
            $h.State | Should -Be 'running'
            $h.RunningSha | Should -Be 'abcdef12'
            $h.RunningSeconds | Should -BeLessThan 30   # 剛開始
            New-Verdict -Sha $Sha -Repo '/r' -Outcome 'passed' -TestsRun 5
        }
        Invoke-WatcherRun -Store $store -Slug 'me/repo' -RepoPath '/r' -Target (Pull 1 ('abcdef12' + '0' * 32)) -Log { param($m) } | Out-Null
    }
}

Describe 'Get-WatcherHealth：活著還是死了' {
    BeforeEach { $script:hstore = Initialize-Store (NewStore) }
    function script:SetBeat([string]$note, [int]$minutesAgo) {
        $stamp = [DateTime]::UtcNow.AddMinutes(-$minutesAgo).ToString('o')
        [System.IO.File]::WriteAllText($script:hstore.Heartbeat, "$stamp`n$note`n", (New-Object System.Text.UTF8Encoding $false))
    }
    It '沒有心跳檔 → never，不是活的' {
        $h = Get-WatcherHealth -Store $script:hstore
        $h.State | Should -Be 'never'; $h.Alive | Should -BeFalse
    }
    It '剛跳過而且在輪詢 → idle，活的' {
        SetBeat 'looking' 0
        $h = Get-WatcherHealth -Store $script:hstore
        $h.State | Should -Be 'idle'; $h.Alive | Should -BeTrue
    }
    It '閒置超過五分鐘 → stale，不是活的' {
        SetBeat 'looking' 6
        $h = Get-WatcherHealth -Store $script:hstore
        $h.State | Should -Be 'stale'; $h.Alive | Should -BeFalse
    }
    It '正在跑二十分鐘 → running，仍然是活的（一輪本來就要十幾分鐘）' {
        SetBeat 'running abc12345' 20
        $h = Get-WatcherHealth -Store $script:hstore
        $h.State | Should -Be 'running'; $h.Alive | Should -BeTrue; $h.RunningSha | Should -Be 'abc12345'
    }
    It '同一個 sha 跑超過一小時 → stuck，不是活的' {
        SetBeat 'running abc12345' 61
        $h = Get-WatcherHealth -Store $script:hstore
        $h.State | Should -Be 'stuck'; $h.Alive | Should -BeFalse; $h.RunningSha | Should -Be 'abc12345'
    }
    It '「跑多久了」看 since，不看心跳年齡 —— 脈搏刷新心跳不該把它歸零' {
        # 脈搏 10 秒前才刷新過心跳，但這一輪是 20 分鐘前開始的
        $since = [DateTime]::UtcNow.AddMinutes(-20).ToString('o')
        SetBeat "running abc12345 since $since" 0
        $h = Get-WatcherHealth -Store $script:hstore
        $h.State | Should -Be 'running'
        $h.SecondsAgo | Should -BeLessThan 30          # 心跳很新 = 還在動
        $h.RunningSeconds | Should -BeGreaterThan 1100 # 但已經跑了二十分鐘
        $h.Detail | Should -Match '20 分鐘'
    }
    It 'since 說跑超過一小時 → stuck，即使心跳是新的' {
        $since = [DateTime]::UtcNow.AddMinutes(-70).ToString('o')
        SetBeat "running abc12345 since $since" 0
        $h = Get-WatcherHealth -Store $script:hstore
        $h.State | Should -Be 'stuck'; $h.Alive | Should -BeFalse
    }
    It 'New-RunningNote 產生的備註讀得回來' {
        $note = New-RunningNote -Sha 'deadbeef' -StartedAt ([DateTime]::UtcNow.AddMinutes(-5))
        SetBeat $note 0
        $h = Get-WatcherHealth -Store $script:hstore
        $h.RunningSha | Should -Be 'deadbeef'
        $h.RunningSeconds | Should -BeGreaterThan 250
    }
}

Describe 'Watcher 設定檔' {
    It '存了再讀回來，預設值補齊' {
        $store = NewStore
        Save-WatcherConfig -Store $store -Config @{ Repo = '/home/me/r'; Slug = 'me/r' }
        $c = Get-WatcherConfig -Store $store
        $c.Repo | Should -Be '/home/me/r'
        $c.Slug | Should -Be 'me/r'
        $c.Event | Should -Be 'pull_request'
        $c.IntervalSeconds | Should -Be 60
        $c.TaskName | Should -Be 'actci-watcher'
        $c.InstalledAt | Should -Match '^\d{4}-'
    }
    It '沒有設定檔回 null' {
        Get-WatcherConfig -Store (NewStore) | Should -BeNullOrEmpty
    }
}

Describe '安裝器與入口腳本至少要能被解析' {
    It '<name> 沒有語法錯誤' -ForEach @(
        @{ name = 'watcher.ps1' }, @{ name = 'install_watcher.ps1' }
    ) {
        $path = Join-Path $PSScriptRoot "..\$name"
        $errors = $null
        [System.Management.Automation.PSParser]::Tokenize((Get-Content -Raw $path), [ref]$errors) | Out-Null
        @($errors).Count | Should -Be 0
    }
    It '安裝器守住 NextRunTime 那一條' {
        (Get-Content -Raw (Join-Path $PSScriptRoot '..\install_watcher.ps1')) | Should -Match 'NextRunTime'
    }
    It '安裝器清舊行程時不會殺到自己或別的安裝器' {
        $text = Get-Content -Raw (Join-Path $PSScriptRoot '..\install_watcher.ps1')
        $text | Should -Match "-notlike '\*install_watcher\*'"
        $text | Should -Match '\$_\.ProcessId -ne \$PID'
        $text | Should -Not -Match "CommandLine -like '\*watcher\.ps1\*'"
    }
    It '安裝器註冊前先試跑一圈' {
        $text = Get-Content -Raw (Join-Path $PSScriptRoot '..\install_watcher.ps1')
        $text.IndexOf('-Once') | Should -BeLessThan $text.IndexOf('Register-ScheduledTask')
    }
}
