# runner/ 底下是 GitHub self-hosted runner 的重啟與看門狗腳本，從 localci 搬來。
# 這些測試是 localci 的 test_restart_runner_script.py 與 test_runner_watchdog_script.py
# 逐條翻成 Pester，內容不改 —— 它們守的是 2026-08-28 與 08-31 兩次事故換來的順序。
#
# 用讀原始碼的方式測：擋得住的是「有人把等待拿掉」或「把砍的動作搬到等待前面」。
# 找位置時要在**去掉整行註解**的原始碼裡找，否則檔頭註解裡提到的字會先命中。

BeforeAll {
    $script:RunnerDir = Join-Path $PSScriptRoot '..\runner'
    $script:Restart = Join-Path $script:RunnerDir 'restart_runner.ps1'
    $script:Watchdog = Join-Path $script:RunnerDir 'runner_watchdog.ps1'
    $script:Installer = Join-Path $script:RunnerDir 'install_runner_watchdog.ps1'

    function script:Read-Source([string]$path) {
        [System.IO.File]::ReadAllText($path, [System.Text.Encoding]::UTF8)   # 自動吃掉 BOM
    }
    function script:Remove-CommentLines([string]$source) {
        ($source -split "`r?`n" | Where-Object { -not $_.TrimStart().StartsWith('#') }) -join "`n"
    }
    function script:Find-At([string]$haystack, [string]$needle) {
        $i = $haystack.IndexOf($needle)
        if ($i -lt 0) { throw "找不到：$needle" }
        return $i
    }
    function script:Test-Bom([string]$path) {
        $b = [System.IO.File]::ReadAllBytes($path)
        return ($b.Length -ge 3 -and $b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF)
    }
}

Describe '三支腳本 PowerShell 5.1 讀得懂' {
    It '<name> 帶 UTF-8 BOM' -ForEach @(
        @{ name = 'restart_runner.ps1' }, @{ name = 'runner_watchdog.ps1' }, @{ name = 'install_runner_watchdog.ps1' }
    ) {
        $path = Join-Path $script:RunnerDir $name
        Test-Path $path | Should -BeTrue
        Test-Bom $path | Should -BeTrue
    }
    It '<name> 沒有語法錯誤' -ForEach @(
        @{ name = 'restart_runner.ps1' }, @{ name = 'runner_watchdog.ps1' }, @{ name = 'install_runner_watchdog.ps1' },
        @{ name = 'install_ci_runner_banner.ps1' }, @{ name = '_runner_common.ps1' }
    ) {
        $errors = $null
        [System.Management.Automation.PSParser]::Tokenize((Read-Source (Join-Path $script:RunnerDir $name)), [ref]$errors) | Out-Null
        @($errors).Count | Should -Be 0
    }
}

Describe 'restart_runner.ps1 的順序不能亂' {
    BeforeAll { $script:src = Read-Source $script:Restart }

    It '先等它自己結束，還在才動手砍' {
        (Find-At $script:src 'Start-Sleep -Milliseconds 500') | Should -BeLessThan (Find-At $script:src 'Stop-Process -Id $proc.Id -Force')
    }
    It '寬限時間可設定且不是零' {
        $script:src | Should -Match '\[int\]\$GraceSeconds = 15'
    }
    It '確認乾淨之後才啟動' {
        (Find-At $script:src '沒有繼續啟動') | Should -BeLessThan (Find-At $script:src 'Start-ScheduledTask -TaskName $TaskName')
    }
    It '停止排在啟動之前' {
        (Find-At $script:src 'Stop-ScheduledTask -TaskName $TaskName') | Should -BeLessThan (Find-At $script:src 'Start-ScheduledTask -TaskName $TaskName')
    }
    It '看的是日誌裡的 Listening for Jobs，不只看行程在不在' {
        $script:src.Contains("-match 'Listening for Jobs'") | Should -BeTrue
    }
    It '沒接上是 Write-Error，不是聳肩' {
        $script:src.Substring((Find-At $script:src '== 4/4')) | Should -Match 'Write-Error'
    }
    It '砍不掉的時候說要用系統管理員' {
        $script:src.Contains('請用系統管理員身分再跑一次') | Should -BeTrue
    }
    It '強殺過就把等待上限放寬' {
        $script:src.Contains('$wasForceKilled = $true') | Should -BeTrue
        $script:src.Contains('if ($wasForceKilled) { $WaitSeconds * 2 }') | Should -BeTrue
    }
    It '接上的判斷讀最後十行，不只最後一行' {
        $script:src.Contains("`$tail[-1] -match 'Listening for Jobs'") | Should -BeFalse
        $script:src.Contains('-Tail 10') | Should -BeTrue
    }
    It '成功路徑不在空陣列上取 Id（去掉註解後看）' {
        $report = $script:src.Substring((Find-At $script:src '$proc = @(Get-Process'))
        $code = Remove-CommentLines $report
        $code.Contains('$proc.Id') | Should -BeFalse
        $code.Contains('$proc.Count') | Should -BeTrue
    }
    It '行程清單空的時候說「查不到」' {
        $report = $script:src.Substring((Find-At $script:src '$pids = '))
        $report.Substring(0, [Math]::Min(200, $report.Length)) | Should -Match '查不到'
    }
}

