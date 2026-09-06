BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\src\actci.psm1') -Force
}

Describe 'Store 基本存取' {
    BeforeEach {
        $script:store = New-Store -Path (Join-Path $TestDrive ('s-' + [guid]::NewGuid().ToString('N')))
    }

    It '預設路徑在 USERPROFILE\.actci，不在 AppData（AppData 會被 Claude 桌面版的 MSIX 重導）' {
        (New-Store).Root | Should -Be (Join-Path $env:USERPROFILE '.actci')
        (New-Store).Root | Should -Not -Match 'AppData'
    }
    It 'Initialize-Store 建出三個目錄' {
        Initialize-Store $script:store | Out-Null
        Test-Path $script:store.Verdicts | Should -BeTrue
        Test-Path $script:store.Logs | Should -BeTrue
    }
    It '存了再讀回來一樣' {
        $v = New-Verdict -Sha 'ABCDEF1234567' -Repo '/r' -Outcome 'passed' -TestsRun 9
        $path = Save-Verdict $script:store $v
        $path | Should -Match 'abcdef1234567\.json$'
        Test-Path "$path.tmp" | Should -BeFalse
        $back = Get-StoredVerdict $script:store 'abcdef1234567'
        $back.TestsRun | Should -Be 9
        $back.Outcome | Should -Be 'passed'
    }
    It '大小寫不同的 sha 找到同一個檔' {
        Save-Verdict $script:store (New-Verdict -Sha 'abcdef1' -Repo '/r' -Outcome 'passed' -TestsRun 1) | Out-Null
        (Get-StoredVerdict $script:store 'ABCDEF1').TestsRun | Should -Be 1
    }
    It '沒有的 sha 回 null' {
        Initialize-Store $script:store | Out-Null
        Get-StoredVerdict $script:store '0000000' | Should -BeNullOrEmpty
    }
    It '不像 sha 的東西丟例外，不會去讀奇怪的路徑' {
        { Get-StoredVerdict $script:store '..\..\x' } | Should -Throw
    }
    It '壞掉的判定檔回 null 並警告' {
        Initialize-Store $script:store | Out-Null
        Set-Content -Path (Join-Path $script:store.Verdicts 'bad0000.json') -Value '{not json'
        $warn = $null
        $r = Get-StoredVerdict $script:store 'bad0000' -WarningVariable warn -WarningAction SilentlyContinue
        $r | Should -BeNullOrEmpty
        $warn | Should -Not -BeNullOrEmpty
    }
}

Describe 'Get-RecentVerdicts' {
    BeforeEach {
        $script:store = New-Store -Path (Join-Path $TestDrive ('r-' + [guid]::NewGuid().ToString('N')))
    }
    It '空 store 回空陣列' {
        @(Get-RecentVerdicts $script:store).Count | Should -Be 0
    }
    It '最近完成的在前，Limit 有效，壞檔跳過' {
        foreach ($i in 1..5) {
            $v = New-Verdict -Sha ('a' * 6 + $i) -Repo '/r' -Outcome 'passed' -TestsRun $i
            $v.FinishedAt = '2026-09-06T00:00:0{0}Z' -f $i
            Save-Verdict $script:store $v | Out-Null
        }
        Set-Content -Path (Join-Path $script:store.Verdicts 'bad0000.json') -Value 'nope'
        $recent = @(Get-RecentVerdicts $script:store -Limit 3 -WarningAction SilentlyContinue)
        $recent.Count | Should -Be 3
        $recent[0].TestsRun | Should -Be 5
        $recent[2].TestsRun | Should -Be 3
    }
    It '沒 FinishedAt 的用 StartedAt 排' {
        $old = New-Verdict -Sha 'aaaaaa1' -Repo '/r'; $old.StartedAt = '2026-01-01T00:00:00Z'
        $new = New-Verdict -Sha 'aaaaaa2' -Repo '/r'; $new.StartedAt = '2026-02-01T00:00:00Z'
        Save-Verdict $script:store $old | Out-Null
        Save-Verdict $script:store $new | Out-Null
        (Get-RecentVerdicts $script:store)[0].Sha | Should -Be 'aaaaaa2'
    }
}

Describe '心跳' {
    BeforeEach {
        $script:store = New-Store -Path (Join-Path $TestDrive ('h-' + [guid]::NewGuid().ToString('N')))
    }
    It '從來沒跳過回 null，不是 0' {
        Get-HeartbeatAge $script:store | Should -BeNullOrEmpty
    }
    It '寫了之後幾秒前算得出來，Note 帶回來' {
        Write-Heartbeat $script:store -Note 'looking'
        $age = Get-HeartbeatAge $script:store
        $age.Seconds | Should -BeLessThan 5
        $age.Note | Should -Be 'looking'
    }
    It '用指定的 Now 算出精確秒數' {
        Write-Heartbeat $script:store
        $age = Get-HeartbeatAge $script:store
        $later = Get-HeartbeatAge $script:store -Now ($age.At.AddSeconds(300))
        [int][Math]::Round($later.Seconds) | Should -Be 300
    }
    It 'Note 裡的換行被壓平，不會弄壞檔案格式' {
        Write-Heartbeat $script:store -Note "a`nb"
        (Get-HeartbeatAge $script:store).Note | Should -Be 'a b'
    }
    It '心跳檔壞掉回 null' {
        Initialize-Store $script:store | Out-Null
        Set-Content -Path $script:store.Heartbeat -Value 'not a date'
        Get-HeartbeatAge $script:store | Should -BeNullOrEmpty
    }
}
