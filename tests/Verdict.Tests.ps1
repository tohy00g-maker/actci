BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\src\actci.psm1') -Force
}

Describe 'New-Verdict' {
    It '預設是 errored，TestsRun 0' {
        $v = New-Verdict -Sha 'abc1234' -Repo '/home/me/repo'
        $v.Outcome | Should -Be 'errored'
        $v.TestsRun | Should -Be 0
        $v.Schema | Should -Be 1
        $v.Engine | Should -Be 'act'
        $v.StartedAt | Should -Match '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$'
    }
    It '不認得的 Outcome 直接丟例外' {
        { New-Verdict -Sha 'abc1234' -Repo 'r' -Outcome 'green' } | Should -Throw
    }
}

Describe '通過與值得相信是兩個問題' {
    It 'passed 且 TestsRun > 0 才 trustworthy' {
        $v = New-Verdict -Sha 'abc1234' -Repo 'r' -Outcome 'passed' -TestsRun 12
        Test-VerdictPassed $v | Should -BeTrue
        Test-VerdictTrustworthy $v | Should -BeTrue
    }
    It 'passed 但 TestsRun = 0 是 passed 卻不 trustworthy' {
        $v = New-Verdict -Sha 'abc1234' -Repo 'r' -Outcome 'passed' -TestsRun 0
        Test-VerdictPassed $v | Should -BeTrue
        Test-VerdictTrustworthy $v | Should -BeFalse
    }
    It 'failed 兩個都不是' {
        $v = New-Verdict -Sha 'abc1234' -Repo 'r' -Outcome 'failed' -TestsRun 12
        Test-VerdictPassed $v | Should -BeFalse
        Test-VerdictTrustworthy $v | Should -BeFalse
    }
}

Describe 'Get-VerdictHeadline' {
    It '通過時一定講跑了幾支與來源' {
        $v = New-Verdict -Sha 'abc1234' -Repo 'r' -Outcome 'passed' -TestsRun 42 -TestsSource @('pytest')
        $v.Seconds = 12.6
        Get-VerdictHeadline $v | Should -Be '通過（42 支，13 秒，pytest）'
    }
    It '0 支的通過講成沒有驗證' {
        $v = New-Verdict -Sha 'abc1234' -Repo 'r' -Outcome 'passed' -TestsRun 0
        Get-VerdictHeadline $v | Should -Match '沒有驗證'
    }
    It 'failed 帶跑了幾支' {
        $v = New-Verdict -Sha 'abc1234' -Repo 'r' -Outcome 'failed' -TestsRun 7
        Get-VerdictHeadline $v | Should -Match '^失敗（跑了 7 支'
    }
    It 'errored 帶 Note' {
        $v = New-Verdict -Sha 'abc1234' -Repo 'r' -Outcome 'errored' -Note 'Docker 用不了'
        Get-VerdictHeadline $v | Should -Be 'CI 自己出問題：Docker 用不了'
    }
    It 'errored 沒 Note 也不會是空字串' {
        $v = New-Verdict -Sha 'abc1234' -Repo 'r'
        Get-VerdictHeadline $v | Should -Be 'CI 自己出問題：沒有說明'
    }
}

Describe 'JSON 往返' {
    It '所有欄位存回來一樣' {
        $v = New-Verdict -Sha 'deadbeef' -Repo '/r' -Outcome 'failed' -TestsRun 3 -TestsSource @('jest', 'pytest') -Event 'push' -Job 'test' -Note 'n'
        $v.Seconds = 4.5
        $v.FinishedAt = '2026-09-06T01:02:03Z'
        $v.LogPath = 'C:\x\deadbeef.log'
        $v.Steps = @((New-VerdictStep -Name 'act' -ExitCode 1 -Seconds 4.5))
        $back = ConvertFrom-VerdictJson (ConvertTo-VerdictJson $v)
        $back.Sha | Should -Be 'deadbeef'
        $back.Outcome | Should -Be 'failed'
        $back.TestsRun | Should -Be 3
        @($back.TestsSource) | Should -Be @('jest', 'pytest')
        $back.Event | Should -Be 'push'
        $back.Job | Should -Be 'test'
        $back.Seconds | Should -Be 4.5
        $back.FinishedAt | Should -Be '2026-09-06T01:02:03Z'
        $back.LogPath | Should -Be 'C:\x\deadbeef.log'
        @($back.Steps).Count | Should -Be 1
        $back.Steps[0].Name | Should -Be 'act'
        $back.Steps[0].ExitCode | Should -Be 1
        $back.Note | Should -Be 'n'
    }
    It '空 Steps 與空 TestsSource 往返後還是空陣列' {
        $v = New-Verdict -Sha 'deadbeef' -Repo '/r' -Outcome 'passed' -TestsRun 1
        $back = ConvertFrom-VerdictJson (ConvertTo-VerdictJson $v)
        @($back.Steps).Count | Should -Be 0
        @($back.TestsSource).Count | Should -Be 0
    }
    It '不認得的欄位被忽略，不會炸' {
        $json = '{"Sha":"abc1234","Repo":"/r","Outcome":"passed","TestsRun":5,"FutureField":{"x":1}}'
        $back = ConvertFrom-VerdictJson $json
        $back.TestsRun | Should -Be 5
        $back.PSObject.Properties['FutureField'] | Should -BeNullOrEmpty
    }
    It '缺 Sha 直接丟例外' {
        { ConvertFrom-VerdictJson '{"Repo":"/r"}' } | Should -Throw
    }
    It '認不得的 Outcome 讀進來變 errored，不會變成通過' {
        $back = ConvertFrom-VerdictJson '{"Sha":"abc1234","Repo":"/r","Outcome":"green","TestsRun":5}'
        $back.Outcome | Should -Be 'errored'
        Test-VerdictTrustworthy $back | Should -BeFalse
    }
}
