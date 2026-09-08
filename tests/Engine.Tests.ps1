BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\src\actci.psm1') -Force

    $script:PytestOk = @'
[CI/test] ⭐ Run Main pytest
[CI/test]   | ======================== 12 passed, 1 skipped in 0.31s =========================
[CI/test]   ✅  Success - Main pytest
[CI/test] 🏁  Job succeeded
'@
    $script:PytestFail = @'
[CI/test] ⭐ Run Main pytest
[CI/test]   | ======================== 2 failed, 10 passed in 0.31s =========================
[CI/test]   ❌  Failure - Main pytest
[CI/test] 🏁  Job failed
'@
    $script:BuildFail = @'
[CI/build] ⭐ Run Main npm run build
[CI/build]   | error TS2322: Type 'string' is not assignable to type 'number'.
[CI/build]   ❌  Failure - Main npm run build
[CI/build] 🏁  Job failed
'@
    $script:DockerDown = @'
time="2026-09-06T00:00:00Z" level=error msg="Cannot connect to the Docker daemon at unix:///var/run/docker.sock. Is the docker daemon running?"
Error: Cannot connect to the Docker daemon at unix:///var/run/docker.sock. Is the docker daemon running?
'@

    # 讓每個測試用 $script:wslScript 決定 wsl 假替身怎麼回。
    function script:Fake([int]$code, [string]$out, [string]$err = '') {
        [pscustomobject]@{ ExitCode = $code; Output = $out; Error = $err }
    }
}

Describe 'New-ActCommand' {
    It '有 sha：git archive 到暫存目錄，跑完清掉，離開碼留著' {
        $cmd = New-ActCommand -RepoPath '/home/me/repo' -Sha 'abc1234' -Event 'push' -Job 'test'
        $cmd | Should -Match "git -C '/home/me/repo' archive --format=tar 'abc1234' \| tar -x -C"
        $cmd | Should -Match 'cd "\$tmp" && NO_COLOR=1 TERM=dumb act --artifact-server-port "\$ap" .push. -j .test. 2>&1; rc=\$\?; cd /; rm -rf "\$tmp"; exit \$rc$'
        $cmd | Should -Match '^export PATH="\$HOME/.local/bin:\$PATH"; '
    }
    It '沒 sha：直接 cd 進 repo' {
        $cmd = New-ActCommand -RepoPath '/home/me/repo' -Event 'pull_request'
        $cmd | Should -Match "cd '/home/me/repo' && NO_COLOR=1 TERM=dumb act --artifact-server-port ""\`$ap"" 'pull_request' 2>&1$"
        $cmd | Should -Not -Match 'archive'
    }
    It 'ExtraArgs 逐一加引號，RawArgs 原樣附在後面' {
        $cmd = New-ActCommand -RepoPath '/r' -ExtraArgs @('-W', ".github/workflows/it's.yml") -RawArgs '--env FOO=bar'
        $cmd | Should -Match "'push' '-W' '.github/workflows/it'\\''s.yml' --env FOO=bar 2>&1"
    }
    It 'repo 路徑有空白與單引號也安全' {
        $cmd = New-ActCommand -RepoPath "/home/me/my repo's"
        $cmd | Should -Match "cd '/home/me/my repo'\\''s' &&"
    }
}

Describe '一次只准一個 act 在跑' {
    BeforeEach { $script:lockStore = Initialize-Store (New-Store -Path (Join-Path $TestDrive ('lock-' + [guid]::NewGuid().ToString('N')))) }

    It '第二個拿不到鎖（TimeoutMs 0 就立刻放棄）' {
        $a = Enter-ActLock -Store $script:lockStore
        try {
            $a | Should -Not -BeNullOrEmpty
            Enter-ActLock -Store $script:lockStore | Should -BeNullOrEmpty
        } finally { Exit-ActLock $a }
    }
    It '放掉之後下一個拿得到' {
        $a = Enter-ActLock -Store $script:lockStore
        Exit-ActLock $a
        $b = Enter-ActLock -Store $script:lockStore
        try { $b | Should -Not -BeNullOrEmpty } finally { Exit-ActLock $b }
    }
    It 'Exit-ActLock 收到 null 不會炸' {
        { Exit-ActLock $null } | Should -Not -Throw
    }
    It '每一輪自己找一個沒在聽的埠，不要撞死在 34567' {
        $cmd = New-ActCommand -RepoPath '/r' -Sha 'abc1234'
        $cmd | Should -Match 'ss -ltnH'
        $cmd | Should -Match '--artifact-server-port "\$ap"'
    }
}

