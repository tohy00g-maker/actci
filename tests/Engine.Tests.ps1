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
        $cmd | Should -Match 'cd "\$tmp" && NO_COLOR=1 TERM=dumb act .push. -j .test. 2>&1; rc=\$\?; cd /; rm -rf "\$tmp"; exit \$rc$'
        $cmd | Should -Match '^export PATH="\$HOME/.local/bin:\$PATH"; '
    }
    It '沒 sha：直接 cd 進 repo' {
        $cmd = New-ActCommand -RepoPath '/home/me/repo' -Event 'pull_request'
        $cmd | Should -Match "cd '/home/me/repo' && NO_COLOR=1 TERM=dumb act 'pull_request' 2>&1$"
        $cmd | Should -Not -Match 'archive'
    }
    It 'ExtraArgs 逐一加引號，RawArgs 原樣附在後面' {
        $cmd = New-ActCommand -RepoPath '/r' -ExtraArgs @('-W', ".github/workflows/it's.yml") -RawArgs '--env FOO=bar'
        $cmd | Should -Match "act 'push' '-W' '.github/workflows/it'\\''s.yml' --env FOO=bar 2>&1"
    }
    It 'repo 路徑有空白與單引號也安全' {
        $cmd = New-ActCommand -RepoPath "/home/me/my repo's"
        $cmd | Should -Match "cd '/home/me/my repo'\\''s' &&"
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
        $v = Invoke-ActRun -RepoPath '/r' -Sha 'abc1234'
        $v.Outcome | Should -Be 'errored'
        $v.Note | Should -Match 'docker'
        @($script:calls | Where-Object { $_ -like '*archive*' }).Count | Should -Be 0
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
