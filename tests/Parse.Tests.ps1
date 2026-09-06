BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\src\actci.psm1') -Force

    # 真實 act 輸出的形狀：每行帶 [workflow/job] 前綴，step 輸出再加 "| "。
    $script:ActPytest = @'
[CI/test] 🚀  Start image=catthehacker/ubuntu:act-latest
[CI/test]   🐳  docker pull image=catthehacker/ubuntu:act-latest platform=linux/amd64 username= forcePull=true
[CI/test] ⭐ Run Main actions/checkout@v4
[CI/test]   ✅  Success - Main actions/checkout@v4
[CI/test] ⭐ Run Main pytest
[CI/test]   | ============================= test session starts ==============================
[CI/test]   | platform linux -- Python 3.12.3, pytest-8.2.0, pluggy-1.5.0
[CI/test]   | collected 13 items
[CI/test]   |
[CI/test]   | tests/test_a.py ........                                                 [ 61%]
[CI/test]   | tests/test_b.py ....s                                                    [100%]
[CI/test]   |
[CI/test]   | ======================== 12 passed, 1 skipped in 0.31s =========================
[CI/test]   ✅  Success - Main pytest
[CI/test] 🏁  Job succeeded
'@

    $script:ActDjango = @'
[CI/checks] ⭐ Run Main python manage.py test
[CI/checks]   | Creating test database for alias 'default'...
[CI/checks]   | ....................
[CI/checks]   | ----------------------------------------------------------------------
[CI/checks]   | Ran 2762 tests in 201.465s
[CI/checks]   |
[CI/checks]   | OK
[CI/checks]   | Destroying test database for alias 'default'...
[CI/checks]   ✅  Success - Main python manage.py test
'@

    $script:ActJest = @'
[CI/web]   | PASS src/app.test.ts
[CI/web]   |
[CI/web]   | Test Suites: 3 passed, 3 total
[CI/web]   | Tests:       2 failed, 40 passed, 42 total
[CI/web]   | Snapshots:   0 total
[CI/web]   | Time:        3.12 s
'@
}

Describe 'ConvertFrom-ActOutput' {
    It '剝掉 [job] 前綴與 "| "' {
        $lines = ConvertFrom-ActOutput "[CI/test]   | hello`n[CI/test] ⭐ Run Main x"
        $lines[0] | Should -Be 'hello'
        $lines[1] | Should -Be '⭐ Run Main x'
    }
    It '去掉 ANSI 色碼與 CR' {
        $esc = [char]27   # PS 5.1 沒有 `e
        $lines = ConvertFrom-ActOutput "${esc}[32mgreen${esc}[0m`r`nnext"
        $lines[0] | Should -Be 'green'
        $lines[1] | Should -Be 'next'
    }
    It '空字串回空陣列' {
        @(ConvertFrom-ActOutput '').Count | Should -Be 0
    }
}

Describe 'Get-TestsRun 各框架' {
    It 'pytest：skipped 不算' {
        $r = Get-TestsRun $script:ActPytest
        $r.Count | Should -Be 12
        @($r.Sources) | Should -Be @('pytest')
    }
    It 'pytest：failed 與 error 都算跑過' {
        $r = Get-TestsRun '==== 3 failed, 10 passed, 1 error, 2 xfailed in 1.00s ===='
        $r.Count | Should -Be 16
    }
    It 'pytest：no tests ran 認得但是 0' {
        $r = Get-TestsRun '============================ no tests ran in 0.01s ============================='
        $r.Count | Should -Be 0
        @($r.Sources) | Should -Be @('pytest')
    }
    It 'Django / unittest：Ran N tests' {
        $r = Get-TestsRun $script:ActDjango
        $r.Count | Should -Be 2762
        @($r.Sources) | Should -Be @('unittest')
    }
    It 'unittest：單數 Ran 1 test 也認得' {
        (Get-TestsRun 'Ran 1 test in 0.001s').Count | Should -Be 1
    }
    It 'jest：total 含 failed' {
        $r = Get-TestsRun $script:ActJest
        $r.Count | Should -Be 42
        @($r.Sources) | Should -Be @('jest')
    }
    It 'mocha：passing 加 failing' {
        $r = Get-TestsRun "  12 passing (45ms)`n  1 failing"
        $r.Count | Should -Be 13
        @($r.Sources) | Should -Be @('mocha')
    }
    It 'go test -v：數 --- PASS/FAIL 行' {
        $out = "=== RUN   TestA`n--- PASS: TestA (0.00s)`n=== RUN   TestB`n--- FAIL: TestB (0.01s)`n    --- PASS: TestB/sub (0.00s)`nFAIL`nFAIL`tgithub.com/x/y`t0.012s"
        $r = Get-TestsRun $out
        $r.Count | Should -Be 3
        @($r.Sources) | Should -Be @('go')
    }
    It 'go test 沒有 -v：只有套件數，來源標 go(packages)' {
        $r = Get-TestsRun "ok  `tgithub.com/x/y`t0.012s`nok  `tgithub.com/x/z`t0.050s"
        $r.Count | Should -Be 2
        @($r.Sources) | Should -Be @('go(packages)')
    }
    It 'cargo：多個二進位相加，ignored 不算' {
        $out = "test result: ok. 15 passed; 0 failed; 1 ignored; 0 measured; 0 filtered out; finished in 0.02s`ntest result: FAILED. 3 passed; 1 failed; 0 ignored; 0 measured; 0 filtered out; finished in 0.01s"
        $r = Get-TestsRun $out
        $r.Count | Should -Be 19
        @($r.Sources) | Should -Be @('cargo')
    }
    It 'dotnet：Failed + Passed，Skipped 不算' {
        $r = Get-TestsRun 'Passed! - Failed: 0, Passed: 42, Skipped: 1, Total: 43, Duration: 1 s - Tests.dll (net8.0)'
        $r.Count | Should -Be 42
        @($r.Sources) | Should -Be @('dotnet')
    }
}

Describe 'Get-TestsRun 組合情況' {
    It '什麼都認不出來回 0 與空來源' {
        $r = Get-TestsRun "[CI/build] ⭐ Run Main npm run build`n[CI/build]   | done`n[CI/build] 🏁  Job succeeded"
        $r.Count | Should -Be 0
        @($r.Sources).Count | Should -Be 0
    }
    It '多個 job 不同框架相加' {
        $r = Get-TestsRun ($script:ActPytest + "`n" + $script:ActJest)
        $r.Count | Should -Be 54
        @($r.Sources) | Should -Be @('pytest', 'jest')
    }
    It '同框架多個 job 相加' {
        $r = Get-TestsRun ($script:ActDjango + "`n" + $script:ActDjango)
        $r.Count | Should -Be 5524
    }
    It 'ACTCI_TESTS_RUN=N 明講的優先，且只算最後一個' {
        $r = Get-TestsRun ($script:ActPytest + "`n[CI/test]   | ACTCI_TESTS_RUN=7`n[CI/test]   | ACTCI_TESTS_RUN=99")
        $r.Count | Should -Be 99
        @($r.Sources) | Should -Be @('explicit')
    }
    It '帶 ANSI 色碼的統計行也認得' {
        $esc = [char]27
        $r = Get-TestsRun "[CI/t]   | ${esc}[32m============ ${esc}[1m5 passed${esc}[0m${esc}[32m in 0.10s ============${esc}[0m"
        $r.Count | Should -Be 5
    }
}
