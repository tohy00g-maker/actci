BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\src\actci.psm1') -Force
}

Describe 'Get-StatusState' {
    It 'passed 且有測試數 -> success' {
        Get-StatusState (New-Verdict -Sha 'abc1234' -Repo 'r' -Outcome 'passed' -TestsRun 1) | Should -Be 'success'
    }
    It 'passed 但 0 支 -> failure，不是 success' {
        Get-StatusState (New-Verdict -Sha 'abc1234' -Repo 'r' -Outcome 'passed' -TestsRun 0) | Should -Be 'failure'
    }
    It 'failed -> failure' {
        Get-StatusState (New-Verdict -Sha 'abc1234' -Repo 'r' -Outcome 'failed' -TestsRun 10) | Should -Be 'failure'
    }
    It 'errored -> error' {
        Get-StatusState (New-Verdict -Sha 'abc1234' -Repo 'r' -Outcome 'errored') | Should -Be 'error'
    }
}

Describe 'New-StatusPayload' {
    It '預設 context 是 actci，description 是 headline' {
        $v = New-Verdict -Sha 'abc1234' -Repo 'r' -Outcome 'passed' -TestsRun 3 -TestsSource @('jest')
        $p = New-StatusPayload $v
        $p.state | Should -Be 'success'
        $p.context | Should -Be 'actci'
        $p.description | Should -Be (Get-VerdictHeadline $v)
        $p.Contains('target_url') | Should -BeFalse
    }
    It 'context 與 target_url 可指定' {
        $v = New-Verdict -Sha 'abc1234' -Repo 'r' -Outcome 'passed' -TestsRun 3
        $p = New-StatusPayload $v -Context 'actci/manual' -TargetUrl 'https://example.test/log'
        $p.context | Should -Be 'actci/manual'
        $p.target_url | Should -Be 'https://example.test/log'
    }
    It 'description 截到 140 字' {
        $v = New-Verdict -Sha 'abc1234' -Repo 'r' -Outcome 'errored' -Note ('x' * 300)
        (New-StatusPayload $v).description.Length | Should -Be 140
    }
    It '轉成 JSON 後欄位名是 GitHub 要的小寫' {
        $v = New-Verdict -Sha 'abc1234' -Repo 'r' -Outcome 'failed' -TestsRun 2
        $json = New-StatusPayload $v | ConvertTo-Json -Compress
        $json | Should -Match '"state":"failure"'
        $json | Should -Match '"context":"actci"'
    }
}
