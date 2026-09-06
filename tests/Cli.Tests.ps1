# actci-cli.ps1 是給機器用的入口，離開碼就是介面。這裡用子行程跑它，驗的是離開碼與 JSON。

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\src\actci.psm1') -Force
    $script:Cli = Join-Path $PSScriptRoot '..\actci-cli.ps1'
    function script:Invoke-Cli([string[]]$CliArgs) {
        # 用 Process 直接收 stdout/stderr：PS 5.1 把原生程式的 stderr 包成 ErrorRecord，
        # 在 ErrorActionPreference=Stop 之下連 2>file 都會變成測試失敗。
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = 'powershell.exe'
        $psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$($script:Cli)`" " + (($CliArgs | ForEach-Object { '"' + $_ + '"' }) -join ' ')
        $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
        $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
        $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8; $psi.StandardErrorEncoding = [System.Text.Encoding]::UTF8
        $p = [System.Diagnostics.Process]::Start($psi)
        $so = $p.StandardOutput.ReadToEndAsync(); $se = $p.StandardError.ReadToEndAsync()
        $p.WaitForExit()
        [pscustomobject]@{ ExitCode = $p.ExitCode; Output = $so.Result.TrimEnd(); Error = $se.Result }
    }
}

Describe 'gate' {
    BeforeEach {
        $script:state = Join-Path $TestDrive ('cli-' + [guid]::NewGuid().ToString('N'))
        $script:store = Initialize-Store (New-Store -Path $script:state)
    }
    It '沒有判定 → 2' {
        $r = Invoke-Cli @('gate', ('a' * 40), '--state', $script:state)
        $r.ExitCode | Should -Be 2
        $r.Output | Should -Match '沒有判定紀錄'
    }
    It '值得相信的通過 → 0，--json 有 trustworthy=true' {
        Save-Verdict $script:store (New-Verdict -Sha ('b' * 40) -Repo '/r' -Outcome 'passed' -TestsRun 12 -TestsSource @('pytest')) | Out-Null
        $r = Invoke-Cli @('gate', ('b' * 40), '--state', $script:state, '--json')
        $r.ExitCode | Should -Be 0
        $o = $r.Output | ConvertFrom-Json
        $o.trustworthy | Should -BeTrue
        $o.testsRun | Should -Be 12
        $o.state | Should -Be 'success'
    }
    It 'passed 但 0 支 → 1（這是整個設計的重點）' {
        Save-Verdict $script:store (New-Verdict -Sha ('c' * 40) -Repo '/r' -Outcome 'passed' -TestsRun 0) | Out-Null
        (Invoke-Cli @('gate', ('c' * 40), '--state', $script:state)).ExitCode | Should -Be 1
    }
    It 'failed → 1' {
        Save-Verdict $script:store (New-Verdict -Sha ('d' * 40) -Repo '/r' -Outcome 'failed' -TestsRun 5) | Out-Null
        (Invoke-Cli @('gate', ('d' * 40), '--state', $script:state)).ExitCode | Should -Be 1
    }
    It '沒給 sha → 2，用法訊息在 stderr' {
        $r = Invoke-Cli @('gate', '--state', $script:state)
        $r.ExitCode | Should -Be 2
        $r.Error | Should -Match 'gate 需要'
    }
}

Describe 'status / verdict / help' {
    BeforeAll {
        $script:state = Join-Path $TestDrive ('cli-s-' + [guid]::NewGuid().ToString('N'))
        $script:store = Initialize-Store (New-Store -Path $script:state)
        $v = New-Verdict -Sha ('e' * 40) -Repo '/r' -Outcome 'passed' -TestsRun 7 -TestsSource @('jest'); $v.FinishedAt = '2026-09-06T01:00:00Z'
        Save-Verdict $script:store $v | Out-Null
        Write-Heartbeat -Store $script:store -Note 'looking'
    }
    It 'status 永遠 0，--json 有心跳與 recent' {
        $r = Invoke-Cli @('status', '--state', $script:state, '--json')
        $r.ExitCode | Should -Be 0
        $o = $r.Output | ConvertFrom-Json
        $o.heartbeat.note | Should -Be 'looking'
        @($o.recent).Count | Should -Be 1
        $o.recent[0].trustworthy | Should -BeTrue
        $o.store | Should -Be $script:state
    }
    It 'status 人讀格式有 [ok] 標記，純 ASCII 不會在 cp950 主控台炸掉' {
        $r = Invoke-Cli @('status', '--state', $script:state)
        $r.Output | Should -Match '\[ok\] eeeeeeeeeeee'
    }
    It 'verdict --json 是完整判定 JSON' {
        $r = Invoke-Cli @('verdict', ('e' * 40), '--state', $script:state, '--json')
        $r.ExitCode | Should -Be 0
        ($r.Output | ConvertFrom-Json).TestsRun | Should -Be 7
    }
    It 'verdict 沒有 → 2' {
        (Invoke-Cli @('verdict', ('f' * 40), '--state', $script:state)).ExitCode | Should -Be 2
    }
    It 'help → 0，未知指令 → 1' {
        (Invoke-Cli @('help')).ExitCode | Should -Be 0
        (Invoke-Cli @('nonsense')).ExitCode | Should -Be 1
    }
}