Describe 'runner_watchdog.ps1 不能變成它要防的那種東西' {
    BeforeAll {
        $script:wsrc = Read-Source $script:Watchdog
        $script:wcode = Remove-CommentLines $script:wsrc
    }
    It 'Runner.Listener 活著就結束，排在呼叫重啟之前' {
        (Find-At $script:wcode 'Write-Line "正常：Runner.Listener 在') | Should -BeLessThan (Find-At $script:wcode '-File $restart')
    }
    It '不自己重寫停止流程' {
        $script:wsrc.Contains('Stop-ScheduledTask') | Should -BeFalse
        $script:wsrc.Contains('Stop-Process') | Should -BeFalse
    }
    It '重啟前先看冷卻' {
        (Find-At $script:wcode '$CooldownMinutes') | Should -BeLessThan (Find-At $script:wcode '-File $restart')
    }
    It '一切正常也寫日誌' {
        $script:wsrc.Contains('Write-Line "正常') | Should -BeTrue
    }
    It '寫不了日誌不會讓看門狗死掉' {
        $tail = $script:wsrc.Substring((Find-At $script:wsrc 'function Write-Line'))
        # .NET 的 Split(string) 是拆單一字元，不是子字串；用 IndexOf 切。
        $tail.Substring(0, $tail.IndexOf('$listener')) | Should -Match 'catch'
    }
}

Describe 'install_runner_watchdog.ps1 不會留下一個安靜壞掉的看門狗' {
    BeforeAll {
        $script:isrc = Read-Source $script:Installer
        $script:icode = Remove-CommentLines $script:isrc
    }
    It '裝完跑一次而且失敗要大聲' {
        $script:isrc | Should -Match 'Start-ScheduledTask'
        $script:isrc | Should -Match 'LastTaskResult'
        $script:isrc | Should -Match 'Write-Error'
    }
    It '借用被看的那個工作的身分' {
        $script:isrc.Contains('$watched.Principal.UserId') | Should -BeTrue
        $script:isrc.Contains('$watched.Principal.LogonType') | Should -BeTrue
    }
    It '跑兩次不會長出第二個' {
        $u = $script:isrc.IndexOf('Unregister-ScheduledTask'); $r = $script:isrc.IndexOf('Register-ScheduledTask `')
        $u | Should -BeGreaterOrEqual 0
        $r | Should -BeGreaterOrEqual 0
        $u | Should -BeLessThan $r
    }
    It '沒東西可看就拒絕' {
        $script:isrc.Contains('看門狗沒有東西可以看') | Should -BeTrue
    }
    It '有一個不等登入的觸發器，而且兩個都註冊' {
        $script:icode.Contains('$nowTrigger = New-ScheduledTaskTrigger -Once') | Should -BeTrue
        $script:icode.Contains('$trigger = @($nowTrigger, $logonTrigger)') | Should -BeTrue
    }
    It '驗 NextRunTime，不只驗手動跑一次' {
        $script:icode.Contains('if (-not $info.NextRunTime)') | Should -BeTrue
    }
}
