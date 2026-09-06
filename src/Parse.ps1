# 從 act 的輸出裡抓「到底跑了幾支測試」。
#
# act 會把每個 step 的每一行加上 "[workflow/job]   | " 前綴，還夾雜 ANSI 色碼。
# 先剝乾淨，再用各框架的結尾統計行去認。
#
# 一個都認不出來就回 0 —— 呼叫端會把「0 支的通過」當成沒有驗證，不是通過。
# 這是整套設計的底線，別為了讓某個專案變綠而在這裡放寬。
#
# 各框架同時出現時（例如一個 workflow 裡 pytest 與 jest 各一個 job）數字相加。
# pytest 與 unittest 不會互相重複：Django/unittest 印 "Ran N tests"，pytest 印
# 自己的 "N passed"，兩者不會同時出現在同一段輸出。

$script:AnsiRegex = [regex]'\x1B\[[0-?]*[ -/]*[@-~]'
# "[CI/test]   | " 或 "[CI/test] "（act 自己的訊息行）
$script:ActPrefixRegex = [regex]'^\[[^\]]*\]\s*(?:\|\s?)?'
$script:ExplicitRegex = [regex]'ACTCI_TESTS_RUN=(\d+)'

function Remove-AnsiCodes {
    param([AllowEmptyString()][string]$Text)
    if (-not $Text) { return '' }
    return $script:AnsiRegex.Replace($Text, '')
}

function ConvertFrom-ActOutput {
    # 回傳剝掉前綴與色碼的行陣列。
    param([AllowEmptyString()][string]$Text)
    if (-not $Text) { return @() }
    $lines = (Remove-AnsiCodes $Text) -replace "`r", '' -split "`n"
    return @(foreach ($line in $lines) { $script:ActPrefixRegex.Replace($line, '', 1) })
}

# 每個解析器：收 string[]，回傳 [int] 或 $null（沒認出來）。
$script:TestParsers = [ordered]@{

    'unittest' = {
        # Django / unittest：Ran 2762 tests in 201.465s（可能多個 job 各印一次）
        param([string[]]$Lines)
        $total = 0; $hit = $false
        foreach ($l in $Lines) {
            if ($l -match '^Ran (\d+) tests? in [\d.]+s') { $total += [int]$Matches[1]; $hit = $true }
        }
        if ($hit) { $total } else { $null }
    }

    'pytest' = {
        # ===== 12 passed, 1 skipped, 2 xfailed in 0.31s =====
        # skipped / deselected 不算：它們沒有驗證任何東西。
        param([string[]]$Lines)
        $total = 0; $hit = $false
        foreach ($l in $Lines) {
            if ($l -notmatch '^=+\s*(.+?)\s+in\s+[\d.]+s') { continue }
            $summary = $Matches[1]
            $matches2 = [regex]::Matches($summary, '(\d+) (passed|failed|errors?|xfailed|xpassed)\b')
            if ($matches2.Count -eq 0) {
                if ($summary -match 'no tests ran') { $hit = $true }
                continue
            }
            $hit = $true
            foreach ($m in $matches2) { $total += [int]$m.Groups[1].Value }
        }
        if ($hit) { $total } else { $null }
    }

    'jest' = {
        # Tests:       2 failed, 40 passed, 42 total
        param([string[]]$Lines)
        $total = 0; $hit = $false
        foreach ($l in $Lines) {
            if ($l -match '^Tests:\s+.*?(\d+) total') { $total += [int]$Matches[1]; $hit = $true }
        }
        if ($hit) { $total } else { $null }
    }

    'mocha' = {
        #   12 passing (45ms)
        #   1 failing
        param([string[]]$Lines)
        $total = 0; $hit = $false
        foreach ($l in $Lines) {
            if ($l -match '^\s*(\d+) (passing|failing)\b') { $total += [int]$Matches[1]; $hit = $true }
        }
        if ($hit) { $total } else { $null }
    }

    'go' = {
        # go test -v：--- PASS: TestX (0.00s) 一行一支（子測試也算）
        # 沒有 -v：只有 "ok  pkg  0.012s" 一行一個套件 —— 那是套件數不是測試數，
        # 但至少證明有東西跑過，來源標成 go(packages) 讓人看得出差別。
        param([string[]]$Lines)
        $tests = @($Lines | Where-Object { $_ -match '^\s*--- (PASS|FAIL):' }).Count
        if ($tests -gt 0) { return $tests }
        $null
    }

    'go(packages)' = {
        param([string[]]$Lines)
        if (@($Lines | Where-Object { $_ -match '^\s*--- (PASS|FAIL):' }).Count -gt 0) { return $null }
        $pkgs = @($Lines | Where-Object { $_ -match '^ok\s+\S+\s+[\d.]+s' }).Count
        if ($pkgs -gt 0) { $pkgs } else { $null }
    }

    'cargo' = {
        # test result: ok. 15 passed; 0 failed; 1 ignored; ...（每個測試二進位各印一次）
        param([string[]]$Lines)
        $total = 0; $hit = $false
        foreach ($l in $Lines) {
            if ($l -match '^test result: (?:ok|FAILED)\. (\d+) passed; (\d+) failed;') {
                $total += [int]$Matches[1] + [int]$Matches[2]; $hit = $true
            }
        }
        if ($hit) { $total } else { $null }
    }

    'dotnet' = {
        # Passed! - Failed: 0, Passed: 42, Skipped: 1, Total: 43, Duration: 1 s
        param([string[]]$Lines)
        $total = 0; $hit = $false
        foreach ($l in $Lines) {
            if ($l -match '^(?:Passed|Failed)!\s+-\s+Failed:\s+(\d+),\s+Passed:\s+(\d+)') {
                $total += [int]$Matches[1] + [int]$Matches[2]; $hit = $true
            }
        }
        if ($hit) { $total } else { $null }
    }
}

function Get-TestsRun {
    # 回傳 @{ Count = [int]; Sources = [string[]] }。
    # 專案可在 workflow 最後 echo 一行 ACTCI_TESTS_RUN=N 直接指定，優先於自動辨識。
    param([AllowEmptyString()][string]$Output)

    $lines = ConvertFrom-ActOutput $Output
    $explicit = $null
    foreach ($l in $lines) {
        $m = $script:ExplicitRegex.Match($l)
        if ($m.Success) { $explicit = [int]$m.Groups[1].Value }
    }
    if ($null -ne $explicit) {
        return [pscustomobject]@{ Count = $explicit; Sources = [string[]]@('explicit') }
    }

    $count = 0
    $sources = New-Object System.Collections.Generic.List[string]
    foreach ($name in $script:TestParsers.Keys) {
        $result = & $script:TestParsers[$name] $lines
        if ($null -ne $result) {
            $count += [int]$result
            $sources.Add($name)
        }
    }
    return [pscustomobject]@{ Count = $count; Sources = [string[]]$sources.ToArray() }
}