Describe 'Invoke-ActRun' {
    BeforeEach {
        $script:calls = New-Object System.Collections.Generic.List[string]
        Mock -ModuleName actci Invoke-Wsl {
            param([string]$BashCommand, [int]$TimeoutMs, [string]$Distro)
            $script:calls.Add($BashCommand)
            & $script:wslScript $BashCommand
        }
        $script:logDir = Join-Path $TestDrive ('log-' + [guid]::NewGuid().ToString('N'))
    }

    It 'Docker Desktop 的替身 docker 把提示印在 stdout：判成沒開 WSL integration，不是可用' {
        $script:wslScript = { param($c) if ($c -like '*command -v act*') { Fake 0 "__NODAEMON__`nThe command 'docker' could not be found in this WSL 2 distro.`nWe recommend to activate the WSL integration in Docker Desktop settings." } else { throw "不該跑到 act：$c" } }
        $pre = Test-ActPreflight
        $pre.Ok | Should -BeFalse
        $pre.Code | Should -Be 'nointegration'
        $pre.Detail | Should -Match 'WSL integration'
    }

    It '前置檢查失敗：errored，act 沒被叫到' {
        $script:wslScript = { param($c) if ($c -like '*command -v act*') { Fake 0 '__NODOCKER__' } else { throw "不該跑到 act：$c" } }
        $v = Invoke-ActRun -RepoPath '/r' -Sha 'abc1234' -NoDockerRestart
        $v.Outcome | Should -Be 'errored'
        $v.Note | Should -Match 'docker'
        @($script:calls | Where-Object { $_ -like '*archive*' }).Count | Should -Be 0
    }

    It 'Docker 沒開：自己重啟，起來了就照常跑，判定不是 errored' {
        # 這是 2026-09-09 那一次：Docker Desktop 自己關了，PR #715 被推成 error。
        # 「Docker 沒開」不是那個 commit 的判定，開回來就該有真正的判定。
        $script:preCalls = 0
        $script:wslScript = {
            param($c)
            if ($c -like '*command -v act*') {
                $script:preCalls++
                if ($script:preCalls -eq 1) { return Fake 0 '__NODOCKER__' }
                return Fake 0 '__OK__ act version 0.2.80 docker 27.0'
            }
            Fake 0 $script:PytestOk
        }
        Mock -ModuleName actci Restore-DockerEngine { @{ Recovered = $true; Started = $true; WaitedSeconds = 25; Detail = '已啟動' } }
        $v = Invoke-ActRun -RepoPath '/r' -Sha 'abc1234'
        $v.Outcome | Should -Be 'passed'
        $v.TestsRun | Should -Be 12
        Should -Invoke -ModuleName actci Restore-DockerEngine -Times 1 -Exactly
    }

    It 'Docker 沒開而且開不起來：errored，註記要說出已經試過重啟' {
        $script:wslScript = { param($c) if ($c -like '*command -v act*') { Fake 0 '__NODOCKER__' } else { throw "不該跑到 act：$c" } }
        Mock -ModuleName actci Restore-DockerEngine { @{ Recovered = $false; Started = $false; WaitedSeconds = 180; Detail = '找不到 Docker Desktop.exe' } }
        $v = Invoke-ActRun -RepoPath '/r' -Sha 'abc1234'
        $v.Outcome | Should -Be 'errored'
        $v.Note | Should -Match '已試著自動重啟 Docker'
        $v.Note | Should -Match '找不到 Docker Desktop.exe'
    }

    It '測試真的失敗：不去重啟 Docker' {
        # 紅了就重啟 Docker 會白等幾分鐘，還會讓人以為問題出在環境。
        $script:wslScript = { param($c) if ($c -like '*command -v act*') { Fake 0 '__OK__' } else { Fake 1 $script:PytestFail } }
        Mock -ModuleName actci Restore-DockerEngine { throw '測試失敗不該去動 Docker' }
        (Invoke-ActRun -RepoPath '/r' -Sha 'abc1234').Outcome | Should -Be 'failed'
        Should -Invoke -ModuleName actci Restore-DockerEngine -Times 0 -Exactly
    }

    It '通過：passed，測試數與來源填好，日誌寫到 LogDir' {
        $script:wslScript = { param($c) if ($c -like '*command -v act*') { Fake 0 '__OK__ act version 0.2.80 docker 27.0' } else { Fake 0 $script:PytestOk } }
        $v = Invoke-ActRun -RepoPath '/r' -Sha 'abcdef1234567890' -Event 'push' -Job 'test' -LogDir $script:logDir
        $v.Outcome | Should -Be 'passed'
        $v.TestsRun | Should -Be 12
        @($v.TestsSource) | Should -Be @('pytest')
        Test-VerdictTrustworthy $v | Should -BeTrue
        $v.Sha | Should -Be 'abcdef1234567890'
        $v.Event | Should -Be 'push'
        $v.Job | Should -Be 'test'
        $v.FinishedAt | Should -Not -BeNullOrEmpty
        $v.Steps[0].ExitCode | Should -Be 0
        @($v.Jobs).Count | Should -Be 1
        $v.Jobs[0].Workflow | Should -Be 'CI'; $v.Jobs[0].Job | Should -Be 'test'; $v.Jobs[0].Status | Should -Be 'succeeded'; $v.Jobs[0].TestsRun | Should -Be 12
        $v.LogPath | Should -Be (Join-Path $script:logDir 'abcdef123456.log')
        Get-Content $v.LogPath -Raw | Should -Match '12 passed'
        $script:calls[1] | Should -Match "archive --format=tar 'abcdef1234567890'"
    }

    It 'act 離開碼 0 但所有 job 因平台不支援被跳過：errored，不是通過（2026-09-06 example-app 實測）' {
        $skipped = "[Self-hosted checks/validate] 🚧  Skipping unsupported platform -- Try running with ``-P self-hosted=...```n[Self-hosted checks/validate] 🚧  Skipping unsupported platform -- Try running with ``-P windows=...``"
        $script:wslScript = { param($c) if ($c -like '*command -v act*') { Fake 0 '__OK__' } else { Fake 0 $skipped } }
        $v = Invoke-ActRun -RepoPath '/r' -Sha 'abc1234' -Event 'pull_request'
        $v.Outcome | Should -Be 'errored'
        $v.Note | Should -Match 'runs-on'
        Get-StatusState $v | Should -Be 'error'
    }

    It 'act 離開碼 0 但事件對不到任何 workflow：errored 並點名事件' {
        $script:wslScript = { param($c) if ($c -like '*command -v act*') { Fake 0 '__OK__' } else { Fake 0 'time="x" level=info msg="Using docker host"' } }
        $v = Invoke-ActRun -RepoPath '/r' -Sha 'abc1234' -Event 'release'
        $v.Outcome | Should -Be 'errored'
        $v.Note | Should -Match 'release'
    }

    It '通過但 0 支：passed 卻不 trustworthy' {
        $script:wslScript = { param($c) if ($c -like '*command -v act*') { Fake 0 '__OK__' } else { Fake 0 "[CI/build] ⭐ Run Main npm run build`n[CI/build]   ✅  Success - Main npm run build`n[CI/build] 🏁  Job succeeded" } }
        $v = Invoke-ActRun -RepoPath '/r' -Sha 'abc1234'
        $v.Outcome | Should -Be 'passed'
        $v.TestsRun | Should -Be 0
        Test-VerdictTrustworthy $v | Should -BeFalse
        Get-StatusState $v | Should -Be 'failure'
    }

    It '測試紅了：failed，測試數照樣填' {
        $script:wslScript = { param($c) if ($c -like '*command -v act*') { Fake 0 '__OK__' } else { Fake 1 $script:PytestFail } }
        $v = Invoke-ActRun -RepoPath '/r' -Sha 'abc1234'
        $v.Outcome | Should -Be 'failed'
        $v.TestsRun | Should -Be 12
    }

    It 'build step 失敗但沒測試數：還是 failed，不是 errored（那是程式碼的問題）' {
        $script:wslScript = { param($c) if ($c -like '*command -v act*') { Fake 0 '__OK__' } else { Fake 1 $script:BuildFail } }
        $v = Invoke-ActRun -RepoPath '/r' -Sha 'abc1234'
        $v.Outcome | Should -Be 'failed'
        $v.TestsRun | Should -Be 0
    }

    It '測試真的紅了：failed，不會因為 act 例行印了 docker.sock 就變成 errored' {
        # 2026-09-06 509c07b4 的形狀：3441 支跑完、job failed，而 log 第一行永遠是
        # `Using docker host 'unix:///var/run/docker.sock'`。那一行不是故障。
        $real = @'
time="2026-09-06T16:51:02+08:00" level=info msg="Using docker host 'unix:///var/run/docker.sock', and daemon socket 'unix:///var/run/docker.sock'"
[Django checks (hosted, manual)/validate] ⭐ Run Main Run test suite
[Django checks (hosted, manual)/validate]   | Ran 3441 tests in 900.000s
[Django checks (hosted, manual)/validate]   | FAILED (failures=2)
[Django checks (hosted, manual)/validate]   ❌  Failure - Main Run test suite
[Django checks (hosted, manual)/validate] 🏁  Job failed
Error: Job 'validate' failed
'@
        $script:wslScript = { param($c) if ($c -like '*command -v act*') { Fake 0 '__OK__' } else { Fake 1 $real } }
        $v = Invoke-ActRun -RepoPath '/r' -Sha 'abc1234'
        $v.Outcome | Should -Be 'failed'
        $v.TestsRun | Should -Be 3441
        Get-StatusState $v | Should -Be 'failure'
    }

    It 'act 拉映像前印的 unable to find image 也不算故障' {
        $out = "[CI/test] unable to find image 'catthehacker/ubuntu:act-latest' locally`n[CI/test]   | ==== 3 failed, 5 passed in 1.0s ====`n[CI/test] 🏁  Job failed"
        $script:wslScript = { param($c) if ($c -like '*command -v act*') { Fake 0 '__OK__' } else { Fake 1 $out } }
        (Invoke-ActRun -RepoPath '/r' -Sha 'abc1234').Outcome | Should -Be 'failed'
    }

    It 'docker 中途死掉：errored，Note 是那一行' {
        $script:wslScript = { param($c) if ($c -like '*command -v act*') { Fake 0 '__OK__' } else { Fake 1 $script:DockerDown } }
        $v = Invoke-ActRun -RepoPath '/r' -Sha 'abc1234'
        $v.Outcome | Should -Be 'errored'
        $v.Note | Should -Match 'Docker daemon'
    }

    It 'act 非零但看不出原因：errored，Note 是最後一行' {
        $script:wslScript = { param($c) if ($c -like '*command -v act*') { Fake 0 '__OK__' } else { Fake 2 "something`nlast line here" } }
        $v = Invoke-ActRun -RepoPath '/r' -Sha 'abc1234'
        $v.Outcome | Should -Be 'errored'
        $v.Note | Should -Be 'last line here'
    }

    It 'git archive 失敗：errored，Note 講 archive' {
        $script:wslScript = { param($c) if ($c -like '*command -v act*') { Fake 0 '__OK__' } else { Fake 98 "fatal: not a valid object name: 'nope123'`n__ARCHIVE_FAILED__" } }
        $v = Invoke-ActRun -RepoPath '/r' -Sha 'nope123'
        $v.Outcome | Should -Be 'errored'
        $v.Note | Should -Match 'git archive nope123 失敗：fatal'
    }

    It '逾時：errored，Note 講秒數' {
        $script:wslScript = { param($c) if ($c -like '*command -v act*') { Fake 0 '__OK__' } else { Fake -1 'partial' '逾時（5000 ms）' } }
        $v = Invoke-ActRun -RepoPath '/r' -Sha 'abc1234' -TimeoutMs 5000
        $v.Outcome | Should -Be 'errored'
        $v.Note | Should -Be '超過 5 秒還沒跑完'
    }

    It '沒給 sha：用 HEAD 當標籤、註明工作目錄、不 archive' {
        $script:wslScript = {
            param($c)
            if ($c -like '*rev-parse HEAD*') { return Fake 0 ('f' * 40) }
            if ($c -like '*command -v act*') { return Fake 0 '__OK__' }
            Fake 0 $script:PytestOk
        }
        $v = Invoke-ActRun -RepoPath '/r'
        $v.Sha | Should -Be ('f' * 40)
        $v.Note | Should -Match '工作目錄'
        $v.Outcome | Should -Be 'passed'
        @($script:calls | Where-Object { $_ -like '*archive*' }).Count | Should -Be 0
        @($script:calls | Where-Object { $_ -like "*cd '/r' && *act*" }).Count | Should -Be 1
    }

    It '沒給 sha 又不是 git repo：標籤是 0000000，照跑' {
        $script:wslScript = {
            param($c)
            if ($c -like '*rev-parse HEAD*') { return Fake 128 '' 'fatal: not a git repository' }
            if ($c -like '*command -v act*') { return Fake 0 '__OK__' }
            Fake 0 $script:PytestOk
        }
        $v = Invoke-ActRun -RepoPath '/r'
        $v.Sha | Should -Be '0000000'
        $v.Outcome | Should -Be 'passed'
    }

    It 'SkipPreflight 就不做前置檢查' {
        $script:wslScript = { param($c) if ($c -like '*command -v act*') { throw '不該做前置檢查' } else { Fake 0 $script:PytestOk } }
        (Invoke-ActRun -RepoPath '/r' -Sha 'abc1234' -SkipPreflight).Outcome | Should -Be 'passed'
    }

    It 'wsl 本身叫不動：errored，不丟例外' {
        $script:wslScript = { param($c) Fake -1 '' 'The system cannot find the file specified' }
        $v = Invoke-ActRun -RepoPath '/r' -Sha 'abc1234'
        $v.Outcome | Should -Be 'errored'
        $v.Note | Should -Match 'WSL 叫不動'
    }
}

