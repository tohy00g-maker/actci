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
            $script:actCalls += ,@{ Sha = $Sha; Event = $Event; LogDir = $LogDir; RepoPath = $RepoPath }
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

        $script:log[0] | Should -Match '^#4 cccccccc older PR title'
        $script:log[1] | Should -Match '通過（12 支'
        (Get-HeartbeatAge $script:store).Note | Should -Match '^running cccccccc'
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
        $script:log[1] | Should -Match '沒有驗證'
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
    It '安裝器註冊前先試跑一圈' {
        $text = Get-Content -Raw (Join-Path $PSScriptRoot '..\install_watcher.ps1')
        $text.IndexOf('-Once') | Should -BeLessThan $text.IndexOf('Register-ScheduledTask')
    }
}