Describe 'Restore-DockerEngine' {
    # 開起來、等到 daemon 真的回話為止。Starter/Prober/Sleeper 都注入，測試不碰真的 Docker、也不真的睡。
    It '等到前置檢查通過就回來，並回報等了幾秒' {
        $script:probes = 0
        $r = Restore-DockerEngine -WaitSeconds 60 -PollSeconds 5 `
            -Starter { @{ Started = $true; Detail = '已啟動' } } `
            -Prober  { $script:probes++; @{ Ok = ($script:probes -ge 3) } } `
            -Sleeper { param($s) }
        $r.Recovered | Should -BeTrue
        $r.WaitedSeconds | Should -Be 15
    }

    It '等到逾時仍然沒回應：Recovered 是 false，說明裡有等了多久' {
        $r = Restore-DockerEngine -WaitSeconds 20 -PollSeconds 5 `
            -Starter { @{ Started = $true; Detail = '已啟動' } } `
            -Prober  { @{ Ok = $false } } `
            -Sleeper { param($s) }
        $r.Recovered | Should -BeFalse
        $r.WaitedSeconds | Should -Be 20
        $r.Detail | Should -Match '20 秒'
    }

    It '連 Docker Desktop 都找不到：不丟例外，照樣回一個結果' {
        $r = Restore-DockerEngine -WaitSeconds 10 -PollSeconds 5 `
            -Starter { @{ Started = $false; Detail = '找不到 Docker Desktop.exe，沒辦法自動啟動' } } `
            -Prober  { @{ Ok = $false } } `
            -Sleeper { param($s) }
        $r.Recovered | Should -BeFalse
        $r.Started | Should -BeFalse
        $r.Detail | Should -Match '找不到 Docker Desktop.exe'
    }

    It '啟動之前不先探一次：daemon 剛剛才被判定沒回應' {
        # 呼叫端是在前置檢查失敗之後才叫這一支的，開頭再探一次只是白白多等一輪。
        $script:firstProbe = $null
        Restore-DockerEngine -WaitSeconds 5 -PollSeconds 5 `
            -Starter { $script:firstProbe = 'started'; @{ Started = $true; Detail = 'x' } } `
            -Prober  { if (-not $script:firstProbe) { throw '啟動前不該探' }; @{ Ok = $true } } `
            -Sleeper { param($s) } | Out-Null
        $script:firstProbe | Should -Be 'started'
    }
}

Describe 'Start-DockerDesktop' {
    It '候選路徑都不存在：回 Started=false 與看得懂的說明，不丟例外' {
        $r = Start-DockerDesktop -CandidatePaths @((Join-Path $TestDrive 'nope\Docker Desktop.exe'))
        $r.Started | Should -BeFalse
        $r.Detail | Should -Match '找不到'
    }
}
